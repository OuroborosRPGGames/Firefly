# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative '../../lib/vector_math_helper'

# BattleMapTestGalleryService creates real Room records through the
# PlaceGeneratorService pipeline, then uses AIBattleMapGeneratorService
# to build the exact production prompt and generate images.
#
# This ensures the test gallery exercises the same code path as real
# in-game rooms, including furniture, decorations, and room features
# (doors/windows).
#
# Results (image URLs, prompts, room_ids) are persisted to a JSON file
# so generated images survive server restarts.
#
class BattleMapTestGalleryService
  extend VectorMathHelper
  RESULTS_DIR = File.join('public', 'uploads', 'battle_map_tests')
  RESULTS_FILE = File.join(RESULTS_DIR, 'results.json')
  TEST_LOCATION_NAME = 'Battle Map Test Gallery'

  # Each config has a `mode` key:
  # - :building  — uses PlaceGeneratorService to create a full building, picks a target room
  # - :standalone — creates a single Room directly with the given room_type
  #
  # All entries use blueprint generation mode.
  # First 8 = Gemini Flash (default tier), last 8 = Gemini Pro (high_quality tier).
  # Reduced to 3 core test configs for active experimentation.
  # Indoor building, outdoor natural, underground — covers the key scenarios.
  TEST_CONFIGS = [
    { mode: :building,    place_type: :tavern,     target_room: 'common_room', width: 45,  height: 35,  label: 'Tavern Common Room',  generation_mode: :blueprint, model_tier: :default },
    { mode: :standalone,  room_type: 'forest',     width: 60,  height: 50,  label: 'Forest Glade',         generation_mode: :blueprint, model_tier: :default },
    { mode: :standalone,  room_type: 'cave',       width: 40,  height: 35,  label: 'Cave Chamber',         generation_mode: :blueprint, model_tier: :default }
  ].freeze

  def initialize
    FileUtils.mkdir_p(RESULTS_DIR)
  end

  # Generate a battle map image for a specific test config.
  # Creates a real Room via PlaceGeneratorService, then uses the
  # production AIBattleMapGeneratorService prompt builder.
  #
  # @param config_index [Integer] index into TEST_CONFIGS
  # @return [Hash] { success:, prompt:, image_url:, room_id:, error:, model_used: }
  DEBUG_LOG = File.join(RESULTS_DIR, 'debug.log')

  def debug_log(msg)
    File.open(DEBUG_LOG, 'a') { |f| f.puts "[#{Time.now.iso8601}] #{msg}" }
  end

  def generate_image(config_index)
    debug_log "START generate_image(#{config_index})"
    config = TEST_CONFIGS[config_index]
    return { success: false, error: "Invalid config index: #{config_index}" } unless config

    # Clean up previous test room if it exists
    prev = load_results[config_index.to_s]
    if prev && prev['room_id']
      debug_log "Cleaning up previous room #{prev['room_id']}"
      cleanup_room(prev['room_id'])
    end

    # Create a real room through the generation pipeline
    debug_log "Generating test room for config: #{config[:label]}"
    room = generate_test_room(config)
    unless room
      debug_log "FAIL: Room generation returned nil"
      error_data = { success: false, error: 'Failed to generate test room', generated_at: Time.now.iso8601 }
      save_result(config_index, error_data)
      return error_data
    end
    debug_log "Room created: id=#{room.id}, type=#{room.room_type}"

    # Use the production prompt builder
    gen_mode = config[:generation_mode] || :text
    tier = config[:model_tier] || :default
    generator = AIBattleMapGeneratorService.new(room, mode: gen_mode, tier: tier)

    blueprint_svg = nil
    if gen_mode == :blueprint
      debug_log "Blueprint mode: generating SVG..."
      blueprint_svg = MapSvgRenderService.render_blueprint(room)
      debug_log "SVG generated: #{blueprint_svg.to_s.length} chars, has_svg=#{blueprint_svg&.include?('<svg')}"
      debug_log "Calling generate_blueprint_image..."
      result = generator.send(:generate_blueprint_image)
      debug_log "Blueprint image result: success=#{result[:success]}, error=#{result[:error]}, local_url=#{result[:local_url]}"
      prompt = generator.send(:build_blueprint_prompt)
    else
      debug_log "Text mode: building prompt..."
      prompt = generator.send(:build_image_prompt)
      aspect_ratio = generator.send(:calculate_aspect_ratio)
      dims = generator.send(:calculate_image_dimensions)
      tier = config[:model_tier] || :default
      debug_log "Calling ImageGenerationService.generate tier=#{tier}, dims=#{dims}..."
      result = LLM::ImageGenerationService.generate(
        prompt: prompt,
        options: {
          aspect_ratio: aspect_ratio,
          dimensions: dims,
          tier: tier
        }
      )
      debug_log "Image result: success=#{result[:success]}, error=#{result[:error]}, local_url=#{result[:local_url]}, model=#{result[:model_used]}"
    end

    if result[:success]
      debug_log "SUCCESS: Processing image..."
      # Trim borders and convert to WebP
      if result[:local_url]
        fs_path = result[:local_url].start_with?('/') ? "public#{result[:local_url]}" : "public/#{result[:local_url]}"
        MapSvgRenderService.trim_image_borders(fs_path)
        fs_path = MapSvgRenderService.convert_to_webp(fs_path)
      end

      # Resize, upscale, then overlay hex labels
      resized_url = nil
      upscaled_url = nil
      labeled_url = nil
      if fs_path
        paths = resize_and_label(fs_path, room)
        if paths
          resized_url = paths[:resized].sub(/^public/, '')
          resized_url = "/#{resized_url}" unless resized_url.start_with?('/')
          upscaled_url = paths[:upscaled].sub(/^public/, '')
          upscaled_url = "/#{upscaled_url}" unless upscaled_url.start_with?('/')
          labeled_url = paths[:labeled].sub(/^public/, '')
          labeled_url = "/#{labeled_url}" unless labeled_url.start_with?('/')
          debug_log "Resized: #{resized_url}, Upscaled: #{upscaled_url}, Labeled: #{labeled_url}"
        end
      end

      url = fs_path ? fs_path.sub(/^public/, '') : result[:local_url]
      url = "/#{url}" unless url&.start_with?('/')
      data = {
        success: true,
        prompt: prompt,
        description: room.long_description,
        image_url: url,
        resized_url: resized_url,
        upscaled_url: upscaled_url,
        labeled_url: labeled_url,
        room_id: room.id,
        model_used: result[:model_used],
        generated_at: Time.now.iso8601
      }

      # Save blueprint SVG for gallery display
      if blueprint_svg && blueprint_svg.include?('<svg')
        svg_filename = "blueprint_#{config_index}_#{Time.now.to_i}.svg"
        svg_path = File.join(RESULTS_DIR, svg_filename)
        File.write(svg_path, blueprint_svg)
        data[:blueprint_url] = "/uploads/battle_map_tests/#{svg_filename}"
      end

      save_result(config_index, data)
      debug_log "DONE: Image saved to #{url}"
      data
    else
      debug_log "FAIL: result[:error]=#{result[:error]}"
      error_data = { success: false, prompt: prompt, room_id: room.id, error: result[:error], generated_at: Time.now.iso8601 }
      save_result(config_index, error_data)
      error_data
    end
  rescue StandardError => e
    debug_log "EXCEPTION: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    error_data = { success: false, error: "#{e.class}: #{e.message}", generated_at: Time.now.iso8601 }
    save_result(config_index, error_data) rescue nil
    error_data
  end

  # Create a real Room record — dispatches to building or standalone mode
  # @param config [Hash] test config
  # @return [Room, nil] the target room
  def generate_test_room(config)
    if config[:mode] == :standalone
      generate_standalone_room(config)
    else
      generate_building_room(config)
    end
  rescue StandardError => e
    warn "[BattleMapTestGallery] Room generation failed: #{e.message}"
    nil
  end

  # Create a room through PlaceGeneratorService building pipeline
  # @param config [Hash] test config with :place_type and :target_room
  # @return [Room, nil]
  def generate_building_room(config)
    location = ensure_test_location

    result = Generators::PlaceGeneratorService.generate(
      location: location,
      place_type: config[:place_type],
      setting: :fantasy,
      generate_rooms: true,
      create_building: true,
      generate_furniture: true,
      options: { size: :standard }
    )

    unless result[:success] && result[:rooms]&.any?
      warn "[BattleMapTestGallery] PlaceGeneratorService failed: #{result[:errors]&.join(', ')}"
      return nil
    end

    # Find the target room by matching room_type from the layout
    target_room_type = config[:target_room]
    target_index = result[:layout]&.index { |r| r[:room_type] == target_room_type }
    room = target_index ? result[:rooms][target_index] : result[:rooms].first

    return nil unless room

    # Override room bounds to match the desired test size
    room.update(min_x: 0, max_x: config[:width], min_y: 0, max_y: config[:height])
    room.reload

    # Regenerate furniture and features at the new bounds
    # (originals were placed within the smaller building footprint)
    Place.where(room_id: room.id).delete
    RoomFeature.where(room_id: room.id).delete

    layout = [{ room_type: result[:layout]&.dig(target_index || 0, :room_type) || room.room_type, floor: 0, position: 0 }]

    Generators::PlaceGeneratorService.generate_room_furniture(
      place_type: config[:place_type],
      rooms: [room],
      layout: layout,
      setting: :fantasy
    )

    Generators::PlaceGeneratorService.generate_room_features(
      place_type: config[:place_type],
      rooms: [room],
      layout: layout,
      setting: :fantasy
    )

    room.reload
  end

  # Create a standalone Room directly (for outdoor / underground types)
  # @param config [Hash] test config with :room_type
  # @return [Room, nil]
  def generate_standalone_room(config)
    location = ensure_test_location
    room_type = config[:room_type]

    # Generate a description via LLM
    desc_result = Generators::RoomGeneratorService.generate_description_for_type(
      name: config[:label],
      room_type: room_type,
      parent: { name: 'Wilderness' },
      setting: :fantasy,
      seed_terms: [],
      options: {}
    )
    description = desc_result[:content] || "A #{room_type} area."

    room = Room.create(
      location_id: location.id,
      name: "Test Gallery - #{config[:label]}",
      room_type: room_type,
      long_description: description,
      min_x: 0, max_x: config[:width],
      min_y: 0, max_y: config[:height],
      min_z: 0, max_z: 10,
      city_role: 'building'
    )

    # Generate furniture, decorations, and features using PlaceGeneratorService helpers
    layout = [{ room_type: room_type, floor: room_type.match?(/crypt|dungeon|cave/) ? -1 : 0, position: 0 }]

    Generators::PlaceGeneratorService.generate_room_furniture(
      place_type: room_type.to_sym,
      rooms: [room],
      layout: layout,
      setting: :fantasy
    )

    Generators::PlaceGeneratorService.generate_room_features(
      place_type: room_type.to_sym,
      rooms: [room],
      layout: layout,
      setting: :fantasy
    )

    room.reload
  end

  # Find or create a Location for test gallery rooms
  # @return [Location]
  def ensure_test_location
    existing = Location.first(name: TEST_LOCATION_NAME)
    return existing if existing

    zone = Zone.first
    Location.create(
      zone_id: zone.id,
      name: TEST_LOCATION_NAME,
      description: 'Temporary location for battle map test gallery rooms',
      location_type: 'building',
      active: true
    )
  end

  # Delete a test room and its associated records
  # @param room_id [Integer]
  def cleanup_room(room_id)
    return unless room_id

    room = Room[room_id]
    return unless room

    DB.transaction do
      Place.where(room_id: room.id).delete
      Decoration.where(room_id: room.id).delete
      RoomFeature.where(room_id: room.id).delete
      RoomHex.where(room_id: room.id).delete
      room.destroy
    end
  rescue StandardError => e
    warn "[BattleMapTestGallery] Cleanup failed for room #{room_id}: #{e.message}"
  end

  # Delete all test rooms created by this gallery
  def cleanup_all
    results = load_results
    results.each_value do |data|
      cleanup_room(data['room_id']) if data['room_id']
    end

    # Also clean up any orphaned rooms in the test location
    location = Location.first(name: TEST_LOCATION_NAME)
    if location
      Room.where(location_id: location.id).each do |room|
        cleanup_room(room.id)
      end
    end

    # Clear saved results
    File.write(RESULTS_FILE, JSON.pretty_generate({})) if File.exist?(RESULTS_FILE)
  end

  # Load a Room record for a given config index from saved results
  # @param config_index [Integer]
  # @return [Room, nil]
  def load_room(config_index)
    data = load_results[config_index.to_s]
    return nil unless data && data['room_id']

    Room[data['room_id']]
  end

  GALLERY_HEX_SIZE_FEET = 2
  RESIZE_MAX_SIDE = 1024
  UPSCALE_FACTOR = 4

  # Resize image to match room aspect ratio, upscale 2x, then overlay hex grid labels.
  # Pipeline: original → resize (1024px) → upscale (2048px) → label (2ft hexes)
  # Saves all intermediate files, preserving the original.
  # @param image_path [String] filesystem path to the original webp image
  # @param room [Room] the room record for hex grid dimensions
  # @return [Hash, nil] { resized:, upscaled:, labeled: } or nil on failure
  def resize_and_label(image_path, room)
    return nil unless image_path && File.exist?(image_path)

    require 'vips'

    room_w = (room.max_x - room.min_x).to_f
    room_h = (room.max_y - room.min_y).to_f
    return nil if room_w <= 0 || room_h <= 0

    # Calculate target dimensions preserving room aspect ratio
    if room_w >= room_h
      target_w = RESIZE_MAX_SIDE
      target_h = (RESIZE_MAX_SIDE * room_h / room_w).round
    else
      target_h = RESIZE_MAX_SIDE
      target_w = (RESIZE_MAX_SIDE * room_w / room_h).round
    end

    # Step 0: Symmetric border trim — detect background from corners, trim equally
    img = Vips::Image.new_from_file(image_path)
    img = symmetric_trim(img)

    # Step 1: Save resized copy (original stays untouched)
    resized_path = image_path.sub(/\.(png|jpg|jpeg|webp)$/i, '_resized.\1')
    resized = img.thumbnail_image(target_w, height: target_h, size: :force)
    resized.write_to_file(resized_path)
    debug_log "Resized to #{target_w}x#{target_h} (room #{room_w.round}x#{room_h.round}ft) → #{resized_path}"

    # Step 2: AI upscale via Crystal (Replicate) for sharp hex labeling
    upscaled_path = image_path.sub(/\.(png|jpg|jpeg|webp)$/i, '_upscaled.\1')
    if ReplicateUpscalerService.available?
      debug_log "Upscaling #{UPSCALE_FACTOR}x via Crystal (Replicate)..."
      result = ReplicateUpscalerService.upscale(resized_path, scale: UPSCALE_FACTOR)
      if result[:success]
        # Crystal may return a different format — convert to match expected path
        if result[:output_path] != upscaled_path
          upscaled_img = Vips::Image.new_from_file(result[:output_path])
          upscaled_img.write_to_file(upscaled_path)
          File.delete(result[:output_path]) if File.exist?(result[:output_path])
        end
        upscaled_img ||= Vips::Image.new_from_file(upscaled_path)
        debug_log "Crystal upscaled to #{upscaled_img.width}x#{upscaled_img.height} → #{upscaled_path}"
      else
        debug_log "Crystal upscale failed: #{result[:error]}, falling back to lanczos3"
        upscaled = resized.resize(UPSCALE_FACTOR.to_f, kernel: :lanczos3)
        upscaled.write_to_file(upscaled_path)
        debug_log "Lanczos3 fallback upscaled to #{upscaled.width}x#{upscaled.height} → #{upscaled_path}"
      end
    else
      debug_log "Replicate not configured, using lanczos3 #{UPSCALE_FACTOR}x upscale"
      upscaled = resized.resize(UPSCALE_FACTOR.to_f, kernel: :lanczos3)
      upscaled.write_to_file(upscaled_path)
      debug_log "Lanczos3 upscaled to #{upscaled.width}x#{upscaled.height} → #{upscaled_path}"
    end

    # Step 3: Overlay hex labels with 2ft hexes onto the upscaled image
    generator = AIBattleMapGeneratorService.new(room)
    labeled_path = generator.send(:overlay_hex_labels, upscaled_path, hex_size_feet: GALLERY_HEX_SIZE_FEET)

    return nil unless labeled_path

    { resized: resized_path, upscaled: upscaled_path, labeled: labeled_path }
  rescue StandardError => e
    debug_log "resize_and_label failed: #{e.class}: #{e.message}"
    warn "[BattleMapTestGallery] resize_and_label failed: #{e.message}"
    nil
  end

  # Trait display colors for multi-trait hex classification overlay.
  # Priority order determines which trait gets the fill color when multiple are present.
  TRAIT_COLORS = {
    'off_map'          => { color: 'rgba(0,0,0,0.75)',       label: 'Off',   priority: 0 },
    'wall'             => { color: 'rgba(80,80,80,0.70)',    label: 'Wall',  priority: 1 },
    'window'           => { color: 'rgba(100,180,255,0.55)', label: 'Win',   priority: 2 },
    'exit'             => { color: 'rgba(0,220,80,0.55)',    label: 'Exit',  priority: 3 },
    'water_deep'       => { color: 'rgba(0,40,180,0.60)',    label: 'Deep',  priority: 4 },
    'water_swimming'   => { color: 'rgba(0,70,200,0.55)',    label: 'Swim',  priority: 5 },
    'water_wading'     => { color: 'rgba(0,100,220,0.45)',   label: 'Wade',  priority: 6 },
    'water_puddle'     => { color: 'rgba(80,160,255,0.35)',  label: 'Pudl',  priority: 7 },
    'hazard'           => { color: 'rgba(200,0,200,0.55)',   label: 'Haz',   priority: 8 },
    'elevation_up'     => { color: 'rgba(180,120,40,0.50)',  label: 'Up',    priority: 9 },
    'elevation_down'   => { color: 'rgba(100,60,20,0.50)',   label: 'Down',  priority: 10 },
    'cover'            => { color: 'rgba(200,180,0,0.45)',   label: 'Cov',   priority: 11 },
    'concealment'      => { color: 'rgba(120,200,80,0.40)',  label: 'Conc',  priority: 11.5 },
    'difficult'        => { color: 'rgba(180,100,0,0.40)',   label: 'Diff',  priority: 12 },
    'open'             => { color: 'rgba(0,200,0,0.25)',     label: 'Open',  priority: 99 }
  }.freeze

  WATER_DEPTHS = %w[none puddle wading swimming deep].freeze
  HAZARD_TYPES = %w[fire lava acid spikes trap poison electricity explosives].freeze

  # === Hex Type System (v4) ===
  # Simple enum of object/terrain types. Each hex gets one type.
  # Known types map to tactical properties via HEX_TYPE_PROPERTIES.
  # "other" triggers a detailed second pass.
  SIMPLE_HEX_TYPES = %w[
    tree dense_trees shrubbery boulder mud snow ice
    puddle wading_water deep_water table chair bench fire log
    wall glass_window open_window barrel balcony staircase door archway
    rubble pillar crate chest wagon tent
    pit cliff ledge bridge fence gate
    off_map open_floor other
  ].freeze

  HEX_TYPE_PROPERTIES = {
    'tree'          => { 'provides_cover' => true, 'traversable' => true },
    'dense_trees'   => { 'is_wall' => true, 'traversable' => false, 'provides_concealment' => true },
    'shrubbery'     => { 'provides_concealment' => true, 'traversable' => true, 'difficult_terrain' => true },
    'boulder'       => { 'provides_cover' => true, 'traversable' => false },
    'mud'           => { 'traversable' => true, 'difficult_terrain' => true },
    'snow'          => { 'traversable' => true, 'difficult_terrain' => true },
    'ice'           => { 'traversable' => true, 'difficult_terrain' => true },
    'puddle'        => { 'traversable' => true, 'water_depth' => 'puddle', 'difficult_terrain' => true },
    'wading_water'  => { 'traversable' => true, 'water_depth' => 'wading', 'difficult_terrain' => true },
    'deep_water'    => { 'traversable' => false, 'water_depth' => 'deep' },
    'table'         => { 'traversable' => true, 'elevation' => 3 },
    'chair'         => { 'traversable' => true },
    'bench'         => { 'traversable' => true },
    'fire'          => { 'traversable' => true, 'hazards' => ['fire'], 'difficult_terrain' => true },
    'log'           => { 'traversable' => true, 'provides_cover' => true, 'difficult_terrain' => true },
    'wall'          => { 'is_wall' => true, 'traversable' => false },
    'glass_window'  => { 'is_window' => true, 'is_window_open' => false, 'is_wall' => true, 'traversable' => false },
    'open_window'   => { 'is_window' => true, 'is_window_open' => true, 'is_wall' => true, 'traversable' => false },
    'barrel'        => { 'provides_cover' => true, 'elevation' => 3, 'difficult_terrain' => true, 'traversable' => true },
    'balcony'       => { 'traversable' => true, 'elevation' => 8 },
    'staircase'     => { 'traversable' => true, 'elevation' => 4, 'difficult_terrain' => true },
    'door'          => { 'is_exit' => true, 'traversable' => true },
    'archway'       => { 'is_exit' => true, 'traversable' => true },
    'rubble'        => { 'difficult_terrain' => true, 'traversable' => true, 'elevation' => 2 },
    'pillar'        => { 'provides_cover' => true, 'traversable' => false },
    'crate'         => { 'provides_cover' => true, 'traversable' => false, 'elevation' => 3 },
    'chest'         => { 'traversable' => true, 'elevation' => 2 },
    'wagon'         => { 'provides_cover' => true, 'traversable' => false, 'elevation' => 3 },
    'tent'          => { 'provides_concealment' => true, 'traversable' => true },
    'pit'           => { 'traversable' => false, 'elevation' => -6 },
    'cliff'         => { 'is_wall' => true, 'traversable' => false },
    'ledge'         => { 'traversable' => true, 'elevation' => 4 },
    'bridge'        => { 'traversable' => true, 'elevation' => 4 },
    'fence'         => { 'provides_cover' => true, 'traversable' => false },
    'gate'          => { 'is_exit' => true, 'traversable' => true },
    'off_map'       => { 'is_off_map' => true, 'traversable' => false },
    'open_floor'    => {},
    'other'         => {}
  }.freeze

  # Default properties for any hex not overridden by its type
  HEX_DEFAULT_PROPERTIES = {
    'traversable' => true, 'provides_cover' => false, 'provides_concealment' => false,
    'elevation' => 0, 'is_wall' => false, 'is_window' => false, 'is_window_open' => false,
    'is_exit' => false, 'is_off_map' => false, 'difficult_terrain' => false,
    'water_depth' => 'none', 'hazards' => []
  }.freeze

  CLASSIFICATION_MODEL = 'gemini-3-flash-preview'
  CHUNK_SIZE = 50
  MAX_CONCURRENT_CHUNKS = 30
  MAX_CONCURRENT_MAPS = 3

  # Gemini structured output schema for hex classification
  CLASSIFICATION_SCHEMA = {
    type: 'OBJECT',
    properties: {
      hexes: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            label:             { type: 'STRING', description: 'Hex label like "1-A", "2-B"' },
            traversable:       { type: 'BOOLEAN', description: 'Can a character walk through? (default: true)' },
            provides_cover:    { type: 'BOOLEAN', description: 'Physical barrier stopping projectiles? (default: false)' },
            provides_concealment: { type: 'BOOLEAN', description: 'Visually obscures without stopping projectiles? (default: false)' },
            elevation:         { type: 'INTEGER', description: 'Height in feet relative to ground (default: 0)' },
            is_wall:           { type: 'BOOLEAN', description: 'Solid impassable structure? (default: false)' },
            is_window:         { type: 'BOOLEAN', description: 'Window in a wall? (default: false)' },
            is_window_open:    { type: 'BOOLEAN', description: 'Open/broken window vs glazed? (default: false)' },
            is_exit:           { type: 'BOOLEAN', description: 'Doorway, archway, gate, or passage? (default: false)' },
            is_off_map:        { type: 'BOOLEAN', description: 'Outside the playable room area? (default: false)' },
            difficult_terrain: { type: 'BOOLEAN', description: 'Movement penalty (rubble, mud, etc.)? (default: false)' },
            water_depth:       { type: 'STRING', enum: WATER_DEPTHS, description: 'Water depth (default: none)' },
            hazards:           { type: 'ARRAY', items: { type: 'STRING', enum: HAZARD_TYPES }, description: 'Active hazards present' }
          },
          required: %w[label]
        }
      }
    },
    required: %w[hexes]
  }.freeze

  # Run LLM hex classification on a gallery entry's labeled image.
  # Uses chunked classification: splits hex grid into chunks of CHUNK_SIZE,
  # crops the labeled image to each chunk's bounding box, and sends cropped
  # images to Gemini for classification. Results are merged.
  # @param config_index [Integer]
  # @return [Hash] result data with hex_classifications added
  def classify_hexes(config_index)
    data = load_results[config_index.to_s]
    return { success: false, error: 'No result for this index' } unless data && data['success']

    room = Room[data['room_id']]
    return { success: false, error: "Room #{data['room_id']} not found" } unless room

    # Use unlabeled upscaled image as base — each chunk gets only its own labels
    upscaled_url = data['upscaled_url']
    return { success: false, error: 'No upscaled image' } unless upscaled_url

    upscaled_path = upscaled_url.start_with?('/') ? "public#{upscaled_url}" : "public/#{upscaled_url}"
    return { success: false, error: 'Upscaled image file missing' } unless File.exist?(upscaled_path)

    require 'vips'

    @coord_lookup = nil # Reset per-entry lookup cache
    model = CLASSIFICATION_MODEL
    debug_log "Classifying ##{config_index} with #{model} (#{GALLERY_HEX_SIZE_FEET}ft hexes, chunked)..."

    # Generate hex coords with gallery-specific hex size
    generator = AIBattleMapGeneratorService.new(room)
    hex_coords = generator.send(:custom_hex_coords_for_room, GALLERY_HEX_SIZE_FEET)
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min

    room_w = (room.max_x - room.min_x).round
    room_h = (room.max_y - room.min_y).round

    debug_log "  #{hex_coords.length} hexes at #{GALLERY_HEX_SIZE_FEET}ft, room #{room_w}x#{room_h}ft"

    # Precompute pixel positions for all hexes (needed for cropping + labeling)
    base = Vips::Image.new_from_file(upscaled_path)
    img_width = base.width
    img_height = base.height
    hex_pixel_map = build_hex_pixel_map(hex_coords, generator, min_x, min_y, img_width, img_height, hex_coords)

    # Build coord_lookup eagerly so threads can share it (read-only)
    @coord_lookup = {}
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]

      @coord_lookup[[info[:hx], info[:hy]]] = info
    end

    # Split into spatial chunks (rectangular tiles) for classification
    api_key = AIProviderService.api_key_for('google_gemini')
    all_chunk_results = []
    chunk_urls = []
    results_mutex = Mutex.new
    chunks = build_spatial_chunks(hex_coords, CHUNK_SIZE)
    semaphore = Mutex.new
    active_count = 0
    max_wait = 300 # seconds

    debug_log "  #{chunks.length} spatial chunks (~#{CHUNK_SIZE} hexes each, max #{MAX_CONCURRENT_CHUNKS} concurrent)"

    # Diagnostic: log pixel mapping for a sample of hexes (useful for alignment debugging)
    sample_labels = %w[1-A 1-E 5-A 5-E 10-A 10-E 15-A 21-E]
    sample_labels.each do |lbl|
      info = hex_pixel_map[lbl]
      debug_log "  HEX #{lbl} -> px=(#{info[:px]},#{info[:py]}) hx=(#{info[:hx]},#{info[:hy]})" if info
    end

    threads = chunks.each_with_index.map do |chunk_info, chunk_idx|
      chunk = chunk_info[:coords]
      Thread.new do
        # Semaphore: wait until a slot is available
        loop do
          slot_available = false
          semaphore.synchronize do
            if active_count < MAX_CONCURRENT_CHUNKS
              active_count += 1
              slot_available = true
            end
          end
          break if slot_available
          sleep 0.5
        end

        begin
          chunk_labels = chunk.map { |x, y| generator.send(:coord_to_label, x, y, min_x, min_y, hex_coords_override: hex_coords) }

          # Crop unlabeled image, then overlay ONLY this chunk's hex labels
          crop_result = crop_image_for_chunk(base, chunk, hex_pixel_map, img_width, img_height)
          labeled_crop = overlay_chunk_labels(crop_result, chunk, generator, min_x, min_y, hex_coords, hex_pixel_map)
          chunk_png_path = File.join(RESULTS_DIR, "chunk_#{config_index}_#{chunk_idx}.png")
          File.binwrite(chunk_png_path, labeled_crop)
          chunk_url = "/uploads/battle_map_tests/chunk_#{config_index}_#{chunk_idx}.png"
          results_mutex.synchronize { chunk_urls << { index: chunk_idx, url: chunk_url } }
          cropped_base64 = Base64.strict_encode64(labeled_crop)

          prompt = build_classification_prompt(chunk_labels, room_w, room_h, chunk_coords: chunk, all_hex_coords: hex_coords, generator: generator)

          messages = [{
            role: 'user',
            content: [
              { type: 'image', mime_type: 'image/png', data: cropped_base64 },
              { type: 'text', text: prompt }
            ]
          }]

          response = LLM::Adapters::GeminiAdapter.generate(
            messages: messages,
            model: model,
            api_key: api_key,
            response_schema: CLASSIFICATION_SCHEMA,
            options: { max_tokens: 65536, timeout: 120, temperature: 0, thinking_level: 'minimal' }
          )

          if response[:success]
            content = response[:text] || response[:content]
            chunk_classifications = parse_chunk_classifications(content, chunk, generator, min_x, min_y, hex_coords)
            results_mutex.synchronize { all_chunk_results.concat(chunk_classifications) }
            debug_log "  Chunk #{chunk_idx + 1}/#{chunks.length}: #{chunk_classifications.length} notable hexes"
          else
            debug_log "  Chunk #{chunk_idx + 1}/#{chunks.length} FAILED: #{response[:error]}"
          end
        ensure
          semaphore.synchronize { active_count -= 1 }
        end
      end
    end

    # Wait for all chunks to complete
    threads.each { |t| t.join(max_wait) }

    # Fill in defaults for any hex not returned by any chunk
    classifications = fill_default_hexes(all_chunk_results, hex_coords, generator, min_x, min_y)

    # Generate the classified overlay SVG (derive labeled_path for naming convention)
    labeled_path = upscaled_path.sub('_upscaled', '_labeled')
    classified_path = generate_classified_overlay(labeled_path, room, classifications, generator, hex_coords)
    classified_url = nil
    if classified_path
      classified_url = classified_path.sub(/^public/, '')
      classified_url = "/#{classified_url}" unless classified_url.start_with?('/')
    end

    # Save to results (atomic merge to avoid race conditions)
    update_result(config_index) do |current_data|
      current_data['hex_classifications'] = classifications
      current_data['classified_url'] = classified_url
      current_data['classification_model'] = model
      current_data['classified_at'] = Time.now.iso8601
      current_data['hex_size_feet'] = GALLERY_HEX_SIZE_FEET
      current_data['chunk_urls'] = chunk_urls.sort_by { |c| c[:index] }.map { |c| c[:url] }
    end

    debug_log "Classified ##{config_index}: #{classifications.length} hexes (#{all_chunk_results.length} notable), model=#{model}"
    { success: true, count: classifications.length, model: model, approach: 'legacy' }
  rescue StandardError => e
    debug_log "classify_hexes failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    { success: false, error: "#{e.class}: #{e.message}" }
  end

  # === Approach A: Simple Enum Classification ===
  # Each hex gets a type from SIMPLE_HEX_TYPES. Known types map to properties
  # via HEX_TYPE_PROPERTIES lookup. Only "other" hexes get a detailed second pass.
  SIMPLE_CLASSIFICATION_SCHEMA = {
    type: 'OBJECT',
    properties: {
      hexes: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            label:    { type: 'STRING', description: 'Hex label like "1-A", "2-B"' },
            hex_type: { type: 'STRING', enum: SIMPLE_HEX_TYPES, description: 'What occupies this hex at ground level' }
          },
          required: %w[label hex_type]
        }
      }
    },
    required: %w[hexes]
  }.freeze

  def classify_hexes_simple(config_index)
    data = load_results[config_index.to_s]
    return { success: false, error: 'No result for this index' } unless data && data['success']

    room = Room[data['room_id']]
    return { success: false, error: "Room #{data['room_id']} not found" } unless room

    upscaled_url = data['upscaled_url']
    return { success: false, error: 'No upscaled image' } unless upscaled_url

    upscaled_path = upscaled_url.start_with?('/') ? "public#{upscaled_url}" : "public/#{upscaled_url}"
    return { success: false, error: 'Upscaled image file missing' } unless File.exist?(upscaled_path)

    require 'vips'

    @coord_lookup = nil
    model = CLASSIFICATION_MODEL
    debug_log "Simple classify ##{config_index} with #{model}..."

    generator = AIBattleMapGeneratorService.new(room)
    hex_coords = generator.send(:custom_hex_coords_for_room, GALLERY_HEX_SIZE_FEET)
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min
    room_w = (room.max_x - room.min_x).round
    room_h = (room.max_y - room.min_y).round

    base = Vips::Image.new_from_file(upscaled_path)
    img_width = base.width
    img_height = base.height
    hex_pixel_map = build_hex_pixel_map(hex_coords, generator, min_x, min_y, img_width, img_height, hex_coords)

    @coord_lookup = {}
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]

      @coord_lookup[[info[:hx], info[:hy]]] = info
    end

    api_key = AIProviderService.api_key_for('google_gemini')
    all_chunk_results = []
    other_hexes = []
    chunk_urls = []
    results_mutex = Mutex.new
    chunks = build_spatial_chunks(hex_coords, CHUNK_SIZE)
    semaphore = Mutex.new
    active_count = 0
    max_wait = 300

    debug_log "  #{chunks.length} spatial chunks, simple enum schema"

    # Phase 1: Simple enum classification (parallel chunks)
    threads = chunks.each_with_index.map do |chunk_info, chunk_idx|
      chunk = chunk_info[:coords]
      Thread.new do
        loop do
          slot_available = false
          semaphore.synchronize do
            if active_count < MAX_CONCURRENT_CHUNKS
              active_count += 1
              slot_available = true
            end
          end
          break if slot_available
          sleep 0.5
        end

        begin
          chunk_labels = chunk.map { |x, y| generator.send(:coord_to_label, x, y, min_x, min_y, hex_coords_override: hex_coords) }

          crop_result = crop_image_for_chunk(base, chunk, hex_pixel_map, img_width, img_height)
          labeled_crop = overlay_chunk_labels(crop_result, chunk, generator, min_x, min_y, hex_coords, hex_pixel_map)
          chunk_png_path = File.join(RESULTS_DIR, "chunk_simple_#{config_index}_#{chunk_idx}.png")
          File.binwrite(chunk_png_path, labeled_crop)
          chunk_url = "/uploads/battle_map_tests/chunk_simple_#{config_index}_#{chunk_idx}.png"
          results_mutex.synchronize { chunk_urls << { index: chunk_idx, url: chunk_url } }
          cropped_base64 = Base64.strict_encode64(labeled_crop)

          prompt = build_simple_classification_prompt(chunk_labels, room_w, room_h, chunk_coords: chunk, all_hex_coords: hex_coords, generator: generator)

          messages = [{
            role: 'user',
            content: [
              { type: 'image', mime_type: 'image/png', data: cropped_base64 },
              { type: 'text', text: prompt }
            ]
          }]

          response = LLM::Adapters::GeminiAdapter.generate(
            messages: messages,
            model: model,
            api_key: api_key,
            response_schema: SIMPLE_CLASSIFICATION_SCHEMA,
            options: { max_tokens: 65536, timeout: 120, temperature: 0, thinking_level: 'minimal' }
          )

          if response[:success]
            content = response[:text] || response[:content]
            chunk_results = parse_simple_chunk(content, generator, min_x, min_y, hex_coords)
            results_mutex.synchronize do
              all_chunk_results.concat(chunk_results)
              other_hexes.concat(chunk_results.select { |h| h['hex_type'] == 'other' })
            end
            debug_log "  Simple chunk #{chunk_idx + 1}/#{chunks.length}: #{chunk_results.length} notable"
          else
            debug_log "  Simple chunk #{chunk_idx + 1}/#{chunks.length} FAILED: #{response[:error]}"
          end
        ensure
          semaphore.synchronize { active_count -= 1 }
        end
      end
    end

    threads.each { |t| t.join(max_wait) }

    # Phase 2: Re-classify "other" hexes with detailed schema (if any)
    detailed_results = []
    if other_hexes.any?
      debug_log "  Phase 2: #{other_hexes.length} 'other' hexes need detailed classification"
      detailed_results = reclassify_other_hexes(other_hexes, base, hex_pixel_map, generator, min_x, min_y, hex_coords, room_w, room_h, api_key, model, img_width, img_height)
    end

    # Build final classifications: expand known types, merge detailed results for "other"
    detailed_lookup = {}
    detailed_results.each { |d| detailed_lookup[d['label']] = d }

    expanded = all_chunk_results.map do |hex_data|
      if hex_data['hex_type'] == 'other' && detailed_lookup[hex_data['label']]
        detailed_lookup[hex_data['label']]
      else
        expand_hex_type_to_properties(hex_data['hex_type'], hex_data['label'], x: hex_data['x'], y: hex_data['y'])
      end
    end

    # Fill defaults for unclassified hexes
    returned_labels = {}
    expanded.each { |c| returned_labels[c['label']] = true }

    classifications = expanded.dup
    hex_coords.each do |hx, hy|
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
      next if returned_labels[label]

      classifications << expand_hex_type_to_properties('open_floor', label, x: hx, y: hy)
    end

    # Generate overlay (approach-specific filename)
    labeled_path = upscaled_path.sub('_upscaled', '_labeled')
    classified_path = generate_classified_overlay(labeled_path, room, classifications, generator, hex_coords, suffix: 'classified_simple')
    classified_url = nil
    if classified_path
      classified_url = classified_path.sub(/^public/, '')
      classified_url = "/#{classified_url}" unless classified_url.start_with?('/')
    end

    # Save results under approach-specific keys (preserves other approach results)
    simple_data = {
      'hex_classifications' => classifications,
      'classified_url' => classified_url,
      'classification_model' => model,
      'classified_at' => Time.now.iso8601,
      'other_count' => other_hexes.length,
      'chunk_urls' => chunk_urls.sort_by { |c| c[:index] }.map { |c| c[:url] }
    }
    update_result(config_index) do |current_data|
      current_data['simple'] = simple_data
      current_data['hex_size_feet'] = GALLERY_HEX_SIZE_FEET
    end

    debug_log "Simple classified ##{config_index}: #{classifications.length} hexes, #{other_hexes.length} 'other'"
    { success: true, count: classifications.length, model: model, approach: 'simple', other_count: other_hexes.length }
  rescue StandardError => e
    debug_log "classify_hexes_simple failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    { success: false, error: "#{e.class}: #{e.message}" }
  end

  # === Approach B: Overview Pre-Pass + Constrained Enum Classification ===
  # Phase 1: Send the unlabeled resized image for scene analysis — model identifies
  #   which types are present and can define custom types with properties.
  # Phase 2: Chunked classification constrained to ONLY the discovered types.
  OVERVIEW_SCHEMA = {
    type: 'OBJECT',
    properties: {
      scene_description: { type: 'STRING', description: 'Brief 1-2 sentence summary of the battle map scene' },
      map_layout: { type: 'STRING', description: 'Spatial layout: what is where (north/south/center/edges). E.g. "Walls ring the perimeter. Tables cluster center-left. Fireplace dominates the north wall."' },
      present_types: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            type_name:           { type: 'STRING', description: 'Short snake_case name (e.g. tree, wall, table)' },
            visual_description:  { type: 'STRING', description: 'What this looks like in the image (color, shape, texture) so chunk classifiers can identify it' },
            custom_type_justification: { type: 'STRING', description: 'Required if type_name is NOT a standard type. Explain why no standard type fits.' },
            traversable:         { type: 'BOOLEAN', description: 'Can someone walk through?' },
            provides_cover:      { type: 'BOOLEAN', description: 'Stops projectiles?' },
            provides_concealment: { type: 'BOOLEAN', description: 'Visually obscures but doesnt stop projectiles?' },
            is_wall:             { type: 'BOOLEAN', description: 'Solid impassable structure?' },
            is_exit:             { type: 'BOOLEAN', description: 'Doorway, archway, gate?' },
            difficult_terrain:   { type: 'BOOLEAN', description: 'Movement penalty?' },
            elevation:           { type: 'INTEGER', description: 'Height in feet (0=ground)' },
            water_depth:         { type: 'STRING', enum: WATER_DEPTHS, description: 'Water depth if applicable (default: none)' },
            hazards:             { type: 'ARRAY', items: { type: 'STRING', enum: HAZARD_TYPES }, description: 'Active hazards (fire, lava, acid, etc.)' }
          },
          required: %w[type_name visual_description traversable provides_cover provides_concealment is_wall is_exit difficult_terrain elevation]
        }
      },
      chunk_descriptions: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            chunk_label: { type: 'STRING', description: 'Chunk label from the image (e.g. A1, B2)' },
            description: { type: 'STRING', description: '1-2 sentences: what types are visible in this region and where' }
          },
          required: %w[chunk_label description]
        }
      }
    },
    required: %w[scene_description map_layout present_types chunk_descriptions]
  }.freeze

  def classify_hexes_overview(config_index)
    data = load_results[config_index.to_s]
    return { success: false, error: 'No result for this index' } unless data && data['success']

    room = Room[data['room_id']]
    return { success: false, error: "Room #{data['room_id']} not found" } unless room

    upscaled_url = data['upscaled_url']
    resized_url = data['resized_url']
    return { success: false, error: 'No upscaled image' } unless upscaled_url

    upscaled_path = upscaled_url.start_with?('/') ? "public#{upscaled_url}" : "public/#{upscaled_url}"
    return { success: false, error: 'Upscaled image file missing' } unless File.exist?(upscaled_path)

    # For overview, use the resized (non-labeled) image
    resized_path = resized_url ? (resized_url.start_with?('/') ? "public#{resized_url}" : "public/#{resized_url}") : nil

    require 'vips'

    @coord_lookup = nil
    model = CLASSIFICATION_MODEL
    debug_log "Overview classify ##{config_index} with #{model}..."

    # --- Step 1: Compute hex grid and pixel map from RESIZED image (for overview annotation) ---
    generator = AIBattleMapGeneratorService.new(room)
    hex_coords = generator.send(:custom_hex_coords_for_room, GALLERY_HEX_SIZE_FEET)
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min
    room_w = (room.max_x - room.min_x).round
    room_h = (room.max_y - room.min_y).round

    overview_image_path = resized_path && File.exist?(resized_path) ? resized_path : upscaled_path
    resized_img = Vips::Image.new_from_file(overview_image_path)
    resized_w, resized_h = resized_img.width, resized_img.height

    resized_pixel_map = build_hex_pixel_map(hex_coords, generator, min_x, min_y, resized_w, resized_h, hex_coords)
    @coord_lookup = {}
    resized_pixel_map.each { |_l, info| next unless info.is_a?(Hash) && info[:hx]; @coord_lookup[[info[:hx], info[:hy]]] = info }

    # --- Step 2: Build chunks and assign grid labels ---
    chunks = build_spatial_chunks(hex_coords, CHUNK_SIZE)
    chunk_labels_map = assign_chunk_grid_labels(chunks)
    debug_log "  #{chunks.length} chunks, labels: #{chunk_labels_map.values.join(', ')}"

    # --- Step 3: Draw chunk boundaries on overview image ---
    annotated_path = draw_chunk_boundaries_on_image(overview_image_path, chunks, chunk_labels_map, resized_pixel_map)
    annotated_url = nil

    # --- Step 4: Overview pass with annotated image ---
    overview_data = run_overview_pass(annotated_path || overview_image_path, room, model, chunks: chunks, chunk_labels: chunk_labels_map)

    unless overview_data
      debug_log "  Overview pass failed, falling back to simple approach"
      return classify_hexes_simple(config_index)
    end

    scene_description = overview_data['scene_description'] || ''
    map_layout = overview_data['map_layout'] || ''
    present_types = overview_data['present_types'] || []
    chunk_descriptions = overview_data['chunk_descriptions'] || []

    # Log custom type justifications
    present_types.each do |t|
      justification = t['custom_type_justification']
      standard = (SIMPLE_HEX_TYPES - %w[open_floor other off_map])
      if justification && !justification.empty?
        debug_log "  Custom type '#{t['type_name']}': #{justification}"
      elsif !standard.include?(t['type_name']) && t['type_name'] != 'off_map'
        debug_log "  Warning: non-standard type '#{t['type_name']}' without justification"
      end
    end

    debug_log "  Overview: #{present_types.length} types found: #{present_types.map { |t| t['type_name'] }.join(', ')}"
    debug_log "  Layout: #{map_layout[0..120]}..." if map_layout.length > 0
    debug_log "  Chunk descriptions: #{chunk_descriptions.length} received"

    # Build chunk description lookup for workers
    chunk_desc_lookup = {}
    chunk_descriptions.each { |cd| chunk_desc_lookup[cd['chunk_label']] = cd['description'] }

    # Build constrained type list from overview — add off_map if missing, but NOT open_floor
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('open_floor')
    type_names.delete('other')
    type_names << 'off_map' unless type_names.include?('off_map')
    type_names.uniq!

    # Build properties lookup from overview results
    overview_type_properties = {}
    present_types.each do |t|
      props = {}
      %w[traversable provides_cover provides_concealment is_wall is_exit difficult_terrain].each do |key|
        props[key] = t[key] unless t[key].nil?
      end
      props['elevation'] = t['elevation'] unless t['elevation'].nil?
      props['water_depth'] = t['water_depth'] if WATER_DEPTHS.include?(t['water_depth'])
      props['hazards'] = Array(t['hazards']).select { |h| HAZARD_TYPES.include?(h) } if t['hazards']
      overview_type_properties[t['type_name']] = props
    end

    # --- Step 5: Rebuild pixel map from UPSCALED image for chunk cropping ---
    base = Vips::Image.new_from_file(upscaled_path)
    img_width = base.width
    img_height = base.height
    hex_pixel_map = build_hex_pixel_map(hex_coords, generator, min_x, min_y, img_width, img_height, hex_coords)
    @coord_lookup = {}
    hex_pixel_map.each { |_l, info| next unless info.is_a?(Hash) && info[:hx]; @coord_lookup[[info[:hx], info[:hy]]] = info }

    # Build constrained schema with only the discovered types
    constrained_schema = {
      type: 'OBJECT',
      properties: {
        hexes: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: {
              label:    { type: 'STRING', description: 'Hex label like "1-A", "2-B"' },
              hex_type: { type: 'STRING', enum: type_names, description: 'What occupies this hex at ground level' }
            },
            required: %w[label hex_type]
          }
        }
      },
      required: %w[hexes]
    }

    api_key = AIProviderService.api_key_for('google_gemini')
    all_chunk_results = []
    chunk_urls = []
    results_mutex = Mutex.new
    semaphore = Mutex.new
    active_count = 0
    max_wait = 300

    debug_log "  Phase 2: #{chunks.length} chunks, constrained to #{type_names.length} types"

    # --- Step 6: Run chunk workers with per-chunk descriptions ---
    threads = chunks.each_with_index.map do |chunk_info, chunk_idx|
      chunk = chunk_info[:coords]
      grid_pos = chunk_info[:grid_pos]
      Thread.new do
        loop do
          slot_available = false
          semaphore.synchronize do
            if active_count < MAX_CONCURRENT_CHUNKS
              active_count += 1
              slot_available = true
            end
          end
          break if slot_available
          sleep 0.5
        end

        begin
          hex_labels_for_chunk = chunk.map { |x, y| generator.send(:coord_to_label, x, y, min_x, min_y, hex_coords_override: hex_coords) }

          crop_result = crop_image_for_chunk(base, chunk, hex_pixel_map, img_width, img_height)
          labeled_crop = overlay_chunk_labels(crop_result, chunk, generator, min_x, min_y, hex_coords, hex_pixel_map)
          chunk_png_path = File.join(RESULTS_DIR, "chunk_overview_#{config_index}_#{chunk_idx}.png")
          File.binwrite(chunk_png_path, labeled_crop)
          chunk_url = "/uploads/battle_map_tests/chunk_overview_#{config_index}_#{chunk_idx}.png"
          results_mutex.synchronize { chunk_urls << { index: chunk_idx, url: chunk_url } }
          cropped_base64 = Base64.strict_encode64(labeled_crop)

          # Look up per-chunk description from overview
          chunk_label = chunk_labels_map[chunk_idx]
          chunk_desc = chunk_desc_lookup[chunk_label]

          position_label = chunk_position_label(grid_pos)
          prompt = build_overview_chunk_prompt(hex_labels_for_chunk, room_w, room_h, scene_description, map_layout, type_names, present_types, position_label: position_label, chunk_coords: chunk, all_hex_coords: hex_coords, generator: generator, chunk_description: chunk_desc)

          messages = [{
            role: 'user',
            content: [
              { type: 'image', mime_type: 'image/png', data: cropped_base64 },
              { type: 'text', text: prompt }
            ]
          }]

          response = LLM::Adapters::GeminiAdapter.generate(
            messages: messages,
            model: model,
            api_key: api_key,
            response_schema: constrained_schema,
            options: { max_tokens: 65536, timeout: 120, temperature: 0, thinking_level: 'minimal' }
          )

          if response[:success]
            content = response[:text] || response[:content]
            chunk_results = parse_simple_chunk(content, generator, min_x, min_y, hex_coords, allowed_types: type_names)
            results_mutex.synchronize { all_chunk_results.concat(chunk_results) }
            debug_log "  Overview chunk #{chunk_idx + 1}/#{chunks.length} (#{chunk_label}): #{chunk_results.length} notable"
          else
            debug_log "  Overview chunk #{chunk_idx + 1}/#{chunks.length} (#{chunk_label}) FAILED: #{response[:error]}"
          end
        ensure
          semaphore.synchronize { active_count -= 1 }
        end
      end
    end

    threads.each { |t| t.join(max_wait) }

    # --- Step 7: Visual similarity normalization ---
    # Remove outlier classifications that look more like ground than their assigned type
    debug_log "  Pre-normalize: #{all_chunk_results.length} results, #{hex_coords.length} hex_coords, coord_lookup=#{@coord_lookup&.length}, image=#{base.width}x#{base.height}"
    before_count = all_chunk_results.length
    all_chunk_results = normalize_by_visual_similarity(all_chunk_results, base, hex_pixel_map, hex_coords, generator, min_x, min_y)
    delta = all_chunk_results.length - before_count
    debug_log "  Normalization: #{before_count} → #{all_chunk_results.length} (#{delta >= 0 ? "+#{delta}" : delta})"

    # Expand types to properties using overview-detected properties (falling back to built-in table)
    expanded = all_chunk_results.map do |hex_data|
      ht = hex_data['hex_type']
      builtin = HEX_TYPE_PROPERTIES[ht] || {}
      overview = overview_type_properties[ht] || {}
      merged_props = HEX_DEFAULT_PROPERTIES.merge(builtin).merge(overview)
      merged_props['label'] = hex_data['label']
      merged_props['hex_type'] = ht
      merged_props['x'] = hex_data['x'] if hex_data['x']
      merged_props['y'] = hex_data['y'] if hex_data['y']
      merged_props
    end

    # Fill defaults for unclassified hexes
    returned_labels = {}
    expanded.each { |c| returned_labels[c['label']] = true }

    classifications = expanded.dup
    hex_coords.each do |hx, hy|
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
      next if returned_labels[label]

      classifications << expand_hex_type_to_properties('open_floor', label, x: hx, y: hy)
    end

    # Generate overlay (approach-specific filename)
    labeled_path = upscaled_path.sub('_upscaled', '_labeled')
    classified_path = generate_classified_overlay(labeled_path, room, classifications, generator, hex_coords, suffix: 'classified_overview')
    classified_url = nil
    if classified_path
      classified_url = classified_path.sub(/^public/, '')
      classified_url = "/#{classified_url}" unless classified_url.start_with?('/')
    end

    # Build annotated overview URL for debugging
    if annotated_path
      annotated_url = annotated_path.sub(/^public/, '')
      annotated_url = "/#{annotated_url}" unless annotated_url.start_with?('/')
    end

    # Save results under approach-specific keys (preserves other approach results)
    overview_result_data = {
      'hex_classifications' => classifications,
      'classified_url' => classified_url,
      'classification_model' => model,
      'classified_at' => Time.now.iso8601,
      'overview_data' => {
        'scene_description' => scene_description,
        'map_layout' => map_layout,
        'present_types' => present_types,
        'chunk_descriptions' => chunk_descriptions
      },
      'overview_annotated_url' => annotated_url,
      'chunk_urls' => chunk_urls.sort_by { |c| c[:index] }.map { |c| c[:url] }
    }
    update_result(config_index) do |current_data|
      current_data['overview'] = overview_result_data
      current_data['hex_size_feet'] = GALLERY_HEX_SIZE_FEET
    end

    debug_log "Overview classified ##{config_index}: #{classifications.length} hexes, #{present_types.length} types"
    { success: true, count: classifications.length, model: model, approach: 'overview', types_found: present_types.length }
  rescue StandardError => e
    debug_log "classify_hexes_overview failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    { success: false, error: "#{e.class}: #{e.message}" }
  end

  private

  # Expand a hex_type to full classification properties via lookup table.
  # Merges type-specific properties over defaults.
  # @param hex_type [String] one of SIMPLE_HEX_TYPES
  # @param label [String] hex label like "1-A"
  # @param coords [Array, nil] [x, y] coordinates, auto-resolved from label if nil
  # @return [Hash] full classification hash with all properties
  def expand_hex_type_to_properties(hex_type, label, x: nil, y: nil)
    type_props = HEX_TYPE_PROPERTIES[hex_type] || {}
    result = HEX_DEFAULT_PROPERTIES.merge(type_props)
    result['label'] = label
    result['hex_type'] = hex_type
    result['x'] = x if x
    result['y'] = y if y
    result
  end

  # --- Shared prompt fragments (used by all classification approaches) ---

  def prompt_hex_format
    'Each hex has a label like "1-A", "2-B" (row-dash-column). Column letters are ABSOLUTE — same X position = same letter across all rows.'
  end

  def prompt_crop_warning
    'IMPORTANT: This is a CROPPED SECTION of a larger map. Other workers classify the rest. Crop edges are NOT map boundaries — do NOT mark edge hexes as off_map or wall unless the visual content clearly shows it.'
  end

  def prompt_ground_level_rule
    'GROUND-LEVEL RULE: Classify what occupies the hex at foot level. Overhead canopy = classify ground beneath. Bridge over pit = elevated traversable surface.'
  end

  def prompt_skip_open_floor
    'SKIP open floor/ground hexes — any hex you omit defaults to: traversable, no cover, no concealment, elevation 0. Only report hexes with notable features.'
  end

  def prompt_conservative_classification
    "When in doubt, leave it untagged. It's better to miss a detail than get something wrong."
  end

  # Shared type reference used by both overview and chunk workers.
  # Each description focuses on WHEN to tag something as this type —
  # what tactical effect it represents and the threshold for tagging.
  def standard_types_reference
    <<~TYPES
      STANDARD TYPES — only tag a hex if it clearly matches the description below.

      TERRAIN / NATURE:
      - tree: A standing tree trunk tall and thick enough that a person could take cover behind it. Includes living trees, dead trees, and large stumps with substantial vertical mass. Do NOT use for small stumps, saplings, fallen branches, or anything you couldn't hide behind.
      - dense_trees: A wall of trees and undergrowth so thick a person cannot walk through it. The canopy and ground cover form an impenetrable barrier. Only use where movement is clearly blocked.
      - shrubbery: A bush or hedge tall and thick enough that a person could crouch behind it and be hidden from view (waist-height or taller). Do NOT use for grass, ground cover, small plants, leaf litter, moss, or low vegetation you could easily step over.
      - boulder: A rock large enough that a person could crouch behind it for protection from projectiles (at least waist-height). Do NOT use for small rocks, pebbles, stepping stones, or decorative stones.
      - mud: Ground that is visibly waterlogged, boggy, or swamp-like, making walking slow and difficult. Do NOT use for normal dirt, packed earth, or dry ground that happens to be brown.
      - snow: Ground covered in deep enough snow to impede walking. Not a light dusting.
      - ice: A frozen surface slippery enough to affect movement. Not just cold-looking ground.

      WATER:
      - puddle: A shallow pool of standing water, ankle-deep at most. Enough to splash through but not impede much.
      - wading_water: Water deep enough to reach a person's waist — streams, shallow rivers, pond edges. Deep enough to significantly slow movement.
      - deep_water: Water too deep to walk through — a person would need to swim. Rivers, lakes, deep pools.

      FURNITURE / OBJECTS:
      - table: A table large enough to affect movement — you'd have to climb over or walk around it. Includes rectangular tables, round tables, desks, workbenches. Do NOT use for small side-tables or trays.
      - chair: A chair or stool — a minor obstacle you could push aside but that occupies the space.
      - bench: A bench, pew, or long seat — similar to a chair but longer.
      - fire: An active fire or heat source — a fireplace hearth with flames, a campfire, a brazier, a fire pit. The hex is dangerous to stand in. Do NOT use for warm-looking lighting, candles, lanterns, or wall-mounted torches.
      - log: A fallen tree trunk or heavy timber lying on the ground, large enough to provide cover if you crouched behind it and that you'd need to climb over. Do NOT use for sticks, twigs, small branches, or thin pieces of wood.
      - barrel: A barrel or keg — a solid cylindrical container large enough to crouch behind for cover.
      - crate: A large wooden crate or box that completely blocks the hex — you cannot walk through it, but could take cover behind it.
      - chest: A treasure chest or storage trunk — a solid object on the floor, slightly elevated, but small enough to step over.
      - wagon: A cart or wagon — large enough to block passage entirely and provide solid cover.
      - tent: A tent or canvas canopy — you can walk through it but it hides you from view.

      STRUCTURES / BOUNDARIES:
      - wall: A solid wall or barrier that completely blocks movement. Stone walls, brick walls, thick wooden walls, solid rock faces.
      - glass_window: A closed window with glass — blocks movement like a wall but you can see through it. Look for reflective/translucent panes in walls, light spilling in from outside.
      - open_window: A window opening without glass — blocks movement (it's in a wall) but allows ranged attacks through it. Look for empty window frames, openings with visible outside scenery.
      - door: A door or doorway — a passage point through a wall. Look for hinged panels, door frames, or gaps in walls sized for a person to walk through.
      - archway: An open archway, passage, or corridor entrance — a gap in a wall or boundary that people freely walk through. Look for curved openings, corridor mouths, or clear gaps in the room perimeter.
      - pillar: A structural column thick enough to block movement and provide cover — you could hide behind it.
      - fence: A fence, railing, or low wall — blocks movement but only provides partial cover (you can see and shoot over it).
      - gate: A gate in a fence or wall — a passage point, similar to a door but in a fence.

      ELEVATION:
      - balcony: A raised platform, mezzanine, or elevated walkway significantly above the main floor (+8ft).
      - staircase: Stairs, a ramp, or a ladder — a transition between elevation levels.
      - pit: An actual hole or chasm in the ground that you would fall into. Must be a genuine void/gap, not merely a dark shadow, dark-colored ground, or dark patch. If the surface looks solid, it is NOT a pit.
      - cliff: A vertical rock face or sheer drop — blocks movement like a wall.
      - ledge: A raised stone ledge or low platform — elevated above the floor but walkable.
      - bridge: A bridge spanning a gap or water — elevated and walkable.
      - rubble: A pile of collapsed stone or debris that makes the ground uneven and slow to cross. Do NOT use for scattered pebbles, dust, or minor floor debris.

      SPECIAL:
      - off_map: Void/black areas completely outside the playable map boundary. ONLY use for regions that are clearly not part of the playable space (solid black borders, areas beyond the map edge). Do NOT use for dark floors, shadows, or dark-coloured terrain inside the map.

      NOTE: Similar-sounding types are DIFFERENT. tree (single standing tree you can take cover behind) vs dense_trees (impassable forest). puddle (ankle-deep) vs wading_water (waist-deep) vs deep_water (must swim). Include ALL that apply — do not merge distinct types.
    TYPES
  end

  # Concise type list for the overview pass. Includes brief distinctions for
  # commonly confused pairs so the overview doesn't merge them.
  def overview_types_reference
    <<~TYPES
      STANDARD TYPES (use these names, do not invent new ones unless nothing fits):

      tree (single standing tree — provides cover), dense_trees (impassable forest/undergrowth),
      shrubbery (bush tall enough to hide behind), boulder (rock big enough for cover),
      mud, snow, ice,
      puddle (ankle-deep), wading_water (waist-deep stream), deep_water (swim-depth),
      table, chair, bench, fire (active flames/embers), log (fallen trunk big enough for cover),
      barrel, crate, chest, wagon, tent,
      wall, glass_window, open_window, door, archway, pillar, fence, gate,
      balcony, staircase, pit (actual hole in the ground), cliff, ledge, bridge, rubble,
      off_map

      IMPORTANT: tree and dense_trees are DIFFERENT types. A single standing tree (including dead trees) that you could take cover behind = tree. A thick mass of trees/undergrowth blocking all movement = dense_trees. Include BOTH if both exist in the image.
    TYPES
  end

  # Filtered version of standard_types_reference — only includes types in the given list.
  # Used by chunk workers so they only see descriptions for types the overview identified.
  def filtered_types_reference(type_names)
    return standard_types_reference if type_names.nil? || type_names.empty?

    type_set = type_names.to_set
    lines = standard_types_reference.lines
    filtered = []
    include_line = false

    lines.each do |line|
      if line.strip.start_with?('- ')
        # Type definition line — check if type name matches
        type_name = line.strip.match(/^- (\w+):/)&.captures&.first
        include_line = type_name && type_set.include?(type_name)
        filtered << line if include_line
      else
        # Section header, blank line, or first/last lines of the heredoc
        filtered << line
      end
    end

    # Clean up consecutive blank lines and empty sections
    filtered.join
  end

  # --- End shared prompt fragments ---

  # Build the legacy (v3) classification prompt with full property-per-hex schema.
  # @param hex_labels [Array<String>] labels for this chunk
  # @param room_w [Integer] room width in feet
  # @param room_h [Integer] room height in feet
  # @param chunk_coords [Array, nil] coords for spatial context
  # @param all_hex_coords [Array, nil] full grid coords for spatial legend
  # @param generator [AIBattleMapGeneratorService, nil] for label methods
  def build_classification_prompt(hex_labels, room_w, room_h, chunk_coords: nil, all_hex_coords: nil, generator: nil)
    spatial_context = build_spatial_context(hex_labels, chunk_coords, all_hex_coords, generator)

    GamePrompts.get('battle_maps.gallery.classification',
      hex_format: prompt_hex_format, room_w: room_w, room_h: room_h,
      hex_size_feet: GALLERY_HEX_SIZE_FEET, hex_count: hex_labels.length,
      spatial_context: spatial_context, crop_warning: prompt_crop_warning,
      skip_open_floor: prompt_skip_open_floor, ground_level_rule: prompt_ground_level_rule,
      hex_labels: hex_labels.join(', '))
  end

  # Build spatial context text for a chunk, giving the model explicit row/column ranges
  # and listing all hex labels in reading order so it doesn't need to visually parse them.
  def build_spatial_context(hex_labels, chunk_coords, all_hex_coords, generator)
    return '' unless chunk_coords && all_hex_coords && generator

    min_x = all_hex_coords.map { |x, _| x }.min
    min_y = all_hex_coords.map { |_, y| y }.min

    # Determine row and column ranges for this chunk
    chunk_labels_parsed = hex_labels.map do |lbl|
      if lbl.include?('-')
        parts = lbl.split('-', 2)
        { row: parts[0].to_i, col: parts[1], label: lbl }
      end
    end.compact

    return '' if chunk_labels_parsed.empty?

    rows = chunk_labels_parsed.map { |p| p[:row] }.uniq.sort
    cols = chunk_labels_parsed.map { |p| p[:col] }.uniq.sort

    min_row = rows.first
    max_row = rows.last
    min_col = cols.first
    max_col = cols.last

    # Build reading-order label list (top to bottom, left to right)
    ordered = chunk_labels_parsed.sort_by { |p| [p[:row], p[:col]] }.map { |p| p[:label] }

    all_xs = all_hex_coords.map { |x, _| x }.uniq.sort
    total_cols = all_xs.length
    all_ys = all_hex_coords.map { |_, y| y }.uniq.sort
    total_rows = all_ys.length

    <<~SPATIAL
      SPATIAL LAYOUT: This chunk covers rows #{min_row}-#{max_row} (of #{total_rows}), columns #{min_col}-#{max_col} (of #{total_cols} total columns from #{generator.send(:index_to_column_letter, 0)} to #{generator.send(:index_to_column_letter, total_cols - 1)}).
      #{min_row}-#{min_col} is top-left of this chunk, #{min_row}-#{max_col} is top-right, #{max_row}-#{min_col} is bottom-left, #{max_row}-#{max_col} is bottom-right.
      Column A is leftmost on the full map. Columns increase rightward. Row 1 is topmost. Rows increase downward.
      Even rows (1,3,5...) use even-indexed columns (A,C,E,G...). Odd rows (2,4,6...) use odd-indexed columns (B,D,F,H...).
      Hex labels in reading order (top-to-bottom, left-to-right): #{ordered.join(', ')}
    SPATIAL
  end

  # Build prompt for Approach A — simple enum classification.
  def build_simple_classification_prompt(hex_labels, room_w, room_h, chunk_coords: nil, all_hex_coords: nil, generator: nil)
    spatial_context = build_spatial_context(hex_labels, chunk_coords, all_hex_coords, generator)

    GamePrompts.get('battle_maps.gallery.simple_classification',
      hex_format: prompt_hex_format, room_w: room_w, room_h: room_h,
      hex_size_feet: GALLERY_HEX_SIZE_FEET, hex_count: hex_labels.length,
      spatial_context: spatial_context, crop_warning: prompt_crop_warning,
      ground_level_rule: prompt_ground_level_rule, hex_labels: hex_labels.join(', '))
  end

  # Parse response from simple enum classification (just label + hex_type per hex)
  def parse_simple_chunk(content, generator, min_x, min_y, hex_coords, allowed_types: nil)
    return [] unless content

    valid_types = allowed_types || SIMPLE_HEX_TYPES
    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    data = JSON.parse(json_str)
    hexes = data['hexes'] || []

    hexes.filter_map do |hex|
      label = hex['label']
      hex_type = hex['hex_type']
      next unless label && hex_type

      coords = generator.send(:label_to_coord, label, min_x, min_y, hex_coords_override: hex_coords)
      next unless coords

      {
        'label' => label,
        'x' => coords[0],
        'y' => coords[1],
        'hex_type' => valid_types.include?(hex_type) ? hex_type : 'other'
      }
    end
  rescue JSON::ParserError => e
    debug_log "Simple chunk parse error: #{e.message}"
    []
  end

  # Re-classify "other" hexes using the detailed legacy schema for more nuanced analysis.
  def reclassify_other_hexes(other_hexes, base_image, hex_pixel_map, generator, min_x, min_y, hex_coords, room_w, room_h, api_key, model, img_width, img_height)
    return [] if other_hexes.empty?

    # Group "other" hexes into a single chunk for reclassification
    other_coords = other_hexes.filter_map { |h| [h['x'], h['y']] if h['x'] && h['y'] }
    return [] if other_coords.empty?

    other_labels = other_hexes.map { |h| h['label'] }

    crop_result = crop_image_for_chunk(base_image, other_coords, hex_pixel_map, img_width, img_height)
    labeled_crop = overlay_chunk_labels(crop_result, other_coords, generator, min_x, min_y, hex_coords, hex_pixel_map)
    cropped_base64 = Base64.strict_encode64(labeled_crop)

    prompt = build_classification_prompt(other_labels, room_w, room_h, chunk_coords: other_coords, all_hex_coords: hex_coords, generator: generator)

    messages = [{
      role: 'user',
      content: [
        { type: 'image', mime_type: 'image/png', data: cropped_base64 },
        { type: 'text', text: prompt }
      ]
    }]

    response = LLM::Adapters::GeminiAdapter.generate(
      messages: messages,
      model: model,
      api_key: api_key,
      response_schema: CLASSIFICATION_SCHEMA,
      options: { max_tokens: 65536, timeout: 120, temperature: 0, thinking_level: 'minimal' }
    )

    if response[:success]
      content = response[:text] || response[:content]
      parse_chunk_classifications(content, other_coords, generator, min_x, min_y, hex_coords)
    else
      debug_log "  Other hex reclassification failed: #{response[:error]}"
      []
    end
  rescue StandardError => e
    debug_log "reclassify_other_hexes failed: #{e.class}: #{e.message}"
    []
  end

  # Run the overview pre-pass: send (optionally annotated) image for scene analysis.
  # When chunks/chunk_labels are provided, the prompt references labeled regions.
  # Returns parsed overview data or nil on failure.
  def run_overview_pass(image_path, room, model, chunks: nil, chunk_labels: nil)
    return nil unless image_path && File.exist?(image_path)

    image_base64 = Base64.strict_encode64(File.binread(image_path))
    room_w = (room.max_x - room.min_x).round
    room_h = (room.max_y - room.min_y).round

    desc = room.long_description || room.short_description || room.name

    standard_types_ref = standard_types_reference

    # Build chunk region text if chunk info is available
    if chunk_labels && !chunk_labels.empty?
      sorted_labels = chunk_labels.values.sort
      chunk_labels_text = sorted_labels.join(', ')
      chunk_region_text = "The image has colored rectangular regions labeled #{chunk_labels_text}. Each region will be classified by a separate worker who sees ONLY their cropped section. Provide a description for each chunk region so workers know what to expect."
      chunk_desc_instruction = "For chunk_descriptions: describe what is visible in each labeled region (#{chunk_labels_text}). Be specific about which types appear where."
    else
      chunk_region_text = ''
      chunk_desc_instruction = 'For chunk_descriptions: return an empty array (no chunk regions annotated).'
    end

    prompt = GamePrompts.get('battle_maps.gallery.overview',
      room_name: room.name, room_w: room_w, room_h: room_h,
      description: desc, chunk_region_text: chunk_region_text,
      standard_types_ref: standard_types_ref,
      chunk_desc_instruction: chunk_desc_instruction)

    api_key = AIProviderService.api_key_for('google_gemini')
    messages = [{
      role: 'user',
      content: [
        { type: 'image', mime_type: 'image/png', data: image_base64 },
        { type: 'text', text: prompt }
      ]
    }]

    response = LLM::Adapters::GeminiAdapter.generate(
      messages: messages,
      model: model,
      api_key: api_key,
      response_schema: OVERVIEW_SCHEMA,
      options: { max_tokens: 65536, timeout: 300, temperature: 0, thinking_level: 'low' }
    )

    unless response[:success]
      debug_log "Overview pass failed: #{response[:error]}"
      return nil
    end

    content = response[:text] || response[:content]
    return nil unless content

    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    JSON.parse(json_str)
  rescue StandardError => e
    debug_log "run_overview_pass failed: #{e.class}: #{e.message}"
    nil
  end

  # Build prompt for Approach B chunks — constrained to types discovered in overview.
  def build_overview_chunk_prompt(hex_labels, room_w, room_h, scene_description, map_layout, type_names, present_types, position_label: 'center of the map', chunk_coords: nil, all_hex_coords: nil, generator: nil, chunk_description: nil)
    spatial_context = build_spatial_context(hex_labels, chunk_coords, all_hex_coords, generator)

    # Build filtered type reference — only types the overview identified
    filtered_types_ref = filtered_types_reference(type_names)

    # Build visual guide from overview type descriptions
    visual_lines = present_types.filter_map do |t|
      next if %w[open_floor other].include?(t['type_name'])
      next unless t['visual_description'] && !t['visual_description'].empty?

      "- #{t['type_name']}: #{t['visual_description']}"
    end
    visual_guide = visual_lines.any? ? "VISUAL GUIDE — what each type looks like in this specific map:\n#{visual_lines.join("\n")}" : ''

    chunk_context = chunk_description ? "CHUNK CONTEXT: #{chunk_description}" : ''

    GamePrompts.get('battle_maps.classification.overview_chunk',
      position_label: position_label, hex_format: prompt_hex_format,
      room_w: room_w, room_h: room_h, hex_size_feet: GALLERY_HEX_SIZE_FEET,
      hex_count: hex_labels.length, scene_description: scene_description,
      map_layout: map_layout, chunk_context: chunk_context,
      spatial_context: spatial_context, filtered_types_ref: filtered_types_ref,
      visual_guide: visual_guide, conservative_classification: prompt_conservative_classification,
      crop_warning: prompt_crop_warning, ground_level_rule: prompt_ground_level_rule,
      hex_labels: hex_labels.join(', '))
  end

  # Symmetric border trim: detect background from corners, then mirror the trim.
  # If content starts 10px from the left and 5px from the right, trim 10px from both sides.
  # Uses max(opposite margins) per axis so any detected border is removed symmetrically.
  # This handles both light and dark backgrounds since we sample actual corner colors.
  def symmetric_trim(img)
    w = img.width
    h = img.height

    # Sample 4 corner regions (5x5 blocks) to detect background color
    sample_size = [5, [w, h].min / 10].min
    bands = [img.bands, 3].min
    corners = [
      img.crop(0, 0, sample_size, sample_size),                         # top-left
      img.crop(w - sample_size, 0, sample_size, sample_size),           # top-right
      img.crop(0, h - sample_size, sample_size, sample_size),           # bottom-left
      img.crop(w - sample_size, h - sample_size, sample_size, sample_size) # bottom-right
    ]
    corner_avgs = corners.map do |c|
      stats = c.stats
      (0...bands).map { |b| stats.getpoint(4, b)[0].round(1) }
    end

    # Use the median corner color as background (robust to one odd corner)
    bg = (0...bands).map { |ch| corner_avgs.map { |c| c[ch] }.sort[1..2].sum / 2.0 }
    debug_log "Trim: corners=#{corner_avgs.map { |c| c.map(&:round) }}, bg=#{bg.map(&:round)}"

    # Try find_trim with detected background
    left, top, trim_w, trim_h = img.find_trim(threshold: 15, background: bg)

    # If find_trim found no significant trim, try with white background as fallback
    if trim_w <= 0 || trim_h <= 0 || (trim_w >= w - 4 && trim_h >= h - 4)
      left, top, trim_w, trim_h = img.find_trim(threshold: 10, background: [255, 255, 255])
    end

    # Check if there's actually something to trim
    if trim_w <= 0 || trim_h <= 0 || (trim_w >= w - 4 && trim_h >= h - 4)
      debug_log "Trim: no borders detected"
      return img
    end

    # Calculate margins on each side
    left_margin = left
    top_margin = top
    right_margin = w - (left + trim_w)
    bottom_margin = h - (top + trim_h)

    # Symmetric: use max of opposite sides per axis
    h_trim = [left_margin, right_margin].max
    v_trim = [top_margin, bottom_margin].max

    # Safety: don't trim more than 20% from any side
    max_h = (w * 0.20).round
    max_v = (h * 0.20).round
    h_trim = [h_trim, max_h].min
    v_trim = [v_trim, max_v].min

    # Must leave meaningful content
    new_w = w - (h_trim * 2)
    new_h = h - (v_trim * 2)
    if new_w < w * 0.5 || new_h < h * 0.5
      debug_log "Trim: would remove too much (#{new_w}x#{new_h} from #{w}x#{h}), skipping"
      return img
    end

    if h_trim > 2 || v_trim > 2
      result = img.crop(h_trim, v_trim, new_w, new_h)
      debug_log "Trim: #{w}x#{h} → #{new_w}x#{new_h} (margins: L=#{left_margin} R=#{right_margin} T=#{top_margin} B=#{bottom_margin}, symmetric: h=#{h_trim} v=#{v_trim})"
      result
    else
      debug_log "Trim: margins too small (h=#{h_trim}, v=#{v_trim}), skipping"
      img
    end
  rescue StandardError => e
    debug_log "Trim failed: #{e.message}"
    img
  end

  # Build a map of hex label → pixel position for the entire grid
  def build_hex_pixel_map(hex_coords, generator, min_x, min_y, img_width, img_height, all_hex_coords)
    all_xs = all_hex_coords.map { |x, _| x }.uniq.sort
    all_ys = all_hex_coords.map { |_, y| y }.uniq.sort
    num_cols = all_xs.max - all_xs.min
    num_visual_rows = ((all_ys.max - all_ys.min) / 4.0).floor + 1

    hex_size_by_width = img_width.to_f / [num_cols * 1.5 + 2.0, 1].max
    hex_size_by_height = img_height.to_f / [(num_visual_rows + 0.5) * Math.sqrt(3), 1].max
    hex_size = [hex_size_by_width, hex_size_by_height].max

    grid_width = num_cols * 1.5 * hex_size + 2.0 * hex_size
    grid_height = (num_visual_rows + 0.5) * Math.sqrt(3) * hex_size
    offset_x = ((img_width - grid_width) / 2.0).round
    offset_y = ((img_height - grid_height) / 2.0).round

    pixel_map = {}
    hex_coords.each do |hx, hy|
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: all_hex_coords)
      px, py = generator.send(:hex_to_pixel, hx, hy, min_x, min_y, hex_size, offset_x, offset_y)
      pixel_map[label] = { px: px, py: py, hx: hx, hy: hy }
    end
    pixel_map[:hex_size] = hex_size
    pixel_map[:offset_x] = offset_x
    pixel_map[:offset_y] = offset_y
    pixel_map
  end

  # Group hexes into spatial rectangular tiles using pixel positions.
  # Uses @coord_lookup (pixel coords) to produce roughly square chunks
  # that correspond to map regions rather than horizontal strips.
  def build_spatial_chunks(hex_coords, target_size)
    if hex_coords.length <= target_size
      return [{ coords: hex_coords, grid_pos: { gx: 0, gy: 0, nx: 1, ny: 1 } }]
    end

    # Use pixel positions from @coord_lookup for proper spatial grouping
    # (hex offset coords have non-uniform y spacing that skews the grid)
    coords_with_px = hex_coords.filter_map do |x, y|
      info = @coord_lookup&.dig([x, y])
      next unless info

      [x, y, info[:px], info[:py]]
    end
    if coords_with_px.empty?
      return [{ coords: hex_coords, grid_pos: { gx: 0, gy: 0, nx: 1, ny: 1 } }]
    end

    px_min = coords_with_px.map { |_, _, px, _| px }.min
    px_max = coords_with_px.map { |_, _, px, _| px }.max
    py_min = coords_with_px.map { |_, _, _, py| py }.min
    py_max = coords_with_px.map { |_, _, _, py| py }.max
    px_range = (px_max - px_min).to_f.nonzero? || 1.0
    py_range = (py_max - py_min).to_f.nonzero? || 1.0

    num_chunks = (hex_coords.length.to_f / target_size).ceil
    # Find grid dimensions proportional to the pixel aspect ratio
    best_nx, best_ny = 1, num_chunks
    best_ratio_diff = Float::INFINITY
    (1..num_chunks).each do |nx|
      ny = (num_chunks.to_f / nx).ceil
      next if nx * ny < num_chunks

      cell_w = px_range / nx
      cell_h = py_range / ny
      ratio = cell_w > cell_h ? cell_w / cell_h : cell_h / cell_w
      if ratio < best_ratio_diff
        best_ratio_diff = ratio
        best_nx = nx
        best_ny = ny
      end
    end

    # Assign hexes to grid cells based on pixel position
    grid = Hash.new { |h, k| h[k] = [] }
    coords_with_px.each do |x, y, px, py|
      gx = [((px - px_min) / px_range * best_nx).floor, best_nx - 1].min
      gy = [((py - py_min) / py_range * best_ny).floor, best_ny - 1].min
      grid[[gx, gy]] << [x, y]
    end

    # Return non-empty cells, ordered top-to-bottom, left-to-right
    # Each entry is a Hash with :coords and :grid_pos (for directional context)
    (0...best_ny).flat_map do |gy|
      (0...best_nx).map do |gx|
        next if grid[[gx, gy]].empty?

        { coords: grid[[gx, gy]], grid_pos: { gx: gx, gy: gy, nx: best_nx, ny: best_ny } }
      end
    end.compact
  end

  # Describe a chunk's position on the map in natural language (e.g. "top-right")
  def chunk_position_label(grid_pos)
    gx, gy, nx, ny = grid_pos.values_at(:gx, :gy, :nx, :ny)

    vertical = if ny <= 1 then ''
               elsif gy == 0 then 'top'
               elsif gy == ny - 1 then 'bottom'
               else 'center'
               end

    horizontal = if nx <= 1 then ''
                 elsif gx == 0 then 'left'
                 elsif gx == nx - 1 then 'right'
                 else 'center'
                 end

    parts = [vertical, horizontal].reject(&:empty?)
    return 'center of the map' if parts.empty? || parts == %w[center center]
    return "#{parts.join('-')} of the map" if parts.length == 2 && !parts.include?('center')
    return "#{parts.first} of the map"
  end

  # Assign grid labels (A1, A2, B1, B2...) to chunks based on spatial position.
  # Row = letter (A=top, B=next...), Column = number (1=left, 2=next...).
  # @param chunks [Array<Hash>] from build_spatial_chunks, each with :grid_pos
  # @return [Hash] { chunk_index => "A1", ... }
  def assign_chunk_grid_labels(chunks)
    labels = {}
    chunks.each_with_index do |chunk_info, idx|
      gp = chunk_info[:grid_pos]
      row_letter = ('A'.ord + gp[:gy]).chr
      col_number = gp[:gx] + 1
      labels[idx] = "#{row_letter}#{col_number}"
    end
    labels
  end

  # Draw semi-transparent colored rectangles with labels onto the overview image
  # so the overview model can see chunk boundaries.
  # @param image_path [String] path to the overview image
  # @param chunks [Array<Hash>] from build_spatial_chunks
  # @param chunk_labels [Hash] { chunk_index => "A1", ... }
  # @param pixel_map [Hash] hex label => { px:, py:, hx:, hy: }
  # @return [String, nil] path to annotated image, or nil on failure
  def draw_chunk_boundaries_on_image(image_path, chunks, chunk_labels, pixel_map)
    require 'vips'
    img = Vips::Image.new_from_file(image_path)
    img_w = img.width
    img_h = img.height
    hex_size = pixel_map[:hex_size] || 20

    # Distinct colors for chunk regions (semi-transparent RGBA)
    chunk_colors = [
      'rgba(255,0,0,0.15)',   'rgba(0,128,255,0.15)',  'rgba(0,200,0,0.15)',
      'rgba(255,165,0,0.15)', 'rgba(128,0,255,0.15)',  'rgba(255,0,255,0.15)',
      'rgba(0,200,200,0.15)', 'rgba(200,200,0,0.15)',  'rgba(255,100,100,0.15)',
      'rgba(100,255,100,0.15)'
    ]
    border_colors = [
      'rgba(255,0,0,0.6)',   'rgba(0,128,255,0.6)',  'rgba(0,200,0,0.6)',
      'rgba(255,165,0,0.6)', 'rgba(128,0,255,0.6)',  'rgba(255,0,255,0.6)',
      'rgba(0,200,200,0.6)', 'rgba(200,200,0,0.6)',  'rgba(255,100,100,0.6)',
      'rgba(100,255,100,0.6)'
    ]

    font_size = [img_w / 20, 28].max
    stroke_w = [font_size / 8, 2].max

    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)

    chunks.each_with_index do |chunk_info, idx|
      chunk_coords = chunk_info[:coords]
      label = chunk_labels[idx] || idx.to_s
      color = chunk_colors[idx % chunk_colors.length]
      border = border_colors[idx % border_colors.length]

      # Find pixel bounding box for this chunk's hexes
      pxs = []
      pys = []
      chunk_coords.each do |hx, hy|
        info = @coord_lookup&.dig([hx, hy])
        next unless info

        pxs << info[:px]
        pys << info[:py]
      end
      next if pxs.empty?

      margin = hex_size * 0.8
      rx = [(pxs.min - margin).round, 0].max
      ry = [(pys.min - margin).round, 0].max
      rw = [(pxs.max + margin).round, img_w].min - rx
      rh = [(pys.max + margin).round, img_h].min - ry

      # Semi-transparent rectangle
      svg_parts << %(<rect x="#{rx}" y="#{ry}" width="#{rw}" height="#{rh}" fill="#{color}" stroke="#{border}" stroke-width="3" rx="6"/>)

      # Label in top-left corner with black stroke for contrast
      lx = rx + 8
      ly = ry + font_size + 4
      svg_parts << %(<text x="#{lx}" y="#{ly}" fill="black" stroke="black" stroke-width="#{stroke_w + 2}" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
      svg_parts << %(<text x="#{lx}" y="#{ly}" fill="white" stroke="none" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
    end

    svg_parts << '</svg>'
    svg_string = svg_parts.join("\n")

    overlay = Vips::Image.svgload_buffer(svg_string)
    if overlay.width != img_w || overlay.height != img_h
      overlay = overlay.resize(img_w.to_f / overlay.width)
    end

    img = img.bandjoin(255) if img.bands < 4
    overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb

    result = img.composite2(overlay, :over)

    annotated_path = image_path.sub(/(\.\w+)$/, '_annotated\1')
    result.write_to_file(annotated_path)
    debug_log "  Chunk boundaries drawn: #{chunks.length} regions on #{annotated_path}"
    annotated_path
  rescue StandardError => e
    debug_log "draw_chunk_boundaries_on_image failed: #{e.class}: #{e.message}"
    nil
  end

  # Crop the unlabeled image to the bounding box of a chunk's hexes + margin.
  # Returns the cropped Vips::Image and crop origin for label overlay.
  def crop_image_for_chunk(base_image, chunk_coords, hex_pixel_map, img_width, img_height)
    hex_size = hex_pixel_map[:hex_size]
    margin = (hex_size * 6.0).round

    # Find pixel bounding box for this chunk
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

    # Calculate crop region with margin, clamped to image bounds
    crop_x = [(pxs.min - margin - hex_size).round, 0].max
    crop_y = [(pys.min - margin - hex_size).round, 0].max
    crop_right = [(pxs.max + margin + hex_size).round, img_width].min
    crop_bottom = [(pys.max + margin + hex_size).round, img_height].min
    crop_w = crop_right - crop_x
    crop_h = crop_bottom - crop_y

    cropped = base_image.crop(crop_x, crop_y, crop_w, crop_h)
    { cropped: cropped, crop_x: crop_x, crop_y: crop_y, crop_w: crop_w, crop_h: crop_h, hex_size: hex_size }
  end

  # Overlay hex labels for ONLY the given chunk's hexes onto a cropped image.
  # The margin area shows raw map context without any labels.
  def overlay_chunk_labels(crop_result, chunk_coords, generator, min_x, min_y, hex_coords, hex_pixel_map)
    cropped = crop_result[:cropped]
    crop_x = crop_result[:crop_x]
    crop_y = crop_result[:crop_y]
    crop_w = crop_result[:crop_w]
    crop_h = crop_result[:crop_h]
    hex_size = crop_result[:hex_size]

    font_size = [hex_size * 0.30, 7].max.round
    stroke_w = [hex_size * 0.04, 1.5].max.round(1)

    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{crop_w}" height="#{crop_h}">)

    # First pass: black outlines for contrast
    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] - crop_x
      py = info[:py] - crop_y
      points = generator.send(:hexagon_svg_points, px, py, hex_size)
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="black" stroke-width="#{stroke_w * 3}"/>)
    end

    # Second pass: white outlines + labels
    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] - crop_x
      py = info[:py] - crop_y
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)

      points = generator.send(:hexagon_svg_points, px, py, hex_size)
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="white" stroke-width="#{stroke_w}"/>)

      text_y = (py + font_size * 0.35).round
      svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="black" stroke="black" stroke-width="4" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
      svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="white" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
    end

    svg_parts << '</svg>'
    svg_string = svg_parts.join("\n")

    overlay = Vips::Image.svgload_buffer(svg_string)
    if overlay.width != crop_w || overlay.height != crop_h
      overlay = overlay.resize(crop_w.to_f / overlay.width)
    end

    # Ensure both images have alpha for compositing
    cropped = cropped.bandjoin(255) if cropped.bands < 4
    overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb

    result = cropped.composite2(overlay, :over)
    result.write_to_buffer('.png')
  end

  # Parse classification response for a single chunk
  def parse_chunk_classifications(content, chunk_coords, generator, min_x, min_y, hex_coords)
    return [] unless content

    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    data = JSON.parse(json_str)

    hexes = data['hexes'] || []

    hexes.filter_map do |hex|
      label = hex['label']
      coords = generator.send(:label_to_coord, label, min_x, min_y, hex_coords_override: hex_coords)
      next unless coords

      {
        'label'            => label,
        'x'                => coords[0],
        'y'                => coords[1],
        'traversable'      => !!hex['traversable'],
        'provides_cover'   => !!hex['provides_cover'],
        'provides_concealment' => !!hex['provides_concealment'],
        'elevation'        => (hex['elevation'] || 0).to_i,
        'is_wall'          => !!hex['is_wall'],
        'is_window'        => !!hex['is_window'],
        'is_window_open'   => !!hex['is_window_open'],
        'is_exit'          => !!hex['is_exit'],
        'is_off_map'       => !!hex['is_off_map'],
        'difficult_terrain' => !!hex['difficult_terrain'],
        'water_depth'      => WATER_DEPTHS.include?(hex['water_depth']) ? hex['water_depth'] : 'none',
        'hazards'          => Array(hex['hazards']).select { |h| HAZARD_TYPES.include?(h) }
      }
    end
  rescue JSON::ParserError => e
    debug_log "Chunk parse error: #{e.message}"
    []
  end

  # Fill in default values for any hex not classified by any chunk
  def fill_default_hexes(classified, hex_coords, generator, min_x, min_y)
    returned_labels = {}
    classified.each { |c| returned_labels[c['label']] = true }

    all = classified.dup
    hex_coords.each do |hx, hy|
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
      next if returned_labels[label]

      all << {
        'label' => label, 'x' => hx, 'y' => hy,
        'traversable' => true, 'provides_cover' => false, 'provides_concealment' => false,
        'elevation' => 0, 'is_wall' => false, 'is_window' => false, 'is_window_open' => false,
        'is_exit' => false, 'is_off_map' => false, 'difficult_terrain' => false,
        'water_depth' => 'none', 'hazards' => []
      }
    end
    all
  end

  # Determine the dominant trait for a hex (used for fill color)
  def dominant_trait(hex_data)
    return 'off_map' if hex_data['is_off_map']
    return 'window' if hex_data['is_window']
    return 'wall' if hex_data['is_wall']
    return 'exit' if hex_data['is_exit']

    wd = hex_data['water_depth']
    return "water_#{wd}" if wd && wd != 'none'
    return 'hazard' if hex_data['hazards']&.any?

    elev = hex_data['elevation'].to_i
    return 'elevation_up' if elev > 0
    return 'elevation_down' if elev < 0
    return 'cover' if hex_data['provides_cover']
    return 'concealment' if hex_data['provides_concealment']
    return 'difficult' if hex_data['difficult_terrain']

    'open'
  end

  # Build a short display label for the hex overlay.
  # Prefers hex_type (from simple/overview approaches) over derived trait.
  def hex_display_label(hex_data)
    # If we have a hex_type (simple/overview), show it directly
    if (ht = hex_data['hex_type']) && ht != 'open_floor'
      return abbreviate_hex_type(ht)
    end

    # Fall back to derived trait label (legacy approach)
    trait = dominant_trait(hex_data)
    info = TRAIT_COLORS[trait] || TRAIT_COLORS['open']
    label = info[:label]

    elev = hex_data['elevation'].to_i
    label = "#{label}#{elev > 0 ? "+#{elev}" : elev}" if trait.start_with?('elevation')

    if hex_data['hazards']&.any?
      label = hex_data['hazards'].first[0..2].capitalize
    end

    label
  end

  # Abbreviate a hex_type name to fit in a hex cell.
  # Keeps it readable but short enough for overlay text.
  def abbreviate_hex_type(hex_type)
    # Common abbreviations for long type names
    abbrevs = {
      'dense_trees' => 'DnsTr', 'shallow_water' => 'ShWtr', 'deep_water' => 'DpWtr',
      'glass_window' => 'GlWin', 'open_window' => 'OpWin', 'difficult_terrain' => 'DifTr',
      'open_floor' => 'Open', 'off_map' => 'Off',
      'table_rectangular' => 'RcTbl', 'table_round' => 'RdTbl',
      'perimeter_foliage' => 'Folg', 'river_stones' => 'RvStn',
      'hollow_stump' => 'Stmp', 'fallen_log' => 'FLog',
      'crate_cluster' => 'Crate', 'wall_sconce' => 'Scnce',
      'glowing_flora' => 'Flora', 'stone_slab' => 'Slab',
      'wood_pile' => 'WdPl'
    }
    return abbrevs[hex_type] if abbrevs[hex_type]

    # Generic: capitalize first letters of each word, truncate to ~5 chars
    parts = hex_type.split('_')
    if parts.length == 1
      hex_type.capitalize[0..4]
    else
      parts.map { |p| p[0..2].capitalize }.join[0..5]
    end
  end

  # Generate a color-coded SVG overlay showing classification results,
  # composited onto the upscaled battle map image.
  # @param hex_coords_override [Array, nil] custom hex coords for non-default hex size
  def generate_classified_overlay(labeled_path, room, classifications, generator, hex_coords_override = nil, suffix: 'classified')
    return nil if classifications.empty?

    require 'vips'

    # Use the upscaled (unlabeled) image as base
    upscaled_path = labeled_path.sub('_labeled', '_upscaled')
    resized_path = labeled_path.sub('_labeled', '')
    base_path = if File.exist?(upscaled_path)
                  upscaled_path
                elsif File.exist?(resized_path)
                  resized_path
                else
                  labeled_path
                end
    base = Vips::Image.new_from_file(base_path)
    img_width = base.width
    img_height = base.height

    hex_coords = hex_coords_override || generator.send(:generate_hex_coordinates)
    return nil if hex_coords.empty?

    # Replicate the same hex sizing math from overlay_hex_labels
    all_xs = hex_coords.map { |x, _| x }.uniq.sort
    all_ys = hex_coords.map { |_, y| y }.uniq.sort
    num_cols = all_xs.max - all_xs.min
    num_visual_rows = ((all_ys.max - all_ys.min) / 4.0).floor + 1

    hex_size_by_width = img_width.to_f / [num_cols * 1.5 + 2.0, 1].max
    hex_size_by_height = img_height.to_f / [(num_visual_rows + 0.5) * Math.sqrt(3), 1].max
    hex_size = [hex_size_by_width, hex_size_by_height].max

    grid_width = num_cols * 1.5 * hex_size + 2.0 * hex_size
    grid_height = (num_visual_rows + 0.5) * Math.sqrt(3) * hex_size
    offset_x = ((img_width - grid_width) / 2.0).round
    offset_y = ((img_height - grid_height) / 2.0).round

    min_x = all_xs.min
    min_y = all_ys.min

    font_size = [hex_size * 0.28, 5].max.round
    stroke_w = [hex_size * 0.03, 0.8].max.round(1)

    # Build lookup from label to classification
    class_lookup = {}
    classifications.each { |c| class_lookup[c['label']] = c }

    # Build SVG
    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_width}" height="#{img_height}">)

    hex_coords.each do |hx, hy|
      px, py = generator.send(:hex_to_pixel, hx, hy, min_x, min_y, hex_size, offset_x, offset_y)
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
      points = generator.send(:hexagon_svg_points, px, py, hex_size)

      cls = class_lookup[label]
      trait = cls ? dominant_trait(cls) : 'open'
      trait_info = TRAIT_COLORS[trait] || TRAIT_COLORS['open']

      # Thin hex outline only — no fill shading so underlying map is visible
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="rgba(0,0,0,0.25)" stroke-width="#{stroke_w}"/>)

      # Skip labels for open/uninteresting hexes to reduce clutter
      hex_type = cls&.dig('hex_type')
      next if trait == 'open' && (!hex_type || hex_type == 'open_floor')

      display = hex_display_label(cls)

      # Secondary trait indicators
      secondary = []
      secondary << 'C' if cls['provides_cover'] && trait != 'cover'
      secondary << '~' if cls['provides_concealment'] && trait != 'concealment'
      secondary << 'D' if cls['difficult_terrain'] && trait != 'difficult'
      display = "#{display}#{secondary.join}" if secondary.any?

      # Color-coded text label with black outline for readability
      text_color = trait_info[:color].sub(/[\d.]+\)$/, '1.0)')  # Full opacity for text
      text_y = (py + font_size * 0.35).round
      svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="black" stroke="black" stroke-width="#{(stroke_w * 3).round(1)}" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{display}</text>)
      svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="#{text_color}" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{display}</text>)
    end

    svg_parts << '</svg>'
    svg_string = svg_parts.join("\n")

    overlay = Vips::Image.svgload_buffer(svg_string)
    if overlay.width != img_width || overlay.height != img_height
      overlay = overlay.resize(img_width.to_f / overlay.width)
    end

    base = base.bandjoin(255) if base.bands < 4
    overlay = overlay.bandjoin(255) if overlay.bands < 4

    result = base.composite2(overlay, :over)
    classified_path = base_path.sub(/\.(png|jpg|jpeg|webp)$/i, "_#{suffix}.\\1")
    result.write_to_file(classified_path)
    classified_path
  rescue StandardError => e
    debug_log "generate_classified_overlay failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    nil
  end

  public

  # Load all persisted results
  # @return [Hash] { index => result_data }
  def load_results
    return {} unless File.exist?(RESULTS_FILE)

    JSON.parse(File.read(RESULTS_FILE))
  rescue JSON::ParserError
    {}
  end

  # Save a result for a specific config index (thread-safe with file lock)
  def save_result(index, data)
    File.open(RESULTS_FILE, File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX)
      existing = begin
        content = f.read
        content.empty? ? {} : JSON.parse(content)
      rescue JSON::ParserError
        {}
      end
      existing[index.to_s] = data
      f.rewind
      f.write(JSON.pretty_generate(existing))
      f.truncate(f.pos)
    end
  end

  # Atomically re-read and update a result (avoids race conditions between concurrent classifiers)
  def update_result(index)
    File.open(RESULTS_FILE, File::RDWR | File::CREAT) do |f|
      f.flock(File::LOCK_EX)
      existing = begin
        content = f.read
        content.empty? ? {} : JSON.parse(content)
      rescue JSON::ParserError
        {}
      end
      data = existing[index.to_s] || {}
      yield data
      existing[index.to_s] = data
      f.rewind
      f.write(JSON.pretty_generate(existing))
      f.truncate(f.pos)
    end
  end

  # --- Visual similarity normalization ---
  # Removes outlier hex classifications that look more like open ground than their assigned type.
  # Uses LAB chrominance features (shadow-invariant) to detect misclassified hexes.
  #
  # For each typed hex, compares its visual features to:
  # 1. The centroid of other hexes of the same type
  # 2. The centroid of unclassified (ground) hexes
  # If the hex is closer to ground than to its own type, it's removed (becomes ground).
  #
  # @param chunk_results [Array<Hash>] classified hex results from chunk workers
  # @param image [Vips::Image] upscaled source image
  # @param pixel_map [Hash] hex label → {px, py, hx, hy} + :hex_size
  # @param hex_coords [Array] all hex coordinates
  # @param generator [AIBattleMapGeneratorService] for label generation
  # @param min_x [Integer] minimum hex x coordinate
  # @param min_y [Integer] minimum hex y coordinate
  # @return [Array<Hash>] filtered results with outliers removed
  def normalize_by_visual_similarity(chunk_results, image, pixel_map, hex_coords, generator, min_x, min_y)
    hex_size = pixel_map[:hex_size]
    return chunk_results if hex_size.nil? || chunk_results.empty?

    # Convert to LAB — chrominance channels (A, B) are shadow-invariant
    rgb_image = image.bands > 3 ? image.extract_band(0, n: 3) : image
    lab_image = rgb_image.colourspace(:lab)

    # Build set of typed labels
    typed_labels = {}
    chunk_results.each { |r| typed_labels[r['label']] = r['hex_type'] }

    # Extract features for every hex (typed and untyped)
    features = {}
    hex_label_coords = {} # label → [hx, hy] for promoting ground hexes later
    hex_coords.each do |hx, hy|
      label = generator.send(:coord_to_label, hx, hy, min_x, min_y, hex_coords_override: hex_coords)
      info = @coord_lookup[[hx, hy]]
      next unless info

      feat = extract_hex_features(lab_image, info[:px], info[:py], hex_size)
      if feat
        features[label] = feat
        hex_label_coords[label] = [hx, hy]
      end
    end

    # Separate into ground (untyped) vs typed groups
    ground_labels = [] # { label:, features: }
    type_groups = Hash.new { |h, k| h[k] = [] }

    features.each do |label, feat|
      if typed_labels[label]
        type_groups[typed_labels[label]] << { label: label, features: feat }
      else
        ground_labels << { label: label, features: feat }
      end
    end

    # Build reverse lookup: [hx, hy] → label
    coords_to_label = {}
    hex_label_coords.each { |label, c| coords_to_label[c] = label }

    debug_log "    Normalize: #{features.length} hexes (#{type_groups.values.sum(&:length)} typed, #{ground_labels.length} ground)"
    debug_log "    Types: #{type_groups.map { |k, v| "#{k}=#{v.length}" }.join(', ')}"

    # Need enough ground hexes for a meaningful centroid
    return chunk_results if ground_labels.length < 5

    ground_centroid = vector_centroid(ground_labels.map { |g| g[:features] })

    # off_map is the only type that shouldn't be normalized
    skip_types = Set.new(%w[off_map])

    # --- Pass 1: Remove outliers (typed hexes that look like ground) ---
    type_centroids = {}
    type_stats = {}
    outlier_labels = Set.new

    type_groups.each do |type_name, group|
      next if skip_types.include?(type_name)
      next if group.length < 2

      centroid = vector_centroid(group.map { |h| h[:features] })
      type_centroids[type_name] = centroid

      distances = group.map do |hex_entry|
        coords = hex_label_coords[hex_entry[:label]]
        blended = coords ? blend_with_neighbors(hex_entry[:features], coords, features, coords_to_label) : hex_entry[:features]
        d_own = vector_distance(blended, centroid)
        d_ground = vector_distance(blended, ground_centroid)
        { label: hex_entry[:label], d_own: d_own, d_ground: d_ground }
      end

      own_dists = distances.map { |d| d[:d_own] }
      mean_d = own_dists.sum / own_dists.length.to_f
      variance = own_dists.map { |d| (d - mean_d)**2 }.sum / own_dists.length.to_f
      std_d = Math.sqrt(variance)
      type_stats[type_name] = { mean_d: mean_d, std_d: std_d }

      distances.each do |d|
        next unless d[:d_ground] < d[:d_own]
        next unless d[:d_own] > mean_d + 1.5 * std_d

        outlier_labels.add(d[:label])
        debug_log "    Remove: #{d[:label]} (#{type_name}) → ground " \
                  "(d_type=#{d[:d_own].round(1)}, d_ground=#{d[:d_ground].round(1)})"
      end
    end

    # --- Pass 2: Promote ground hexes that clearly match a type ---
    # Recompute centroids and stats from CLEANED data (outliers removed)
    clean_type_centroids = {}
    clean_type_stats = {}
    type_groups.each do |type_name, group|
      next if skip_types.include?(type_name)

      clean_group = group.reject { |h| outlier_labels.include?(h[:label]) }
      next if clean_group.length < 3 # need a solid group to promote into

      centroid = vector_centroid(clean_group.map { |h| h[:features] })
      clean_type_centroids[type_name] = centroid

      own_dists = clean_group.map { |h| vector_distance(h[:features], centroid) }
      mean_d = own_dists.sum / own_dists.length.to_f
      variance = own_dists.map { |d| (d - mean_d)**2 }.sum / own_dists.length.to_f
      clean_type_stats[type_name] = { mean_d: mean_d, std_d: Math.sqrt(variance) }
    end

    # Also recompute ground centroid excluding any hex that was just demoted
    all_ground_feats = ground_labels.map { |g| g[:features] }
    outlier_labels.each do |label|
      all_ground_feats << features[label] if features[label]
    end
    clean_ground_centroid = vector_centroid(all_ground_feats)

    # Build adjacency map: for each label, what types do its neighbors have?
    # (Used to add spatial context — a ground hex surrounded by boulders is more likely a boulder)
    typed_after_pass1 = {}
    chunk_results.each { |r| typed_after_pass1[r['label']] = r['hex_type'] unless outlier_labels.include?(r['label']) }

    promoted = [] # new classification entries to add
    clean_type_centroids.each do |type_name, centroid|
      stats = clean_type_stats[type_name]
      # Accept threshold: ground hex must be within mean + 0.5 std of the type group
      accept_threshold = stats[:mean_d] + 0.5 * stats[:std_d]

      ground_labels.each do |ground_hex|
        feat = ground_hex[:features]
        coords = hex_label_coords[ground_hex[:label]]
        next unless coords

        # Blend feature vector with 20% neighbor influence
        blended_feat = blend_with_neighbors(feat, coords, features, coords_to_label)

        d_type = vector_distance(blended_feat, centroid)
        d_ground = vector_distance(blended_feat, clean_ground_centroid)

        # Must be meaningfully closer to the type than to ground (at least 40% closer)
        next unless d_type < d_ground * 0.6
        next unless d_type <= accept_threshold

        # Spatial check: at least 2 adjacent hexes must already be this type
        neighbors = HexGrid.hex_neighbors(coords[0], coords[1])
        same_type_neighbors = neighbors.count do |nx, ny|
          nlabel = generator.send(:coord_to_label, nx, ny, min_x, min_y, hex_coords_override: hex_coords)
          typed_after_pass1[nlabel] == type_name
        end
        next unless same_type_neighbors >= 2

        promoted << {
          'label' => ground_hex[:label],
          'hex_type' => type_name,
          'x' => coords.first,
          'y' => coords.last
        }
        debug_log "    Promote: #{ground_hex[:label]} → #{type_name} " \
                  "(d_type=#{d_type.round(1)}, d_ground=#{d_ground.round(1)}, threshold=#{accept_threshold.round(1)})"
      end
    end

    # Deduplicate promotions — if a ground hex matches multiple types, pick the closest
    if promoted.length > 1
      by_label = promoted.group_by { |p| p['label'] }
      promoted = by_label.map do |label, candidates|
        if candidates.length == 1
          candidates.first
        else
          feat = features[label]
          candidates.min_by { |c| vector_distance(feat, clean_type_centroids[c['hex_type']]) }
        end
      end
    end

    debug_log "    Result: #{outlier_labels.length} removed, #{promoted.length} promoted"

    # Apply: remove outliers, add promotions
    result = chunk_results.reject { |r| outlier_labels.include?(r['label']) }
    result.concat(promoted)
    result
  end

  # Extract LAB chrominance features from a hex-sized image patch.
  # Returns a feature vector focused on color (shadow-invariant) with light texture info.
  # @param lab_image [Vips::Image] image in LAB color space
  # @param px [Float] hex center x in pixels
  # @param py [Float] hex center y in pixels
  # @param hex_size [Float] hex radius in pixels
  # @return [Array<Float>, nil] feature vector or nil if patch is invalid
  def extract_hex_features(lab_image, px, py, hex_size)
    # Skip hexes whose center is outside the image
    return nil if px < 0 || py < 0 || px >= lab_image.width || py >= lab_image.height

    # Crop a square patch inscribed within the hex
    inner_r = [(hex_size * 0.7).to_i, 2].max
    x1 = [px.round - inner_r, 0].max
    y1 = [py.round - inner_r, 0].max
    w = [inner_r * 2, lab_image.width - x1].min
    h = [inner_r * 2, lab_image.height - y1].min
    return nil if w < 4 || h < 4

    patch = lab_image.crop(x1, y1, w, h)

    # Extract per-band mean and deviation using simple vips operations
    means = []
    devs = []
    patch.bands.times do |b|
      band = patch.extract_band(b)
      means << band.avg
      devs << band.deviate
    end

    # Feature vector: chrominance-heavy (A,B), L downweighted for shadow invariance
    # LAB bands: 0=L, 1=A, 2=B
    [means[1], means[2], devs[1], devs[2], means[0] * 0.3, devs[0] * 0.2]
  rescue Vips::Error => e
    @_feat_error_logged ||= 0
    if @_feat_error_logged < 3
      debug_log "    extract_hex_features error: #{e.message}"
      @_feat_error_logged += 1
    end
    nil
  end

  # Blend a hex's features with 20% influence from its neighbors' features.
  # This provides spatial context — a hex surrounded by similar hexes gets reinforced.
  # @param feat [Array<Float>] the hex's own feature vector
  # @param coords [Array] [hx, hy] hex coordinates
  # @param features [Hash] label → feature vector for all hexes
  # @param coords_to_label [Hash] [hx,hy] → label reverse lookup
  # @return [Array<Float>] blended feature vector (80% self + 20% neighbor average)
  def blend_with_neighbors(feat, coords, features, coords_to_label)
    neighbors = HexGrid.hex_neighbors(coords[0], coords[1])

    neighbor_feats = neighbors.filter_map do |nx, ny|
      label = coords_to_label[[nx, ny]]
      label ? features[label] : nil
    end

    return feat if neighbor_feats.empty?

    neighbor_avg = vector_centroid(neighbor_feats)
    feat.zip(neighbor_avg).map { |s, n| s * 0.8 + n * 0.2 }
  end
end
