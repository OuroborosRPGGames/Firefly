#!/usr/bin/env ruby
# frozen_string_literal: true

# AI Battle Map Test Harness
# ===========================
# Iterate on battle map hex classification without requiring real rooms.
#
# Usage:
#   cd backend
#   bundle exec ruby tmp/battlemap_harness.rb <command> <map|all> [experiment] [--force]
#
# Commands:
#   generate  <map>                    - Generate image via Gemini
#   overview  <map>  [experiment]      - Run overview (default or experiment-specific)
#   inspect   <map>                    - Generate labeled chunk images
#   classify  <map>  <experiment>      - Run chunk classification
#   visualize <map>  <experiment>      - Render color-coded classification overlay
#   full      <map>                    - generate + overview + inspect
#   all <cmd> [experiment]             - Run command on all maps
#
# Flags:
#   --force    Delete cached results before running
#
# Experiments: defined in tmp/battlemap_experiments.yml

require 'yaml'
require 'json'
require 'fileutils'
require 'ostruct'
require 'base64'

# Boot the application (loads Sequel, models, services, etc.)
require_relative '../config/room_type_config'
Dir[File.join(__dir__, '../app/lib/*.rb')].each { |f| require f }
require_relative '../config/application'

CACHE_DIR = File.join(__dir__, 'battlemap_cache')
MAPS_FILE = File.join(__dir__, 'battlemap_test_maps.yml')
EXPERIMENTS_FILE = File.join(__dir__, 'battlemap_experiments.yml')

# -------------------------------------------------------
# MockRoom: OpenStruct-based mock satisfying the Room interface
# -------------------------------------------------------
class MockRoom
  attr_reader :id, :name, :short_description, :long_description,
              :min_x, :max_x, :min_y, :max_y,
              :places, :room_features, :decorations

  def initialize(map_def)
    @id = map_def['name']&.hash&.abs || rand(10000)
    @name = map_def['display_name']
    @short_description = map_def['display_name']
    @long_description = map_def['description']
    @min_x = 0.0
    @max_x = map_def['width'].to_f
    @min_y = 0.0
    @max_y = map_def['height'].to_f

    @places = (map_def['furniture'] || []).map do |f|
      OpenStruct.new(name: f['name'], x: f['x']&.to_f, y: f['y']&.to_f)
    end

    @room_features = (map_def['features'] || []).map do |f|
      OpenStruct.new(
        name: f['name'],
        feature_type: f['feature_type'],
        x: f['x']&.to_f,
        y: f['y']&.to_f,
        is_open: false
      )
    end

    @decorations = (map_def['decorations'] || []).map do |d|
      OpenStruct.new(name: d['name'])
    end
  end

  def has_custom_polygon?
    false
  end

  def description
    @long_description
  end

  def hex_count
    0
  end

  def battle_map_config
    {}
  end

  def battle_map_config_for_type
    { water_chance: 0, elevation_variance: 0, objects: [], hazard_chance: 0,
      explosive_chance: 0, dark: false, difficult_terrain: false }
  end
end

# -------------------------------------------------------
# HarnessService: Subclass exposing private methods
# -------------------------------------------------------
class HarnessService < AIBattleMapGeneratorService
  public :run_overview_pass, :build_spatial_chunks, :generate_hex_coordinates,
         :build_hex_pixel_map, :normalize_v2,
         :generate_local_edge_map,
         :build_grouped_chunk_prompt, :overlay_sequential_labels_on_crop,
         :build_sequential_labels, :crop_image_for_chunk,
         :generate_battlemap_image, :calculate_image_dimensions,
         :build_image_prompt, :capped_room_dimensions,
         :build_chunk_tool, :parse_grouped_chunk, :types_for_chunk,
         :hex_to_pixel, :hexagon_svg_points,
         :extract_hex_features, :extract_texture_features, :edge_strength_at_hex,
         :coord_to_label,
         :vector_centroid, :vector_distance

  attr_writer :regional_type_map, :crop_margin_factor

  # Override crop to support configurable margin factor
  def crop_image_for_chunk(base_image, chunk_coords, hex_pixel_map, img_width, img_height)
    if @crop_margin_factor
      hex_size = hex_pixel_map[:hex_size]
      margin = (hex_size * @crop_margin_factor).round

      pxs = []
      pys = []
      chunk_coords.each do |hx, hy|
        info = @coord_lookup[[hx, hy]]
        next unless info
        pxs << info[:px]
        pys << info[:py]
      end

      if pxs.empty?
        return { cropped: base_image, crop_x: 0, crop_y: 0, crop_w: img_width, crop_h: img_height, hex_size: hex_size }
      end

      crop_x = [(pxs.min - margin - hex_size).round, 0].max
      crop_y = [(pys.min - margin - hex_size).round, 0].max
      crop_right = [(pxs.max + margin + hex_size).round, img_width].min
      crop_bottom = [(pys.max + margin + hex_size).round, img_height].min
      crop_w = crop_right - crop_x
      crop_h = crop_bottom - crop_y

      cropped = base_image.crop(crop_x, crop_y, crop_w, crop_h)
      { cropped: cropped, crop_x: crop_x, crop_y: crop_y, crop_w: crop_w, crop_h: crop_h, hex_size: hex_size }
    else
      super
    end
  end

  def setup_coord_lookup(hex_pixel_map)
    @coord_lookup = {}
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]

      @coord_lookup[[info[:hx], info[:hy]]] = info
    end
  end

  def coord_lookup
    @coord_lookup
  end
end

# -------------------------------------------------------
# Visualization colors for hex types
# -------------------------------------------------------
VIS_COLORS = {
  'wall'         => [80, 80, 80, 180],
  'off_map'      => [30, 30, 30, 200],
  'tree'         => [34, 139, 34, 160],
  'dense_trees'  => [0, 100, 0, 160],
  'shrubbery'    => [107, 142, 35, 150],
  'boulder'      => [139, 137, 137, 160],
  'mud'          => [139, 119, 101, 150],
  'snow'         => [220, 220, 240, 120],
  'ice'          => [173, 216, 230, 140],
  'puddle'       => [100, 149, 237, 140],
  'wading_water' => [65, 105, 225, 160],
  'deep_water'   => [0, 0, 180, 180],
  'table'        => [139, 90, 43, 160],
  'chair'        => [160, 82, 45, 150],
  'bench'        => [160, 82, 45, 150],
  'fire'         => [255, 100, 0, 180],
  'log'          => [101, 67, 33, 150],
  'glass_window' => [135, 206, 250, 140],
  'open_window'  => [135, 206, 250, 120],
  'barrel'       => [139, 90, 43, 170],
  'balcony'      => [169, 169, 169, 150],
  'staircase'    => [192, 192, 192, 160],
  'door'         => [139, 69, 19, 170],
  'archway'      => [169, 169, 169, 160],
  'rubble'       => [128, 128, 128, 150],
  'pillar'       => [192, 192, 192, 170],
  'crate'        => [160, 120, 60, 160],
  'chest'        => [184, 134, 11, 170],
  'wagon'        => [139, 90, 43, 160],
  'tent'         => [210, 180, 140, 150],
  'pit'          => [50, 50, 50, 180],
  'cliff'        => [105, 105, 105, 170],
  'ledge'        => [128, 128, 128, 150],
  'bridge'       => [160, 140, 100, 160],
  'fence'        => [139, 119, 101, 160],
  'gate'         => [139, 69, 19, 170],
  'bar_counter'  => [139, 69, 19, 170],
  'fireplace'    => [178, 34, 34, 180],
  'forge'        => [178, 34, 34, 180],
  'ships_wheel'  => [218, 165, 32, 170],
  'anvil'        => [105, 105, 105, 170],
  'weapon_rack'  => [139, 119, 101, 160],
  'shelf'        => [160, 120, 60, 160],
  'rug'          => [128, 0, 0, 140],
  'carpet'       => [128, 0, 0, 140],
  'desk'         => [139, 90, 43, 160],
  'bookshelf'    => [101, 67, 33, 160],
  'bed'          => [147, 112, 219, 160],
  'counter'      => [139, 90, 43, 170],
  'cargo_container' => [0, 128, 128, 170],
  'catwalk'      => [169, 169, 169, 150],
  'control_console' => [0, 200, 200, 170],
  'cubicle_partition' => [128, 128, 160, 150],
  'glass_wall'   => [135, 206, 250, 130],
  'potted_plant' => [34, 139, 34, 160],
  'other'        => [200, 200, 0, 150],
  'open_floor'   => [200, 200, 200, 60]
}.freeze

# -------------------------------------------------------
# Harness runner
# -------------------------------------------------------
class BattlemapHarness
  def initialize
    @maps = YAML.load_file(MAPS_FILE)
    @experiments = File.exist?(EXPERIMENTS_FILE) ? YAML.load_file(EXPERIMENTS_FILE) : {}
  end

  def run(command, map_name, experiment_name = nil, force: false)
    if map_name == 'all'
      @maps.each_key { |name| run_single(command, name, experiment_name, force: force) }
    else
      run_single(command, map_name, experiment_name, force: force)
    end
  end

  private

  def run_single(command, map_name, experiment_name, force: false)
    map_def = @maps[map_name]
    abort "Unknown map: #{map_name}. Available: #{@maps.keys.join(', ')}" unless map_def

    room = MockRoom.new(map_def.merge('name' => map_name))
    cache = map_cache_dir(map_name)

    case command
    when 'generate'  then cmd_generate(room, cache, map_name)
    when 'overview'  then cmd_overview(room, cache, map_name, experiment_name, force: force)
    when 'inspect'   then cmd_inspect(room, cache, map_name)
    when 'classify'  then cmd_classify(room, cache, map_name, experiment_name || 'baseline', force: force)
    when 'visualize' then cmd_visualize(room, cache, map_name, experiment_name || 'baseline')
    when 'normalize' then cmd_normalize(room, cache, map_name, experiment_name || 'production', force: force)
    when 'full'
      cmd_generate(room, cache, map_name)
      cmd_overview(room, cache, map_name)
      cmd_inspect(room, cache, map_name)
    else
      abort "Unknown command: #{command}. Use: generate, overview, inspect, classify, visualize, full"
    end
  end

  # ---- generate ----
  def cmd_generate(room, cache, map_name)
    puts "=== [#{map_name}] generate ==="
    existing = find_cached_image(cache)
    if existing
      puts "  Cached image exists (#{File.size(existing)} bytes). Delete to regenerate."
      return existing
    end

    svc = HarnessService.new(room)
    puts "  Prompt: #{svc.build_image_prompt[0..120]}..."
    puts "  Dimensions: #{svc.calculate_image_dimensions}"

    result = svc.generate_battlemap_image
    unless result[:success]
      puts "  FAILED: #{result[:error]}"
      return nil
    end

    tmp_path = File.join(cache, 'image.tmp')
    if result[:base64_data]
      File.binwrite(tmp_path, Base64.decode64(result[:base64_data]))
    elsif result[:local_url] && File.exist?(File.join('public', result[:local_url].sub(%r{^/}, '')))
      FileUtils.cp(File.join('public', result[:local_url].sub(%r{^/}, '')), tmp_path)
    elsif result[:url]
      source = result[:url].start_with?('/') ? File.join('public', result[:url].sub(%r{^/}, '')) : result[:url]
      if File.exist?(source)
        FileUtils.cp(source, tmp_path)
      else
        puts "  FAILED: Cannot locate generated image. Result keys: #{result.keys}"
        return nil
      end
    else
      puts "  FAILED: No image data in result. Result keys: #{result.keys}"
      return nil
    end

    ext = detect_image_format(tmp_path)
    image_path = File.join(cache, "image.#{ext}")
    File.rename(tmp_path, image_path)

    require 'vips'
    pre_image = Vips::Image.new_from_file(image_path)
    pre_dims = "#{pre_image.width}x#{pre_image.height}"
    MapSvgRenderService.trim_image_borders(image_path)
    post_image = Vips::Image.new_from_file(image_path)
    post_dims = "#{post_image.width}x#{post_image.height}"
    if pre_dims != post_dims
      puts "  Trimmed: #{pre_dims} -> #{post_dims}"
    else
      puts "  No trim needed (image fills canvas)"
    end

    puts "  Saved: #{image_path} (#{File.size(image_path)} bytes)"
    image_path
  end

  # ---- overview ----
  def cmd_overview(room, cache, map_name, experiment_name = nil, force: false)
    puts "=== [#{map_name}] overview ==="
    image_path = find_cached_image(cache)

    unless image_path
      puts "  No image found. Run 'generate' first."
      return nil
    end

    # Determine overview path: experiment-specific or default
    if experiment_name
      config = load_experiment_config(experiment_name)
      return nil unless config

      if config['overview_prompt'] && config['overview_prompt'] != 'default'
        exp_dir = experiment_cache_dir(cache, experiment_name)
        overview_path = File.join(exp_dir, 'overview.json')
        puts "  Experiment '#{experiment_name}' uses custom overview prompt"
      else
        overview_path = File.join(cache, 'overview.json')
      end
    else
      overview_path = File.join(cache, 'overview.json')
    end

    File.delete(overview_path) if force && File.exist?(overview_path)

    if File.exist?(overview_path)
      puts "  Cached overview exists. Delete or use --force to re-run."
      data = JSON.parse(File.read(overview_path))
      print_overview_summary(data)
      return data
    end

    svc = HarnessService.new(room)
    data = svc.run_overview_pass(image_path)
    unless data
      puts "  FAILED: Overview pass returned nil"
      return nil
    end

    FileUtils.mkdir_p(File.dirname(overview_path))
    File.write(overview_path, JSON.pretty_generate(data))
    puts "  Saved: #{overview_path}"
    print_overview_summary(data)
    data
  end

  # ---- inspect ----
  def cmd_inspect(room, cache, map_name)
    puts "=== [#{map_name}] inspect ==="
    image_path = find_cached_image(cache)

    unless image_path
      puts "  No image found. Run 'generate' first."
      return
    end

    require 'vips'

    grid = setup_hex_grid(room, cache)
    svc = grid[:svc]
    hex_coords = grid[:hex_coords]
    base = grid[:base]
    hex_pixel_map = grid[:hex_pixel_map]

    puts "  Image: #{base.width}x#{base.height}"
    puts "  Hex count: #{hex_coords.length}"
    puts "  Hex pixel size: #{hex_pixel_map[:hex_size].round(1)}px"

    chunks = svc.build_spatial_chunks(hex_coords, AIBattleMapGeneratorService::CHUNK_SIZE)
    puts "  Chunks: #{chunks.length}"

    chunk_dir = File.join(cache, 'chunk_images')
    FileUtils.rm_rf(chunk_dir)
    FileUtils.mkdir_p(chunk_dir)

    chunks.each_with_index do |chunk, i|
      coords = chunk[:coords]
      grid_pos = chunk[:grid_pos]
      gx = grid_pos[:gx]
      gy = grid_pos[:gy]

      label_data = svc.build_sequential_labels(coords)
      seq_labels = label_data[:labels]

      crop_result = svc.crop_image_for_chunk(base, coords, hex_pixel_map, base.width, base.height)
      png_data = svc.overlay_sequential_labels_on_crop(crop_result, coords, seq_labels)

      filename = "chunk_#{gx}_#{gy}.png"
      filepath = File.join(chunk_dir, filename)
      File.binwrite(filepath, png_data)

      puts "  Chunk #{i} (#{gx},#{gy}): #{coords.length} hexes, labels 1-#{coords.length} -> #{filename}"
    end

    puts "  Chunk images saved to: #{chunk_dir}/"
  end

  # ---- classify ----
  def cmd_classify(room, cache, map_name, experiment_name, force: false)
    puts "=== [#{map_name}] classify (#{experiment_name}) ==="

    config = load_experiment_config(experiment_name)
    return unless config

    exp_dir = experiment_cache_dir(cache, experiment_name)
    classify_path = File.join(exp_dir, 'classify.json')

    if force && File.exist?(classify_path)
      File.delete(classify_path)
      puts "  Cleared cached results (--force)"
    end

    if File.exist?(classify_path)
      puts "  Cached classify.json exists. Use --force to re-run."
      print_classify_summary(JSON.parse(File.read(classify_path)))
      return
    end

    image_path = find_cached_image(cache)
    unless image_path
      puts "  No image found. Run 'generate' first."
      return
    end

    # Load overview (experiment-specific if available, else default)
    overview = load_overview_for_experiment(cache, experiment_name)
    unless overview
      puts "  No overview.json found. Run 'overview' first."
      return
    end

    require 'vips'

    grid = setup_hex_grid(room, cache)
    svc = grid[:svc]
    hex_coords = grid[:hex_coords]
    base = grid[:base]
    hex_pixel_map = grid[:hex_pixel_map]

    setup_regional_types(svc, overview)

    # Apply crop margin factor if configured
    if config['crop_margin_factor']
      svc.crop_margin_factor = config['crop_margin_factor'].to_f
    end

    type_names = extract_type_names(overview)
    scene_description = overview['scene_description'] || ''
    map_layout = overview['map_layout']
    chunk_size = config['chunk_size'] || 25
    chunk_style = config['chunk_style'] || 'spatial'
    label_style = config['label_style'] || 'sequential'
    provider = config['provider'] || 'anthropic'
    model = config['model'] || 'claude-haiku-4-5-20251001'

    puts "  Config: chunk_style=#{chunk_style}, chunk_size=#{chunk_size}, model=#{model}, provider=#{provider}, labels=#{label_style}"
    puts "  Types: #{type_names.join(', ')}"
    puts "  Hex count: #{hex_coords.length}"

    chunks = if chunk_style == 'rows'
               build_row_chunks(hex_coords, config['rows_per_chunk'] || 2)
             else
               svc.build_spatial_chunks(hex_coords, chunk_size)
             end
    puts "  Chunks: #{chunks.length}"

    api_key = api_key_for(provider)
    unless api_key
      puts "  FAILED: No API key for provider '#{provider}'"
      return
    end

    all_chunk_results = []
    chunk_details = []
    first_prompt = nil
    total_input_tokens = 0
    total_output_tokens = 0

    chunks.each_with_index do |chunk_info, chunk_idx|
      coords = chunk_info[:coords]
      grid_pos = chunk_info[:grid_pos]

      # Build labels
      label_data = build_labels(svc, label_style, coords)
      seq_labels = label_data[:labels]
      reverse_labels = label_data[:reverse]
      hex_list_str = coords.sort_by { |hx, hy| [hy, hx] }.map { |hx, hy| seq_labels[[hx, hy]] }.compact.join(', ')

      # Crop + overlay labels
      crop_result = svc.crop_image_for_chunk(base, coords, hex_pixel_map, base.width, base.height)
      labeled_crop = svc.overlay_sequential_labels_on_crop(crop_result, coords, seq_labels)
      cropped_base64 = Base64.strict_encode64(labeled_crop)

      # Build prompt
      chunk_types = svc.types_for_chunk(grid_pos, type_names)
      prompt = build_classify_prompt(svc, config, hex_list_str, scene_description, chunk_types,
                                     grid_pos: grid_pos, map_layout: map_layout)
      first_prompt ||= prompt

      # Build tool + messages
      chunk_tools = svc.build_chunk_tool(chunk_types)
      messages = build_classify_message(provider, prompt, cropped_base64)

      # Call LLM
      adapter = adapter_for(provider)
      opts = { max_tokens: 4096, timeout: 120 }
      # GPT-5 and o-series models only support temperature=1
      if model.start_with?('gpt-5') || model.start_with?('o1') || model.start_with?('o3')
        opts[:temperature] = 1
      else
        opts[:temperature] = 0
      end
      response = adapter.generate(
        messages: messages,
        model: model,
        api_key: api_key,
        tools: chunk_tools,
        options: opts
      )

      # Track token usage from raw response data
      usage = response[:data]&.dig('usage') || {}
      input_tok = usage['input_tokens'] || usage['prompt_tokens'] || 0
      output_tok = usage['output_tokens'] || usage['completion_tokens'] || 0
      total_input_tokens += input_tok
      total_output_tokens += output_tok

      chunk_result = { chunk_idx: chunk_idx, grid_pos: grid_pos, coords_count: coords.length,
                       input_tokens: input_tok, output_tokens: output_tok }

      if response[:tool_calls]&.any?
        args = response[:tool_calls].first[:arguments]
        objects = args['objects'] || []
        area_desc = args['area_description'] || ''
        content = { 'objects' => objects }.to_json
        parsed = svc.parse_grouped_chunk(content, reverse_labels, allowed_types: chunk_types)
        all_chunk_results.concat(parsed)

        types_found = parsed.map { |r| r['hex_type'] }.uniq
        chunk_result[:classified] = parsed.length
        chunk_result[:types] = types_found
        chunk_result[:area_description] = area_desc
        chunk_result[:raw_objects] = objects

        puts "  Chunk #{chunk_idx} (#{grid_pos[:gx]},#{grid_pos[:gy]}): " \
             "#{parsed.length}/#{coords.length} classified, types: #{types_found.join(', ')}"
        puts "    #{area_desc}" unless area_desc.empty?
      else
        error = response[:error] || 'no tool call returned'
        chunk_result[:error] = error
        puts "  Chunk #{chunk_idx} (#{grid_pos[:gx]},#{grid_pos[:gy]}): FAILED - #{error}"
      end

      chunk_details << chunk_result
    end

    # Summary
    puts "\n  === Summary ==="
    puts "  Total classified: #{all_chunk_results.length} / #{hex_coords.length} hexes"
    type_dist = all_chunk_results.group_by { |r| r['hex_type'] }.transform_values(&:length).sort_by { |_, v| -v }
    type_dist.each { |type, count| puts "    #{type}: #{count}" }
    unclassified = hex_coords.length - all_chunk_results.length
    puts "    (open_floor/unclassified): #{unclassified}"

    # Cost analysis
    cost = estimate_cost(provider, model, total_input_tokens, total_output_tokens)
    puts "\n  === Cost ==="
    puts "  Tokens: #{total_input_tokens} input + #{total_output_tokens} output = #{total_input_tokens + total_output_tokens} total"
    puts "  Estimated cost: $#{'%.4f' % cost}"
    cost_per_hex = hex_coords.length > 0 ? cost / hex_coords.length : 0
    puts "  Cost per hex: $#{'%.6f' % cost_per_hex}"

    # Show first prompt for iteration reference
    puts "\n  === First chunk prompt ==="
    puts first_prompt&.lines&.map { |l| "    #{l}" }&.join

    # Build merged results hash: [hx,hy] => hex_type
    merged = {}
    all_chunk_results.each { |r| merged[[r['x'], r['y']]] = r['hex_type'] }

    # Save
    output = {
      'experiment' => experiment_name,
      'config' => config,
      'map' => map_name,
      'total_hexes' => hex_coords.length,
      'total_classified' => all_chunk_results.length,
      'type_distribution' => type_dist.to_h,
      'cost' => {
        'input_tokens' => total_input_tokens,
        'output_tokens' => total_output_tokens,
        'estimated_usd' => cost.round(6),
        'cost_per_hex' => cost_per_hex.round(8)
      },
      'chunk_details' => chunk_details,
      'merged_results' => merged.map { |(x, y), t| { 'x' => x, 'y' => y, 'hex_type' => t } },
      'raw_results' => all_chunk_results
    }
    File.write(classify_path, JSON.pretty_generate(output))
    puts "\n  Saved: #{classify_path}"
  end

  # ---- visualize ----
  def cmd_visualize(room, cache, map_name, experiment_name)
    puts "=== [#{map_name}] visualize (#{experiment_name}) ==="

    exp_dir = experiment_cache_dir(cache, experiment_name)
    classify_path = File.join(exp_dir, 'classify.json')

    unless File.exist?(classify_path)
      puts "  No classify.json found. Run 'classify #{map_name} #{experiment_name}' first."
      return
    end

    image_path = find_cached_image(cache)
    unless image_path
      puts "  No image found. Run 'generate' first."
      return
    end

    require 'vips'

    data = JSON.parse(File.read(classify_path))
    merged = data['merged_results'] || []

    grid = setup_hex_grid(room, cache)
    svc = grid[:svc]
    hex_coords = grid[:hex_coords]
    base = grid[:base]
    hex_pixel_map = grid[:hex_pixel_map]
    hex_size = hex_pixel_map[:hex_size]

    # Build lookup of classified hexes
    classified = {}
    merged.each { |r| classified[[r['x'], r['y']]] = r['hex_type'] }

    # Scale up for readability (target ~2000px wide minimum)
    scale = [2000.0 / base.width, 1.0].max.ceil
    img_w = base.width * scale
    img_h = base.height * scale
    scaled_hex_size = hex_size * scale

    if scale > 1
      base = base.resize(scale.to_f)
      puts "  Scaled #{scale}x to #{img_w}x#{img_h} for readability"
    end

    # Build SVG overlay
    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)

    font_size = [scaled_hex_size * 0.22, 8].max.round

    hex_coords.each do |hx, hy|
      info = svc.coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] * scale
      py = info[:py] * scale
      points = svc.hexagon_svg_points(px, py, scaled_hex_size)

      hex_type = classified[[hx, hy]]
      if hex_type
        color = VIS_COLORS[hex_type] || [255, 0, 255, 180] # magenta for unknown
        r, g, b, a = color
        opacity = (a / 255.0).round(2)
        svg_parts << %(<polygon points="#{points}" fill="rgb(#{r},#{g},#{b})" fill-opacity="#{opacity}" stroke="rgb(#{r},#{g},#{b})" stroke-width="1" stroke-opacity="0.8"/>)

        # Full type name label
        text_y = (py + font_size * 0.35).round
        svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="white" stroke="black" stroke-width="2" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{hex_type}</text>)
      else
        # Unclassified: thin faint outline
        svg_parts << %(<polygon points="#{points}" fill="none" stroke="white" stroke-width="0.5" stroke-opacity="0.15"/>)
      end
    end

    svg_parts << '</svg>'
    svg_string = svg_parts.join("\n")

    overlay = Vips::Image.svgload_buffer(svg_string)
    if overlay.width != img_w || overlay.height != img_h
      overlay = overlay.resize(img_w.to_f / overlay.width)
    end

    base_rgba = base.bands < 4 ? base.bandjoin(255) : base
    overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb

    result = base_rgba.composite2(overlay, :over)
    output_path = File.join(exp_dir, 'visualize.png')
    result.write_to_file(output_path)

    type_count = classified.values.tally.sort_by { |_, v| -v }
    puts "  Classified hexes: #{classified.length} / #{hex_coords.length}"
    type_count.each { |type, count| puts "    #{type}: #{count}" }
    puts "  Saved: #{output_path}"
  end

  # ---- normalize ----
  def cmd_normalize(room, cache, map_name, experiment_name, force: false)
    puts "=== [#{map_name}] normalize (#{experiment_name}) ==="

    exp_dir = experiment_cache_dir(cache, experiment_name)
    classify_path = File.join(exp_dir, 'classify.json')
    normalize_path = File.join(exp_dir, 'normalize.json')

    unless File.exist?(classify_path)
      puts "  No classify.json found. Run 'classify #{map_name} #{experiment_name}' first."
      return
    end

    if !force && File.exist?(normalize_path)
      puts "  Cached normalize.json exists. Use --force to re-run."
      data = JSON.parse(File.read(normalize_path))
      print_normalize_summary(data)
      return
    end

    image_path = find_cached_image(cache)
    unless image_path
      puts "  No image found. Run 'generate' first."
      return
    end

    require 'vips'

    classify_data = JSON.parse(File.read(classify_path))
    chunk_results = classify_data['raw_results'] || classify_data['merged_results'] || []

    grid = setup_hex_grid(room, cache)
    svc = grid[:svc]
    hex_coords = grid[:hex_coords]
    base = grid[:base]
    hex_pixel_map = grid[:hex_pixel_map]
    min_x = grid[:min_x]
    min_y = grid[:min_y]

    # Build edge map
    rgb_image = base.bands > 3 ? base.extract_band(0, n: 3) : base
    gray = rgb_image.colourspace(:b_w)
    # Simple Canny-like edge detection via Sobel
    begin
      sx = gray.sobel
      edge_map = (sx > 30).ifthenelse(255, 0).cast(:uchar)
    rescue StandardError => e
      warn "[BattlemapHarness] Edge detection failed: #{e.message}"
      edge_map = nil
    end

    # PRE-normalization stats
    pre_dist = chunk_results.group_by { |r| r['hex_type'] }.transform_values(&:length).sort_by { |_, v| -v }
    puts "  Pre-normalization: #{chunk_results.length} classified hexes"
    pre_dist.each { |type, count| puts "    #{type}: #{count}" }

    # Run normalization
    normalized = svc.normalize_v2(
      chunk_results, base, hex_pixel_map, hex_coords, min_x, min_y,
      edge_map: edge_map
    )

    # POST-normalization stats
    post_dist = normalized.group_by { |r| r['hex_type'] }.transform_values(&:length).sort_by { |_, v| -v }
    puts "\n  Post-normalization: #{normalized.length} classified hexes"
    post_dist.each { |type, count| puts "    #{type}: #{count}" }

    # Delta
    pre_hash = pre_dist.to_h
    post_hash = post_dist.to_h
    all_types = (pre_hash.keys + post_hash.keys).uniq.sort
    puts "\n  Delta:"
    all_types.each do |type|
      pre_c = pre_hash[type] || 0
      post_c = post_hash[type] || 0
      delta = post_c - pre_c
      next if delta == 0
      sign = delta > 0 ? '+' : ''
      puts "    #{type}: #{pre_c} -> #{post_c} (#{sign}#{delta})"
    end

    # Build normalized merged results
    norm_merged = {}
    normalized.each { |r| norm_merged[[r['x'], r['y']]] = r['hex_type'] }

    output = {
      'experiment' => experiment_name,
      'map' => map_name,
      'total_hexes' => hex_coords.length,
      'pre_classified' => chunk_results.length,
      'post_classified' => normalized.length,
      'pre_distribution' => pre_dist.to_h,
      'post_distribution' => post_dist.to_h,
      'merged_results' => norm_merged.map { |(x, y), t| { 'x' => x, 'y' => y, 'hex_type' => t } },
      'raw_results' => normalized
    }
    File.write(normalize_path, JSON.pretty_generate(output))
    puts "\n  Saved: #{normalize_path}"

    # Generate before/after visualizations
    puts "\n  Generating visualizations..."
    render_normalize_visualization(svc, hex_coords, base, hex_pixel_map, exp_dir,
                                    chunk_results, normalized, 'normalize_compare.png')
    puts "  Done."
  end

  def render_normalize_visualization(svc, hex_coords, base, hex_pixel_map, exp_dir,
                                      pre_results, post_results, filename)
    hex_size = hex_pixel_map[:hex_size]
    scale = [2000.0 / base.width, 1.0].max.ceil
    img_w = base.width * scale
    img_h = base.height * scale
    scaled_hex_size = hex_size * scale
    scaled_base = scale > 1 ? base.resize(scale.to_f) : base

    # Build lookups
    pre_map = {}
    pre_results.each { |r| pre_map[[r['x'], r['y']]] = r['hex_type'] }
    post_map = {}
    post_results.each { |r| post_map[[r['x'], r['y']]] = r['hex_type'] }

    # Side-by-side: left half = pre, right half = post
    # Actually render two separate images for easier comparison
    ['pre', 'post'].each do |stage|
      classified = stage == 'pre' ? pre_map : post_map
      svg_parts = []
      svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)

      font_size = [scaled_hex_size * 0.22, 8].max.round

      hex_coords.each do |hx, hy|
        info = svc.coord_lookup[[hx, hy]]
        next unless info

        px = info[:px] * scale
        py = info[:py] * scale
        points = svc.hexagon_svg_points(px, py, scaled_hex_size)

        hex_type = classified[[hx, hy]]
        if hex_type
          color = VIS_COLORS[hex_type] || [255, 0, 255, 180]
          r, g, b, a = color
          opacity = (a / 255.0).round(2)
          svg_parts << %(<polygon points="#{points}" fill="rgb(#{r},#{g},#{b})" fill-opacity="#{opacity}" stroke="rgb(#{r},#{g},#{b})" stroke-width="1" stroke-opacity="0.8"/>)
          text_y = (py + font_size * 0.35).round
          svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="white" stroke="black" stroke-width="2" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{hex_type}</text>)
        else
          svg_parts << %(<polygon points="#{points}" fill="none" stroke="white" stroke-width="0.5" stroke-opacity="0.15"/>)
        end
      end

      svg_parts << '</svg>'
      svg_string = svg_parts.join("\n")

      overlay = Vips::Image.svgload_buffer(svg_string)
      overlay = overlay.resize(img_w.to_f / overlay.width) if overlay.width != img_w
      base_rgba = scaled_base.bands < 4 ? scaled_base.bandjoin(255) : scaled_base
      overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb
      result = base_rgba.composite2(overlay, :over)

      out_path = File.join(exp_dir, "normalize_#{stage}.png")
      result.write_to_file(out_path)
      puts "    Saved: #{out_path}"
    end
  end

  def print_normalize_summary(data)
    puts "  Pre: #{data['pre_classified']} -> Post: #{data['post_classified']} / #{data['total_hexes']} hexes"
    pre = data['pre_distribution'] || {}
    post = data['post_distribution'] || {}
    all_types = (pre.keys + post.keys).uniq.sort
    all_types.each do |type|
      pre_c = pre[type] || 0
      post_c = post[type] || 0
      delta = post_c - pre_c
      next if delta == 0
      sign = delta > 0 ? '+' : ''
      puts "    #{type}: #{pre_c} -> #{post_c} (#{sign}#{delta})"
    end
  end

  # ==================================================
  # Shared helpers
  # ==================================================

  def setup_hex_grid(room, cache)
    image_path = find_cached_image(cache)
    abort "  No image found in #{cache}. Run 'generate' first." unless image_path

    require 'vips'
    svc = HarnessService.new(room)
    hex_coords = svc.generate_hex_coordinates
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min

    base = Vips::Image.new_from_file(image_path)
    hex_pixel_map = svc.build_hex_pixel_map(hex_coords, min_x, min_y, base.width, base.height)
    svc.setup_coord_lookup(hex_pixel_map)

    { svc: svc, hex_coords: hex_coords, min_x: min_x, min_y: min_y,
      base: base, hex_pixel_map: hex_pixel_map, image_path: image_path }
  end

  def load_overview_for_experiment(cache, experiment_name)
    # Check experiment-specific overview first
    if experiment_name
      exp_overview = File.join(experiment_cache_dir(cache, experiment_name), 'overview.json')
      return JSON.parse(File.read(exp_overview)) if File.exist?(exp_overview)
    end
    # Fall back to default overview
    default_path = File.join(cache, 'overview.json')
    return JSON.parse(File.read(default_path)) if File.exist?(default_path)

    nil
  end

  def load_experiment_config(name)
    config = @experiments[name]
    unless config
      available = @experiments.keys.join(', ')
      puts "  Unknown experiment: '#{name}'. Available: #{available}"
      return nil
    end
    config
  end

  def extract_type_names(overview)
    types = (overview['present_types'] || []).map { |t| t['type_name'] }
    types << 'off_map' unless types.include?('off_map')
    types.reject { |t| t == 'open_floor' }
  end

  def setup_regional_types(svc, overview)
    regional_types = overview['regional_types'] || []
    regional_map = {}
    always_available = %w[wall off_map]
    regional_types.each do |rt|
      region = rt['region']
      next unless region

      regional_map[region] = (rt['types'] || []) | always_available
    end
    svc.regional_type_map = regional_map
  end

  # ==================================================
  # Row-based chunking
  # ==================================================

  def build_row_chunks(hex_coords, rows_per_chunk)
    # Group hexes by visual row (hy value), then combine adjacent rows
    rows = hex_coords.group_by { |_, hy| hy }
    sorted_row_keys = rows.keys.sort

    # Determine grid dimensions for grid_pos
    total_row_groups = (sorted_row_keys.length.to_f / rows_per_chunk).ceil

    chunks = []
    sorted_row_keys.each_slice(rows_per_chunk).with_index do |row_keys, gy|
      coords = row_keys.flat_map { |k| rows[k] }
      chunks << {
        coords: coords,
        grid_pos: { gx: 0, gy: gy, nx: 1, ny: total_row_groups }
      }
    end
    chunks
  end

  # ==================================================
  # Label styles
  # ==================================================

  def build_labels(svc, style, chunk_coords)
    case style
    when 'sequential'
      svc.build_sequential_labels(chunk_coords)
    when 'alphanumeric'
      build_alphanumeric_labels(chunk_coords)
    when 'describe_first'
      # Same labels as sequential, prompt modification handled in build_classify_prompt
      svc.build_sequential_labels(chunk_coords)
    else
      svc.build_sequential_labels(chunk_coords)
    end
  end

  def build_alphanumeric_labels(chunk_coords)
    labels = {}
    reverse = {}

    # Group by visual row (hy), then assign row number + column letter
    sorted = chunk_coords.sort_by { |hx, hy| [hy, hx] }
    rows = sorted.group_by { |_, hy| hy }

    rows.keys.sort.each_with_index do |hy, row_idx|
      row_num = row_idx + 1
      row_hexes = rows[hy].sort_by { |hx, _| hx }
      row_hexes.each_with_index do |(hx, hy2), col_idx|
        col_letter = ('A'.ord + col_idx).chr
        label = "#{row_num}#{col_letter}"
        labels[[hx, hy2]] = label
        reverse[label] = [hx, hy2]
      end
    end

    { labels: labels, reverse: reverse }
  end

  # ==================================================
  # Multi-provider message building
  # ==================================================

  def build_classify_message(provider, prompt, image_base64)
    case provider
    when 'anthropic'
      [{ role: 'user', content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: image_base64 } },
        { type: 'text', text: prompt }
      ] }]
    when 'openai'
      [{ role: 'user', content: [
        { type: 'image_url', image_url: { url: "data:image/png;base64,#{image_base64}" } },
        { type: 'text', text: prompt }
      ] }]
    when 'gemini'
      [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/png', data: image_base64 },
        { type: 'text', text: prompt }
      ] }]
    else
      abort "Unknown provider: #{provider}"
    end
  end

  def adapter_for(provider)
    case provider
    when 'anthropic' then LLM::Adapters::AnthropicAdapter
    when 'openai'    then LLM::Adapters::OpenAIAdapter
    when 'gemini'    then LLM::Adapters::GeminiAdapter
    else abort "Unknown provider: #{provider}"
    end
  end

  def api_key_for(provider)
    key_name = case provider
               when 'anthropic' then 'anthropic'
               when 'openai'    then 'openai'
               when 'gemini'    then 'google_gemini'
               else provider
               end
    AIProviderService.api_key_for(key_name)
  end

  # ==================================================
  # Cost estimation (USD per 1M tokens)
  # ==================================================

  # Prices per million tokens (update as pricing changes)
  MODEL_COSTS = {
    # Anthropic
    'claude-haiku-4-5-20251001' => { input: 1.0, output: 5.0 },
    'claude-haiku-4-5'          => { input: 1.0, output: 5.0 },
    'claude-sonnet-4-6'         => { input: 3.0, output: 15.0 },
    'claude-sonnet-4-5'         => { input: 3.0, output: 15.0 },
    'claude-opus-4-6'           => { input: 15.0, output: 75.0 },
    # OpenAI
    'gpt-5-mini'                => { input: 0.15, output: 0.60 },
    'gpt-5.4'                   => { input: 2.50, output: 10.0 },
    # Gemini
    'gemini-3.0-flash-preview'  => { input: 0.10, output: 0.40 },
    'gemini-2.5-flash'          => { input: 0.15, output: 0.60 }
  }.freeze

  def estimate_cost(provider, model, input_tokens, output_tokens)
    costs = MODEL_COSTS[model]
    unless costs
      warn "  [cost] Unknown model '#{model}', using haiku pricing as fallback"
      costs = { input: 1.0, output: 5.0 }
    end
    (input_tokens * costs[:input] / 1_000_000.0) + (output_tokens * costs[:output] / 1_000_000.0)
  end

  # ==================================================
  # Prompt building
  # ==================================================

  def build_classify_prompt(svc, config, hex_list_str, scene_description, type_names, grid_pos: nil, map_layout: nil)
    classify_prompt = config['classify_prompt'] || 'default'
    label_style = config['label_style'] || 'sequential'

    if classify_prompt == 'default'
      prompt = svc.build_grouped_chunk_prompt(hex_list_str, scene_description, type_names,
                                              grid_pos: grid_pos, map_layout: map_layout)
      if label_style == 'describe_first'
        prompt = "First describe what you see in detail, then classify each hex.\n\n" + prompt
      end
      prompt
    else
      # Custom prompt with placeholder interpolation
      location_hint = grid_pos ? svc.send(:chunk_location_hint, grid_pos) : nil
      classify_prompt
        .gsub('{scene_description}', scene_description)
        .gsub('{type_names}', type_names.join(', '))
        .gsub('{hex_list}', hex_list_str)
        .gsub('{map_layout}', map_layout || '')
        .gsub('{location_hint}', location_hint || 'center')
    end
  end

  # ==================================================
  # Cache / output helpers
  # ==================================================

  def find_cached_image(cache)
    %w[png webp jpg jpeg].each do |ext|
      path = File.join(cache, "image.#{ext}")
      return path if File.exist?(path)
    end
    nil
  end

  def detect_image_format(path)
    bytes = File.binread(path, 16)
    if bytes[0..7] == "\x89PNG\r\n\x1a\n"
      'png'
    elsif bytes[0..3] == 'RIFF' && bytes[8..11] == 'WEBP'
      'webp'
    elsif bytes[0..1] == "\xFF\xD8"
      'jpg'
    else
      'png'
    end
  end

  def map_cache_dir(map_name)
    dir = File.join(CACHE_DIR, map_name)
    FileUtils.mkdir_p(dir)
    dir
  end

  def experiment_cache_dir(cache, experiment_name)
    dir = File.join(cache, 'experiments', experiment_name)
    FileUtils.mkdir_p(dir)
    dir
  end

  def print_overview_summary(data)
    puts "  Scene: #{data['scene_description']}"
    puts "  Layout: #{data['map_layout']}"
    types = (data['present_types'] || []).map { |t| t['type_name'] }
    puts "  Types: #{types.join(', ')}"
  end

  def print_classify_summary(data)
    puts "  Total classified: #{data['total_classified']} / #{data['total_hexes']} hexes"
    dist = data['type_distribution'] || {}
    dist.sort_by { |_, v| -v }.each { |type, count| puts "    #{type}: #{count}" }
    unclassified = (data['total_hexes'] || 0) - (data['total_classified'] || 0)
    puts "    (open_floor/unclassified): #{unclassified}"
    if data['cost']
      c = data['cost']
      puts "  Cost: $#{'%.4f' % c['estimated_usd']} (#{c['input_tokens']} in + #{c['output_tokens']} out), $#{'%.6f' % c['cost_per_hex']}/hex"
    end
  end
end

# -------------------------------------------------------
# CLI
# -------------------------------------------------------
args = ARGV.dup
force = args.delete('--force')

command = args[0]
map_name = args[1]
experiment = args[2]

unless command && map_name
  puts <<~USAGE
    Usage: bundle exec ruby tmp/battlemap_harness.rb <command> <map|all> [experiment] [--force]

    Commands:
      generate  <map>                    - Generate image via Gemini
      overview  <map>  [experiment]      - Run overview (default or experiment-specific)
      inspect   <map>                    - Generate labeled chunk images
      classify  <map>  <experiment>      - Run chunk classification
      visualize <map>  <experiment>      - Render color-coded classification overlay
      full      <map>                    - generate + overview + inspect
      all <cmd> [experiment]             - Run command on all maps

    Flags:
      --force    Delete cached results before running

    Experiments: defined in tmp/battlemap_experiments.yml
    Maps: forge, tavern, forest, office, cargo_bay
  USAGE
  exit 1
end

# Handle "all <cmd>" syntax
if command == 'all'
  command = map_name
  map_name = 'all'
  experiment = args[2]
end

BattlemapHarness.new.run(command, map_name, experiment, force: !!force)
