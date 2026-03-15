# frozen_string_literal: true

# Visualize normalizer CHANGES only (demotions=red, promotions=green)
# and output per-hex signals for manual correctness assessment.
# Caches classification results so we can iterate on normalization fast.
#
# Usage: cd backend && bundle exec ruby tmp/normalizer_regression.rb [room_id]

require_relative '../app'
require 'vips'
require 'base64'
require 'json'

ROOM_ID = (ARGV[0] || 155).to_i

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room
abort "Room #{ROOM_ID} has no battle map image" unless room.battle_map_image_url

image_path = "public/#{room.battle_map_image_url}"
abort "Image not found: #{image_path}" unless File.exist?(image_path)

puts "=== Normalizer Regression Analysis ==="
puts "Room: #{ROOM_ID} (#{room.name})"

svc = AIBattleMapGeneratorService.new(room, debug: true)
hex_coords = svc.send(:generate_hex_coordinates)
min_x = hex_coords.map { |x, _| x }.min
min_y = hex_coords.map { |_, y| y }.min

base = Vips::Image.new_from_file(image_path)
img_w = base.width
img_h = base.height
hex_pixel_map = svc.send(:build_hex_pixel_map, hex_coords, min_x, min_y, img_w, img_h)
hex_size = hex_pixel_map[:hex_size]

svc.instance_variable_set(:@coord_lookup, {})
hex_pixel_map.each do |_label, info|
  next unless info.is_a?(Hash) && info[:hx]
  svc.instance_variable_get(:@coord_lookup)[[info[:hx], info[:hy]]] = info
end

coord_lookup = svc.instance_variable_get(:@coord_lookup)

# === CLASSIFICATION (cached) ===
cache_path = "tmp/classification_cache_#{ROOM_ID}.json"
all_results = nil

if File.exist?(cache_path)
  puts "Loading cached classification from #{cache_path}..."
  all_results = JSON.parse(File.read(cache_path))
  puts "Loaded #{all_results.length} cached results"

  # Rebuild overview data for regional types
  chunks = svc.send(:build_spatial_chunks, hex_coords, 25)
  puts "Running overview pass..."
  overview_data = svc.send(:run_overview_pass, image_path)
  abort "Overview failed" unless overview_data
  regional_types = overview_data['regional_types'] || []
  regional_type_map = {}
  regional_types.each do |rt|
    region = rt['region']
    next unless region
    regional_type_map[region] = (rt['types'] || []) | %w[wall off_map]
  end
  svc.instance_variable_set(:@regional_type_map, regional_type_map)
else
  puts "No cache found, running full classification..."
  chunks = svc.send(:build_spatial_chunks, hex_coords, 25)

  puts "Running overview pass..."
  overview_data = svc.send(:run_overview_pass, image_path)
  abort "Overview failed" unless overview_data

  scene_description = overview_data['scene_description'] || ''
  map_layout = overview_data['map_layout'] || ''
  present_types = overview_data['present_types'] || []

  standard_types = AIBattleMapGeneratorService::SIMPLE_HEX_TYPES.to_set
  present_types.reject! do |t|
    name = t['type_name']
    next false if standard_types.include?(name)
    t['traversable'] && !t['provides_cover'] && !t['provides_concealment'] &&
      !t['is_wall'] && !t['is_exit'] && !t['difficult_terrain'] &&
      (t['elevation'] || 0).zero? && (t['hazards'].nil? || t['hazards'].empty?)
  end

  type_names = present_types.map { |t| t['type_name'] }
  type_names -= %w[open_floor other]
  type_names << 'off_map' unless type_names.include?('off_map')
  type_names.uniq!

  regional_types = overview_data['regional_types'] || []
  regional_type_map = {}
  regional_types.each do |rt|
    region = rt['region']
    next unless region
    regional_type_map[region] = (rt['types'] || []) | %w[wall off_map]
  end
  svc.instance_variable_set(:@regional_type_map, regional_type_map)

  anthropic_key = AIProviderService.api_key_for('anthropic')
  abort "No Anthropic API key" unless anthropic_key

  all_results = []
  chunks.each_with_index do |chunk_info, idx|
    chunk = chunk_info[:coords]
    grid_pos = chunk_info[:grid_pos]
    seq = svc.send(:build_sequential_labels, chunk)
    hex_list_str = chunk.sort_by { |hx, hy| [hy, hx] }.map { |hx, hy| seq[:labels][[hx, hy]] }.join(', ')

    crop_result = svc.send(:crop_image_for_chunk, base, chunk, hex_pixel_map, img_w, img_h)
    labeled_crop = svc.send(:overlay_sequential_labels_on_crop, crop_result, chunk, seq[:labels])
    cropped_base64 = Base64.strict_encode64(labeled_crop)

    chunk_types = svc.send(:types_for_chunk, grid_pos, type_names)
    chunk_tools = svc.send(:build_chunk_tool, chunk_types)
    prompt = svc.send(:build_grouped_chunk_prompt, hex_list_str, scene_description, chunk_types,
                       grid_pos: grid_pos, map_layout: map_layout)

    location = svc.send(:chunk_location_hint, grid_pos) || '?'
    print "  #{idx + 1}/#{chunks.length} [#{location}]... "
    $stdout.flush

    response = LLM::Adapters::AnthropicAdapter.generate(
      messages: [{ role: 'user', content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: cropped_base64 } },
        { type: 'text', text: prompt }
      ] }],
      model: 'claude-haiku-4-5-20251001',
      api_key: anthropic_key,
      tools: chunk_tools,
      options: { max_tokens: 4096, timeout: 120, temperature: 0 }
    )

    if response[:tool_calls]&.any?
      args = response[:tool_calls].first[:arguments]
      objects = args['objects'] || []
      content = { 'objects' => objects }.to_json
      chunk_results = svc.send(:parse_grouped_chunk, content, seq[:reverse], allowed_types: chunk_types)
      all_results.concat(chunk_results)
      puts "#{chunk_results.length}"
    else
      puts "FAIL"
    end
  end

  File.write(cache_path, JSON.pretty_generate(all_results))
  puts "Cached #{all_results.length} results to #{cache_path}"
end

# === EDGE DETECTION ===
edge_map = nil
if ReplicateEdgeDetectionService.available?
  print "Loading edge map... "
  edge_result = ReplicateEdgeDetectionService.detect(image_path, mode: :canny)
  if edge_result&.dig(:success) && edge_result[:edge_map_path] && File.exist?(edge_result[:edge_map_path])
    edge_candidate = Vips::Image.new_from_file(edge_result[:edge_map_path])
    avg = edge_candidate.extract_band(0).avg
    if avg > 5 && avg < 250
      if edge_candidate.width != img_w || edge_candidate.height != img_h
        edge_candidate = edge_candidate.resize(img_w.to_f / edge_candidate.width,
                                                vscale: img_h.to_f / edge_candidate.height)
      end
      edge_map = edge_candidate
      puts "OK"
    else
      puts "rejected"
    end
  else
    puts "failed"
  end
end

# === NORMALIZATION ===
puts "Running normalization..."
normalized = svc.send(:normalize_by_visual_similarity, all_results, base, hex_pixel_map, hex_coords, min_x, min_y, edge_map: edge_map)

# === BUILD BEFORE/AFTER MAPS ===
before_map = {}
all_results.each { |r| before_map[[r['x'], r['y']]] = r['hex_type'] if r['x'] && r['y'] }

after_map = {}
normalized.each { |r| after_map[[r['x'], r['y']]] = r['hex_type'] if r['x'] && r['y'] }

# === COMPUTE SIGNALS FOR CHANGED HEXES ===
rgb_image = base.bands > 3 ? base.extract_band(0, n: 3) : base
lab_image = rgb_image.colourspace(:lab)
gray_image = rgb_image.colourspace(:b_w)

features = {}
texture_features = {}
hex_label_coords = {}
hex_coords.each do |hx, hy|
  label = svc.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
  info = coord_lookup[[hx, hy]]
  next unless info
  feat = svc.send(:extract_hex_features, lab_image, info[:px], info[:py], hex_size)
  if feat
    features[label] = feat
    hex_label_coords[label] = [hx, hy]
    tex = svc.send(:extract_texture_features, gray_image, info[:px], info[:py], hex_size)
    texture_features[label] = tex if tex
  end
end

typed_labels = {}
all_results.each do |r|
  next unless r['x'] && r['y']
  label = svc.send(:coord_to_label, r['x'], r['y'], min_x, min_y, hex_coords_override: hex_coords)
  typed_labels[label] = r['hex_type'] if label
end

coords_to_label = {}
hex_label_coords.each { |label, c| coords_to_label[c] = label }

ground_labels = []
type_groups = Hash.new { |h, k| h[k] = [] }
features.each do |label, feat|
  if typed_labels[label]
    type_groups[typed_labels[label]] << { label: label, features: feat }
  else
    ground_labels << { label: label, features: feat }
  end
end

ground_centroid = svc.send(:vector_centroid, ground_labels.map { |g| g[:features] })
type_centroids = {}
type_groups.each do |type_name, group|
  next if type_name == 'off_map'
  next if group.length < 2
  type_centroids[type_name] = svc.send(:vector_centroid, group.map { |h| h[:features] })
end

blob_sizes = svc.send(:compute_blob_sizes, typed_labels, hex_label_coords, coords_to_label)

# === CATEGORIZE CHANGES ===
demotions = []   # Was typed by classifier, removed by normalizer
promotions = []  # Was ground, promoted by normalizer
kept = []        # Was typed by classifier, kept by normalizer

hex_coords.each do |hx, hy|
  label = coords_to_label[[hx, hy]]
  next unless label

  before_type = before_map[[hx, hy]]
  after_type = after_map[[hx, hy]]
  info = coord_lookup[[hx, hy]]
  next unless info

  proposed_type = before_type || after_type
  next unless proposed_type
  centroid = type_centroids[proposed_type]

  signals = nil
  confidence = nil
  if centroid && features[label]
    signals = svc.send(:compute_signals,
      label, [hx, hy], proposed_type, features[label],
      centroid, ground_centroid, features, coords_to_label,
      typed_labels, hex_label_coords, edge_map, hex_size, blob_sizes,
      texture_features: texture_features
    )
    rule = svc.send(:rule_for_type, proposed_type)
    confidence = svc.send(rule, signals)
  end

  entry = {
    coords: [hx, hy],
    px: info[:px], py: info[:py],
    label: label,
    before_type: before_type,
    after_type: after_type,
    signals: signals,
    confidence: confidence,
  }

  if before_type && after_type.nil?
    demotions << entry
  elsif before_type.nil? && after_type
    promotions << entry
  elsif before_type && after_type
    kept << entry
  end
end

# === PRINT REPORT ===
puts
puts "=" * 90
puts "NORMALIZER CHANGES"
puts "=" * 90
puts "Classifier tagged: #{all_results.length}, After normalization: #{normalized.length}"
puts "Demotions: #{demotions.length}, Promotions: #{promotions.length}, Kept: #{kept.length}"

# Print demotions grouped by type
puts
puts "-" * 90
puts "DEMOTIONS (#{demotions.length}) — classifier tagged these, normalizer removed them"
puts "Mark each as CORRECT (classifier was wrong) or INCORRECT (normalizer broke it)"
puts "-" * 90

demotion_by_type = demotions.group_by { |e| e[:before_type] }
demotion_by_type.sort_by { |_, v| -v.length }.each do |type, entries|
  puts "\n  #{type.upcase} (#{entries.length} demoted):"
  puts "  %-4s %-8s %-7s %-7s %-7s %-5s %-5s %-5s %-5s %-7s" %
    ['#', 'Label', 'Color', 'Edge', 'TexM', 'NC', 'NT', 'Blob', 'Wall', 'Conf']
  entries.sort_by { |e| e[:confidence] || 0 }.each_with_index do |e, idx|
    s = e[:signals]
    if s
      puts "  %-4d %-8s %6.3f  %6.3f  %6.1f  %4d  %4d  %4d  %-5s %6.3f" % [
        idx + 1, e[:label],
        s[:color_score], s[:edge_score], s[:texture_mean] || 0,
        s[:neighbor_color], s[:neighbor_typed], s[:blob_size] || 0,
        s[:has_wall_neighbor] ? 'yes' : 'no',
        e[:confidence] || 0
      ]
    else
      puts "  %-4d %-8s (no signals)" % [idx + 1, e[:label]]
    end
  end
end

# Print promotions grouped by type
if promotions.any?
  puts
  puts "-" * 90
  puts "PROMOTIONS (#{promotions.length}) — normalizer added these (were ground)"
  puts "-" * 90

  promo_by_type = promotions.group_by { |e| e[:after_type] }
  promo_by_type.sort_by { |_, v| -v.length }.each do |type, entries|
    puts "\n  #{type.upcase} (#{entries.length} promoted):"
    puts "  %-4s %-8s %-7s %-7s %-7s %-5s %-5s %-5s %-5s %-7s" %
      ['#', 'Label', 'Color', 'Edge', 'TexM', 'NC', 'NT', 'Blob', 'Wall', 'Conf']
    entries.sort_by { |e| -(e[:confidence] || 0) }.each_with_index do |e, idx|
      s = e[:signals]
      if s
        puts "  %-4d %-8s %6.3f  %6.3f  %6.1f  %4d  %4d  %4d  %-5s %6.3f" % [
          idx + 1, e[:label],
          s[:color_score], s[:edge_score], s[:texture_mean] || 0,
          s[:neighbor_color], s[:neighbor_typed], s[:blob_size] || 0,
          s[:has_wall_neighbor] ? 'yes' : 'no',
          e[:confidence] || 0
        ]
      end
    end
  end
end

# === RENDER DIFF VISUALIZATION ===
puts "\nRendering diff visualization..."

svg_parts = [%(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)]

# Helper to draw hex
draw_hex = ->(px, py, fill, stroke, stroke_w, label_text, label_color) {
  points = (0..5).map do |i|
    angle = Math::PI / 3 * i - Math::PI / 6
    vx = px + hex_size * 0.85 * Math.cos(angle)
    vy = py + hex_size * 0.85 * Math.sin(angle)
    "#{vx.round(1)},#{vy.round(1)}"
  end.join(' ')

  svg_parts << %(<polygon points="#{points}" fill="#{fill}" stroke="#{stroke}" stroke-width="#{stroke_w}"/>)

  if label_text
    font_size = [hex_size * 0.28, 5].max.round
    svg_parts << %(<text x="#{px.round(1)}" y="#{(py + font_size * 0.35).round(1)}" )
    svg_parts << %(font-size="#{font_size}" fill="#{label_color}" text-anchor="middle" font-family="monospace" font-weight="bold">)
    svg_parts << %(#{label_text}</text>)
  end
}

# Draw kept hexes as dim colored overlay
kept.each do |e|
  type = e[:after_type]
  color = case type
          when 'wall' then 'rgba(100,100,100,0.3)'
          when 'glass_window' then 'rgba(135,206,250,0.3)'
          when 'door' then 'rgba(139,69,19,0.3)'
          when 'table' then 'rgba(210,180,140,0.3)'
          when 'chair' then 'rgba(244,164,96,0.3)'
          when 'barrel' then 'rgba(160,82,45,0.3)'
          when 'crate' then 'rgba(205,133,63,0.3)'
          when 'fire' then 'rgba(255,69,0,0.3)'
          when 'off_map' then 'rgba(0,0,0,0.3)'
          when 'forge' then 'rgba(255,140,0,0.3)'
          else 'rgba(180,180,180,0.3)'
          end
  abbrev = type[0..2]
  draw_hex.call(e[:px], e[:py], color, 'rgba(255,255,255,0.3)', '0.3', abbrev, 'rgba(255,255,255,0.5)')
end

# Draw demotions as RED with X
demotions.each do |e|
  type = e[:before_type]
  abbrev = type[0..2]
  draw_hex.call(e[:px], e[:py], 'rgba(255,0,0,0.5)', 'red', '2', abbrev, 'white')
end

# Draw promotions as GREEN with +
promotions.each do |e|
  type = e[:after_type]
  abbrev = "+#{type[0..2]}"
  draw_hex.call(e[:px], e[:py], 'rgba(0,200,0,0.5)', 'lime', '2', abbrev, 'white')
end

svg_parts << '</svg>'
svg_data = svg_parts.join("\n")

overlay = Vips::Image.svgload_buffer(svg_data)
if overlay.width != img_w || overlay.height != img_h
  overlay = overlay.crop(0, 0, [overlay.width, img_w].min, [overlay.height, img_h].min)
end
base_rgba = base.bands == 4 ? base : base.bandjoin(255)
result = base_rgba.composite(overlay, :over)
out_path = "tmp/normalizer_diff_#{ROOM_ID}.png"
result.pngsave(out_path)
puts "Saved: #{out_path}"

# === ALSO RENDER FULL BEFORE for reference ===
TYPE_COLORS = {
  'wall'         => 'rgba(100,100,100,0.5)',
  'glass_window' => 'rgba(135,206,250,0.5)',
  'door'         => 'rgba(139,69,19,0.5)',
  'table'        => 'rgba(210,180,140,0.5)',
  'chair'        => 'rgba(244,164,96,0.5)',
  'barrel'       => 'rgba(160,82,45,0.5)',
  'crate'        => 'rgba(205,133,63,0.5)',
  'fire'         => 'rgba(255,69,0,0.6)',
  'off_map'      => 'rgba(0,0,0,0.6)',
  'forge'        => 'rgba(255,140,0,0.5)',
  'pillar'       => 'rgba(128,128,128,0.5)',
  'staircase'    => 'rgba(75,0,130,0.5)',
}.freeze
DEFAULT_COLOR = 'rgba(255,0,255,0.5)'

svg2 = [%(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)]
all_results.each do |r|
  info = coord_lookup[[r['x'], r['y']]]
  next unless info
  px, py = info[:px], info[:py]
  color = TYPE_COLORS[r['hex_type']] || DEFAULT_COLOR
  abbrev = r['hex_type'][0..2]
  font_size = [hex_size * 0.28, 5].max.round

  points = (0..5).map do |i|
    angle = Math::PI / 3 * i - Math::PI / 6
    vx = px + hex_size * 0.85 * Math.cos(angle)
    vy = py + hex_size * 0.85 * Math.sin(angle)
    "#{vx.round(1)},#{vy.round(1)}"
  end.join(' ')

  svg2 << %(<polygon points="#{points}" fill="#{color}" stroke="white" stroke-width="0.5"/>)
  svg2 << %(<text x="#{px.round(1)}" y="#{(py + font_size * 0.35).round(1)}" font-size="#{font_size}" fill="white" text-anchor="middle" font-family="monospace" font-weight="bold">#{abbrev}</text>)
end
svg2 << '</svg>'

overlay2 = Vips::Image.svgload_buffer(svg2.join("\n"))
if overlay2.width != img_w || overlay2.height != img_h
  overlay2 = overlay2.crop(0, 0, [overlay2.width, img_w].min, [overlay2.height, img_h].min)
end
result2 = base_rgba.composite(overlay2, :over)
result2.pngsave("tmp/normalizer_before_#{ROOM_ID}.png")
puts "Saved: tmp/normalizer_before_#{ROOM_ID}.png"

puts "\nDone. Review tmp/normalizer_diff_#{ROOM_ID}.png to assess each change."
puts "RED hexes = demotions (normalizer removed), GREEN hexes = promotions (normalizer added)"
puts "DIM hexes = kept by normalizer"
