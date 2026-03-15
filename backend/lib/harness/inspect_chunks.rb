# frozen_string_literal: true

# Inspect raw LLM chunk responses for a room's battle map.
# Runs 4 chunks (corners + center) and prints raw JSON + prompt for each.
#
# Usage: cd backend && bundle exec ruby tmp/inspect_chunks.rb [room_id]

require_relative '../app'
require 'vips'
require 'base64'

ROOM_ID = (ARGV[0] || 155).to_i

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room
abort "Room #{ROOM_ID} has no battle map image" unless room.battle_map_image_url

image_path = "public/#{room.battle_map_image_url}"
abort "Image not found: #{image_path}" unless File.exist?(image_path)

puts "=== Chunk Response Inspector ==="
puts "Room: #{ROOM_ID} (#{room.name})"
puts "Image: #{image_path}"
puts

# Use the service's internals via send
svc = AIBattleMapGeneratorService.new(room, debug: true)

# Replicate the pipeline setup
hex_coords = svc.send(:generate_hex_coordinates)
min_x = hex_coords.map { |x, _| x }.min
min_y = hex_coords.map { |_, y| y }.min

base = Vips::Image.new_from_file(image_path)
img_width = base.width
img_height = base.height
hex_pixel_map = svc.send(:build_hex_pixel_map, hex_coords, min_x, min_y, img_width, img_height)

# Build coord_lookup (needed by crop/overlay methods)
svc.instance_variable_set(:@coord_lookup, {})
hex_pixel_map.each do |_label, info|
  next unless info.is_a?(Hash) && info[:hx]
  svc.instance_variable_get(:@coord_lookup)[[info[:hx], info[:hy]]] = info
end

chunks = svc.send(:build_spatial_chunks, hex_coords, 25)

puts "Total chunks: #{chunks.length}"
puts "Total hexes: #{hex_coords.length}"
puts

# Run overview pass
puts "--- Running overview pass ---"
overview_data = svc.send(:run_overview_pass, image_path)
abort "Overview pass failed" unless overview_data

scene_description = overview_data['scene_description'] || ''
present_types = overview_data['present_types'] || []
type_names = present_types.map { |t| t['type_name'] }
type_names.delete('open_floor')
type_names.delete('other')
type_names << 'off_map' unless type_names.include?('off_map')
type_names.uniq!

puts "Scene: #{scene_description}"
puts "Types: #{type_names.join(', ')}"
puts

constrained_schema = svc.send(:build_grouped_schema, type_names)
api_key = AIProviderService.api_key_for('google_gemini')
anthropic_key = AIProviderService.api_key_for('anthropic')

# Pick chunks to inspect: first, last, middle, and one from center
inspect_indices = [0, chunks.length / 4, chunks.length / 2, chunks.length - 1].uniq

inspect_indices.each do |idx|
  chunk_info = chunks[idx]
  chunk = chunk_info[:coords]
  grid_pos = chunk_info[:grid_pos]

  puts "=" * 70
  puts "CHUNK #{idx + 1}/#{chunks.length} (grid: #{grid_pos[:gx]},#{grid_pos[:gy]} of #{grid_pos[:nx]}x#{grid_pos[:ny]})"
  puts "  Hexes: #{chunk.length}"
  puts

  seq = svc.send(:build_sequential_labels, chunk)
  hex_list_str = chunk.sort_by { |hx, hy| [hy, hx] }.map { |hx, hy| seq[:labels][[hx, hy]] }.join(', ')

  crop_result = svc.send(:crop_image_for_chunk, base, chunk, hex_pixel_map, img_width, img_height)

  # Save the labeled crop for visual inspection
  labeled_crop = svc.send(:overlay_sequential_labels_on_crop, crop_result, chunk, seq[:labels])
  crop_path = "tmp/chunk_#{idx}_labeled.png"
  File.binwrite(crop_path, labeled_crop)
  puts "  Labeled crop saved: #{crop_path}"

  prompt = svc.send(:build_grouped_chunk_prompt, hex_list_str, scene_description, type_names)
  puts "  --- PROMPT ---"
  puts prompt.lines.map { |l| "  #{l}" }.join
  puts

  cropped_base64 = Base64.strict_encode64(labeled_crop)

  # Run both Gemini and Haiku on the same chunk
  providers = [
    {
      name: 'gemini-3-flash',
      adapter: LLM::Adapters::GeminiAdapter,
      model: 'gemini-3-flash-preview',
      api_key: api_key,
      messages: [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/png', data: cropped_base64 },
        { type: 'text', text: prompt }
      ] }],
      extra: { response_schema: constrained_schema },
      options: { max_tokens: 65536, timeout: 120, temperature: 0, thinking_level: 'minimal' }
    },
    {
      name: 'claude-haiku-4.5',
      adapter: LLM::Adapters::AnthropicAdapter,
      model: 'claude-haiku-4-5-20251001',
      api_key: anthropic_key,
      messages: [{ role: 'user', content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: cropped_base64 } },
        { type: 'text', text: prompt }
      ] }],
      extra: {
        tools: [{
          name: 'classify_hexes',
          description: 'Submit hex classification results',
          parameters: {
            type: 'object',
            properties: {
              objects: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    description: { type: 'string', description: 'Brief description of this object' },
                    hex_type: { type: 'string', enum: type_names, description: 'Classification type' },
                    size_hexes: { type: 'integer', description: 'How many hexes this object covers' },
                    labels: { type: 'array', items: { type: 'string' }, description: 'Hex numbers this object covers' }
                  },
                  required: %w[hex_type size_hexes labels]
                }
              }
            },
            required: %w[objects]
          }
        }]
      },
      options: { max_tokens: 4096, timeout: 120, temperature: 0 },
      tool_mode: true
    }
  ]

  providers.each do |prov|
    print "  [#{prov[:name]}] "
    $stdout.flush

    response = prov[:adapter].generate(
      messages: prov[:messages],
      model: prov[:model],
      api_key: prov[:api_key],
      options: prov[:options],
      **prov[:extra]
    )

    if response[:success] || response[:tool_calls]
      # Handle tool call responses (Anthropic with forced tool use)
      if response[:tool_calls]&.any?
        args = response[:tool_calls].first[:arguments]
        objects = args['objects'] || []
        objects.each do |obj|
          labels = (obj['labels'] || []).map(&:to_s)
          desc = obj['description'] ? " — #{obj['description']}" : ''
          size = obj['size_hexes'] ? " (size: #{obj['size_hexes']})" : ''
          puts "    #{obj['hex_type']}: [#{labels.join(', ')}] (#{labels.length} hexes)#{size}#{desc}"
        end
        # Convert to content string for parse_grouped_chunk
        content = { 'objects' => objects }.to_json
      else
        content = response[:text] || response[:content]
      end

      chunk_results = svc.send(:parse_grouped_chunk, content, seq[:reverse], allowed_types: type_names)
      tagged = chunk_results.length
      by_type = chunk_results.group_by { |r| r['hex_type'] }.transform_values(&:length)
      puts "    => #{tagged}/#{chunk.length} tagged (#{(100.0 * tagged / chunk.length).round(1)}%) — #{by_type.sort_by { |_, v| -v }.to_h}"
    else
      puts "    FAILED: #{response[:error]}"
    end
    puts
  end
  puts
end
