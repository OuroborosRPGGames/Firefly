# frozen_string_literal: true

# Diagnose normalization: print signal values for each demoted hex
# to understand WHY things are being removed.
#
# Usage: cd backend && bundle exec ruby tmp/diagnose_normalizer.rb [room_id]

require_relative '../app'
require 'vips'
require 'base64'

ROOM_ID = (ARGV[0] || 155).to_i

room = Room[ROOM_ID]
abort "Room #{ROOM_ID} not found" unless room
abort "Room #{ROOM_ID} has no battle map image" unless room.battle_map_image_url

image_path = "public/#{room.battle_map_image_url}"
abort "Image not found: #{image_path}" unless File.exist?(image_path)

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

chunks = svc.send(:build_spatial_chunks, hex_coords, 25)

# Overview
puts "Running overview..."
overview_data = svc.send(:run_overview_pass, image_path)
abort "Overview failed" unless overview_data

scene_description = overview_data['scene_description'] || ''
type_names = (overview_data['present_types'] || []).map { |t| t['type_name'] }
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

# Classify
puts "Classifying #{chunks.length} chunks..."
anthropic_key = AIProviderService.api_key_for('anthropic')
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
                     grid_pos: grid_pos, map_layout: overview_data['map_layout'])

  print "  #{idx + 1}/#{chunks.length}... "
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

puts "\nTotal classified: #{all_results.length}"

# Edge detection
edge_map = nil
if ReplicateEdgeDetectionService.available?
  puts "Loading edge map..."
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
      puts "Edge map loaded"
    end
  end
end

# Now manually run normalization setup and diagnose each step
puts "\n=== DIAGNOSTIC NORMALIZATION ==="

rgb_image = base.bands > 3 ? base.extract_band(0, n: 3) : base
lab_image = rgb_image.colourspace(:lab)
gray_image = rgb_image.colourspace(:b_w)

typed_labels = {}
all_results.each do |r|
  next unless r['x'] && r['y']
  label = svc.send(:coord_to_label, r['x'], r['y'], min_x, min_y, hex_coords_override: hex_coords)
  typed_labels[label] = r['hex_type'] if label
end

features = {}
texture_features = {}
hex_label_coords = {}
hex_coords.each do |hx, hy|
  label = svc.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
  info = svc.instance_variable_get(:@coord_lookup)[[hx, hy]]
  next unless info

  feat = svc.send(:extract_hex_features, lab_image, info[:px], info[:py], hex_size)
  if feat
    features[label] = feat
    hex_label_coords[label] = [hx, hy]
    tex = svc.send(:extract_texture_features, gray_image, info[:px], info[:py], hex_size)
    texture_features[label] = tex if tex
  end
end

ground_labels = []
type_groups = Hash.new { |h, k| h[k] = [] }
features.each do |label, feat|
  if typed_labels[label]
    type_groups[typed_labels[label]] << { label: label, features: feat }
  else
    ground_labels << { label: label, features: feat }
  end
end

coords_to_label = {}
hex_label_coords.each { |label, c| coords_to_label[c] = label }

puts "Hexes: #{features.length} (#{type_groups.values.sum(&:length)} typed, #{ground_labels.length} ground)"

skip_types = Set.new(%w[off_map])
ground_centroid = svc.send(:vector_centroid, ground_labels.map { |g| g[:features] })

type_centroids = {}
type_groups.each do |type_name, group|
  next if skip_types.include?(type_name)
  next if group.length < 2
  type_centroids[type_name] = svc.send(:vector_centroid, group.map { |h| h[:features] })
end

blob_sizes = svc.send(:compute_blob_sizes, typed_labels, hex_label_coords, coords_to_label)

# Print signals for EVERY typed hex, grouped by type
puts "\n=== SIGNALS PER TYPED HEX ==="
demotion_threshold = 0.3

type_groups.each do |type_name, group|
  next if skip_types.include?(type_name)
  centroid = type_centroids[type_name]
  next unless centroid

  puts "\n--- #{type_name.upcase} (#{group.length} hexes, centroid from #{group.length} samples) ---"
  puts "  %-6s %-8s %-8s %-8s %-8s %-5s %-5s %-5s %-5s %-8s %s" %
    ['Label', 'Color', 'Edge', 'TexMean', 'TexStd', 'NC', 'NT', 'Blob', 'Wall?', 'Conf', 'Action']

  group.each do |hex_entry|
    label = hex_entry[:label]
    coords = hex_label_coords[label]
    next unless coords

    signals = svc.send(:compute_signals,
      label, coords, type_name, hex_entry[:features],
      centroid, ground_centroid, features, coords_to_label,
      typed_labels, hex_label_coords, edge_map, hex_size, blob_sizes,
      texture_features: texture_features
    )

    rule = svc.send(:rule_for_type, type_name)
    confidence = svc.send(rule, signals)
    action = confidence < demotion_threshold ? 'DEMOTE' : 'keep'

    puts "  %-6s %7.3f  %7.3f  %7.1f  %7.1f  %4d  %4d  %4d  %-5s %7.3f  %s" % [
      label,
      signals[:color_score],
      signals[:edge_score],
      signals[:texture_mean],
      signals[:texture_std],
      signals[:neighbor_color],
      signals[:neighbor_typed],
      signals[:blob_size],
      signals[:has_wall_neighbor] ? 'yes' : 'no',
      confidence,
      action
    ]
  end
end
