# frozen_string_literal: true

require 'base64'
require 'json'
require 'vips'
require_relative '../../lib/vector_math_helper'
require_relative '../../lib/safe_json_helper'
require_relative '../battlemap_v2/hex_type_mapping'
require_relative '../battlemap_v2/l1_analysis_config'

# AIBattleMapGeneratorService generates battle maps using AI image generation
# and multimodal analysis to determine hex terrain features.
#
# Workflow:
# 1. Generate a gridless battlemap image from room description using Gemini
# 2. Overlay hex grid with labels (1A, 1B for row 1, 2A, 2B for row 2, top to bottom)
# 3. Send labeled image to multimodal LLM for hex-by-hex analysis (labels use "1-A" dash format)
# 4. Parse JSON response and populate RoomHex records
# 5. Store image URL and mark battle map as ready
#
# Falls back to procedural generation if AI is disabled or fails.
#
class AIBattleMapGeneratorService
  include BattleMapPubsub

  # Bundles normalization analysis artifacts so normalize_v3 call sites stay readable
  # and less error-prone as the pipeline evolves.
  class NormalizationContext
    attr_reader :edge_map, :zone_map, :depth_map, :image_path, :type_properties,
                :present_type_names, :prefetched_sam_threads, :l1_hints

    def initialize(edge_map: nil, zone_map: nil, depth_map: nil, image_path: nil,
                   type_properties: nil, present_type_names: nil, prefetched_sam_threads: nil, l1_hints: nil)
      @edge_map = edge_map
      @zone_map = zone_map
      @depth_map = depth_map
      @image_path = image_path
      @type_properties = type_properties || {}
      @present_type_names = present_type_names || []
      @prefetched_sam_threads = prefetched_sam_threads || {}
      @l1_hints = l1_hints || {}
    end
  end

  extend VectorMathHelper
  include VectorMathHelper
  extend SafeJSONHelper
  include SafeJSONHelper
  include BattleMapConnectivity
  # Maximum room dimension (in feet) reported to the LLM / used for hex layout.
  # Keeps the generated map consistent with the compressed hex grid size.
  MAX_ROOM_DIMENSION_FEET = 180

  # Rooms smaller than this (per axis) get inflated for hex grid sizing.
  # Gemini generates battlemaps at roughly the same visual scale regardless of
  # stated room size, so small rooms end up with too few hexes and oversized
  # hex spacing.  Inflating dimensions halfway toward this target gives them
  # more hexes that better match the actual image content.
  SMALL_ROOM_INFLATE_TARGET = 30

  # Threshold for chunking large hex grids
  CHUNK_THRESHOLD = 100

  # Size of each chunk for processing large grids
  CHUNK_SIZE = 25

  MIN_CHUNK_SIZE = 5            # Minimum chunk size before giving up

  # --- Advanced classification pipeline constants ---

  CLASSIFICATION_MODEL = 'claude-sonnet-4-6'
  OVERVIEW_MODEL = 'claude-sonnet-4-6'
  MAX_CONCURRENT_CHUNKS = 30

  WATER_DEPTHS = %w[none puddle wading swimming deep].freeze
  OVERVIEW_HAZARD_TYPES = %w[fire lava acid spikes trap poison electricity explosives].freeze

  SIMPLE_HEX_TYPES = %w[
    treetrunk treebranch shrubbery boulder mud snow ice
    puddle wading_water deep_water table chair bench fire log
    wall glass_window open_window barrel balcony staircase ladder door archway
    rubble pillar crate chest wagon tent
    pit cliff ledge bridge fence gate
    off_map open_floor other
  ].freeze

  # Types exempt from edge-based clearing (Pass 2) — don't produce visible edges
  EDGE_EXEMPT_TYPES = Set.new(%w[
    puddle wading_water deep_water mud snow ice
    fire shrubbery open_floor off_map
  ]).freeze

  # Types that should punch through walls (Pass 8)
  PASSTHROUGH_TYPES = Set.new(%w[door archway gate open_window glass_window]).freeze

  # Architectural types that form valid clusters together (wall+window+door = one structure)
  ARCHITECTURAL_TYPES = Set.new(%w[wall fence cliff glass_window open_window door archway gate]).freeze

  # Wall-like types that can be extended via edge-guided wall extension.
  WALL_EXTENSION_TYPES = Set.new(%w[wall fence cliff]).freeze

  # Flat hex types (floor-level) that have clear visual boundaries but no depth signal.
  # Used by flat shape snap (Pass 3b) to fill visual shapes detected in the raw image.
  FLAT_SNAP_TYPES = Set.new(%w[puddle wading_water deep_water mud snow ice fire shrubbery]).freeze

  # SAM call categories — types within a category are mutually exclusive,
  # types in different categories can overlap (stacking).
  SAM_CATEGORIES = {
    structure: %w[wall door archway gate glass_window open_window fence pillar cliff],
    furniture: %w[table chair bench barrel crate chest wagon tent log],
    terrain:   %w[shrubbery mud snow ice puddle wading_water deep_water treetrunk treebranch boulder],
    hazards:   %w[fire pit rubble],
    elevation: %w[staircase ladder balcony bridge ledge]
  }.freeze

  # Priority order for hex_type when multiple categories overlap the same hex.
  # Higher index = higher priority for primary type assignment.
  SAM_CATEGORY_PRIORITY = %i[terrain hazards furniture elevation structure].freeze

  # --- Grid classification pipeline constants ---
  SMALL_ROOM_THRESHOLD = 16  # pixels_per_hex below this = small room (4x4 L1, skip L2)

  STANDARD_FEATURE_TYPES = SIMPLE_HEX_TYPES.reject { |t|
    %w[wall off_map open_floor other].include?(t)
  }.freeze

  GRID_L1_MODEL = 'gemini-3.1-pro-preview'
  GRID_BATCH_MODEL = 'gemini-3.1-flash-lite-preview'

  HEX_TYPE_PROPERTIES = {
    'treetrunk'     => { 'provides_cover' => true, 'traversable' => false },
    'treebranch'    => { 'provides_cover' => true, 'traversable' => true },
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

  HEX_DEFAULT_PROPERTIES = {
    'traversable' => true, 'provides_cover' => false, 'provides_concealment' => false,
    'elevation' => 0, 'is_wall' => false, 'is_window' => false, 'is_window_open' => false,
    'is_exit' => false, 'is_off_map' => false, 'difficult_terrain' => false,
    'water_depth' => 'none', 'hazards' => []
  }.freeze

  OVERVIEW_SCHEMA = {
    type: 'OBJECT',
    properties: {
      scene_description: { type: 'STRING', description: 'Brief 1-2 sentence summary of the battle map scene' },
      map_layout: { type: 'STRING', description: 'Spatial layout: what is where (north/south/center/edges).' },
      present_types: {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: {
            type_name:           { type: 'STRING', description: 'Short snake_case name (e.g. treetrunk, wall, table)' },
            visual_description:  { type: 'STRING', description: 'What this looks like in the image (color, shape, texture)' },
            custom_type_justification: { type: 'STRING', description: 'Required if type_name is NOT a standard type.' },
            traversable:         { type: 'BOOLEAN', description: 'Can someone walk through?' },
            provides_cover:      { type: 'BOOLEAN', description: 'Stops projectiles?' },
            provides_concealment: { type: 'BOOLEAN', description: 'Visually obscures but doesnt stop projectiles?' },
            is_wall:             { type: 'BOOLEAN', description: 'Solid impassable structure?' },
            is_exit:             { type: 'BOOLEAN', description: 'Doorway, archway, gate?' },
            difficult_terrain:   { type: 'BOOLEAN', description: 'Movement penalty?' },
            elevation:           { type: 'INTEGER', description: 'Height in feet (0=ground)' },
            water_depth:         { type: 'STRING', enum: WATER_DEPTHS, description: 'Water depth if applicable' },
            hazards:             { type: 'ARRAY', items: { type: 'STRING', enum: OVERVIEW_HAZARD_TYPES }, description: 'Active hazards' }
          },
          required: %w[type_name visual_description traversable provides_cover provides_concealment is_wall is_exit difficult_terrain elevation]
        }
      }
    },
    required: %w[scene_description map_layout present_types]
  }.freeze

  # Maps fine-grained LLM simple types → RoomHex database fields.
  # Delegates to BattlemapV2::HexTypeMapping — single source of truth.
  SIMPLE_TYPE_TO_ROOM_HEX = BattlemapV2::HexTypeMapping::SIMPLE_TYPE_TO_ROOM_HEX

  attr_reader :room

  def initialize(room, mode: :text, tier: :default, debug: false)
    @room = room
    @mode = mode
    @tier = tier
    @debug = debug
    @errors = []
  end

  # Re-analyze an existing battle map image without regenerating it.
  # Useful for debugging hex classification issues.
  # @param image_path [String] path to the image file (e.g. "public/uploads/...")
  # @return [Hash] { success: Boolean, hex_count: Integer, raw_results: Array }
  def reanalyze(image_path)
    hex_data = analyze_hexes_with_grid(image_path)
    if @debug
      # In debug mode, return the data without persisting — lets us inspect raw results
      { success: true, hex_count: hex_data.size, hex_data: hex_data }
    else
      hex_data = ensure_traversable_connectivity(hex_data)
      hex_data = crop_non_traversable_border(hex_data)
      persist_hex_data(hex_data)
      if hex_data.any?
        new_w, new_h = arena_dimensions_from_hex_data(hex_data)
        Fight.where(room_id: room.id).exclude(status: 'ended').update(arena_width: new_w, arena_height: new_h)
      end
      { success: true, hex_count: hex_data.size }
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Reanalyze failed: #{e.class}: #{e.message}"
    warn e.backtrace&.first(5)&.join("\n")
    { success: false, error: e.message }
  end

  # Generate battle map with AI assistance
  # @return [Hash] { success: Boolean, hex_count: Integer, fallback: Boolean, error: String }
  def generate
    return fallback_to_procedural('AI battle maps disabled') unless ai_enabled?
    return fallback_to_procedural('Room has no bounds') unless room_has_bounds?

    # Landscape rooms generate poorly — swap to portrait, generate, then rotate back
    landscape = landscape_room?
    orig_bounds = swap_to_portrait! if landscape

    # Step 1: Generate battlemap image
    image_result = generate_battlemap_image
    unless image_result[:success]
      restore_bounds!(orig_bounds) if landscape
      return fallback_to_procedural("Image generation failed: #{image_result[:error]}")
    end

    # Get full filesystem path from local_url (which is relative to public/)
    local_path = image_result[:local_url] ? "public/#{image_result[:local_url]}" : nil
    unless local_path
      restore_bounds!(orig_bounds) if landscape
      return fallback_to_procedural('No local path in image result')
    end

    # Save raw generated image for inspection
    copy_inspection_file(local_path, '01_raw_generated.png') rescue nil

    # Upscale if image is smaller than target dimensions
    local_path = upscale_if_needed(local_path)

    # Save upscaled image for inspection
    copy_inspection_file(local_path, '02_upscaled.png') rescue nil

    # Trim black/white/gray borders from generated image
    MapSvgRenderService.trim_image_borders(local_path)

    # Convert to WebP for smaller file size
    local_path = MapSvgRenderService.convert_to_webp(local_path)

    # Save processed image for inspection
    copy_inspection_file(local_path, '03_processed.webp') rescue nil

    # Step 2: Analyze hexes — Grid pipeline preferred, overview pipeline fallback
    hex_data = if GameConfig::Rendering::BATTLEMAP_V2_ENABLED
      analyze_hexes_v2(local_path)
    else
      analyze_hexes_with_grid(local_path)
    end
    if hex_data.empty?
      restore_bounds!(orig_bounds) if landscape
      return fallback_to_procedural('LLM analysis returned no hex data')
    end

    # Step 3: Validate connectivity, crop borders, persist, and apply post-crop assets/lights.
    hex_data, local_path = persist_battlemap_outputs(hex_data, local_path)

    # Save final image and metadata for inspection
    begin
      copy_inspection_file(local_path, '10_final.webp')
      save_inspection_metadata(:room, {
        id: room.id, name: room.respond_to?(:name) ? room.name : nil,
        hex_count: hex_data.size, generated_at: Time.now.iso8601
      })
      flush_inspection_metadata
    rescue StandardError => e
      warn "[AIBattleMapGenerator] Final inspection save failed: #{e.message}"
    end

    finalize_battlemap_generation_state(landscape: landscape, orig_bounds: orig_bounds)

    { success: true, hex_count: hex_data.size, fallback: false }
  rescue StandardError => e
    restore_bounds!(orig_bounds) if landscape && orig_bounds
    fallback_to_procedural("Unexpected error: #{e.message}")
  end

  # Generate battle map asynchronously with progress tracking
  # Designed to be called from background jobs
  # @param fight [Fight] the fight instance
  def generate_async(fight)
    publish_progress(fight.id, 0, "Starting generation...")

    # Landscape rooms generate poorly — swap to portrait, generate, then rotate back
    landscape = landscape_room?
    orig_bounds = swap_to_portrait! if landscape

    begin
      # 1. Generate base image (0-40%)
      publish_progress(fight.id, 5, "Generating battle map image...")
      image_result = generate_battlemap_image
      unless image_result[:success]
        raise StandardError, "Image generation failed: #{image_result[:error]}"
      end

      local_path = image_result[:local_url] ? "public/#{image_result[:local_url]}" : nil
      raise StandardError, 'No local path in image result' unless local_path

      publish_progress(fight.id, 40, "Image generated")

      # 2. Upscale if needed (40-55%)
      publish_progress(fight.id, 45, "Upscaling image...")
      local_path = upscale_if_needed(local_path)
      publish_progress(fight.id, 55, "Upscaling complete")

      # 3. Trim/convert (55-65%)
      publish_progress(fight.id, 60, "Processing image...")
      MapSvgRenderService.trim_image_borders(local_path)
      local_path = MapSvgRenderService.convert_to_webp(local_path)
      publish_progress(fight.id, 65, "Processing complete")

      # 4. Analyze hexes (65-95%) — V2 pipeline preferred, grid fallback
      publish_progress(fight.id, 70, "Analyzing terrain...")
      hex_data = if GameConfig::Rendering::BATTLEMAP_V2_ENABLED
        analyze_hexes_v2(local_path, fight_id: fight.id)
      else
        analyze_hexes_with_grid(local_path)
      end
      raise StandardError, 'LLM analysis returned no hex data' if hex_data.empty?

      publish_progress(fight.id, 95, "Analysis complete")

      # 5. Validate connectivity/persist and finalize rotated/pixel-wall state (95-100%)
      hex_data, local_path = persist_battlemap_outputs(hex_data, local_path)
      finalize_battlemap_generation_state(landscape: landscape, orig_bounds: orig_bounds, fight: fight)

      publish_progress(fight.id, 100, "Complete")

      # Mark fight as ready
      fight.complete_battle_map_generation!
      publish_completion(fight.id, success: true)

    rescue StandardError => e
      # Restore bounds before fallback
      restore_bounds!(orig_bounds) if landscape && orig_bounds

      # Fall back to procedural generation
      warn "[AIBattleMapGenerator] Failed for room #{room.id}: #{e.message}"
      publish_progress(fight.id, 50, "Falling back to procedural generation...")

      fallback_success = false
      begin
        fallback_success = BattleMapGeneratorService.new(room).generate!
      rescue StandardError => fallback_error
        warn "[AIBattleMapGenerator] Procedural fallback also failed: #{fallback_error.message}"
      end

      publish_progress(fight.id, 100, "Complete")
      fight.complete_battle_map_generation!
      publish_completion(fight.id, success: fallback_success, fallback: true)
    end
  end

  # Detect light sources in the battle map image.
  # Primary path: L1+SAM (populated during grid classification).
  # Fallback: CV-based detection via the Python lighting microservice.
  #
  # @param room [Room] the room to update
  # @param image_path [String] path to the battle map image
  def detect_and_store_light_sources(room, image_path)
    return unless image_path && File.exist?(image_path)

    # If L1+SAM already populated light sources during classification, we're done.
    # Note: Sequel::Postgres::JSONBArray doesn't pass is_a?(Array), use respond_to?.
    existing = room.detected_light_sources
    if existing.respond_to?(:any?) && existing.any?
      warn "[AIBattleMapGenerator] Light sources already detected by L1+SAM (#{existing.length} sources)"
      return
    end

    # Fallback: CV-based detection via Python lighting microservice
    unless LightingServiceManager.ensure_running
      warn "[AIBattleMapGenerator] Lighting service unavailable, skipping light detection"
      return
    end

    url = ENV.fetch('LIGHTING_SERVICE_URL', 'http://localhost:18942')
    conn = Faraday.new(url: url) do |f|
      f.options.timeout = 30
      f.options.open_timeout = 10
    end

    hex_data = room.room_hexes_dataset
                   .where(hex_type: %w[fire])
                   .map { |h| { hex_x: h.hex_x, hex_y: h.hex_y, hex_type: h.hex_type } }

    response = conn.post('/detect-light-sources', {
      battlemap_path: File.expand_path(image_path),
      hex_data: hex_data
    }.to_json, 'Content-Type' => 'application/json')

    return unless response.success?

    result = JSON.parse(response.body)
    if result['success'] && result['light_sources']
      room.update(detected_light_sources: Sequel.pg_jsonb_wrap(result['light_sources']))
      warn "[AIBattleMapGenerator] CV fallback detected #{result['light_sources'].length} light sources"
      LightingServiceManager.mark_used
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Light source detection failed: #{e.message}"
  end

  def persist_battlemap_outputs(hex_data, local_path)
    normalized_hex_data = ensure_traversable_connectivity(hex_data)
    normalized_hex_data, local_path = crop_border_with_image(normalized_hex_data, local_path)
    persist_hex_data(normalized_hex_data)

    # Store URL path (not filesystem path) for web serving
    url = local_path.sub(%r{^public/?}, '')
    url = "/#{url}" unless url.start_with?('/')
    persist_image(url)

    # Persist AI object metadata and raw type mask (before border crop so mask gets cropped)
    if @final_typed_map&.any? && @inspection_base
      persist_object_metadata_and_mask(
        @final_typed_map, @inspection_base,
        l1_data: @l1_classification_data,
        overview: @overview_classification_data
      )
    end

    # Keep auxiliary assets (masks/depth/lights) aligned with post-classification crop
    apply_border_crop_to_aux_assets!

    # Detect and store light sources (L1+SAM primary, CV fallback)
    detect_and_store_light_sources(room, local_path)

    [normalized_hex_data, local_path]
  end

  def finalize_battlemap_generation_state(landscape:, orig_bounds:, fight: nil)
    # Rotate portrait → landscape if we swapped earlier.
    if landscape
      restore_bounds!(orig_bounds)
      rotate_landscape_to_final!
    end

    # Pixel wall mask governs movement at edge-level (including internal walls).
    # Must run after final hex persistence and any rotation.
    refresh_wall_passability_edges!

    return unless room.hex_count.positive?

    final_hex_data = room.room_hexes_dataset.all.map { |h| { x: h.hex_x, y: h.hex_y } }
    new_w, new_h = arena_dimensions_from_hex_data(final_hex_data)

    if fight
      fight.update(arena_width: new_w, arena_height: new_h)
    else
      Fight.where(room_id: room.id).exclude(status: 'ended').update(arena_width: new_w, arena_height: new_h)
    end
  end

  # Extract center positions and radii from a binary SAM mask using OpenCV.
  # Returns [{cx:, cy:, radius:}, ...]
  # Public class method so admin routes can call it without instantiating the service.
  def self.extract_positions_from_mask(mask_path)
    script = <<~PYTHON
      import cv2, numpy as np, json, sys
      mask = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
      if mask is None:
          print('[]')
          sys.exit(0)
      _, binary = cv2.threshold(mask, 127, 255, cv2.THRESH_BINARY)
      contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
      h, w = mask.shape[:2]
      min_area = (min(h, w) * 0.005) ** 2
      results = []
      for c in contours:
          area = cv2.contourArea(c)
          if area < min_area:
              continue
          M = cv2.moments(c)
          if M['m00'] < 1:
              continue
          cx = M['m10'] / M['m00']
          cy = M['m01'] / M['m00']
          radius = np.sqrt(area / np.pi)
          results.append({'cx': round(cx, 1), 'cy': round(cy, 1), 'radius': round(radius, 1)})
      print(json.dumps(results))
    PYTHON

    require 'tempfile'
    script_file = Tempfile.new(['extract_lights', '.py'])
    script_file.write(script)
    script_file.close

    output = `python3 #{script_file.path} #{mask_path} 2>/dev/null`.strip
    script_file.unlink

    return [] if output.empty?

    JSON.parse(output).map { |p| { cx: p['cx'], cy: p['cy'], radius: p['radius'] } }
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Mask position extraction failed: #{e.message}"
    []
  end

  # Public accessors for L1 analysis prompt/schema — used by BattlemapV2::PipelineService
  # to avoid calling private methods via send.
  def l1_prompt(grid_n = 3)
    grid_l1_prompt(grid_n)
  end

  def l1_schema
    grid_l1_schema
  end

  private

  # --- Inspection / debug artifact helpers ---

  def inspection_dir
    @inspection_dir ||= begin
      dir = File.join('public', 'uploads', 'battle_map_debug', "room_#{room.id}")
      FileUtils.mkdir_p(dir)
      dir
    end
  end

  def save_inspection_image(vips_image, name)
    path = File.join(inspection_dir, name)
    vips_image.write_to_file(path)
    path
  rescue StandardError => e
    warn "[AIBattleMapGenerator] save_inspection_image(#{name}) failed: #{e.message}"
    nil
  end

  def copy_inspection_file(src, name)
    return unless src && File.exist?(src)
    dst = File.join(inspection_dir, name)
    FileUtils.cp(src, dst)
    dst
  rescue StandardError => e
    warn "[AIBattleMapGenerator] copy_inspection_file(#{name}) failed: #{e.message}"
    nil
  end

  def save_inspection_metadata(key, data)
    @inspection_metadata ||= {}
    @inspection_metadata[key] = data
  rescue StandardError => e
    warn "[AIBattleMapGenerator] save_inspection_metadata(#{key}) failed: #{e.message}"
  end

  def flush_inspection_metadata
    return unless @inspection_metadata
    path = File.join(inspection_dir, 'inspection.json')
    # Merge into existing data so V2 pipeline artifacts (l1, sam_results) are preserved
    existing = File.exist?(path) ? (JSON.parse(File.read(path)) rescue {}) : {}
    new_data = JSON.parse(JSON.generate(@inspection_metadata)) # symbol → string keys
    File.write(path, JSON.pretty_generate(existing.merge(new_data)))
  rescue StandardError => e
    warn "[AIBattleMapGenerator] flush_inspection_metadata failed: #{e.message}"
  end

  INSPECTION_COLORS = {
    'wall' => 'rgba(80,80,80,0.5)', 'off_map' => 'rgba(30,30,30,0.5)',
    'door' => 'rgba(139,69,19,0.5)', 'glass_window' => 'rgba(135,206,250,0.5)',
    'water' => 'rgba(30,100,200,0.5)', 'fire' => 'rgba(255,100,0,0.5)',
    'table' => 'rgba(139,90,43,0.5)', 'chair' => 'rgba(160,82,45,0.5)',
    'barrel' => 'rgba(139,90,43,0.5)', 'crate' => 'rgba(160,120,60,0.5)',
    'staircase' => 'rgba(192,192,192,0.5)', 'pillar' => 'rgba(192,192,192,0.5)',
    'boulder' => 'rgba(139,137,137,0.5)', 'counter' => 'rgba(120,80,50,0.5)',
    'bench' => 'rgba(160,82,45,0.5)', 'bookshelf' => 'rgba(100,70,40,0.5)',
    'statue' => 'rgba(180,180,180,0.5)', 'campfire' => 'rgba(255,120,30,0.5)',
    'treetrunk' => 'rgba(0,100,0,0.5)', 'shrubbery' => 'rgba(107,142,35,0.5)',
  }.freeze

  # RGB tuples for object type mask rendering (derived from INSPECTION_COLORS)
  OBJECT_TYPE_RGB = INSPECTION_COLORS.transform_values { |rgba|
    rgba.scan(/\d+/).first(3).map(&:to_i)
  }.freeze

  # Deterministic RGB for types not in OBJECT_TYPE_RGB
  def type_name_to_rgb(type_name)
    return OBJECT_TYPE_RGB[type_name] if OBJECT_TYPE_RGB.key?(type_name)
    hue = type_name.hash.abs % 360
    # HSL to RGB with s=0.7, l=0.5
    c = (1 - (2 * 0.5 - 1).abs) * 0.7
    x = c * (1 - ((hue / 60.0) % 2 - 1).abs)
    m = 0.5 - c / 2.0
    r, g, b = case hue
              when 0...60   then [c, x, 0]
              when 60...120 then [x, c, 0]
              when 120...180 then [0, c, x]
              when 180...240 then [0, x, c]
              when 240...300 then [x, 0, c]
              else [c, 0, x]
              end
    [((r + m) * 255).round, ((g + m) * 255).round, ((b + m) * 255).round]
  end

  def render_inspection_overlay(typed_map, base, filename)
    return unless @coord_lookup&.any? && base

    hex_size = @inspection_hex_size || 20

    svg_elements = typed_map.filter_map do |(hx, hy), ht|
      info = @coord_lookup[[hx, hy]]
      next unless info
      color = INSPECTION_COLORS[ht] || 'rgba(255,0,255,0.5)'
      px, py = info[:px], info[:py]
      points = inspection_hex_points(px, py, hex_size)
      "<polygon points='#{points}' fill='#{color}' stroke='#{color.sub(/[\d.]+\)$/, '0.8)')}' stroke-width='1'/>"
    end.join("\n")

    svg = "<svg xmlns='http://www.w3.org/2000/svg' width='#{base.width}' height='#{base.height}'>#{svg_elements}</svg>"
    overlay = Vips::Image.svgload_buffer(svg)
    if overlay.width != base.width
      overlay = overlay.resize(base.width.to_f / overlay.width, vscale: base.height.to_f / overlay.height)
    end

    base_rgba = base.bands >= 4 ? base : base.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composite = base_rgba.composite(overlay_rgba, :over)
    save_inspection_image(composite, filename)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Inspection overlay failed: #{e.message}"
  end

  def inspection_hex_points(cx, cy, size)
    (0..5).map { |i|
      angle = Math::PI / 3.0 * i
      "#{(cx + size * Math.cos(angle)).round(1)},#{(cy + size * Math.sin(angle)).round(1)}"
    }.join(' ')
  end

  # Check if AI battle maps are enabled
  def ai_enabled?
    return false unless defined?(GameSetting)

    GameSetting.boolean('ai_battle_maps_enabled') &&
      AIProviderService.provider_available?('google_gemini')
  end

  # Check if room has valid bounds
  def room_has_bounds?
    room.min_x && room.max_x && room.min_y && room.max_y
  end

  # Room dimensions in feet, capped to MAX_ROOM_DIMENSION_FEET.
  # Used for image generation prompts (tells the LLM the real room size).
  def capped_room_dimensions
    w = [(room.max_x - room.min_x).round, MAX_ROOM_DIMENSION_FEET].min
    h = [(room.max_y - room.min_y).round, MAX_ROOM_DIMENSION_FEET].min
    [w, h]
  end

  # Room dimensions inflated for hex grid sizing.
  # Gemini produces battlemaps at roughly the same visual scale regardless of
  # stated room size, so a 16x16 room image looks similar to a 30x30 one.
  # For axes below SMALL_ROOM_INFLATE_TARGET we move halfway toward the target
  # so the hex grid density better matches the generated image content.
  # Axes already at or above the target are returned unchanged.
  def inflated_room_dimensions
    w, h = capped_room_dimensions
    target = SMALL_ROOM_INFLATE_TARGET
    w = ((w + target) / 2.0).round if w < target
    h = ((h + target) / 2.0).round if h < target
    [w, h]
  end

  # Upscale image if it's smaller than the target dimensions
  def upscale_if_needed(local_path)
    return local_path unless ReplicateUpscalerService.available?

    target = calculate_image_dimensions
    image = Vips::Image.new_from_file(local_path)

    if image.width < target[:width] * 0.9  # 10% tolerance
      scale = (target[:width].to_f / image.width).ceil.clamp(2, 4)
      result = ReplicateUpscalerService.upscale(local_path, scale: scale)
      if result[:success] && File.exist?(result[:output_path])
        File.delete(local_path) if File.exist?(local_path)
        File.rename(result[:output_path], local_path)
      else
        warn "[AIBattleMapGenerator] Upscale skipped: #{result[:error]}"
      end
    end

    local_path
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Upscale check failed: #{e.message}"
    local_path
  end

  # Fall back to procedural generation
  def fallback_to_procedural(reason = nil)
    warn "[AIBattleMapGenerator] Falling back to procedural: #{reason}" if reason
    success = BattleMapGeneratorService.new(room).generate!
    { success: success, hex_count: room.hex_count, fallback: true, error: reason }
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Procedural fallback failed: #{e.message}"
    { success: false, hex_count: room.hex_count, fallback: true, error: "#{reason} | fallback failed: #{e.message}" }
  end

  # ==================================================
  # Step 1: Image Generation
  # ==================================================

  def generate_battlemap_image
    case @mode
    when :blueprint
      generate_blueprint_image
    else
      generate_text_image
    end
  end

  # Existing text-only generation with validation and retry
  def generate_text_image
    prompt = build_image_prompt
    save_inspection_metadata(:image_prompt, prompt) rescue nil
    aspect_ratio = calculate_aspect_ratio
    dims = calculate_image_dimensions

    max_attempts = 3
    max_attempts.times do |attempt|
      tier = :high_quality
      warn "[AIBattleMapGenerator] Image generation attempt #{attempt + 1}/#{max_attempts} (tier: #{tier})" if attempt > 0

      result = LLM::ImageGenerationService.generate(
        prompt: prompt,
        options: { aspect_ratio: aspect_ratio, dimensions: dims, tier: tier }
      )
      unless result[:success]
        warn "[AIBattleMapGenerator] Image generation failed (attempt #{attempt + 1}): #{result[:error]}"
        next
      end

      local_path = result[:local_url] ? "public/#{result[:local_url]}" : nil
      unless local_path && File.exist?(local_path)
        warn "[AIBattleMapGenerator] Image file not found (attempt #{attempt + 1}): local_url=#{result[:local_url].inspect}"
        next
      end

      env = room.respond_to?(:environment_type) ? room.environment_type : 'indoor'
      if attempt == 0
        # First attempt: validate with aspect ratio (not exact feet — image gen
        # can't produce correctly-scaled images for small rooms)
        ar = calculate_aspect_ratio
        shape_hint = case ar
                     when '9:16' then 'a tall narrow'
                     when '16:9' then 'a wide narrow'
                     else 'a roughly square'
                     end
        room_ctx = "#{shape_hint} #{env} area called #{room.name}"
      else
        # Retries with pro model: just check quality
        room_ctx = "an #{env} area called #{room.name}"
      end
      validation = validate_battlemap_image(local_path, room_context: room_ctx)
      save_inspection_metadata(:validation, { pass: validation[:pass], reason: validation[:reason] }) rescue nil
      if validation[:pass]
        warn "[AIBattleMapGenerator] Image validation passed: #{validation[:reason]}"

        # Check for shadows and remove them if present
        shadow_check = check_battlemap_shadows(local_path)
        save_inspection_metadata(:shadow_check, { has_shadows: shadow_check[:has_shadows], reason: shadow_check[:reason] }) rescue nil
        if shadow_check[:has_shadows]
          warn "[AIBattleMapGenerator] Shadows detected: #{shadow_check[:reason]}"
          shadow_result = remove_battlemap_shadows(local_path)
          if shadow_result[:success]
            warn "[AIBattleMapGenerator] Shadows removed successfully"
            result[:local_url] = shadow_result[:local_path].sub(%r{^public/?}, '')
          else
            warn "[AIBattleMapGenerator] Shadow removal failed: #{shadow_result[:error]}, using original"
          end
        end

        return result
      end

      warn "[AIBattleMapGenerator] Image validation failed (attempt #{attempt + 1}): #{validation[:reason]}"
      File.delete(local_path) if File.exist?(local_path)
    end

    # All attempts failed — return last result anyway so caller can decide
    LLM::ImageGenerationService.generate(
      prompt: prompt,
      options: { aspect_ratio: aspect_ratio, dimensions: dims, tier: :high_quality }
    )
  end

  # Quick validation of a generated battlemap image using flash-lite.
  # Checks: top-down perspective, quality, proportions, and setting match.
  # Uses a low-res version for speed and cost.
  #
  # @param image_path [String] path to the generated image
  # @param room_context [String, nil] e.g. "90x90ft indoor blacksmith called Quality Iron Arms"
  # @return [Hash] { pass: Boolean, reason: String }
  def validate_battlemap_image(image_path, room_context: nil)
    api_key = AIProviderService.api_key_for('google_gemini')
    return { pass: true, reason: 'no API key, skipping validation' } unless api_key

    context = room_context || 'an area'
    prompt_text = "Is this a high quality top-down tactical battlemap suitable for an RPG battle, representing #{context}? Answer PASS or FAIL with a brief reason.\n\nPASS: [reason]\nor\nFAIL: [reason]"
    text = query_gemini_flash_lite_image(image_path, prompt_text, api_key: api_key)
    if text.start_with?('PASS')
      { pass: true, reason: text }
    else
      { pass: false, reason: text }
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Image validation error: #{e.message}"
    { pass: true, reason: "validation error, allowing: #{e.message}" }
  end

  # Check if a battlemap image has non-trivial shadows.
  # Uses flash-lite for a cheap yes/no check.
  #
  # @param image_path [String] path to the image
  # @return [Hash] { has_shadows: Boolean, reason: String }
  def check_battlemap_shadows(image_path)
    api_key = AIProviderService.api_key_for('google_gemini')
    return { has_shadows: false, reason: 'no API key, skipping check' } unless api_key

    prompt_text = "Does this top-down battlemap image have non-trivial shadows (cast shadows, drop shadows, or dark shadow areas that could be confused with walls or terrain features)? Ignore normal shading/texture variation. Answer YES or NO with a brief reason.\n\nYES: [reason]\nor\nNO: [reason]"
    text = query_gemini_flash_lite_image(image_path, prompt_text, api_key: api_key)
    if text.start_with?('YES')
      { has_shadows: true, reason: text }
    else
      { has_shadows: false, reason: text }
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Shadow check error: #{e.message}"
    { has_shadows: false, reason: "check error: #{e.message}" }
  end

  # Remove shadows from a battlemap image by sending it back to Gemini
  # with the original image as reference and a shadow-removal instruction.
  #
  # @param image_path [String] path to the shadowed image
  # @return [Hash] { success: Boolean, local_path: String, error: String }
  def remove_battlemap_shadows(image_path)
    image = Vips::Image.new_from_file(image_path)
    image_data = Base64.strict_encode64(image.write_to_buffer('.png'))

    aspect_ratio = calculate_aspect_ratio
    prompt = "Regenerate this exact same top-down battlemap image but with absolutely no shadows. " \
             "Remove all cast shadows, drop shadows, and dark shadow areas. " \
             "Keep all objects, textures, colors, and layout exactly the same — only remove the shadows. " \
             "The result should be a flat, evenly-lit top-down view with no shadow artifacts."

    result = LLM::ImageGenerationService.generate(
      prompt: prompt,
      options: {
        aspect_ratio: aspect_ratio,
        reference_image: { data: image_data, mime_type: 'image/png' }
      }
    )

    if result[:success] && result[:local_url]
      local = "public/#{result[:local_url]}"
      if File.exist?(local)
        return { success: true, local_path: local }
      end
    end

    { success: false, error: result[:error] || 'Shadow removal failed' }
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Shadow removal error: #{e.message}"
    { success: false, error: e.message }
  end

  def query_gemini_flash_lite_image(image_path, prompt_text, api_key:)
    image = Vips::Image.new_from_file(image_path)
    scale = 512.0 / [image.width, image.height].max
    small = scale < 1.0 ? image.resize(scale) : image
    image_data = Base64.strict_encode64(small.write_to_buffer('.jpg', Q: 70))

    response = LLM::Adapters::GeminiAdapter.generate(
      messages: [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/jpeg', data: image_data },
        { type: 'text', text: prompt_text }
      ]}],
      model: 'gemini-3.1-flash-lite-preview',
      api_key: api_key,
      options: { max_tokens: 150, timeout: 15, temperature: 0 }
    )
    response[:text].to_s.strip
  end

  # Blueprint mode: render SVG → PNG → send as reference image
  def generate_blueprint_image
    # Calculate dimensions first so blueprint matches target image resolution
    dims = calculate_image_dimensions
    aspect_ratio = calculate_aspect_ratio

    # Generate clean SVG blueprint (no text labels — those go in the prompt)
    svg = MapSvgRenderService.render_blueprint_clean(room, width: dims[:width])
    return text_fallback('SVG blueprint generation failed') unless svg&.include?('<svg')

    # Convert to PNG at target resolution
    png_path = MapSvgRenderService.svg_to_png(svg, width: dims[:width])
    return text_fallback('SVG to PNG conversion failed') unless png_path && File.exist?(png_path)

    # Read and encode PNG
    png_data = Base64.strict_encode64(File.binread(png_path))

    # Build prompt (includes room name, description, decorations — non-spatial details)
    prompt = build_blueprint_prompt

    result = LLM::ImageGenerationService.generate(
      prompt: prompt,
      options: {
        aspect_ratio: aspect_ratio,
        dimensions: dims,
        tier: @tier,
        reference_image: { data: png_data, mime_type: 'image/png' }
      }
    )

    # Clean up temp PNG
    File.delete(png_path) if File.exist?(png_path)

    result
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Blueprint mode failed: #{e.message}, falling back to text"
    text_fallback(e.message)
  end

  def text_fallback(reason)
    warn "[AIBattleMapGenerator] Blueprint fallback: #{reason}"
    generate_text_image
  end

  # Prompt for blueprint mode — the reference image is a clean floor plan,
  # and this text provides the context about what everything is.
  def build_blueprint_prompt
    parts = []

    # Core instruction — emphasize strict overhead camera and how features look from above
    parts << "Generate a top-down RPG battle map image based on the attached floor plan for: #{room.name}."
    parts << 'Generate a fully rendered, photorealistic top-down battle map with rich textures and detail. No shadows — shadowless flat lighting only.'
    parts << 'CAMERA: Strictly overhead, looking straight down at the floor. No perspective, no isometric, no 3/4 angle. The viewer sees ONLY the floor surface and objects sitting on it.'
    parts << 'RENDERING RULES for overhead view: Walls are thick dark borders at room edges. A DOOR from above is just a gap in the wall — you cannot see the door panel, hinges, or handle because they are vertical and invisible from overhead. Never draw a door as a flat rectangle on the floor. A WINDOW from above is a thin lighter strip in the wall edge — you cannot see glass panes or frames because they are vertical. Never draw a window as a flat pane on the floor. Only the floor surface and objects resting on it are visible.'

    # Room shape and dimensions — placed before description so shape anchors the layout
    if room_has_bounds?
      w, h = capped_room_dimensions
      sq_ft = w * h
      shape = describe_room_shape(w, h)
      parts << "SHAPE: The playable area must be a #{shape} filling the canvas, approximately #{sq_ft} square feet (#{w}ft wide x #{h}ft tall). Do not make it circular or oval — maintain rectangular proportions."
    end

    desc = room.long_description || (room.respond_to?(:description) ? room.description : nil) || room.short_description
    parts << "Setting: #{desc}" if desc && !desc.to_s.strip.empty?

    # Furniture described naturally (no coded keys)
    if room.respond_to?(:places) && room.places.any?
      items = room.places.map { |p| natural_furniture_description(p) }
      parts << "Furniture shown in the floor plan: #{items.join('; ')}."
    end

    # Doors and windows described by wall position
    if room.respond_to?(:room_features) && room.room_features.any?
      grouped = room.room_features.group_by { |f| f.respond_to?(:feature_type) ? (f.feature_type || 'door') : 'door' }
      grouped.each do |type, features|
        descs = features.map { |f| natural_feature_description(f) }
        parts << "#{type.capitalize}s: #{descs.join('. ')}."
      end
    end

    if room.respond_to?(:decorations) && room.decorations.any?
      deco_names = room.decorations.map(&:name).join('; ')
      parts << "The room also contains: #{deco_names}"
    end

    # Tactical elements from battle map config
    tactical = build_tactical_prompt_section
    parts << tactical unless tactical.empty?

    parts << 'An ideal battlemap has a mix of environmental features — water, fire, elevation changes, and hazards — while still leaving plenty of open space for characters to maneuver and fight. However, only include features that make sense for this specific setting — do not invent features the room description does not suggest.'
    parts << 'Match the room shape, proportions, and placement of elements from the floor plan.'
    parts << 'IMPORTANT: No text, labels, letters, numbers, annotations, dimension markers, scale indicators, or any writing whatsoever. No people or figures. No grid lines, hexagons, or square tile patterns. Never render vertical surfaces (door panels, window panes, wall faces) flat on the ground — from directly overhead these are invisible. Doors = wall gaps only. Paint the scene on a plain white background — the room does not need to fill the entire canvas.'

    parts.join("\n")
  end

  # Group discovered types into SAM call categories.
  # Only includes categories that have at least one discovered type.
  # Custom types from L1 are added to the closest matching category.
  #
  # @param type_names [Array<String>] type names from L1 overview
  # @return [Hash] { category_symbol => "dot . separated . query" }
  def categorize_types_for_sam(type_names)
    categories = {}

    SAM_CATEGORIES.each do |category, standard_types|
      matched = type_names & standard_types
      next if matched.empty?

      categories[category] = matched.join(' . ')
    end

    # Custom types not in any standard category go into furniture (most common)
    all_standard = SAM_CATEGORIES.values.flatten
    custom_types = type_names.reject { |t| all_standard.include?(t) || t == 'off_map' || t == 'open_floor' }
    if custom_types.any?
      existing = categories[:furniture] || ''
      categories[:furniture] = [existing, custom_types.join(' . ')].reject(&:empty?).join(' . ')
    end

    categories
  end

  def build_image_prompt
    parts = []
    parts << "STRICTLY top-down overhead view (bird's-eye, looking straight down) shadowless gridless RPG tactical battlemap for: #{room.name}. NOT isometric, NOT 3D, NOT angled — flat 2D top-down only. No shadows."

    # Dimensions — use aspect ratio description for small rooms where image gen
    # can't produce correctly-scaled output, exact feet for larger rooms.
    if room_has_bounds?
      room_width, room_height = capped_room_dimensions
      if room.has_custom_polygon?
        parts << "Room shape: irregular polygon approximately #{room_width}ft x #{room_height}ft"
      elsif room_width <= 20 && room_height <= 20
        ar = calculate_aspect_ratio
        shape_desc = case ar
                     when '9:16' then 'a tall narrow corridor (portrait orientation, roughly 1:3 ratio)'
                     when '16:9' then 'a wide narrow corridor (landscape orientation, roughly 3:1 ratio)'
                     else 'a square room'
                     end
        parts << "SHAPE: The playable area must be #{shape_desc}. Fill the canvas with the room — walls at the edges, open floor in the center."
      else
        shape = describe_room_shape(room_width, room_height)
        parts << "SHAPE: The playable area must be a #{shape}, #{room_width}ft wide (east-west) x #{room_height}ft tall (north-south). Maintain rectangular proportions."
      end
    end

    # Full description for maximum context
    desc = room.long_description || room.description || room.short_description
    parts << "Setting: #{desc}" if desc && !desc.to_s.strip.empty?

    # Furniture with positions
    if room.respond_to?(:places) && room.places.any?
      furniture = room.places.map do |p|
        name = p.respond_to?(:name) ? p.name : p.to_s
        if p.respond_to?(:x) && p.x && p.respond_to?(:y) && p.y
          "#{name} at X=#{p.x.round}ft, Y=#{p.y.round}ft"
        else
          name
        end
      end.join('; ')
      parts << "Furniture: #{furniture}"
    end

    # Features split by type with wall-relative positions
    if room.respond_to?(:room_features) && room.room_features.any?
      grouped = room.room_features.group_by { |f| f.respond_to?(:feature_type) ? f.feature_type : 'other' }
      grouped.each do |type, features|
        label = type.capitalize
        label = 'Doors' if type == 'door'
        label = 'Windows' if type == 'window'
        label = 'Openings' if type == 'opening'
        label = 'Archways' if type == 'archway'
        label = 'Gates' if type == 'gate'
        label = 'Hatches' if type == 'hatch'

        descriptions = features.map { |f| feature_wall_description(f) }
        parts << "#{label}: #{descriptions.join('. ')}"
      end
    end

    # Decorations as ambient details
    if room.respond_to?(:decorations) && room.decorations.any?
      deco_names = room.decorations.map(&:name).join('; ')
      parts << "The room also contains: #{deco_names}"
    end

    # Tactical elements from battle map config
    tactical = build_tactical_prompt_section
    parts << tactical unless tactical.empty?

    parts << 'An ideal battlemap has a mix of environmental features — water, fire, elevation changes, and hazards — while still leaving plenty of open space for characters to maneuver and fight. However, only include features that make sense for this specific setting — do not invent features the room description does not suggest.'
    parts << 'Instructions: Paint the scene on a plain white canvas background — the room does not need to fill the entire canvas. Walls and floors must have visible color and texture appropriate to the setting — never use white or near-white for walls or floors unless the room description specifically calls for it. No text, labels, letters, numbers, annotations, dimension markers, or any writing. No grid lines, hexagons, or square floor patterns. No people, characters, or figures. We will overlay our own hex grid on top of the image later.'

    parts.join("\n")
  end

  # Describe a feature relative to its wall, inferred from coordinates
  def feature_wall_description(feature)
    return feature.name || feature.feature_type unless feature.respond_to?(:x) && feature.x && feature.respond_to?(:y) && feature.y

    name = feature.respond_to?(:name) && feature.name && !feature.name.to_s.strip.empty? ? feature.name : nil
    wall = infer_wall(feature.x, feature.y)

    case wall
    when :south, :north
      pos = "X=#{feature.x.round}ft"
    when :west, :east
      pos = "Y=#{feature.y.round}ft"
    else
      pos = "X=#{feature.x.round}ft, Y=#{feature.y.round}ft"
    end

    wall_label = "#{wall.to_s.capitalize} wall"
    name ? "#{name}, #{wall_label} at #{pos}" : "#{wall_label} at #{pos}"
  end

  # Infer which wall a feature is on based on its coordinates relative to room bounds
  def infer_wall(x, y)
    return :unknown unless room_has_bounds?

    min_x = room.min_x
    max_x = room.max_x
    min_y = room.min_y
    max_y = room.max_y
    width = max_x - min_x
    height = max_y - min_y

    # Distance from each edge as fraction of room size
    dist_south = (y - min_y).to_f / height
    dist_north = (max_y - y).to_f / height
    dist_west = (x - min_x).to_f / width
    dist_east = (max_x - x).to_f / width

    min_dist = [dist_south, dist_north, dist_west, dist_east].min

    case min_dist
    when dist_south then :south
    when dist_north then :north
    when dist_west then :west
    when dist_east then :east
    else :south
    end
  end

  # Describe room shape from width/height aspect ratio
  def describe_room_shape(width, height)
    ratio = width.to_f / height
    if ratio.between?(0.85, 1.15)
      'square'
    elsif ratio > 3.0 || ratio < 0.33
      width > height ? 'narrow corridor, much wider than deep' : 'narrow corridor, much deeper than wide'
    elsif ratio > 1.8
      'rectangle roughly twice as wide as deep'
    elsif ratio > 1.15
      'rectangle, wider than deep'
    elsif ratio < 0.55
      'rectangle roughly twice as deep as wide'
    else
      'rectangle, deeper than wide'
    end
  end

  # Natural-language description of a furniture piece using position relative to room
  def natural_furniture_description(place)
    name = place.respond_to?(:name) ? place.name : place.to_s
    return name unless place.respond_to?(:x) && place.x && place.respond_to?(:y) && place.y && room_has_bounds?

    position = position_description(place.x, place.y)
    "#{name} #{position}"
  end

  # Natural-language description of a feature (door/window) by wall and position along wall
  def natural_feature_description(feature)
    name = feature.respond_to?(:name) && feature.name && !feature.name.to_s.strip.empty? ? feature.name : nil
    type_label = feature.respond_to?(:feature_type) ? (feature.feature_type || 'door') : 'door'
    label = name || type_label

    return label unless feature.respond_to?(:x) && feature.x && feature.respond_to?(:y) && feature.y && room_has_bounds?

    wall = infer_wall(feature.x, feature.y)
    wall_pos = wall_position_description(feature.x, feature.y, wall)

    "#{label} on the #{wall} wall#{wall_pos}"
  end

  # Describe a position relative to room bounds using spatial language
  def position_description(x, y)
    return 'in the room' unless room_has_bounds?

    pct_x = ((x - room.min_x).to_f / (room.max_x - room.min_x) * 100).round
    pct_y = ((y - room.min_y).to_f / (room.max_y - room.min_y) * 100).round

    # Map percentages to spatial zones
    ew = if pct_x < 25 then 'west'
         elsif pct_x > 75 then 'east'
         end
    ns = if pct_y < 25 then 'south'
         elsif pct_y > 75 then 'north'
         end

    if ew.nil? && ns.nil?
      'near the center of the room'
    elsif ew && ns
      "in the #{ns}#{ew} corner"
    elsif ew
      "against the #{ew} wall"
    else
      "against the #{ns} wall"
    end
  end

  # Describe position along a wall (e.g. "slightly left of center", "near the southeast corner")
  def wall_position_description(x, y, wall)
    return '' unless room_has_bounds?

    min_x = room.min_x
    max_x = room.max_x
    min_y = room.min_y
    max_y = room.max_y

    case wall
    when :north, :south
      pct = ((x - min_x).to_f / (max_x - min_x) * 100).round
      if pct < 20
        ', near the west end'
      elsif pct < 40
        ', slightly left of center'
      elsif pct > 80
        ', near the east end'
      elsif pct > 60
        ', slightly right of center'
      else
        ', near the center'
      end
    when :east, :west
      pct = ((y - min_y).to_f / (max_y - min_y) * 100).round
      if pct < 20
        ', near the south end'
      elsif pct < 40
        ', slightly south of center'
      elsif pct > 80
        ', near the north end'
      elsif pct > 60
        ', slightly north of center'
      else
        ', near the center'
      end
    else
      ''
    end
  end

  # Build tactical elements description from room's battle map config
  def build_tactical_prompt_section
    config = room.battle_map_config_for_type
    elements = []

    # Water features
    if config[:water_chance].to_f > 0
      intensity = config[:water_chance] >= 0.3 ? 'prominent' : 'minor'
      elements << "#{intensity.capitalize} water features visible from above — puddles, pools, or streams with reflective surfaces and wet edges on surrounding ground"
    end

    # Elevation changes
    if config[:elevation_variance].to_i > 0
      variance = config[:elevation_variance].to_i
      if variance >= 3
        elements << 'Significant elevation changes visible through shadows and color shifts — raised stone platforms, sunken areas, natural ledges with clear height differences'
      else
        elements << 'Subtle elevation changes — slightly raised areas, shallow steps, or gentle slopes shown through shadow gradients'
      end
    end

    # Cover objects
    if config[:objects]&.any?
      samples = config[:objects].sample([3, config[:objects].size].min)
      elements << "Scatter tactical cover objects across the floor: #{samples.join(', ')} — these should cast shadows and be clearly visible from above"
    end

    # Hazards
    if config[:hazard_chance].to_f > 0
      elements << 'Environmental hazards visible on the ground — cracks in the floor, scorch marks, glowing danger zones, or unstable areas with distinct coloring'
    end

    # Explosive risk
    if config[:explosive_chance].to_f > 0
      elements << 'Volatile materials present — barrels or containers that look flammable/explosive'
    end

    # Darkness
    elements << 'Dimly lit with prominent shadows — most light comes from a single source (torch, fire, crack in ceiling), leaving deep shadows in corners and edges' if config[:dark]

    # Difficult terrain
    elements << 'Rough/uneven ground texture that suggests difficult footing — scattered debris, tangled roots, loose rubble, or mud patches' if config[:difficult_terrain]

    elements.empty? ? '' : "Tactical environment: #{elements.join('. ')}."
  end


  def calculate_aspect_ratio
    # Use the room's physical dimensions for image aspect ratio
    width = (room.max_x - room.min_x + 1).to_f
    height = (room.max_y - room.min_y + 1).to_f

    ratio = width / height
    if ratio > 1.5
      '16:9'
    elsif ratio < 0.67
      '9:16'
    else
      '1:1'
    end
  end

  # Calculate image dimensions from room area (log scale)
  # Small rooms (~300 sq ft) get 1024px, large rooms (~3000 sq ft) get 2048px
  def calculate_image_dimensions
    w = (room.max_x - room.min_x).to_f
    h = (room.max_y - room.min_y).to_f
    area = w * h

    base = 1024
    max_size = 2048
    size = if area <= 300
             base
           else
             (base * (1 + Math.log10(area / 300.0))).clamp(base, max_size).round
           end

    ratio = w / h
    if ratio > 1.5
      { width: size, height: (size * 9.0 / 16).round }
    elsif ratio < 0.67
      { width: (size * 9.0 / 16).round, height: size }
    else
      { width: size, height: size }
    end
  end

  # ==================================================
  # Step 2: Hex Label Overlay
  # ==================================================

  def overlay_hex_labels(image_path, padding: 0, hex_size_feet: nil)
    return nil unless image_path && File.exist?(image_path)

    require 'vips'

    # Get image dimensions
    base = Vips::Image.new_from_file(image_path)
    img_width = base.width
    img_height = base.height

    # Calculate hex grid dimensions (custom hex size for denser grids)
    hex_coords = if hex_size_feet
                   custom_hex_coords_for_room(hex_size_feet)
                 else
                   generate_hex_coordinates
                 end
    return nil if hex_coords.empty?

    # Calculate hex size to fit the grid on the image
    all_xs = hex_coords.map { |x, _y| x }.uniq.sort
    all_ys = hex_coords.map { |_x, y| y }.uniq.sort
    num_cols = all_xs.max - all_xs.min
    num_visual_rows = ((all_ys.max - all_ys.min) / 4.0).floor + 1

    usable_width = img_width * (1.0 - 2 * padding)
    usable_height = img_height * (1.0 - 2 * padding)

    hex_size_by_width = usable_width / ([num_cols * 1.5 + 2.0, 1].max)
    hex_size_by_height = usable_height / ([(num_visual_rows + 0.5) * Math.sqrt(3), 1].max)
    # Use min so grid fits within image, zero offsets to match frontend layout
    hex_size = [hex_size_by_width, hex_size_by_height].min

    offset_x = 0
    offset_y = 0

    min_x = all_xs.min
    min_y = all_ys.min

    font_size = [hex_size * 0.30, 7].max.round
    stroke_w = [hex_size * 0.04, 1.5].max.round(1)

    # Build SVG overlay with hex polygons and labels
    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_width}" height="#{img_height}">)

    # First pass: black outlines for contrast shadow
    hex_coords.each do |hx, hy|
      px, py = hex_to_pixel(hx, hy, min_x, min_y, hex_size, offset_x, offset_y)
      points = hexagon_svg_points(px, py, hex_size)
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="black" stroke-width="#{stroke_w * 3}"/>)
    end

    # Second pass: white outlines + labels on top
    hex_coords.each do |hx, hy|
      px, py = hex_to_pixel(hx, hy, min_x, min_y, hex_size, offset_x, offset_y)
      label = coord_to_label(hx, hy, min_x, min_y, hex_coords_override: hex_size_feet ? hex_coords : nil)

      # White hex outline
      points = hexagon_svg_points(px, py, hex_size)
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="white" stroke-width="#{stroke_w}"/>)

      # Label: black shadow text then white foreground (double-draw for guaranteed contrast)
      text_y = (py + font_size * 0.35).round
      svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="black" stroke="black" stroke-width="4" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
      svg_parts << %(<text x="#{px.round}" y="#{text_y}" text-anchor="middle" fill="white" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
    end

    svg_parts << '</svg>'
    svg_string = svg_parts.join("\n")

    # Load SVG overlay and composite onto base image
    overlay = Vips::Image.svgload_buffer(svg_string)

    # Ensure overlay matches base dimensions
    if overlay.width != img_width || overlay.height != img_height
      overlay = overlay.resize(img_width.to_f / overlay.width)
    end

    # Ensure both images have alpha channels for compositing
    base = base.bandjoin(255) if base.bands < 4
    overlay = overlay.bandjoin(255) if overlay.bands < 4

    result = base.composite2(overlay, :over)

    labeled_path = image_path.sub(/\.(png|jpg|jpeg|webp)$/i, '_labeled.\1')
    result.write_to_file(labeled_path)
    labeled_path
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Overlay error: #{e.message}"
    nil
  end

  # Generate SVG polygon points string for hex overlay
  def hexagon_svg_points(cx, cy, size)
    (0..5).map do |i|
      angle = Math::PI / 3 * i
      x = (cx + size * Math.cos(angle)).round
      y = (cy + size * Math.sin(angle)).round
      "#{x},#{y}"
    end.join(' ')
  end

  # Convert a 0-based index to a column letter (0=A, 25=Z, 26=AA, 27=AB, ...)
  # Supports arbitrarily large indices for rooms wider than 26 columns.
  def index_to_column_letter(idx)
    letters = ''
    loop do
      letters = (('A'.ord + (idx % 26)).chr) + letters
      idx = idx / 26 - 1
      break if idx < 0
    end
    letters
  end

  # Convert column letters back to 0-based index (A=0, Z=25, AA=26, AB=27, ...)
  def column_letter_to_index(letters)
    idx = 0
    letters.each_char do |ch|
      idx = idx * 26 + (ch.ord - 'A'.ord + 1)
    end
    idx - 1
  end

  # Convert hex coordinates to label using ABSOLUTE column indices.
  # All unique X values across all rows are sorted and assigned column letters:
  # x=0→A, x=1→B, x=2→C, etc. This means the same hx always gets the same
  # column letter regardless of which row it's in.
  # Row numbers go top to bottom (1 at top).
  # Format: "1-A", "2-B", "15-AA" (row-column with dash separator)
  # @param hex_coords_override [Array, nil] custom hex coords (for non-default hex sizes)
  # Return the nearest compass direction symbol for a dx/dy offset.
  # Used to match a wall hex's position relative to main component against L1 door hints.
  def approx_compass_direction(dx, dy)
    angle = Math.atan2(dy, dx) * 180 / Math::PI  # -180..180, east=0, south=90
    case angle
    when -22.5..22.5    then :east
    when 22.5..67.5     then :southeast
    when 67.5..112.5    then :south
    when 112.5..157.5   then :southwest
    when -67.5..-22.5   then :northeast
    when -112.5..-67.5  then :north
    when -157.5..-112.5 then :northwest
    else                     :west
    end
  end

  def coord_to_label(x, y, min_x, min_y, hex_coords_override: nil)
    coords = hex_coords_override || generate_hex_coordinates

    all_ys = coords.map { |_hx, hy| hy }.uniq.sort
    row_index = all_ys.index(y) || 0
    row = row_index + 1

    all_xs = coords.map { |hx, _hy| hx }.uniq.sort
    col_index = all_xs.index(x) || 0
    col = index_to_column_letter(col_index)

    "#{row}-#{col}"
  end

  # Convert label back to coordinates (accepts both "1-A" dash format and legacy "1A")
  # Uses absolute column mapping — column letter maps to a global X value.
  # @param hex_coords_override [Array, nil] custom hex coords (for non-default hex sizes)
  def label_to_coord(label, min_x, min_y, hex_coords_override: nil)
    coords = hex_coords_override || generate_hex_coordinates

    if label.include?('-')
      parts = label.split('-', 2)
      row = parts[0].to_i - 1
      col_letters = parts[1]
    else
      row = label[/^\d+/].to_i - 1
      col_letters = label[/[A-Z]+$/]
    end
    return nil unless col_letters

    col_index = column_letter_to_index(col_letters)

    all_ys = coords.map { |_hx, hy| hy }.uniq.sort
    return nil if row < 0 || row >= all_ys.length

    target_y = all_ys[row]

    all_xs = coords.map { |hx, _hy| hx }.uniq.sort
    return nil if col_index < 0 || col_index >= all_xs.length

    target_x = all_xs[col_index]

    # Verify this coordinate actually exists in the grid (not all x,y combos are valid in offset hex grids)
    coords.include?([target_x, target_y]) ? [target_x, target_y] : nil
  end

  # Convert hex coordinates to pixel position (flat-top layout)
  # X values are direct column indices, Y pairs form visual rows:
  #   y,y+2 = visual row 0; y+4,y+6 = visual row 1; etc.
  # So visual_row = floor((hy - min_y) / 4)
  # offset_x/offset_y are pixel offsets to center the grid on the image
  def hex_to_pixel(hx, hy, min_x, min_y, hex_size, offset_x, offset_y)
    hex_height = hex_size * Math.sqrt(3)
    col = hx - min_x
    visual_row = ((hy - min_y) / 4.0).floor

    # Y-flip to match frontend renderer (north at top: high hex Y = low pixel Y)
    if @analysis_total_rows
      visual_row = (@analysis_total_rows - 1) - visual_row
      stagger = col.to_i.odd? ? -hex_height / 2.0 : 0
    else
      stagger = col.to_i.odd? ? hex_height / 2.0 : 0
    end

    px = offset_x + hex_size + col * hex_size * 1.5
    py = offset_y + hex_height / 2.0 + visual_row * hex_height + stagger

    [px.round, py.round]
  end

  # Generate flat-top hexagon polygon points string for ImageMagick
  # Matches the JS renderer's flat-top layout (angle starts at 0)
  def hexagon_points(cx, cy, size)
    (0..5).map do |i|
      angle = Math::PI / 3 * i
      x = (cx + size * Math.cos(angle)).round
      y = (cy + size * Math.sin(angle)).round
      "#{x},#{y}"
    end.join(' ')
  end

  def generate_hex_coordinates
    @hex_coordinates ||= begin
      w, h = inflated_room_dimensions
      arena_w, arena_h = HexGrid.arena_dimensions_from_feet(w, h)
      hex_max_x = [arena_w - 1, 0].max
      hex_max_y = [(arena_h - 1) * 4 + 2, 0].max
      HexGrid.hex_coords_in_bounds(0, 0, hex_max_x, hex_max_y)
    end
  end

  # Generate hex coordinates using a custom hex size (e.g. 2ft for denser grids).
  # Uses the same offset coordinate system but with more hexes per room dimension.
  def custom_hex_coords_for_room(hex_size_feet)
    room_width, room_height = inflated_room_dimensions
    arena_w = [(room_width.to_f / hex_size_feet).ceil, 1].max
    arena_h = [(room_height.to_f / hex_size_feet).ceil, 1].max
    hex_max_x = [arena_w - 1, 0].max
    hex_max_y = [(arena_h - 1) * 4 + 2, 0].max
    HexGrid.hex_coords_in_bounds(0, 0, hex_max_x, hex_max_y)
  end

  # ==================================================
  # Step 3: LLM Analysis
  # ==================================================

  # Non-chunked analysis - send all hexes in one request (used by legacy pipeline)
  def analyze_all_hexes(image_path, hex_labels, hex_coords)
    # Read and encode image
    image_base64 = Base64.strict_encode64(File.read(image_path))

    # Build prompt
    prompt = build_analysis_prompt(hex_labels)

    # Build multimodal message
    messages = [{
      role: 'user',
      content: [
        { type: 'image', mime_type: 'image/png', data: image_base64 },
        { type: 'text', text: prompt }
      ]
    }]

    # Call Gemini
    api_key = AIProviderService.api_key_for('google_gemini')
    response = LLM::Adapters::GeminiAdapter.generate(
      messages: messages,
      model: 'gemini-3-flash-preview',
      api_key: api_key,
      json_mode: true,
      options: { max_tokens: 32000, timeout: 180 }  # Higher limits for large hex analysis
    )

    unless response[:success]
      warn "[AIBattleMapGenerator] LLM analysis failed: #{response[:error]}"
      return []
    end

    content = response[:text] || response[:content]
    parse_hex_response(content, hex_coords)
  rescue JSON::ParserError => e
    warn "[AIBattleMapGenerator] JSON parse error: #{e.message}"
    []
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Analysis error: #{e.message}"
    []
  end

  def analyze_hex_chunk(image_path, hex_labels, chunk_coords, chunk_size)
    return nil if chunk_size < MIN_CHUNK_SIZE

    # Read and encode image
    image_base64 = Base64.strict_encode64(File.read(image_path))

    # Build prompt
    prompt = build_analysis_prompt(hex_labels)

    # Build multimodal message
    messages = [{
      role: 'user',
      content: [
        { type: 'image', mime_type: 'image/png', data: image_base64 },
        { type: 'text', text: prompt }
      ]
    }]

    # Call Gemini with appropriate limits for chunk size
    api_key = AIProviderService.api_key_for('google_gemini')
    response = LLM::Adapters::GeminiAdapter.generate(
      messages: messages,
      model: 'gemini-3-flash-preview',
      api_key: api_key,
      json_mode: true,
      options: { max_tokens: 16000, timeout: 120 }  # Smaller limits for chunks
    )

    unless response[:success]
      warn "[AIBattleMapGenerator] LLM analysis failed: #{response[:error]}"
      # Retry with smaller chunk
      return analyze_hex_chunk_smaller(image_path, hex_labels, chunk_coords, chunk_size)
    end

    content = response[:text] || response[:content]
    parse_hex_response(content, chunk_coords)
  rescue JSON::ParserError, StandardError => e
    warn "[AIBattleMapGenerator] Chunk analysis failed (#{e.class}): #{e.message}, retrying with smaller chunk"
    analyze_hex_chunk_smaller(image_path, hex_labels, chunk_coords, chunk_size)
  end

  def analyze_hex_chunk_smaller(image_path, hex_labels, chunk_coords, current_size)
    new_size = current_size / 2
    return nil if new_size < MIN_CHUNK_SIZE

    results = []
    hex_labels.each_slice(new_size).zip(chunk_coords.each_slice(new_size)) do |labels, coords|
      next unless labels && coords

      result = analyze_hex_chunk(image_path, labels, coords, new_size)
      results.concat(result) if result
    end
    results
  end

  def build_analysis_prompt(hex_labels)
    room_width, room_height = inflated_room_dimensions
    arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)

    GamePrompts.get(
      'battle_maps.hex_analysis',
      hex_labels: hex_labels.join(', '),
      room_width: room_width,
      room_height: room_height,
      hex_size: HexGrid::HEX_SIZE_FEET,
      arena_columns: arena_w,
      arena_rows: arena_h,
      total_hexes: hex_labels.length
    )
  end

  def parse_hex_response(content, chunk_coords)
    return [] unless content

    # Clean up response (remove markdown code blocks if present)
    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    data = JSON.parse(json_str)

    hexes = data['hexes'] || []
    min_x = room.min_x
    min_y = room.min_y

    hexes.filter_map do |hex|
      label = hex['label']
      coords = label_to_coord(label, min_x, min_y)
      next unless coords

      x, y = coords
      {
        x: x,
        y: y,
        hex_type: map_terrain_to_hex_type(hex['terrain']),
        cover_object: normalize_cover_object(hex['cover_object']),
        has_cover: (hex['cover_value'] || 0).to_i > 0,
        hazard_type: normalize_hazard(hex['hazard']),
        elevation_level: (hex['elevation'] || 0).to_i.clamp(-10, 10),
        water_type: normalize_water_type(hex['water_type']),
        surface_type: normalize_surface(hex['surface'])
      }
    end
  end

  def map_terrain_to_hex_type(terrain)
    case terrain&.downcase
    when 'wall' then 'wall'
    when 'water' then 'water'
    when 'pit' then 'pit'
    when 'difficult' then 'difficult'
    when 'blocked' then 'cover'
    else 'normal'
    end
  end

  def normalize_cover_object(obj)
    return nil if obj.nil? || obj == 'none' || obj.empty?

    valid_objects = RoomHex::COVER_OBJECTS
    obj_lower = obj.to_s.downcase.gsub(' ', '_')
    valid_objects.include?(obj_lower) ? obj_lower : nil
  end

  def normalize_hazard(hazard)
    return nil if hazard.nil? || hazard == 'none' || hazard.empty?

    valid_hazards = RoomHex::HAZARD_TYPES
    hazard_lower = hazard.to_s.downcase
    valid_hazards.include?(hazard_lower) ? hazard_lower : nil
  end

  def normalize_water_type(water)
    return nil if water.nil? || water == 'none' || water.empty?

    valid_types = RoomHex::WATER_TYPES
    water_lower = water.to_s.downcase
    valid_types.include?(water_lower) ? water_lower : nil
  end

  def normalize_surface(surface)
    return 'stone' if surface.nil? || surface.empty?

    valid_surfaces = RoomHex::SURFACE_TYPES
    surface_lower = surface.to_s.downcase
    valid_surfaces.include?(surface_lower) ? surface_lower : 'stone'
  end

  # ==================================================
  # Advanced Classification: Prompt Helpers
  # ==================================================

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

  def standard_types_reference
    <<~TYPES
      STANDARD TYPES — only tag a hex if it clearly matches the description below.

      TERRAIN / NATURE:
      - treetrunk: A thick tree trunk that blocks movement — a person cannot walk through it but can take cover behind it.
      - treebranch: Overhead tree canopy, branches, or foliage — provides cover from above but is traversable on the ground.
      - shrubbery: A bush, hedge, low foliage, or undergrowth dense enough that a person could hide inside it and be concealed from view.
      - boulder: A rock large enough that a person could crouch behind it for protection from projectiles.
      - mud: Ground that is visibly waterlogged, boggy, or swamp-like, making walking slow and difficult.
      - snow: Ground covered in deep enough snow to impede walking.
      - ice: A frozen surface slippery enough to affect movement.

      WATER:
      - puddle: A shallow pool of standing water, ankle-deep at most.
      - wading_water: Water deep enough to reach a person's waist — streams, shallow rivers, pond edges.
      - deep_water: Water too deep to walk through — a person would need to swim.

      FURNITURE / OBJECTS:
      - table: A table large enough to affect movement.
      - chair: A chair or stool — a minor obstacle.
      - bench: A bench, pew, or long seat.
      - fire: An active fire or heat source — fireplace hearth, campfire, brazier.
      - log: A fallen tree trunk or heavy timber lying on the ground, large enough to provide cover.
      - barrel: A barrel or keg — large enough to crouch behind for cover.
      - crate: A large wooden crate or box that completely blocks the hex.
      - chest: A treasure chest or storage trunk on the floor.
      - wagon: A cart or wagon — large enough to block passage and provide cover.
      - tent: A tent or canvas canopy — you can walk through but it hides you from view.

      STRUCTURES / BOUNDARIES:
      - wall: A solid wall or barrier that completely blocks movement.
      - glass_window: A closed window with glass — blocks movement like a wall.
      - open_window: A window opening without glass — blocks movement but allows ranged attacks.
      - door: A door or doorway — a passage point through a wall.
      - archway: An open archway, passage, or corridor entrance.
      - pillar: A structural column thick enough to block movement and provide cover.
      - fence: A fence, railing, or low wall — blocks movement but only provides partial cover.
      - gate: A gate in a fence or wall — a passage point.

      ELEVATION:
      - balcony: A raised platform, mezzanine, or elevated walkway (+8ft).
      - staircase: Stairs, a ramp, or a ladder — transition between elevation levels.
      - pit: An actual hole or chasm in the ground that you would fall into.
      - cliff: A vertical rock face or sheer drop — blocks movement like a wall.
      - ledge: A raised stone ledge or low platform.
      - bridge: A bridge spanning a gap or water — elevated and walkable.
      - rubble: A pile of collapsed stone or debris — uneven and slow to cross.

      SPECIAL:
      - off_map: Void/black areas completely outside the playable map boundary.

      NOTE: Similar-sounding types are DIFFERENT. treetrunk vs treebranch. puddle vs wading_water vs deep_water.
    TYPES
  end

  COMPASS_REGIONS = %w[northwest north northeast west center east southwest south southeast].freeze

  # Standard JSON Schema for Anthropic tool calling (overview pass).
  def overview_tool_schema
    {
      type: 'object',
      properties: {
        scene_description: { type: 'string', description: 'Brief 1-2 sentence summary of the battle map scene' },
        map_layout: { type: 'string', description: 'Spatial layout: what is where (north/south/center/edges).' },
        present_types: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              type_name:           { type: 'string', description: 'Short snake_case name (e.g. treetrunk, wall, table)' },
              visual_description:  { type: 'string', description: 'What this looks like in the image (color, shape, texture)' },
              custom_type_justification: { type: 'string', description: 'Required if type_name is NOT a standard type.' },
              traversable:         { type: 'boolean', description: 'Can someone walk through?' },
              provides_cover:      { type: 'boolean', description: 'Stops projectiles?' },
              provides_concealment: { type: 'boolean', description: 'Visually obscures but doesnt stop projectiles?' },
              is_wall:             { type: 'boolean', description: 'Solid impassable structure?' },
              is_exit:             { type: 'boolean', description: 'Doorway, archway, gate?' },
              difficult_terrain:   { type: 'boolean', description: 'Movement penalty?' },
              elevation:           { type: 'integer', description: 'Height in feet (0=ground)' },
              water_depth:         { type: 'string', enum: WATER_DEPTHS, description: 'Water depth if applicable' },
              hazards:             { type: 'array', items: { type: 'string', enum: OVERVIEW_HAZARD_TYPES }, description: 'Active hazards' }
            },
            required: %w[type_name visual_description traversable provides_cover provides_concealment is_wall is_exit difficult_terrain elevation]
          }
        },
        regional_types: {
          type: 'array',
          description: 'Which non-floor types appear in each region of the map. Helps chunk classifiers know what to expect.',
          items: {
            type: 'object',
            properties: {
              region: { type: 'string', enum: COMPASS_REGIONS, description: 'Compass region of the map' },
              types: { type: 'array', items: { type: 'string' }, description: 'Type names expected in this region (exclude wall/off_map — those are always included)' }
            },
            required: %w[region types]
          }
        }
      },
      required: %w[scene_description map_layout present_types regional_types]
    }
  end

  def overview_types_reference
    <<~TYPES
      STANDARD TYPES (use these names, do not invent new ones unless nothing fits):

      treetrunk (thick tree trunk — blocks movement, provides cover), treebranch (overhead canopy/foliage — traversable, provides cover),
      shrubbery (bush, hedge, or low foliage — provides concealment), boulder (rock big enough for cover),
      mud, snow, ice,
      puddle (ankle-deep), wading_water (waist-deep stream), deep_water (swim-depth),
      table, chair, bench, fire (active flames/embers), log (fallen trunk big enough for cover),
      barrel, crate, chest, wagon, tent,
      wall, glass_window, open_window, door, archway, pillar, fence, gate,
      balcony, staircase, pit (actual hole in the ground), cliff, ledge, bridge, rubble,
      off_map

      IMPORTANT: treetrunk and treebranch are DIFFERENT types. treetrunk = the solid trunk (impassable), treebranch = overhead canopy (traversable).
    TYPES
  end

  def filtered_types_reference(type_names)
    return standard_types_reference if type_names.nil? || type_names.empty?

    type_set = type_names.to_set
    lines = standard_types_reference.lines
    filtered = []

    lines.each do |line|
      if line.strip.start_with?('- ')
        type_name = line.strip.match(/^- (\w+):/)&.captures&.first
        filtered << line if type_name && type_set.include?(type_name)
      else
        filtered << line
      end
    end

    filtered.join
  end

  def build_spatial_context(hex_labels, chunk_coords, all_hex_coords)
    return '' unless chunk_coords && all_hex_coords

    min_x = all_hex_coords.map { |x, _| x }.min
    min_y = all_hex_coords.map { |_, y| y }.min

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

    ordered = chunk_labels_parsed.sort_by { |p| [p[:row], p[:col]] }.map { |p| p[:label] }

    all_xs = all_hex_coords.map { |x, _| x }.uniq.sort
    total_cols = all_xs.length
    all_ys = all_hex_coords.map { |_, y| y }.uniq.sort
    total_rows = all_ys.length

    <<~SPATIAL
      SPATIAL LAYOUT: This chunk covers rows #{min_row}-#{max_row} (of #{total_rows}), columns #{min_col}-#{max_col} (of #{total_cols} total columns from #{index_to_column_letter(0)} to #{index_to_column_letter(total_cols - 1)}).
      #{min_row}-#{min_col} is top-left of this chunk, #{min_row}-#{max_col} is top-right, #{max_row}-#{min_col} is bottom-left, #{max_row}-#{max_col} is bottom-right.
      Column A is leftmost on the full map. Columns increase rightward. Row 1 is topmost. Rows increase downward.
      Hex labels in reading order (top-to-bottom, left-to-right): #{ordered.join(', ')}
    SPATIAL
  end

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

    "#{parts.first} of the map"
  end

  def build_overview_chunk_prompt(hex_labels, room_w, room_h, scene_description, map_layout, type_names, present_types, position_label: 'center of the map', chunk_coords: nil, all_hex_coords: nil, chunk_description: nil)
    spatial_context = build_spatial_context(hex_labels, chunk_coords, all_hex_coords)

    filtered_types_ref = filtered_types_reference(type_names)

    visual_lines = present_types.filter_map do |t|
      next if %w[open_floor other].include?(t['type_name'])
      next unless t['visual_description'] && !t['visual_description'].empty?

      "- #{t['type_name']}: #{t['visual_description']}"
    end
    visual_guide = visual_lines.any? ? "VISUAL GUIDE — what each type looks like in this specific map:\n#{visual_lines.join("\n")}" : ''

    chunk_context = chunk_description ? "CHUNK CONTEXT: #{chunk_description}" : ''

    GamePrompts.get('battle_maps.classification.overview_chunk',
      position_label: position_label, hex_format: prompt_hex_format,
      room_w: room_w, room_h: room_h, hex_size_feet: HexGrid::HEX_SIZE_FEET,
      hex_count: hex_labels.length, scene_description: scene_description,
      map_layout: map_layout, chunk_context: chunk_context,
      spatial_context: spatial_context, filtered_types_ref: filtered_types_ref,
      visual_guide: visual_guide, conservative_classification: prompt_conservative_classification,
      crop_warning: prompt_crop_warning, ground_level_rule: prompt_ground_level_rule,
      hex_labels: hex_labels.join(', '))
  end

  # ==================================================
  # Advanced Classification: Core Pipeline Methods
  # ==================================================

  # Build a map of hex label → pixel position for the entire grid.
  # Used by spatial chunking and image cropping.
  def build_hex_pixel_map(hex_coords, min_x, min_y, img_width, img_height)
    all_xs = hex_coords.map { |x, _| x }.uniq.sort
    all_ys = hex_coords.map { |_, y| y }.uniq.sort
    num_cols = all_xs.max - all_xs.min
    num_visual_rows = ((all_ys.max - all_ys.min) / 4.0).floor + 1

    # Use MAX so the grid always covers the full image on both dimensions.
    # This may extend hexes slightly beyond one edge, but ensures no bare margins.
    hex_size_by_width = img_width.to_f / [num_cols * 1.5 + 2.0, 1].max
    hex_size_by_height = img_height.to_f / [(num_visual_rows + 0.5) * Math.sqrt(3), 1].max
    hex_size = [hex_size_by_width, hex_size_by_height].max

    offset_x = 0.0
    offset_y = 0.0
    @analysis_total_rows = num_visual_rows

    pixel_map = {}
    hex_coords.each do |hx, hy|
      label = coord_to_label(hx, hy, min_x, min_y, hex_coords_override: hex_coords)
      px, py = hex_to_pixel(hx, hy, min_x, min_y, hex_size, offset_x, offset_y)
      pixel_map[label] = { px: px, py: py, hx: hx, hy: hy }
    end
    pixel_map[:hex_size] = hex_size
    pixel_map[:offset_x] = offset_x
    pixel_map[:offset_y] = offset_y
    @analysis_hex_size = hex_size
    pixel_map
  end

  # Group hexes into spatial rectangular tiles using pixel positions.
  def build_spatial_chunks(hex_coords, target_size)
    if hex_coords.length <= target_size
      return [{ coords: hex_coords, grid_pos: { gx: 0, gy: 0, nx: 1, ny: 1 } }]
    end

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

    grid = Hash.new { |h, k| h[k] = [] }
    coords_with_px.each do |x, y, px, py|
      gx = [((px - px_min) / px_range * best_nx).floor, best_nx - 1].min
      gy = [((py - py_min) / py_range * best_ny).floor, best_ny - 1].min
      grid[[gx, gy]] << [x, y]
    end

    (0...best_ny).flat_map do |gy|
      (0...best_nx).map do |gx|
        next if grid[[gx, gy]].empty?

        { coords: grid[[gx, gy]], grid_pos: { gx: gx, gy: gy, nx: best_nx, ny: best_ny } }
      end
    end.compact
  end

  # Run overview pre-pass: send image for scene analysis.
  # Returns parsed overview data or nil on failure.
  def run_overview_pass(image_path)
    return nil unless image_path && File.exist?(image_path)

    image_data = File.binread(image_path)
    image_base64 = Base64.strict_encode64(image_data)
    mime_type = case image_path
                when /\.webp$/i then 'image/webp'
                when /\.jpe?g$/i then 'image/jpeg'
                else 'image/png'
                end
    room_w, room_h = inflated_room_dimensions
    desc = room.long_description || room.short_description || room.name

    prompt = GamePrompts.get('battle_maps.overview.analysis',
      room_name: room.name, room_w: room_w, room_h: room_h,
      description: desc, types_reference: overview_types_reference)

    api_key = AIProviderService.api_key_for('anthropic')
    messages = [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mime_type, data: image_base64 } },
        { type: 'text', text: prompt }
      ]
    }]

    overview_tool = {
      name: 'submit_overview',
      description: 'Submit battle map overview analysis',
      parameters: overview_tool_schema
    }

    response = LLM::Adapters::AnthropicAdapter.generate(
      messages: messages,
      model: OVERVIEW_MODEL,
      api_key: api_key,
      tools: [overview_tool],
      options: { max_tokens: 4096, timeout: 300, temperature: 0 }
    )

    if response[:tool_calls]&.any?
      return response[:tool_calls].first[:arguments]
    end

    unless response[:success]
      warn "[AIBattleMapGenerator] Overview pass failed: #{response[:error]}"
      return nil
    end

    # Fallback: try parsing text response
    content = response[:text] || response[:content]
    return nil unless content

    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    JSON.parse(json_str)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] run_overview_pass failed: #{e.class}: #{e.message}"
    nil
  end

  # Crop the unlabeled image to the bounding box of a chunk's hexes + margin.
  def crop_image_for_chunk(base_image, chunk_coords, hex_pixel_map, img_width, img_height)
    hex_size = hex_pixel_map[:hex_size]
    margin = (hex_size * 2).round

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
  end

  # Overlay hex labels for ONLY the given chunk's hexes onto a cropped image.
  def overlay_chunk_labels_on_crop(crop_result, chunk_coords, min_x, min_y, hex_coords)
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

    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] - crop_x
      py = info[:py] - crop_y
      points = hexagon_svg_points(px, py, hex_size)
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="black" stroke-width="#{stroke_w * 3}"/>)
    end

    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] - crop_x
      py = info[:py] - crop_y
      label = coord_to_label(hx, hy, min_x, min_y, hex_coords_override: hex_coords)

      points = hexagon_svg_points(px, py, hex_size)
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

    cropped = cropped.bandjoin(255) if cropped.bands < 4
    overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb

    result = cropped.composite2(overlay, :over)
    result.write_to_buffer('.png')
  end

  # Parse response from simple enum classification (just label + hex_type per hex)
  def parse_simple_chunk(content, min_x, min_y, hex_coords, allowed_types: nil)
    return [] unless content

    valid_types = allowed_types || SIMPLE_HEX_TYPES
    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    data = safe_json_parse(json_str, fallback: nil, context: 'AIBattleMapGeneratorService')
    return [] if data.nil?

    hexes = data['hexes'] || []

    hexes.filter_map do |hex|
      label = hex['label']
      hex_type = hex['hex_type']
      next unless label && hex_type

      coords = label_to_coord(label, min_x, min_y, hex_coords_override: hex_coords)
      next unless coords

      {
        'label' => label,
        'x' => coords[0],
        'y' => coords[1],
        'hex_type' => valid_types.include?(hex_type) ? hex_type : 'other'
      }
    end
  end

  # Parse response from grouped classification.
  # Handles both new format (wall_hexes/off_map_hexes + features) and legacy (objects array).
  # @param content [String] JSON response from LLM
  # @param seq_to_coord [Hash] sequential label → [hx, hy] mapping
  # @param allowed_types [Array<String>, nil] valid type names
  # @return [Array<Hash>] parsed hex classifications
  def parse_grouped_chunk(content, seq_to_coord, allowed_types: nil)
    return [] unless content

    valid_types = allowed_types || SIMPLE_HEX_TYPES
    json_str = content.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip
    data = safe_json_parse(json_str, fallback: nil, context: 'AIBattleMapGeneratorService')
    return [] if data.nil?

    results = []

    # Flat boundary arrays (new format)
    %w[wall_hexes off_map_hexes].each do |key|
      hex_type = key.sub('_hexes', '').sub('off_map', 'off_map')
      (data[key] || []).each do |label|
        coords = seq_to_coord[label.to_s]
        next unless coords
        results << { 'label' => label.to_s, 'x' => coords[0], 'y' => coords[1], 'hex_type' => hex_type }
      end
    end

    # Feature/object arrays (new and legacy format)
    features = data['features'] || data['objects'] || []
    features.each do |feature|
      hex_type = feature['hex_type']
      next unless hex_type

      resolved_type = valid_types.include?(hex_type) ? hex_type : 'other'
      (feature['labels'] || []).each do |label|
        coords = seq_to_coord[label.to_s]
        next unless coords
        results << { 'label' => label.to_s, 'x' => coords[0], 'y' => coords[1], 'hex_type' => resolved_type }
      end
    end

    results
  end

  # Build Anthropic tool definition for chunk classification.
  # Two arrays: boundary_hexes (wall/off_map as flat lists) and features (objects with details).
  # @param type_names [Array<String>] valid type names for this chunk
  # @return [Array<Hash>] tool definitions for AnthropicAdapter
  def build_chunk_tool(type_names)
    feature_types = type_names - %w[wall off_map]

    [{
      name: 'classify_hexes',
      description: 'Submit hex classification results for this map section',
      parameters: {
        type: 'object',
        properties: {
          area_description: {
            type: 'string',
            description: 'Short description of what is under the numbered hexes in this section'
          },
          wall_hexes: {
            type: 'array', items: { type: 'string' },
            description: 'Hex numbers that are walls (solid structures characters cannot move through)'
          },
          features: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                description: { type: 'string', description: 'Brief description of this feature' },
                hex_type: { type: 'string', enum: feature_types, description: 'Classification type' },
                size_hexes: { type: 'integer', description: 'How many hexes this feature covers' },
                labels: { type: 'array', items: { type: 'string' }, description: 'Hex numbers this feature covers' }
              },
              required: %w[hex_type size_hexes labels]
            }
          }
        },
        required: %w[area_description wall_hexes features]
      }
    }]
  end

  # Build concise chunk prompt using overview context.
  # @param hex_list_str [String] comma-separated sequential hex labels (unused, kept for compat)
  # @param scene_description [String] from overview pass (used as brief context)
  # @param type_names [Array<String>] from overview pass
  # @return [String] prompt text
  def build_grouped_chunk_prompt(_hex_list_str, scene_description, type_names, grid_pos: nil, map_layout: nil)
    feature_types = type_names - %w[wall off_map]

    # Use just the first sentence of scene_description for brief context
    brief_context = scene_description.split(/(?<=[.!?])\s+/).first || scene_description

    GamePrompts.get('battle_maps.classification.grouped_chunk',
      feature_types: feature_types.join(', '), brief_context: brief_context)
  end

  # Convert grid position to compass hint (e.g. "northwest", "center", "south").
  def chunk_location_hint(grid_pos)
    return nil unless grid_pos

    gx, gy, nx, ny = grid_pos.values_at(:gx, :gy, :nx, :ny)
    return nil unless nx && ny && nx > 0 && ny > 0

    # Normalize to 0.0-1.0
    fx = nx > 1 ? gx.to_f / (nx - 1) : 0.5
    fy = ny > 1 ? gy.to_f / (ny - 1) : 0.5

    ns = fy < 0.33 ? 'north' : fy > 0.66 ? 'south' : nil
    ew = fx < 0.33 ? 'west' : fx > 0.66 ? 'east' : nil

    if ns && ew
      "#{ns}#{ew}"
    elsif ns
      ns
    elsif ew
      ew
    else
      'center'
    end
  end

  # Get types available for a specific chunk based on its region.
  # Falls back to all types if no regional data.
  def types_for_chunk(grid_pos, all_type_names)
    return all_type_names unless @regional_type_map && !@regional_type_map.empty?

    hint = chunk_location_hint(grid_pos)
    return all_type_names unless hint

    regional = @regional_type_map[hint]
    return all_type_names unless regional

    # Only keep types that are in both the regional list and the overall type list
    (regional & all_type_names) | %w[wall]
  end

  # Overlay sequential number labels on a cropped chunk image.
  # @param crop_result [Hash] from crop_image_for_chunk
  # @param chunk_coords [Array<Array>] hex coordinate pairs in this chunk
  # @param seq_labels [Hash] {[hx,hy] => "1", [hx,hy] => "2", ...}
  # @return [String] PNG image data as binary string
  def overlay_sequential_labels_on_crop(crop_result, chunk_coords, seq_labels)
    cropped = crop_result[:cropped]
    crop_x = crop_result[:crop_x]
    crop_y = crop_result[:crop_y]
    crop_w = crop_result[:crop_w]
    crop_h = crop_result[:crop_h]
    hex_size = crop_result[:hex_size]

    font_size = [hex_size * 0.35, 7].max.round
    stroke_w = [hex_size * 0.04, 1.5].max.round(1)

    # Light blur on context area outside the chunk hexes
    mask_svg_parts = []
    mask_svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{crop_w}" height="#{crop_h}">)
    mask_svg_parts << %(<rect width="#{crop_w}" height="#{crop_h}" fill="black"/>)
    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info
      px = info[:px] - crop_x
      py = info[:py] - crop_y
      points = hexagon_svg_points(px, py, hex_size)
      mask_svg_parts << %(<polygon points="#{points}" fill="white"/>)
    end
    mask_svg_parts << '</svg>'

    mask = Vips::Image.svgload_buffer(mask_svg_parts.join("\n"))
    mask = mask.resize(crop_w.to_f / mask.width) if mask.width != crop_w || mask.height != crop_h
    mask_band = mask.extract_band(0).cast(:uchar)

    blur_radius = [hex_size * 0.2, 1].max
    blurred = cropped.gaussblur(blur_radius)

    cropped_rgba = cropped.bands >= 4 ? cropped : cropped.bandjoin(255)
    blurred_rgba = blurred.bands >= 4 ? blurred : blurred.bandjoin(255)
    cropped = (mask_band > 128).ifthenelse(cropped_rgba, blurred_rgba)

    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{crop_w}" height="#{crop_h}">)

    # Black shadow outlines
    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] - crop_x
      py = info[:py] - crop_y
      points = hexagon_svg_points(px, py, hex_size)
      svg_parts << %(<polygon points="#{points}" fill="none" stroke="black" stroke-width="#{stroke_w * 3}"/>)
    end

    # White outlines + labels
    chunk_coords.each do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next unless info

      px = info[:px] - crop_x
      py = info[:py] - crop_y
      label = seq_labels[[hx, hy]]
      next unless label

      points = hexagon_svg_points(px, py, hex_size)
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

    cropped = cropped.bandjoin(255) if cropped.bands < 4
    overlay = overlay.colourspace(:srgb) if overlay.interpretation != :srgb

    result = cropped.composite2(overlay, :over)
    result.write_to_buffer('.png')
  end

  # Build sequential labels for a chunk (1, 2, 3... in reading order)
  # @param chunk_coords [Array<Array>] hex coordinate pairs
  # @return [Hash] {[hx,hy] => "1", ...} and reverse {label => [hx,hy]}
  def build_sequential_labels(chunk_coords)
    labels = {}
    reverse = {}
    # Sort left-to-right, top-to-bottom (high hy = top in Y-flipped rendering)
    chunk_coords.sort_by { |hx, hy| [-hy, hx] }.each_with_index do |(hx, hy), i|
      label = (i + 1).to_s
      labels[[hx, hy]] = label
      reverse[label] = [hx, hy]
    end
    { labels: labels, reverse: reverse }
  end

  # Filter out hexes whose hexagon extends beyond the image boundary.
  # These partial hexes confuse the classifier — skip them entirely.
  # @param chunk_coords [Array<Array>] hex coordinate pairs
  # @param img_width [Integer] full base image width
  # @param img_height [Integer] full base image height
  # @return [Array<Array>] filtered coordinates (only fully visible hexes)
  def filter_partial_edge_hexes(chunk_coords, img_width, img_height)
    hex_size = @analysis_hex_size
    return chunk_coords unless hex_size && img_width && img_height

    hex_h = hex_size * Math.sqrt(3)
    chunk_coords.select do |hx, hy|
      info = @coord_lookup[[hx, hy]]
      next false unless info

      px, py = info[:px], info[:py]
      # Flat-top hex: width = 2*hex_size, height = sqrt(3)*hex_size
      px - hex_size >= 0 && px + hex_size <= img_width &&
        py - hex_h / 2.0 >= 0 && py + hex_h / 2.0 <= img_height
    end
  end

  # Count hex types in a result array for diagnostic logging.
  def type_distribution(results)
    results.each_with_object(Hash.new(0)) { |r, h| h[r['hex_type']] += 1 }
  end

  # Extract LAB chrominance features from a hex-sized image patch.
  # Returns a feature vector focused on color (shadow-invariant) with light texture info.
  def extract_hex_features(lab_image, px, py, hex_size)
    return nil if px < 0 || py < 0 || px >= lab_image.width || py >= lab_image.height

    inner_r = [(hex_size * 0.7).to_i, 2].max
    x1 = [px.round - inner_r, 0].max
    y1 = [py.round - inner_r, 0].max
    w = [inner_r * 2, lab_image.width - x1].min
    h = [inner_r * 2, lab_image.height - y1].min
    return nil if w < 4 || h < 4

    patch = lab_image.crop(x1, y1, w, h)

    means = []
    devs = []
    patch.bands.times do |b|
      band = patch.extract_band(b)
      means << band.avg
      devs << band.deviate
    end

    # Feature vector: chrominance-heavy (A,B), L downweighted for shadow invariance
    [means[1], means[2], devs[1], devs[2], means[0] * 0.3, devs[0] * 0.2]
  rescue Vips::Error
    nil
  end

  # Extract gradient-based texture features from a hex patch.
  # Returns [mean_gradient_magnitude, std_gradient_magnitude] or nil.
  # Walls show high mean + low std (one strong edge), terrain shows low mean (smooth),
  # objects show medium mean, vegetation shows high std (chaotic).
  def extract_texture_features(gray_image, px, py, hex_size)
    return nil if px < 0 || py < 0 || px >= gray_image.width || py >= gray_image.height

    inner_r = [(hex_size * 0.7).to_i, 2].max
    x1 = [px.round - inner_r, 0].max
    y1 = [py.round - inner_r, 0].max
    w = [inner_r * 2, gray_image.width - x1].min
    h = [inner_r * 2, gray_image.height - y1].min
    return nil if w < 4 || h < 4

    patch = gray_image.crop(x1, y1, w, h)

    # Sobel gradient magnitude via horizontal + vertical convolution
    sobel_x = Vips::Image.new_from_array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]])
    sobel_y = Vips::Image.new_from_array([[-1, -2, -1], [0, 0, 0], [1, 2, 1]])

    gx = patch.conv(sobel_x, precision: :float)
    gy = patch.conv(sobel_y, precision: :float)
    mag = ((gx**2) + (gy**2))**0.5

    [mag.avg, mag.deviate]
  rescue Vips::Error
    nil
  end

  # Sample edge strength between two pixel positions in the edge map.
  # Returns 0.0-1.0 (proportion of "edge" pixels along the line between the two points).
  # Returns 0.0 if edge_map is nil (graceful degradation).
  def edge_strength_between(edge_map, px1, py1, px2, py2, samples: 10)
    return 0.0 unless edge_map

    edge_threshold = 128 # Canny output is near-binary: 0 or 255
    edge_band = edge_map.bands > 1 ? edge_map.extract_band(0) : edge_map
    hits = 0
    valid_samples = 0

    samples.times do |i|
      t = (i + 0.5) / samples.to_f
      sx = (px1 + (px2 - px1) * t).round
      sy = (py1 + (py2 - py1) * t).round
      next if sx < 0 || sy < 0 || sx >= edge_band.width || sy >= edge_band.height

      valid_samples += 1
      val = edge_band.getpoint(sx, sy)[0]
      hits += 1 if val >= edge_threshold
    end

    return 0.0 if valid_samples == 0
    hits.to_f / valid_samples
  rescue Vips::Error
    0.0
  end

  # Average edge strength in a radius around a hex center.
  # Samples edge map pixels in the hex-sized area and returns proportion that are edges.
  # Returns 0.0 if edge_map is nil.
  def edge_strength_at_hex(edge_map, px, py, hex_size)
    return 0.0 unless edge_map

    edge_threshold = 128
    edge_band = edge_map.bands > 1 ? edge_map.extract_band(0) : edge_map
    r = [(hex_size * 0.7).to_i, 2].max

    x1 = [px.round - r, 0].max
    y1 = [py.round - r, 0].max
    w = [r * 2, edge_band.width - x1].min
    h = [r * 2, edge_band.height - y1].min
    return 0.0 if w < 2 || h < 2

    patch = edge_band.crop(x1, y1, w, h)
    avg = patch.avg
    avg / 255.0
  rescue Vips::Error
    0.0
  end

  # Collect edge detection result from a background thread.
  # Returns a Vips::Image edge map or nil.
  #
  # @param edge_thread [Thread] thread running edge detection
  # @param base [Vips::Image] base image for size matching
  # @return [Vips::Image, nil] the edge map, resized to match base if needed
  def collect_edge_result(edge_thread, base)
    edge_result = edge_thread.join(120)&.value
    return nil unless edge_result&.dig(:success)

    edge_candidate = if edge_result[:edge_map]
      edge_result[:edge_map]
    elsif edge_result[:edge_map_path] && File.exist?(edge_result[:edge_map_path])
      Vips::Image.new_from_file(edge_result[:edge_map_path])
    end

    return nil unless edge_candidate

    avg_brightness = edge_candidate.extract_band(0).avg
    if avg_brightness > 5 && avg_brightness < 250
      if edge_candidate.width != base.width || edge_candidate.height != base.height
        edge_candidate = edge_candidate.resize(base.width.to_f / edge_candidate.width,
                                                vscale: base.height.to_f / edge_candidate.height)
      end
      warn "[AIBattleMapGenerator] Edge map loaded (#{edge_result[:source]}): #{edge_candidate.width}x#{edge_candidate.height}, avg brightness: #{avg_brightness.round(1)}"
      edge_candidate
    else
      warn "[AIBattleMapGenerator] Edge map blank (avg #{avg_brightness.round(1)}), skipping edge-based normalization"
      nil
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Edge collection failed: #{e.message}"
    nil
  end

  # Collect depth estimation result from a background thread and generate zone map.
  # Returns [depth_map, zone_map] pair (either or both may be nil).
  #
  # @param depth_thread [Thread] thread running depth estimation
  # @param edge_map [Vips::Image, nil] edge map for zone map generation
  # @param base [Vips::Image] base image for size matching
  # @param hex_size [Numeric] hex pixel size for zone map generation
  # @param local_path [String] path to battle map image (for debug dir)
  # @return [Array(Vips::Image, Vips::Image)] [depth_map, zone_map]
  def collect_depth_result(depth_thread, edge_map, base, hex_size, local_path)
    depth_result = depth_thread.join(120)&.value
    process_depth_result(depth_result, edge_map, base, hex_size, local_path)
  end

  # Process a raw depth result hash into depth_map and zone_map Vips images.
  # Extracted so callers can join the thread themselves when they need the raw result.
  def process_depth_result(depth_result, edge_map, base, hex_size, local_path)
    unless depth_result&.dig(:success) && depth_result[:depth_path] && File.exist?(depth_result[:depth_path])
      warn "[AIBattleMapGenerator] Depth estimation unavailable: #{depth_result&.dig(:error) || 'timeout'}"
      return [nil, nil]
    end

    @zone_map_path = nil
    @depth_estimation_path = depth_result[:depth_path]

    depth_map = Vips::Image.new_from_file(depth_result[:depth_path])
    depth_map = depth_map.extract_band(0) if depth_map.bands > 1
    if depth_map.width != base.width || depth_map.height != base.height
      depth_map = depth_map.resize(base.width.to_f / depth_map.width,
                                    vscale: base.height.to_f / depth_map.height)
    end
    warn "[AIBattleMapGenerator] Depth map loaded: #{depth_map.width}x#{depth_map.height}"

    zone_map = nil
    if edge_map
      debug_dir = inspection_dir
      zone_map = generate_zone_map(depth_result[:depth_path], edge_map,
                                    debug_dir: debug_dir)
      if zone_map
        if zone_map.width != base.width || zone_map.height != base.height
          zone_map = zone_map.resize(base.width.to_f / zone_map.width,
                                      vscale: base.height.to_f / zone_map.height,
                                      kernel: :nearest)
        end
        warn "[AIBattleMapGenerator] Zone map generated: #{zone_map.width}x#{zone_map.height}"
        @zone_map_path = depth_result[:depth_path].sub(/(\.\w+)$/, '_zone_map.png')
      else
        warn "[AIBattleMapGenerator] Zone map generation failed"
      end
    end

    [depth_map, zone_map]
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Depth collection failed: #{e.message}"
    [nil, nil]
  end

  # Generate a local edge map from the battle map image using Sobel gradient.
  # Used as fallback when shadow-aware and Replicate edge detection are unavailable.
  # Applies shadow suppression via LAB local mean subtraction before Sobel,
  # and combines luminance edges with chrominance (A/B) edges.
  # Returns a single-band Vips::Image thresholded to 0 or 255.
  #
  # @param image [Vips::Image] the battle map image (RGB or RGBA)
  # @return [Vips::Image] single-band edge map
  def generate_local_edge_map(image)
    rgb = image.bands > 3 ? image.extract_band(0, n: 3) : image

    # Convert to LAB for shadow-aware processing
    lab = rgb.colourspace(:lab)
    l_chan = lab.extract_band(0)
    a_chan = lab.extract_band(1)
    b_chan = lab.extract_band(2)

    # Shadow suppression: subtract local mean from L channel (approximates CLAHE)
    # Large sigma captures shadow-scale brightness variation
    local_mean = l_chan.gaussblur(40)
    l_eq = ((l_chan - local_mean) + 50).cast(:float)
    l_eq = (l_eq < 0).ifthenelse(0, l_eq)
    l_eq = (l_eq > 100).ifthenelse(100, l_eq)
    gray = (l_eq * 2.55).cast(:uchar)

    # Gaussian blur to suppress floor texture noise
    blurred = gray.gaussblur(1.5)

    sobel_x = Vips::Image.new_from_array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]])
    sobel_y = Vips::Image.new_from_array([[-1, -2, -1], [0, 0, 0], [1, 2, 1]])

    # Luminance edges (shadow-suppressed)
    gx = blurred.conv(sobel_x, precision: :float)
    gy = blurred.conv(sobel_y, precision: :float)
    mag = ((gx**2) + (gy**2))**0.5

    # Chrominance edges — shadows don't shift A/B, so these capture real color boundaries
    a_u = (a_chan.cast(:float) * 2.55).cast(:uchar)
    gx_a = a_u.conv(sobel_x, precision: :float)
    gy_a = a_u.conv(sobel_y, precision: :float)
    mag_a = ((gx_a**2) + (gy_a**2))**0.5

    b_u = (b_chan.cast(:float) * 2.55).cast(:uchar)
    gx_b = b_u.conv(sobel_x, precision: :float)
    gy_b = b_u.conv(sobel_y, precision: :float)
    mag_b = ((gx_b**2) + (gy_b**2))**0.5

    # Combine: max of luminance and chrominance magnitudes
    combined = mag
    combined = (mag_a > combined).ifthenelse(mag_a, combined)
    combined = (mag_b > combined).ifthenelse(mag_b, combined)

    # Higher threshold (50) than Canny to compensate for Sobel noise
    threshold_mask = combined.cast(:uchar) > 50
    threshold_mask.ifthenelse(255, 0).cast(:uchar)
  rescue Vips::Error => e
    warn "[AIBattleMapGenerator] Local edge map generation failed: #{e.message}"
    nil
  end

  # Generate a shadow-aware edge map using OpenCV (CLAHE + bilateral + Canny + chrominance).
  # Neutralizes shadow contrast before edge detection so shadow boundaries don't appear as walls.
  # Requires python3 and opencv-python (cv2).
  #
  # @param image_path [String] path to the battle map image file
  # @return [Vips::Image, nil] single-band edge map, or nil on failure
  def generate_shadow_aware_edge_map(image_path)
    output_path = image_path.sub(/(\.\w+)$/, '_shadow_edges.png')
    script = File.expand_path('../../../lib/cv/shadow_edge_detect.py', __dir__)

    unless File.exist?(script)
      warn "[AIBattleMapGenerator] Shadow edge script not found: #{script}"
      return nil
    end

    success = system('python3', script, image_path, output_path,
                      out: File::NULL, err: File::NULL)
    return nil unless success && File.exist?(output_path)

    result = Vips::Image.new_from_file(output_path)
    result = result.extract_band(0) if result.bands > 1
    result
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Shadow-aware edge detection failed: #{e.message}"
    nil
  end

  # Generate a pixel-level zone map from depth + edge signals.
  # Returns a Vips::Image where pixel values are zone IDs:
  #   0 = off_map, 1 = wall, 2 = floor, 3 = object
  #
  # @param depth_path [String] path to depth map PNG
  # @param edge_map [Vips::Image] edge detection result
  # @param debug_dir [String, nil] directory for debug output
  # @return [Vips::Image, nil] single-band zone map
  def generate_zone_map(depth_path, edge_map, debug_dir: nil)
    script = File.expand_path('../../../lib/cv/zone_map.py', __dir__)
    unless File.exist?(script)
      warn "[AIBattleMapGenerator] Zone map script not found: #{script}"
      return nil
    end

    # Write edge map to temp file for Python
    require 'tempfile'
    edge_file = Tempfile.new(['edges', '.png'])
    edge_map.write_to_file(edge_file.path)

    output_path = depth_path.sub(/(\.\w+)$/, '_zone_map.png')

    args = ['python3', script, depth_path, edge_file.path, output_path]
    if debug_dir
      args += ['--debug', debug_dir]
    end

    success = system(*args, out: File::NULL, err: File::NULL)
    edge_file.close!

    return nil unless success && File.exist?(output_path)

    result = Vips::Image.new_from_file(output_path)
    result = result.extract_band(0) if result.bands > 1
    result
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Zone map generation failed: #{e.message}"
    nil
  end

  # ==================================================
  # Normalization v3: Shape Map + Zone Map + 9 Passes
  # ==================================================

  # Sample pixel-level zone map at each hex center to get per-hex zone.
  # Zone IDs: 0=off_map, 1=wall, 2=floor, 3=object
  #
  # Off_map and object require majority coverage (>50%).
  # Wall uses any presence — the actual wall pixel fraction is stored
  # in @hex_wall_coverage for use by wall_flood and lockoff.
  #
  # @param zone_map [Vips::Image] single-band image with zone IDs (0-3)
  # @param hex_size [Float] hex diameter in pixels
  # @return [Hash] {[hx,hy] => Integer} zone ID per hex
  def build_hex_zone_map(zone_map, hex_size)
    return {} unless zone_map && @coord_lookup&.any?

    result = {}
    @hex_wall_coverage = {}
    @hex_wall_passthrough = {}
    r = [(hex_size * 0.35).to_i, 2].max  # sample within ~70% of hex radius
    zm_w = zone_map.width
    zm_h = zone_map.height

    @coord_lookup.each do |(hx, hy), info|
      cx = info[:px].round
      cy = info[:py].round
      x1 = [cx - r, 0].max
      y1 = [cy - r, 0].max
      w = [r * 2, zm_w - x1].min
      h = [r * 2, zm_h - y1].min
      next if w < 2 || h < 2

      begin
        patch = zone_map.crop(x1, y1, w, h)
        data = patch.to_a.flatten
        counts = [0, 0, 0, 0]
        data.each { |v| counts[v] += 1 if v >= 0 && v <= 3 }

        total = data.length.to_f
        wall_frac = counts[1] / total

        # Store wall coverage fraction (area) for wall extension decisions
        @hex_wall_coverage[[hx, hy]] = wall_frac if wall_frac > 0.0

        # Compute wall pass-through: how far wall pixels span across the hex.
        # A wall line crossing the hex from edge to edge = passthrough ~1.0,
        # even if it's only 1px wide. Used for first-row wall detection.
        if wall_frac > 0.0
          min_col = w
          max_col = 0
          min_row = h
          max_row = 0
          data.each_with_index do |v, i|
            next unless v == 1
            col = i % w
            row = i / w
            min_col = col if col < min_col
            max_col = col if col > max_col
            min_row = row if row < min_row
            max_row = row if row > max_row
          end
          h_span = (max_col - min_col + 1).to_f / w
          v_span = (max_row - min_row + 1).to_f / h
          passthrough = [h_span, v_span].max
          @hex_wall_passthrough[[hx, hy]] = passthrough
        end

        if counts[0] / total > 0.5
          result[[hx, hy]] = 0  # off_map
        elsif counts[3] / total > 0.5
          result[[hx, hy]] = 3  # object
        elsif wall_frac > 0.0 && @hex_wall_passthrough[[hx, hy]]&.>=(0.5)
          result[[hx, hy]] = 1  # wall (passes through hex)
        elsif wall_frac > 0.0
          # Wall pixels present but don't span the hex — just clipping a corner.
          # Store coverage but don't assign wall zone; wall_flood can extend here.
          result[[hx, hy]] = 2  # floor (wall doesn't pass through)
        else
          result[[hx, hy]] = 2  # floor (default)
        end
      rescue Vips::Error
        result[[hx, hy]] = 2
      end
    end

    result
  end

  # Classify hexes using pixel-level overlap analysis via hex_classify.py.
  # This replaces the simple center-point sampling of build_hex_zone_map with
  # proper hex-polygon overlap that considers all pixels within each hex.
  #
  # @param zone_map_path [String] path to zone map PNG (pixel values 0-3)
  # @param hex_size [Numeric] hex diameter in pixels
  # @param depth_path [String, nil] optional depth image path for shape contour grouping
  # @param debug_dir [String, nil] optional directory for debug output images
  # @return [Hash, nil] { hex_zones:, hex_shapes:, hex_image_shapes: } or nil on failure
  def classify_hexes_with_overlap(zone_map_path, hex_size, depth_path: nil, image_path: nil, sam2_masks_dir: nil, debug_dir: nil)
    script = File.expand_path('../../../lib/cv/hex_classify.py', __dir__)
    unless File.exist?(script)
      warn "[AIBattleMapGenerator] hex_classify.py not found: #{script}"
      return nil
    end

    return nil unless @coord_lookup&.any?

    require 'tempfile'
    coords = @coord_lookup.map do |(hx, hy), info|
      [hx, hy, info[:px], info[:py]]
    end
    coords_file = Tempfile.new(['hex_coords', '.json'])
    coords_file.write(JSON.generate(coords))
    coords_file.close

    output_file = Tempfile.new(['hex_classify', '.json'])
    output_file.close

    args = ['python3', script, zone_map_path, coords_file.path, hex_size.to_s, output_file.path]
    args += ['--depth', depth_path] if depth_path
    if sam2_masks_dir && Dir.exist?(sam2_masks_dir.to_s)
      args += ['--sam2-masks-dir', sam2_masks_dir]
    else
      args += ['--image', image_path] if image_path && File.exist?(image_path.to_s)
    end
    args += ['--debug', debug_dir] if debug_dir

    success = system(*args)
    coords_file.unlink

    unless success && File.exist?(output_file.path) && File.size(output_file.path) > 2
      warn "[AIBattleMapGenerator] hex_classify.py failed"
      output_file.unlink
      return nil
    end

    raw = JSON.parse(File.read(output_file.path))
    output_file.unlink

    hex_zones = {}
    @hex_wall_coverage = {}
    @hex_wall_passthrough = {}
    hex_shapes = {}
    hex_image_shapes = {}

    raw.each do |key, data|
      hx, hy = key.split(',').map(&:to_i)
      coord = [hx, hy]

      hex_zones[coord] = data['zone']
      @hex_wall_coverage[coord] = data['wall_coverage'] if data['wall_coverage'] > 0
      @hex_wall_passthrough[coord] = data['wall_passthrough'] if data['wall_passthrough'] > 0
      hex_shapes[coord] = data['shape_id'] if data['shape_id']
      hex_image_shapes[coord] = data['image_shape_id'] if data['image_shape_id']
    end

    { hex_zones: hex_zones, hex_shapes: hex_shapes, hex_image_shapes: hex_image_shapes }
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Hex classification failed: #{e.message}"
    nil
  end

  # Sample depth map at each hex center to get per-hex depth value.
  # Returns 0-255 where low=close/floor, high=far/elevated.
  #
  # @param depth_map [Vips::Image] single-band grayscale depth map
  # @param hex_size [Float] hex diameter in pixels
  # @return [Hash] {[hx,hy] => Float} average depth value (0-255)
  def build_hex_depth_map(depth_map, hex_size)
    return {} unless depth_map && @coord_lookup&.any?

    result = {}
    r = [(hex_size * 0.3).to_i, 2].max
    dm_w = depth_map.width
    dm_h = depth_map.height
    dm_band = depth_map.bands > 1 ? depth_map.extract_band(0) : depth_map

    @coord_lookup.each do |(hx, hy), info|
      cx = info[:px].round
      cy = info[:py].round
      x1 = [cx - r, 0].max
      y1 = [cy - r, 0].max
      w = [r * 2, dm_w - x1].min
      h = [r * 2, dm_h - y1].min
      next if w < 2 || h < 2

      begin
        result[[hx, hy]] = dm_band.crop(x1, y1, w, h).avg
      rescue Vips::Error
        next
      end
    end

    result
  end


  # Pass 1: Off-map flood fill from grid borders.
  # Seeds from border hexes not inside any shape, BFS inward through unclassified hexes.
  # Stops at shape boundaries or classified hexes.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type} -- not mutated
  # @param all_coords [Set] all valid hex coordinates
  # @return [Set] coordinates to mark as off_map
  def norm_v3_off_map_flood(typed_map, all_coords, image: nil, hex_size: nil, hex_zones: {})
    fills = Set.new
    max_region_ratio = 0.30 # abort a region if it exceeds 30% of all hexes
    has_zones = hex_zones.any?

    # Pre-compute brightness at each hex for off-map detection (fallback when no zone map).
    brightness = {}
    unless has_zones
      if image && hex_size && @coord_lookup
        gray = image.bands > 1 ? image.colourspace(:b_w).extract_band(0) : image
        @coord_lookup.each do |(hx, hy), info|
          r = [(hex_size * 0.5).to_i, 2].max
          x1 = [info[:px].round - r, 0].max
          y1 = [info[:py].round - r, 0].max
          w = [r * 2, gray.width - x1].min
          h = [r * 2, gray.height - y1].min
          brightness[[hx, hy]] = (w >= 2 && h >= 2) ? gray.crop(x1, y1, w, h).avg : 128.0
        rescue Vips::Error
          brightness[[hx, hy]] = 128.0
        end
      end
    end

    # If zone map available, directly mark all zone=0 hexes as off_map
    if has_zones
      candidate_fills = Set.new
      all_coords.each do |hx, hy|
        next if typed_map[[hx, hy]] # don't override LLM classifications
        candidate_fills.add([hx, hy]) if hex_zones[[hx, hy]] == 0
      end
      ratio = all_coords.size > 0 ? candidate_fills.size.to_f / all_coords.size : 0.0
      if ratio > 0.70
        warn "[AIBattleMapGenerator] Pass 1: zone map would off_map #{(ratio * 100).round}% of hexes — skipping (likely bad depth segmentation)"
      else
        fills.merge(candidate_fills)
        warn "[AIBattleMapGenerator] Pass 1: zone map directly marked #{fills.length} off_map hexes"
      end
    end

    # Border hexes: fewer than 6 valid neighbors
    border_hexes = all_coords.select do |hx, hy|
      HexGrid.hex_neighbors(hx, hy).count { |nx, ny| all_coords.include?([nx, ny]) } < 6
    end

    max_region_size = (all_coords.size * max_region_ratio).to_i

    border_hexes.each do |hx, hy|
      next if typed_map[[hx, hy]]
      next if fills.include?([hx, hy])

      if has_zones
        next unless hex_zones[[hx, hy]] == 0
      elsif brightness.any?
        next if brightness[[hx, hy]] && brightness[[hx, hy]] > 40
      end

      region = Set.new([[hx, hy]])
      queue = [[hx, hy]]
      aborted = false

      while (current = queue.shift)
        cx, cy = current
        HexGrid.hex_neighbors(cx, cy).each do |nx, ny|
          next unless all_coords.include?([nx, ny])
          next if region.include?([nx, ny]) || fills.include?([nx, ny])
          next if typed_map[[nx, ny]] # stop at classified hexes

          if has_zones
            next unless hex_zones[[nx, ny]] == 0
          elsif brightness.any? && brightness[[nx, ny]] && brightness[[nx, ny]] > 50
            next
          end

          region.add([nx, ny])
          queue << [nx, ny]

          if region.size > max_region_size
            aborted = true
            break
          end
        end
        break if aborted
      end

      fills.merge(region) unless aborted
    end

    fills
  end

  # Pass 2: Clear misclassified objects using zone map signals.
  # Zone=3 (object) confirms, zone=2 (floor) demotes non-exempt types.
  # Without zone map, keeps all classifications (no shape map to check against).
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type} -- not mutated
  # @param hex_zones [Hash] {[hx,hy] => zone_id}
  # @return [Set] coordinates to demote (delete from typed_map)
  def norm_v3_object_clearing(typed_map, hex_zones: {}, type_properties: {})
    demoted = Set.new
    return demoted unless hex_zones.any?

    # Types that are structural/architectural — don't demote these based on zone
    wall_types = WALL_EXTENSION_TYPES | ARCHITECTURAL_TYPES

    # Build set of flat types that should be kept on floor zones.
    # A type is "flat" if it has no elevation and no tactical significance
    # (no cover, no concealment, not a wall). These are ground coverings
    # like rugs, carpets, blood stains — the depth model can't see them.
    flat_types = Set.new
    type_properties.each do |type_name, props|
      next if HEX_TYPE_PROPERTIES.key?(type_name) # standard types already handled
      next if wall_types.include?(type_name)
      elev = props['elevation'] || 0
      next unless elev.zero?
      next if props['provides_cover'] || props['provides_concealment']
      next if props['is_wall']
      flat_types.add(type_name)
    end
    # Also include standard types with elevation 0, traversable, no cover
    HEX_TYPE_PROPERTIES.each do |type_name, props|
      next if EDGE_EXEMPT_TYPES.include?(type_name)
      next if wall_types.include?(type_name)
      elev = props['elevation'] || 0
      next unless elev.zero?
      next if props['provides_cover'] || props['provides_concealment']
      next unless props['traversable'] != false
      flat_types.add(type_name)
    end

    typed_map.each do |(hx, hy), hex_type|
      next if hex_type == 'off_map'
      next if EDGE_EXEMPT_TYPES.include?(hex_type)
      next if wall_types.include?(hex_type) # walls/doors/windows handled by other passes
      next if flat_types.include?(hex_type) # flat ground-level types survive on floor zones

      # Pits, hazards, and below-floor features have negative/zero elevation in depth —
      # they appear as floor-level and won't have depth signal. Keep them on floor zones.
      std_props = HEX_TYPE_PROPERTIES[hex_type]
      cust_props = type_properties[hex_type]
      elev = std_props&.dig('elevation') || cust_props&.dig('elevation') || 0
      next if elev < 0  # negative elevation = below floor (pits, hazards), keep it

      zone = hex_zones[[hx, hy]]
      next if zone == 3 # zone confirms this is an object — keep it
      next if zone == 1 # zone says wall — keep it (wall-like objects)

      # zone=2 (floor) or zone=0 (off_map) or nil — demote
      # These are objects the LLM classified but the zone map says don't belong here
      demoted.add([hx, hy])
    end

    demoted
  end

  # Pass 2: Zone-based validation — override LLM classification where zone map
  # provides strong structural signal.
  def norm_v3_zone_validation(typed_map, hex_zones: {}, type_properties: {})
    overrides = {}
    demotions = Set.new
    return { overrides: overrides, demotions: demotions } unless hex_zones.any?

    wall_types = WALL_EXTENSION_TYPES | ARCHITECTURAL_TYPES

    # Build flat types set (types that depth model can't see)
    flat_types = Set.new
    type_properties.each do |type_name, props|
      next if HEX_TYPE_PROPERTIES.key?(type_name)
      next if wall_types.include?(type_name)
      elev = props['elevation'] || 0
      next unless elev.zero?
      next if props['provides_cover'] || props['provides_concealment']
      next if props['is_wall']
      flat_types.add(type_name)
    end
    HEX_TYPE_PROPERTIES.each do |type_name, props|
      next if EDGE_EXEMPT_TYPES.include?(type_name)
      next if wall_types.include?(type_name)
      elev = props['elevation'] || 0
      next unless elev.zero?
      next if props['provides_cover'] || props['provides_concealment']
      next unless props['traversable'] != false
      flat_types.add(type_name)
    end

    typed_map.each do |(hx, hy), hex_type|
      next if hex_type == 'off_map'
      zone = hex_zones[[hx, hy]]
      next unless zone

      std_props = HEX_TYPE_PROPERTIES[hex_type]
      cust_props = type_properties[hex_type]
      elev = std_props&.dig('elevation') || cust_props&.dig('elevation') || 0

      next if elev < 0  # negative elevation = below floor, always keep

      case zone
      when 1  # wall zone — only force blank floor→wall; preserve LLM-identified objects.
        # The zone=1 band can be ~5% of image wide and may overlap with objects placed
        # near walls (weapon racks, crates, forges). The LLM's visual recognition is
        # reliable for named object types; override only generic 'floor' placeholders.
        if hex_type == 'floor'
          overrides[[hx, hy]] = 'wall'
        end
      when 2  # floor zone — demote walls only, elevated objects are legitimate furniture
        if WALL_EXTENSION_TYPES.include?(hex_type)
          demotions.add([hx, hy])
        end
      when 3  # object zone — walls here are misclassified
        if WALL_EXTENSION_TYPES.include?(hex_type)
          demotions.add([hx, hy])
        end
      end
    end

    # Promote unclassified wall-zone hexes to wall.
    # Only promote hexes with strong zone=1 coverage (>65% of hex pixels in wall zone).
    # Hexes at the inner edge of zone=1 (50-65% coverage) may be interior floor hexes
    # that the distance-transform band clips — leave those as nil (type mapping → floor).
    hex_zones.each do |(hx, hy), zone|
      next unless zone == 1
      next if typed_map[[hx, hy]]  # already classified
      next if overrides[[hx, hy]]  # already promoted
      wall_cov = @hex_wall_coverage&.dig([hx, hy]) || 0.0
      overrides[[hx, hy]] = 'wall' if wall_cov > 0.65
    end

    { overrides: overrides, demotions: demotions }
  end

  # Pass 2.5: Border wall guarantee for enclosed rooms.
  # The outermost row of hexes on each edge must be wall.
  # Passthrough types (door, archway, window) are preserved.
  def norm_v3_border_walls(typed_map, all_coords)
    overrides = {}
    coord_set = all_coords.is_a?(Set) ? all_coords : Set.new(all_coords)

    cols = Hash.new { |h, k| h[k] = [] }
    rows = Hash.new { |h, k| h[k] = [] }
    all_coords.each do |hx, hy|
      cols[hx] << hy
      rows[hy] << hx
    end

    num_cols = cols.size
    num_rows = rows.size
    # Offset hex grids produce 2 Y values per visual row (even/odd staggering),
    # so divide by 2 to get actual visual row count for threshold comparison.
    visual_rows = (num_rows + 1) / 2
    border_hexes = Set.new

    # For narrow axes (< 5 hexes), push boundary OUTSIDE the grid as
    # off_map hexes so the interior stays playable. Using off_map (not wall)
    # prevents Pass 4 wall flood from seeding inward off these virtual hexes.
    # For wider axes, enforce walls on the existing outermost hexes as before.

    # Top and bottom borders
    if visual_rows < 5
      cols.each do |hx, hy_list|
        HexGrid.hex_neighbors(hx, hy_list.min).each do |nx, ny|
          next if coord_set.include?([nx, ny])
          next unless ny < hy_list.min
          overrides[[nx, ny]] = 'off_map'
        end
        HexGrid.hex_neighbors(hx, hy_list.max).each do |nx, ny|
          next if coord_set.include?([nx, ny])
          next unless ny > hy_list.max
          overrides[[nx, ny]] = 'off_map'
        end
      end
    else
      cols.each do |hx, hy_list|
        border_hexes.add([hx, hy_list.min])
        border_hexes.add([hx, hy_list.max])
      end
    end

    # Left and right borders
    if num_cols < 5
      rows.each do |hy, hx_list|
        HexGrid.hex_neighbors(hx_list.min, hy).each do |nx, ny|
          next if coord_set.include?([nx, ny])
          next unless nx < hx_list.min
          overrides[[nx, ny]] = 'off_map'
        end
        HexGrid.hex_neighbors(hx_list.max, hy).each do |nx, ny|
          next if coord_set.include?([nx, ny])
          next unless nx > hx_list.max
          overrides[[nx, ny]] = 'off_map'
        end
      end
    else
      rows.each do |hy, hx_list|
        border_hexes.add([hx_list.min, hy])
        border_hexes.add([hx_list.max, hy])
      end
    end

    # Enforce walls on interior border hexes (wide axes only)
    wall_types = WALL_EXTENSION_TYPES | ARCHITECTURAL_TYPES
    border_hexes.each do |hx, hy|
      current = typed_map[[hx, hy]]
      next if current == 'off_map'
      next if wall_types.include?(current)
      next if PASSTHROUGH_TYPES.include?(current)
      overrides[[hx, hy]] = 'wall'
    end

    overrides
  end

  # Pass 10: Convert innermost off_map hexes to walls.
  # Any off_map hex adjacent to a non-off_map, non-wall hex becomes a wall.
  # This creates a wall shell around the playable interior.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @return [Array<Array>] coordinates to convert to wall
  def norm_v3_off_map_wall_shell(typed_map)
    conversions = []
    typed_map.each do |(hx, hy), hex_type|
      next unless hex_type == 'off_map'

      adjacent_to_interior = HexGrid.hex_neighbors(hx, hy).any? do |nx, ny|
        neighbor_type = typed_map[[nx, ny]]
        neighbor_type && neighbor_type != 'off_map' && !WALL_EXTENSION_TYPES.include?(neighbor_type)
      end
      conversions << [hx, hy] if adjacent_to_interior
    end
    conversions
  end

  # Pass 3: Shape snapping — use zone map object contours to add/trim hexes.
  #
  # For each connected component of object-zone (zone=3) hexes:
  # 1. Determine the majority LLM-classified type inside the shape
  # 2. ADD: floor/untyped hexes inside the shape → snap to the shape's type
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type} — not mutated
  # @param all_coords [Set] all valid hex coordinates
  # @param hex_zones [Hash] {[hx,hy] => zone_id}
  # @return [Hash] { additions: {coord => type}, trims: {} }
  def norm_v3_shape_snap(typed_map, all_coords, hex_zones: {}, hex_shapes: {})
    additions = {}
    trims = {}
    return { additions: additions, trims: trims } unless hex_zones.any?

    wall_types = WALL_EXTENSION_TYPES | ARCHITECTURAL_TYPES

    # Step 1: Build connected components of object-zone (zone=3) hexes
    object_hexes = hex_zones.select { |_, zone| zone == 3 }.keys
    return { additions: additions, trims: trims } if object_hexes.empty?

    shapes = [] # Array of Sets, each = one object shape

    # Primary: group by depth shape ID (pixel-level contour detection)
    if hex_shapes.any?
      shape_groups = hex_shapes.group_by { |_, sid| sid }.transform_values { |pairs| pairs.map(&:first) }
      shape_groups.each_value do |coords|
        component = Set.new(coords)
        shapes << component if component.size >= 2
      end
      uncovered_object_hexes = object_hexes.reject { |c| hex_shapes.key?(c) }
    else
      uncovered_object_hexes = object_hexes
    end

    # Secondary: BFS on zone=3 hexes not covered by depth shapes
    uncovered_set = Set.new(uncovered_object_hexes)
    visited = Set.new
    hex_shapes.each_key { |c| visited.add(c) } if hex_shapes.any?

    uncovered_object_hexes.each do |coord|
      next if visited.include?(coord)
      component = Set.new
      queue = [coord]
      while (c = queue.shift)
        next if visited.include?(c)
        next unless uncovered_set.include?(c)
        visited.add(c)
        component.add(c)
        HexGrid.hex_neighbors(*c).each do |nc|
          queue << nc unless visited.include?(nc)
        end
      end
      shapes << component if component.size >= 2
    end

    # Step 2: For each shape, determine majority type and snap/trim
    shapes.each do |shape_hexes|
      # Skip long thin shapes — they're likely wall segments misclassified as objects.
      # A shape with aspect ratio > 3:1 and a narrow dimension < 3 hexes is a wall strip.
      hex_xs = shape_hexes.map(&:first)
      hex_ys = shape_hexes.map(&:last)
      shape_w = hex_xs.max - hex_xs.min + 1
      shape_h = (hex_ys.max - hex_ys.min) / 2 + 1
      if shape_w > 0 && shape_h > 0
        aspect = [shape_w, shape_h].max.to_f / [shape_w, shape_h].min.to_f
        narrow = [shape_w, shape_h].min
        next if aspect > 3.0 && narrow < 3
      end

      # Find majority non-floor, non-wall type in this shape
      type_counts = Hash.new(0)
      shape_hexes.each do |coord|
        hex_type = typed_map[coord]
        next unless hex_type
        next if hex_type == 'floor' || hex_type == 'off_map'
        next if wall_types.include?(hex_type)
        next if PASSTHROUGH_TYPES.include?(hex_type)
        type_counts[hex_type] += 1
      end
      next if type_counts.empty?

      shape_type = type_counts.max_by { |_, count| count }.first

      # ADD: floor/untyped hexes inside the shape → snap to shape type
      shape_hexes.each do |coord|
        hex_type = typed_map[coord]
        if hex_type.nil? || hex_type == 'floor'
          additions[coord] = shape_type
        end
      end

      # TRIM: find same-type hexes in floor zone that have NO zone=3 neighbor.
      # Hexes adjacent to a zone=3 hex may be visually inside the object but
      # just missed by the depth model — preserve those. Only trim hexes that
      # are ≥2 hops from the depth shape (true LLM overextensions).
      object_zone_set = Set.new(hex_zones.select { |_, z| z == 3 }.keys)
      shape_hexes.each do |c|
        HexGrid.hex_neighbors(*c).each do |nc|
          next unless all_coords.include?(nc)
          next if shape_hexes.include?(nc)
          next unless typed_map[nc] == shape_type
          next unless hex_zones[nc].nil? || hex_zones[nc] == 2
          # Only trim if nc is not adjacent to any zone=3 hex (i.e., ≥2 hops from shape)
          has_object_neighbor = HexGrid.hex_neighbors(*nc).any? { |nnc| object_zone_set.include?(nnc) }
          trims[nc] = 'floor' unless has_object_neighbor
        end
      end

    end

    { additions: additions, trims: trims }
  end

  # Pass 3b: Flat shape snap — fill floor hexes inside visual image shapes
  # that already contain ≥2 hexes of a flat depthless type (water, fire, etc.).
  #
  # Flat types sit at floor level and are invisible to the depth model.
  # Their visual boundaries are extracted from the raw image via bilateral+Sobel.
  # If a shape already has ≥2 LLM-classified flat hexes, snap the remaining
  # floor/untyped hexes inside it to the majority flat type.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param hex_image_shapes [Hash] {[hx,hy] => image_shape_id}
  # @param hex_zones [Hash] {[hx,hy] => zone_id}
  # @return [Hash] { additions: {coord => type} }
  def norm_v3_flat_shape_snap(typed_map, all_coords, hex_image_shapes: {}, hex_zones: {})
    additions = {}
    return { additions: additions } unless hex_image_shapes.any?

    shape_groups = hex_image_shapes.group_by { |_, sid| sid }
                                    .transform_values { |pairs| pairs.map(&:first) }

    shape_groups.each_value do |coords|
      flat_counts = Hash.new(0)
      coords.each do |coord|
        t = typed_map[coord]
        flat_counts[t] += 1 if t && FLAT_SNAP_TYPES.include?(t)
      end
      next if flat_counts.values.sum < 2  # need ≥2 hexes of flat type already placed

      majority_flat = flat_counts.max_by { |_, c| c }.first

      coords.each do |coord|
        t = typed_map[coord]
        next unless t.nil? || t == 'floor'
        next if hex_zones[coord] == 0 || hex_zones[coord] == 1  # skip off_map/wall
        additions[coord] = majority_flat
      end
    end

    { additions: additions }
  end

  # Pass 3: Flood-fill partially classified objects.
  # For each cluster of same-type hexes, promote unclassified neighbors
  # where zone=3 (object) confirms they belong.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param hex_zones [Hash] {[hx,hy] => zone_id}
  # @return [Hash] {[hx,hy] => hex_type} newly promoted hexes
  def norm_v3_object_flood(typed_map, all_coords, hex_zones: {})
    promotions = {}
    visited = Set.new
    has_zones = hex_zones.any?

    skip_types = EDGE_EXEMPT_TYPES | Set.new(%w[off_map open_floor])

    typed_map.each do |(hx, hy), hex_type|
      next if skip_types.include?(hex_type)
      next if visited.include?([hx, hy])

      cluster = Set.new([[hx, hy]])
      queue = [[hx, hy]]
      visited.add([hx, hy])

      while (current = queue.shift)
        cx, cy = current
        HexGrid.hex_neighbors(cx, cy).each do |nx, ny|
          next unless all_coords.include?([nx, ny])
          next if visited.include?([nx, ny])
          if typed_map[[nx, ny]] == hex_type
            visited.add([nx, ny])
            cluster.add([nx, ny])
            queue << [nx, ny]
          end
        end
      end

      cluster.each do |cx, cy|
        HexGrid.hex_neighbors(cx, cy).each do |nx, ny|
          next unless all_coords.include?([nx, ny])
          next if typed_map[[nx, ny]]
          next if promotions[[nx, ny]]

          promotions[[nx, ny]] = hex_type if has_zones && hex_zones[[nx, ny]] == 3
        end
      end
    end

    promotions
  end

  # Pass 4: Wall flood -- extend wall segments using shape map + room awareness.
  # For indoor rooms, extends walls along wall-like shapes.
  # Fills 1-hex gaps between wall segments. Respects doors/windows/archways.
  # Zone map: zone=1 (wall) confirms wall extension even without shape map support.
  # Skips outdoor rooms entirely.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param hex_zones [Hash] {[hx,hy] => zone_id} (zone 1 = wall)
  # @return [Hash] {[hx,hy] => 'wall'} newly wall-extended hexes
  def norm_v3_wall_flood(typed_map, all_coords, hex_zones: {})
    return {} if room.outdoor_room?

    extensions = {}

    # Types that interrupt wall extension
    interruption_types = Set.new(%w[door archway gate glass_window open_window staircase ladder])

    # Hex axes for gap detection: N-S, NE-SW, NW-SE
    hex_axes = [[0, 4], [1, 2], [1, -2]]

    # Pass A: Fill 1-hex gaps between wall-like types
    all_coords.each do |hx, hy|
      next if typed_map[[hx, hy]]
      next if extensions[[hx, hy]]

      # Only fill gaps in wall zone
      next unless hex_zones[[hx, hy]] == 1 || hex_zones[[hx, hy]].nil?

      is_gap = hex_axes.any? do |dx, dy|
        n1_type = typed_map[[hx + dx, hy + dy]] || extensions[[hx + dx, hy + dy]]
        n2_type = typed_map[[hx - dx, hy - dy]] || extensions[[hx - dx, hy - dy]]
        wall_like = ->(t) { WALL_EXTENSION_TYPES.include?(t) || ARCHITECTURAL_TYPES.include?(t) }
        wall_like.call(n1_type) && wall_like.call(n2_type)
      end

      extensions[[hx, hy]] = 'wall' if is_gap
    end

    # Pass B: Extend wall segments along wall-like shape/zone neighbors
    wall_seeds = typed_map.select { |_, t| WALL_EXTENSION_TYPES.include?(t) }.keys
    wall_seeds += extensions.keys

    wall_seeds.each do |wx, wy|
      HexGrid.hex_neighbors(wx, wy).each do |nx, ny|
        next unless all_coords.include?([nx, ny])
        next if typed_map[[nx, ny]]
        next if extensions[[nx, ny]]

        # Only extend into wall-zone hexes
        next unless hex_zones[[nx, ny]] == 1 || hex_zones[[nx, ny]].nil?

        # Don't extend near interruption features
        near_interruption = HexGrid.hex_neighbors(nx, ny).any? do |fx, fy|
          t = typed_map[[fx, fy]]
          interruption_types.include?(t)
        end
        next if near_interruption

        extensions[[nx, ny]] = 'wall'
      end
    end

    # Pass C: Smooth wall thickness — fill interior holes.
    # If a non-wall hex has 4+ wall neighbors, it's inside a wall cluster.
    all_walls = typed_map.select { |_, t| WALL_EXTENSION_TYPES.include?(t) }.keys.to_set
    all_walls.merge(extensions.keys)

    all_coords.each do |hx, hy|
      next if typed_map[[hx, hy]]
      next if extensions[[hx, hy]]
      wall_neighbors = HexGrid.hex_neighbors(hx, hy).count do |nx, ny|
        all_walls.include?([nx, ny])
      end
      extensions[[hx, hy]] = 'wall' if wall_neighbors >= 4
    end

    extensions
  end

  # Pass 5: Elevation fix -- assign sequential elevation to stairs/ladders,
  # flood connected elevated areas from the top.
  # Depth map: use depth gradient to validate stair direction and detect
  # elevated platforms even without explicit staircase classification.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param ascending_directions [Hash] {[hx,hy] => direction_string} from classification
  # @param hex_depths [Hash] {[hx,hy] => Float} depth values (0-255)
  # @param hex_zones [Hash] {[hx,hy] => zone_id} (zone 1 = wall)
  # @return [Hash] {[hx,hy] => Integer} elevation in feet
  def norm_v3_elevation_fix(typed_map, all_coords, ascending_directions, hex_depths: {}, hex_zones: {})
    elevations = {}
    elevation_per_step = 4 # feet per staircase hex
    has_depths = hex_depths.any?

    # Direction vectors for sorting stairs along ascending direction
    dir_vectors = {
      'north' => [0, -1], 'south' => [0, 1],
      'east' => [1, 0], 'west' => [-1, 0],
      'northeast' => [1, -1], 'northwest' => [-1, -1],
      'southeast' => [1, 1], 'southwest' => [-1, 1]
    }

    # Find staircase/ladder clusters
    stair_types = Set.new(%w[staircase ladder])
    visited = Set.new

    typed_map.each do |(hx, hy), hex_type|
      next unless stair_types.include?(hex_type)
      next if visited.include?([hx, hy])

      # BFS to find full stair cluster
      cluster = [[hx, hy]]
      queue = [[hx, hy]]
      visited.add([hx, hy])

      while (current = queue.shift)
        cx, cy = current
        HexGrid.hex_neighbors(cx, cy).each do |nx, ny|
          next unless all_coords.include?([nx, ny])
          next if visited.include?([nx, ny])
          next unless stair_types.include?(typed_map[[nx, ny]])
          visited.add([nx, ny])
          cluster << [nx, ny]
          queue << [nx, ny]
        end
      end

      # Determine ascending direction: prefer LLM classification,
      # fall back to depth gradient (ascending = increasing depth value)
      direction = cluster.filter_map { |c| ascending_directions[c] }.first

      if direction.nil? && has_depths
        # Use depth gradient across cluster to infer ascending direction
        depths = cluster.filter_map { |c| hex_depths[c] ? [c, hex_depths[c]] : nil }
        if depths.length >= 2
          min_d = depths.min_by(&:last)
          max_d = depths.max_by(&:last)
          dx = max_d[0][0] - min_d[0][0]
          dy = max_d[0][1] - min_d[0][1]
          # Map dx/dy to cardinal direction
          if dx.abs > dy.abs
            direction = dx > 0 ? 'east' : 'west'
          elsif dy != 0
            direction = dy > 0 ? 'south' : 'north'
          end
        end
      end

      next unless direction
      vec = dir_vectors[direction]
      next unless vec

      # Sort cluster: with depth data, sort by depth (ascending = higher depth);
      # without depth, sort by direction vector dot product
      sorted = if has_depths && cluster.all? { |c| hex_depths[c] }
        cluster.sort_by { |c| hex_depths[c] }
      else
        cluster.sort_by { |cx, cy| cx * vec[0] + cy * vec[1] }
      end

      # Assign incrementing elevation
      sorted.each_with_index do |coord, i|
        elevations[coord] = i * elevation_per_step
      end

      # Flood from the top of the stairs
      top_elevation = (sorted.length - 1) * elevation_per_step
      top_hex = sorted.last
      flood_queue = [top_hex]
      flooded = Set.new([top_hex])

      # Compute floor depth baseline for depth-aware flooding
      floor_depth = nil
      if has_depths
        floor_depths = typed_map.select { |_, t| t.nil? || t == 'open_floor' }.keys
          .filter_map { |c| hex_depths[c] }
        floor_depth = floor_depths.empty? ? nil : floor_depths.sort[floor_depths.length / 2]
      end

      while (current = flood_queue.shift)
        cx, cy = current
        HexGrid.hex_neighbors(cx, cy).each do |nx, ny|
          next unless all_coords.include?([nx, ny])
          next if flooded.include?([nx, ny])
          next if elevations[[nx, ny]] # already has elevation
          # Stop at walls or wall-zone boundaries
          next if typed_map[[nx, ny]] && WALL_EXTENSION_TYPES.include?(typed_map[[nx, ny]])
          next if hex_zones[[nx, ny]] == 1

          # With depth data: only flood into hexes that are elevated above floor
          if has_depths && floor_depth && hex_depths[[nx, ny]]
            next if hex_depths[[nx, ny]] < floor_depth + 10 # not elevated enough
          end

          elevations[[nx, ny]] = top_elevation
          flooded.add([nx, ny])
          flood_queue << [nx, ny]
        end
      end
    end

    elevations
  end

  # Pass 6: Elevated objects -- stack object elevation on surface elevation.
  # If an object sits on an elevated surface (from pass 5), add the object's
  # own elevation to the surface elevation.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param elevations [Hash] {[hx,hy] => Integer} from pass 5
  # @return [Hash] {[hx,hy] => Integer} updated elevations for object hexes
  def norm_v3_elevated_objects(typed_map, elevations)
    updated = {}

    typed_map.each do |(hx, hy), hex_type|
      surface_elev = elevations[[hx, hy]]
      next unless surface_elev && surface_elev > 0

      # Get the object's own elevation from type properties
      own_elev = HEX_TYPE_PROPERTIES.dig(hex_type, 'elevation') || 0
      next if own_elev <= 0

      updated[[hx, hy]] = surface_elev + own_elev
    end

    updated
  end

  # Pass 7: Terrain scoring — weighted promotion/demotion for terrain types.
  # Uses a scoring system combining color similarity and edge boundaries.
  #
  # Edge signal meaning depends on neighbor type:
  #   Same-type neighbor + edge between  = -2.0 (cluster is fragmented)
  #   Same-type neighbor + no edge       = +0.5 (smooth continuation)
  #   Different-type neighbor + edge     = +0.3 (confirms terrain boundary)
  #   Different-type neighbor + no edge  = -0.3 (blends into surroundings)
  #
  # Color signal (same-type neighbors only):
  #   +1.0  color match (LAB distance < threshold)
  #   -0.5  color mismatch
  #
  # Promotion: unclassified hex with score >= 1.5 for a terrain type
  # Demotion: terrain hex with score < 0.0
  #
  # After scoring, flood-remove terrain clusters separated by edges that
  # are small or form lines (not blob-shaped).
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param color_features [Hash] {[hx,hy] => feature_vector} LAB color features
  # @param edge_map [Vips::Image, nil] edge map for boundary detection
  # @param hex_size [Float, nil] hex diameter in pixels
  # @return [Array<Hash, Set>] [promotions_hash, demotions_set]
  def norm_v3_terrain_color_pass(typed_map, all_coords, color_features, edge_map: nil, hex_size: nil)
    promotions = {}
    demotions = Set.new
    color_threshold = 15.0
    edge_boundary_threshold = 0.12
    terrain_types = EDGE_EXEMPT_TYPES - Set.new(%w[open_floor off_map])
    has_edges = edge_map && hex_size && @coord_lookup

    # Helper: compute edge strength between two hex coordinates
    edge_between = if has_edges
      lambda do |c1, c2|
        i1 = @coord_lookup[c1]
        i2 = @coord_lookup[c2]
        return 0.0 unless i1 && i2
        mid_px = (i1[:px] + i2[:px]) / 2.0
        mid_py = (i1[:py] + i2[:py]) / 2.0
        edge_strength_at_hex(edge_map, mid_px, mid_py, hex_size * 0.5)
      end
    end

    # Helper: score a hex for belonging to a terrain type.
    # Edges between same-type = bad (fragmented), edges to different-type = good (boundary).
    score_hex = lambda do |coord, ttype, features|
      score = 0.0
      HexGrid.hex_neighbors(*coord).each do |nx, ny|
        nc = [nx, ny]
        nt = typed_map[nc] || promotions[nc]
        is_same_type = (nt == ttype)
        has_edge = false

        if edge_between
          es = edge_between.call(coord, nc)
          has_edge = es >= edge_boundary_threshold

          if is_same_type
            # Edge splitting same-type cluster = bad signal
            score += has_edge ? -2.0 : 0.5
          else
            # Edge separating from different type = confirms boundary
            score += has_edge ? 0.3 : -0.3
          end
        end

        # Color signal (only against same-type neighbors, and only if no splitting edge)
        next unless is_same_type
        next if has_edge  # already penalized above, don't double-count

        n_features = color_features[nc]
        next unless n_features

        dist = vector_distance(features, n_features)
        score += dist < color_threshold ? 1.0 : -0.5
      end
      score
    end

    # --- Promotion round ---
    all_coords.each do |hx, hy|
      next if typed_map[[hx, hy]]
      next if promotions[[hx, hy]]

      my_features = color_features[[hx, hy]]
      next unless my_features

      # Score against each adjacent terrain type
      type_scores = {}
      HexGrid.hex_neighbors(hx, hy).each do |nx, ny|
        t = typed_map[[nx, ny]]
        next unless t && terrain_types.include?(t)
        type_scores[t] ||= 0.0
      end

      type_scores.each_key do |ttype|
        type_scores[ttype] = score_hex.call([hx, hy], ttype, my_features)
      end

      best_type, best_score = type_scores.max_by { |_, s| s }
      promotions[[hx, hy]] = best_type if best_type && best_score >= 1.5
    end

    # --- Demotion round ---
    typed_map.each do |(hx, hy), hex_type|
      next unless terrain_types.include?(hex_type)

      my_features = color_features[[hx, hy]]
      next unless my_features

      score = score_hex.call([hx, hy], hex_type, my_features)
      demotions.add([hx, hy]) if score < 0.0
    end

    # --- Flood-remove: find edge-separated terrain clusters and remove
    # small or line-shaped fragments ---
    if has_edges
      terrain_types.each do |ttype|
        # Collect all hexes of this type (original + promoted, minus demoted)
        terrain_hexes = []
        typed_map.each { |(hx, hy), t| terrain_hexes << [hx, hy] if t == ttype }
        promotions.each { |(hx, hy), t| terrain_hexes << [hx, hy] if t == ttype }
        terrain_hexes.reject! { |c| demotions.include?(c) }
        next if terrain_hexes.length < 2

        terrain_set = terrain_hexes.to_set

        # Build edge-aware connected components
        visited = Set.new
        clusters = []

        terrain_hexes.each do |coord|
          next if visited.include?(coord)
          cluster = [coord]
          queue = [coord]
          visited.add(coord)

          while (current = queue.shift)
            HexGrid.hex_neighbors(*current).each do |nx, ny|
              nc = [nx, ny]
              next unless terrain_set.include?(nc)
              next if visited.include?(nc)

              es = edge_between.call(current, nc)
              next if es >= edge_boundary_threshold

              visited.add(nc)
              cluster << nc
              queue << nc
            end
          end
          clusters << cluster
        end

        next if clusters.length < 2
        largest = clusters.max_by(&:length)

        clusters.each do |c|
          next if c.equal?(largest)

          # Small fragments: demote
          if c.length <= 3
            c.each { |coord| demotions.add(coord); promotions.delete(coord) }
            next
          end

          # Line detection: if cluster is elongated (length >> width), demote.
          # Approximate by checking if any hex has > 2 same-cluster neighbors
          # (blobs have interior hexes with 3+ neighbors, lines don't).
          has_interior = c.any? do |coord|
            c_set = c.to_set
            HexGrid.hex_neighbors(*coord).count { |nx, ny| c_set.include?([nx, ny]) } >= 3
          end
          unless has_interior
            c.each { |coord| demotions.add(coord); promotions.delete(coord) }
          end
        end
      end
    end

    [promotions, demotions]
  end

  # Window/water type names that trigger SAM queries.
  # Only queried if L1 overview found matching types.
  SAM_WINDOW_TYPES = %w[glass_window open_window window].freeze
  SAM_FOLIAGE_TYPES = %w[treetrunk treebranch shrubbery].freeze
  SAM_WATER_TYPES = %w[puddle wading_water deep_water water stream river pond fountain pool].freeze

  # SAM text prompts for light source types (L1 reports source_type → SAM query).
  # Light source types L1 can report. Each maps to a SAM text prompt.
  # fire + torch share the same SAM query since SAM handles both well.
  LIGHT_SOURCE_TYPES = BattlemapV2::L1AnalysisConfig::LIGHT_SOURCE_TYPES

  SAM_LIGHT_QUERIES = {
    'fire'           => 'hearth fire',
    'torch'          => 'torch flame',
    'candle'         => 'candle',
    'gaslamp'        => 'lamp',
    'electric_light' => 'light fixture',
    'magical_light'  => 'glowing crystal',
  }.freeze

  LIGHT_COLORS = BattlemapV2::L1AnalysisConfig::LIGHT_COLORS
  LIGHT_COLOR_DEFAULT = BattlemapV2::L1AnalysisConfig::LIGHT_COLOR_DEFAULT
  LIGHT_INTENSITIES = BattlemapV2::L1AnalysisConfig::LIGHT_INTENSITIES
  LIGHT_INTENSITY_DEFAULT = BattlemapV2::L1AnalysisConfig::LIGHT_INTENSITY_DEFAULT

  # Pass 7.5: SAM authoritative feature detection — windows and water.
  # SAM is highly authoritative for these because glass reflections and water
  # surfaces create distinctive visual signatures.
  #
  # Only queries SAM for features that L1 actually discovered — avoids false
  # positives (e.g. detecting "windows" on screens/monitors in a sci-fi map).
  #
  # Windows: applied only to wall-zone hexes (zone=1).
  # Water: applied to any non-wall hex. Raw masks stored in @sam_feature_masks
  # for downstream animation use.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param hex_zones [Hash] {[hx,hy] => zone_id}
  # @param image_path [String] path to source image
  # @param hex_size [Float] hex diameter in pixels
  # @param present_type_names [Array<String>] type names from L1 overview
  # @return [Hash] {[hx,hy] => hex_type} hexes to reclassify
  # @param prefetched_sam_threads [Hash] optional {hex_type => Thread} from pre-fired SAM queries
  def norm_v3_sam_features(typed_map, all_coords, hex_zones:, image_path:, hex_size:, present_type_names: [], prefetched_sam_threads: {})
    detections = {}
    return detections unless image_path && File.exist?(image_path)
    return detections unless ReplicateSamService.available?

    # Build SAM queries based on what L1 actually found
    sam_queries = {}
    has_windows = (present_type_names & SAM_WINDOW_TYPES).any?
    has_water = (present_type_names & SAM_WATER_TYPES).any?

    sam_queries['glass_window'] = 'window' if has_windows
    sam_queries['water'] = 'water' if has_water

    return detections if sam_queries.empty?

    # Use pre-fetched threads if available, otherwise fire new ones
    threads = {}
    sam_queries.each do |hex_type, query|
      if prefetched_sam_threads[hex_type]
        threads[hex_type] = prefetched_sam_threads[hex_type]
      else
        threads[hex_type] = Thread.new do
          ReplicateSamService.segment_with_samg_fallback(image_path, query, suffix: "_sam_#{hex_type}")
        end
      end
    end

    masks = {}
    threads.each do |hex_type, thread|
      result = thread.value
      if result[:success] && result[:mask_path] && !result[:no_detections]
        begin
          mask = Vips::Image.new_from_file(result[:mask_path])
          mask = mask.extract_band(0) if mask.bands > 1
          masks[hex_type] = mask
        rescue StandardError => e
          warn "[AIBattleMapGenerator] SAM mask load failed for #{hex_type}: #{e.message}"
        end
      elsif result[:no_detections]
        warn "[AIBattleMapGenerator] SAM: no #{hex_type} detected"
      else
        warn "[AIBattleMapGenerator] SAM #{hex_type} failed: #{result[:error]}"
      end
    end

    # Store raw masks for downstream use (animations, etc.)
    @sam_feature_masks = masks

    return detections if masks.empty?
    return detections unless @coord_lookup&.any?

    sample_r = [(hex_size * 0.35).to_i, 2].max

    masks.each do |hex_type, mask|
      is_window = hex_type == 'glass_window'

      @coord_lookup.each do |(hx, hy), info|
        next unless all_coords.include?([hx, hy])

        if is_window
          # Windows: only in wall zones, only override wall hexes
          next unless hex_zones[[hx, hy]] == 1
          existing = typed_map[[hx, hy]]
          next if existing && existing != 'wall'
        else
          # Water: skip wall and off_map hexes
          next if hex_zones[[hx, hy]] == 1 || hex_zones[[hx, hy]] == 0
        end

        cx = info[:px].round
        cy = info[:py].round
        x1 = [cx - sample_r, 0].max
        y1 = [cy - sample_r, 0].max
        w = [sample_r * 2, mask.width - x1].min
        h = [sample_r * 2, mask.height - y1].min
        next if w < 2 || h < 2

        begin
          patch = mask.crop(x1, y1, w, h)
          coverage = patch.avg / 255.0
          # Windows: 25% threshold (SAM is authoritative for glass)
          # Water: 40% threshold (needs more coverage to be confident)
          threshold = is_window ? 0.25 : 0.40
          if coverage > threshold
            # Map water SAM detection to the specific water type L1 found
            actual_type = if hex_type == 'water'
                           (present_type_names & SAM_WATER_TYPES).first || 'wading_water'
                         else
                           hex_type
                         end
            detections[[hx, hy]] = actual_type
          end
        rescue Vips::Error
          next
        end
      end
    end

    detections
  end

  # Pass 7.5c: Exit-guided door placement.
  # If the room has adjacent rooms (from spatial adjacency) in a direction
  # where walls exist but no door/archway hex, find the best wall hex to
  # punch a door through using the zone map wall coverage.
  #
  # Uses @hex_wall_coverage (set in build_hex_zone_map) to find the thinnest
  # wall point — door frames show as lower wall coverage in the zone map.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @return [Hash] {[hx,hy] => 'door'} newly placed doors
  # Direction abbreviation → full symbol mapping for L1 perimeter_wall_doors hints
  L1_DIR_MAP = { 'n' => :north, 's' => :south, 'e' => :east, 'w' => :west,
                 'ne' => :northeast, 'nw' => :northwest, 'se' => :southeast, 'sw' => :southwest }.freeze

  def norm_v3_exit_guided_doors(typed_map, all_coords, forced_directions: nil, hex_zones: {}, l1_hints: {})
    doors = {}

    if forced_directions
      # Test mode: use provided directions directly
      exit_directions = forced_directions.map(&:to_sym)
    else
      # Production mode: only use explicit door/opening room_features.
      # Spatial adjacency alone is insufficient — adjacent rooms share a wall boundary
      # but may not have a physical door opening; placing doors based on adjacency
      # produces false positives (doors placed in solid walls).
      explicit_dirs = Set.new
      if room.respond_to?(:room_features)
        room.room_features.each do |f|
          explicit_dirs.add(f.direction.to_sym) if f.direction && %w[door opening archway gate hatch].include?(f.feature_type)
        end
      end
      # L1 perimeter_wall_doors are treated as low-confidence hints:
      # add them only if no explicit room_feature covers that direction.
      (l1_hints[:perimeter_wall_doors] || []).each do |abbr|
        dir = L1_DIR_MAP[abbr]
        explicit_dirs.add(dir) if dir && !explicit_dirs.include?(dir)
      end
      exit_directions = explicit_dirs.to_a
    end
    return doors if exit_directions.empty?

    door_hex_types = Set.new(%w[door archway gate open_window glass_window])

    # Compute hex coordinate bounds for edge detection
    xs = all_coords.map(&:first)
    ys = all_coords.map(&:last)
    min_hx, max_hx = xs.minmax
    min_hy, max_hy = ys.minmax
    range_x = max_hx - min_hx
    range_y = max_hy - min_hy
    # Edge threshold: hexes within ~20% of the edge
    edge_x = [range_x * 0.2, 4].max
    edge_y = [range_y * 0.2, 8].max  # y uses even steps (0,2,4,6...)

    # Map direction → hex filter for edge walls
    edge_filters = {
      north:     ->(_, hy) { hy <= min_hy + edge_y },
      south:     ->(_, hy) { hy >= max_hy - edge_y },
      east:      ->(hx, _) { hx >= max_hx - edge_x },
      west:      ->(hx, _) { hx <= min_hx + edge_x },
      northeast: ->(hx, hy) { hx >= max_hx - edge_x && hy <= min_hy + edge_y },
      northwest: ->(hx, hy) { hx <= min_hx + edge_x && hy <= min_hy + edge_y },
      southeast: ->(hx, hy) { hx >= max_hx - edge_x && hy >= max_hy - edge_y },
      southwest: ->(hx, hy) { hx <= min_hx + edge_x && hy >= max_hy - edge_y }
    }

    exit_directions.each do |direction|
      filter = edge_filters[direction]
      next unless filter

      # Check if we already have a door on this edge
      has_door = typed_map.any? do |(hx, hy), t|
        door_hex_types.include?(t) && filter.call(hx, hy)
      end
      next if has_door

      # Find wall hexes on this edge — skip off_map zone and require at least
      # one interior (non-wall, non-off_map) neighbor so we don't place doors
      # in deeply embedded wall/exterior hexes.
      edge_walls = typed_map.select do |(hx, hy), t|
        next false unless WALL_EXTENSION_TYPES.include?(t) && filter.call(hx, hy)
        next false if hex_zones[[hx, hy]] == 0  # skip off_map zone
        HexGrid.hex_neighbors(hx, hy).any? do |nx, ny|
          t2 = typed_map[[nx, ny]]
          t2 && t2 != 'wall' && t2 != 'off_map' && !WALL_EXTENSION_TYPES.include?(t2)
        end
      end.keys
      # No walls on this edge = open passage, no door needed
      next if edge_walls.empty?

      # Score each wall hex: lower = better door candidate
      # Prefer: low wall coverage (thinner wall), fewer wall neighbors (thinning point)
      best = edge_walls.min_by do |wx, wy|
        wall_coverage = @hex_wall_coverage&.dig([wx, wy]) || 1.0
        wall_nbrs = HexGrid.hex_neighbors(wx, wy).count do |nx, ny|
          t = typed_map[[nx, ny]]
          WALL_EXTENSION_TYPES.include?(t)
        end
        # Check for door-frame pattern: non-wall on both interior and exterior sides
        non_wall_nbrs = HexGrid.hex_neighbors(wx, wy).count do |nx, ny|
          all_coords.include?([nx, ny]) &&
            !WALL_EXTENSION_TYPES.include?(typed_map[[nx, ny]]) &&
            typed_map[[nx, ny]] != 'off_map'
        end
        frame_bonus = non_wall_nbrs >= 2 ? -0.5 : 0.0
        wall_coverage + wall_nbrs * 0.15 + frame_bonus
      end

      next unless best

      # Extend punch through wall hexes until both sides of the passage have a
      # traversable (non-wall, non-off_map) hex.  A single wall hex flush against
      # another wall just creates a door into a dead end; we keep punching until
      # the passage is clear on both sides (or we reach off_map on the exterior side).
      punch_set = Set.new([best])
      max_punch = 6
      changed = true
      while changed && punch_set.size <= max_punch
        changed = false
        sides_traversable = punch_set.sum do |px, py|
          HexGrid.hex_neighbors(px, py).count do |nx, ny|
            t = typed_map[[nx, ny]]
            t && !WALL_EXTENSION_TYPES.include?(t) && t != 'off_map' && !punch_set.include?([nx, ny])
          end
        end
        if sides_traversable < 2
          # Extend into the lowest-coverage adjacent wall hex not yet in punch_set
          candidate = punch_set.flat_map do |px, py|
            HexGrid.hex_neighbors(px, py).filter_map do |nx, ny|
              next unless all_coords.include?([nx, ny])
              next unless WALL_EXTENSION_TYPES.include?(typed_map[[nx, ny]])
              next if punch_set.include?([nx, ny])
              cov = @hex_wall_coverage&.dig([nx, ny]) || 0.5
              [[nx, ny], cov]
            end
          end.min_by { |_, cov| cov }
          if candidate
            punch_set.add(candidate[0])
            changed = true
          end
        end
      end

      punch_set.each { |coord| doors[coord] = 'door' }
    end

    doors
  end

  # Pass 7.6: Door detection — shape existing door clusters using wall geometry.
  # Instead of independently detecting doors from wall thinning (too many false
  # positives), we find wall hexes adjacent to LLM-classified door/archway hexes
  # that sit at wall thinning points. This extends door clusters to fill the
  # full wall opening without creating spurious doors.
  def norm_v3_wall_door_detection(typed_map, all_coords)
    doors = {}
    door_types = Set.new(%w[door archway gate])

    # Find existing door/archway hexes from LLM classification
    existing_doors = typed_map.select { |_, t| door_types.include?(t) }
    return doors if existing_doors.empty?

    # For each door hex, check adjacent wall hexes at thinning points
    existing_doors.each do |(dx, dy), door_type|
      HexGrid.hex_neighbors(dx, dy).each do |wx, wy|
        next unless all_coords.include?([wx, wy])
        next unless typed_map[[wx, wy]] == 'wall'

        # Check if this wall hex is at a thinning point (narrow wall)
        neighbors = HexGrid.hex_neighbors(wx, wy)
        wall_neighbors = neighbors.count { |nx, ny| typed_map[[nx, ny]] == 'wall' }
        non_wall_neighbors = neighbors.count do |nx, ny|
          all_coords.include?([nx, ny]) &&
            typed_map[[nx, ny]] != 'wall' &&
            typed_map[[nx, ny]] != 'off_map'
        end

        # Wall hex is thin (≤2 wall neighbors) with accessible sides
        next unless wall_neighbors <= 2 && non_wall_neighbors >= 2

        doors[[wx, wy]] = door_type
      end
    end

    doors
  end

  # Pass 7.7: Door joining — fill single-wall-hex gaps between two door hexes.
  # When two door hexes of the same type are separated by exactly one wall hex,
  # that wall hex is likely the middle of the opening and should be a door too.
  def norm_v3_door_join(typed_map, all_coords, hex_zones: {}, max_gap: 8)
    additions = {}
    door_types = Set.new(%w[door archway gate])
    all_coords_set = all_coords.is_a?(Set) ? all_coords : Set.new(all_coords)

    door_hexes = typed_map.select { |_, t| door_types.include?(t) }.keys
    return additions if door_hexes.size < 2

    # A hex is traversable as wall if it is:
    # - an explicit wall/fence/cliff type, OR
    # - unclassified (nil) and in zone=1 (structural wall area with weak coverage)
    wall_traversable = ->(coord) {
      t = typed_map[coord]
      return true if WALL_EXTENSION_TYPES.include?(t)
      t.nil? && hex_zones[coord] == 1
    }

    # BFS from each door hex through wall/structural-nil paths up to max_gap steps.
    # When we reach another door hex, fill all intermediate hexes.
    door_hexes.each do |start|
      next_type = typed_map[start]
      seen = Set.new([start])
      queue = []
      HexGrid.hex_neighbors(*start).each do |nc|
        next unless all_coords_set.include?(nc)
        next if seen.include?(nc)
        seen.add(nc)
        queue << [nc, []] if wall_traversable.call(nc)
      end

      while (entry = queue.shift)
        coord, wall_path = entry
        next if wall_path.size >= max_gap
        current_path = wall_path + [coord]

        HexGrid.hex_neighbors(*coord).each do |nc|
          next unless all_coords_set.include?(nc)
          next if seen.include?(nc)
          seen.add(nc)
          t = typed_map[nc]
          if door_types.include?(t)
            current_path.each { |c| additions[c] ||= next_type }
          elsif wall_traversable.call(nc)
            queue << [nc, current_path]
          end
        end
      end
    end

    additions
  end

  # Pass 9.5: Cleanup object hexes placed in the exterior (off_map) zone.
  # Zone=0 is the area outside the room boundary — any non-structural type there
  # is LLM overreach and should become off_map.
  # Zone=1 (wall band) objects are intentionally preserved: weapon racks, forges,
  # and other objects correctly placed against the walls live in zone=1.
  def norm_v3_cleanup_errant(typed_map, all_coords, hex_zones: {})
    return {} unless hex_zones.any?

    cleanups = {}
    typed_map.each do |(hx, hy), type|
      next unless type
      next if type == 'floor' || type == 'off_map' || type == 'wall'
      zone = hex_zones[[hx, hy]]
      next unless zone
      if zone == 0
        cleanups[[hx, hy]] = 'off_map'
      end
    end
    cleanups
  end

  # Pass 9.8: Inaccessible hex removal.
  # Any non-wall, non-off_map hex that cannot be reached from the main playable
  # area (largest connected floor/object component) is converted to off_map.
  # This cleans up isolated islands from LLM overreach, bad SAM placements, etc.
  def norm_v3_inaccessible(typed_map, all_coords, hex_zones: {})
    # A hex is reachable if it is not wall/off_map.
    # Unclassified (nil) hexes in interior zones (2=floor, 3=object) are treated as
    # passable floor — they will become 'normal' in type mapping anyway. Nil hexes in
    # zone=0 or zone=1 are structural (off_map/wall) and block traversal.
    reachable = ->(coord) {
      t = typed_map[coord]
      return false if t == 'wall' || t == 'off_map'
      return true unless t.nil?
      zone = hex_zones[coord]
      zone.nil? || zone == 2 || zone == 3
    }

    candidates = all_coords.select { |c| reachable.call(c) }
    return {} if candidates.empty?

    # BFS to find all connected components
    visited = Set.new
    components = []

    candidates.each do |coord|
      next if visited.include?(coord)
      component = Set.new
      queue = [coord]
      while (c = queue.shift)
        next if visited.include?(c)
        next unless reachable.call(c)
        visited.add(c)
        component.add(c)
        HexGrid.hex_neighbors(*c).each do |nc|
          queue << nc if all_coords.include?(nc) && !visited.include?(nc) && reachable.call(nc)
        end
      end
      components << component unless component.empty?
    end

    return {} if components.empty?

    # Keep the largest component (the main room)
    main = components.max_by(&:size)

    # All non-main reachable hexes that have an explicit type → off_map.
    # Nil hexes in isolated components are left alone (type mapping will handle them).
    inaccessible = {}
    components.each do |comp|
      next if comp.equal?(main)
      comp.each do |c|
        t = typed_map[c]
        inaccessible[c] = 'off_map' if t && t != 'wall' && t != 'off_map'
      end
    end
    inaccessible
  end

  # Pass 8: Door/window passthrough -- punch passages through wall thickness.
  # For each door/window/archway/gate hex, trace outward through wall hexes
  # (and adjacent off_map hexes) away from the room interior, converting them
  # to the same passthrough type.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @return [Hash] {[hx,hy] => hex_type} hexes to reclassify
  # Hex neighbor directions form 3 axes (opposite pairs):
  #   Axis 0: N (idx 0) ↔ S (idx 3)
  #   Axis 1: NE (idx 1) ↔ SW (idx 4)
  #   Axis 2: SE (idx 2) ↔ NW (idx 5)
  # Maps direction index → axis index.
  PASSTHROUGH_DIR_AXIS = [0, 1, 2, 0, 1, 2].freeze

  def norm_v3_passthrough(typed_map, all_coords, narrow_axes: [])
    conversions = {}
    max_wall_depth = 4  # Punch through walls up to 4 hexes thick

    # Precompute grid bounds for narrow-axis off-grid checks.
    # In offset hex grids ALL neighbor directions have dy != 0, so we can't
    # use dx/dy to detect east/west vs north/south movement. Instead, check
    # if the beyond hex exits the grid boundary on the narrow axis.
    if narrow_axes.any?
      xs = all_coords.map { |c| c[0] }
      ys = all_coords.map { |c| c[1] }
      grid_x_range = (xs.min..xs.max)
      grid_y_range = (ys.min..ys.max)
    end

    # Pre-pass: Trim door clusters wider than 4 hexes parallel to the wall.
    # A hex is 2 feet, so 4 hexes = 8 feet = max door width.
    # Only applies to door-like types (door, archway, gate) — windows can span wider.
    # Since this runs before punch-through, all passthrough hexes are from
    # classification — cluster size = parallel width (no depth yet).
    max_door_width = 4
    door_like = Set.new(%w[door archway gate]).freeze
    trimmed_doors = Set.new

    door_hexes = []
    typed_map.each { |(hx, hy), t| door_hexes << [hx, hy] if door_like.include?(t) }
    door_set = Set.new(door_hexes)
    door_visited = Set.new

    door_hexes.each do |coord|
      next if door_visited.include?(coord)
      cluster = []
      queue = [coord]
      while (c = queue.shift)
        next if door_visited.include?(c)
        next unless door_set.include?(c)
        door_visited.add(c)
        cluster << c
        HexGrid.hex_neighbors(*c).each { |nc| queue << nc unless door_visited.include?(nc) }
      end
      next if cluster.size <= max_door_width

      # Determine wall axis from adjacent wall hexes
      axis_scores = [0, 0, 0]
      cluster.each do |cx, cy|
        HexGrid.hex_neighbors(cx, cy).each_with_index do |(nx, ny), dir_idx|
          next unless all_coords.include?([nx, ny])
          axis_scores[PASSTHROUGH_DIR_AXIS[dir_idx]] += 1 if typed_map[[nx, ny]] == 'wall'
        end
      end
      wall_axis = axis_scores.each_with_index.max_by { |score, _| score }[1]

      # Sort along wall axis direction, trim from edges back to wall
      sort_key = case wall_axis
                 when 0 then ->(h) { h[1] }          # N-S: sort by y
                 when 1 then ->(h) { h[0] + h[1] }   # NE-SW: x+y
                 when 2 then ->(h) { h[0] - h[1] }   # SE-NW: x-y
                 end
      cluster.sort_by!(&sort_key)

      trim_count = cluster.size - max_door_width
      trim_start = trim_count / 2
      trim_end = trim_count - trim_start
      to_trim = cluster[0...trim_start] + cluster[(cluster.size - trim_end)..]
      to_trim.each { |c| typed_map[c] = 'wall'; trimmed_doors.add(c) }
    end

    typed_map.each do |(hx, hy), hex_type|
      next unless PASSTHROUGH_TYPES.include?(hex_type)

      neighbors = HexGrid.hex_neighbors(hx, hy)

      # Determine wall orientation at this hex.
      # Score each axis by how many wall-like neighbors are in that axis.
      # The wall runs along the highest-scoring axis.
      axis_scores = [0, 0, 0]
      neighbors.each_with_index do |(nx, ny), dir_idx|
        next unless all_coords.include?([nx, ny])
        n_type = typed_map[[nx, ny]]
        if n_type == 'wall' || PASSTHROUGH_TYPES.include?(n_type)
          axis_scores[PASSTHROUGH_DIR_AXIS[dir_idx]] += 1
        end
      end
      max_axis_score = axis_scores.max
      # Clear dominant axis exists when one axis scores strictly higher than all others
      has_dominant_axis = axis_scores.count(max_axis_score) == 1

      # Only punch perpendicular to the wall — skip directions along the wall axis
      neighbors.each_with_index do |(nx, ny), dir_idx|
        next unless all_coords.include?([nx, ny])
        next unless typed_map[[nx, ny]] == 'wall'

        dx = nx - hx
        dy = ny - hy
        punch_axis = PASSTHROUGH_DIR_AXIS[dir_idx]

        if has_dominant_axis
          # Clear wall direction — only punch perpendicular to it
          next if axis_scores[punch_axis] == max_axis_score
        else
          # Ambiguous wall direction (tied axes) — fall back to opposite-side check.
          # Only punch if the opposite side has accessible interior space.
          opposite = [hx - dx, hy - dy]
          if all_coords.include?(opposite)
            opp_type = typed_map[opposite]
            next if opp_type == 'wall' || PASSTHROUGH_TYPES.include?(opp_type)
          end
        end

        # Don't start a trace from a trimmed door hex (was over-wide, reverted to wall)
        next if trimmed_doors.include?([nx, ny])

        # Trace outward from this wall hex through more wall hexes only
        current = [nx, ny]
        traced = [[nx, ny]]

        loop do
          break if traced.length >= max_wall_depth

          next_hex = [current[0] + dx, current[1] + dy]
          break unless all_coords.include?(next_hex)
          break if trimmed_doors.include?(next_hex)

          next_type = typed_map[next_hex] || conversions[next_hex]
          break unless next_type == 'wall'

          traced << next_hex
          current = next_hex
        end

        # Only punch through if the other side has accessible floor.
        beyond = [current[0] + dx, current[1] + dy]
        if all_coords.include?(beyond)
          beyond_type = typed_map[beyond] || conversions[beyond]
          reaches_floor = beyond_type.nil? ||
                          PASSTHROUGH_TYPES.include?(beyond_type) ||
                          (beyond_type != 'wall' && beyond_type != 'off_map')
        else
          # Beyond is off the map — door leads outside the room.
          # Block punch-through that exits through thin walls on narrow axes.
          blocked = false
          if narrow_axes.any?
            bx, by = beyond
            blocked = true if narrow_axes.include?(:x) && !grid_x_range.cover?(bx)
            blocked = true if narrow_axes.include?(:y) && !grid_y_range.cover?(by)
          end
          reaches_floor = !blocked
        end

        traced.each { |c| conversions[c] = hex_type } if reaches_floor
      end
    end

    conversions
  end

  # Pass 9: Lockoff detection -- find inaccessible floor areas and punch gaps.
  # Uses connected component analysis on traversable hexes. If multiple components,
  # the smaller ones are locked off. Punches through the weakest wall hex
  # (lowest shape overlap) with the shortest path to another component.
  #
  # @param typed_map [Hash] {[hx,hy] => hex_type}
  # @param all_coords [Set] all valid hex coordinates
  # @param hex_zones [Hash] {[hx,hy] => zone_id} (zone 1 = wall)
  # @return [Hash] {[hx,hy] => hex_type} wall hexes to convert to doors/open_floor
  def norm_v3_lockoff_detection(typed_map, all_coords, hex_zones: {}, l1_hints: {})
    gaps = {}
    min_area_size = 3

    # Find all traversable hexes (unclassified = floor, or traversable types)
    traversable = Set.new
    all_coords.each do |coord|
      hex_type = typed_map[coord]
      if hex_type.nil?
        traversable.add(coord)
      elsif hex_type != 'off_map'
        props = HEX_TYPE_PROPERTIES[hex_type]
        traversable.add(coord) if props.nil? || props['traversable'] != false
      end
    end

    # Connected component analysis
    components = []
    visited = Set.new

    traversable.each do |start|
      next if visited.include?(start)

      component = Set.new([start])
      queue = [start]
      visited.add(start)

      while (current = queue.shift)
        cx, cy = current
        HexGrid.hex_neighbors(cx, cy).each do |nx, ny|
          next unless traversable.include?([nx, ny])
          next if visited.include?([nx, ny])
          visited.add([nx, ny])
          component.add([nx, ny])
          queue << [nx, ny]
        end
      end

      components << component
    end

    return gaps if components.length <= 1

    # Sort by size -- largest is the main area
    components.sort_by!(&:size)
    main_component = components.pop

    # Build a set of hinted door_side directions from internal_walls L1 hints.
    # Only walls with has_door: true contribute. These are hints only — score bonuses.
    hinted_door_dirs = Set.new
    (l1_hints[:internal_walls] || []).each do |iw|
      next unless iw.is_a?(Hash) && iw['has_door']
      dir = L1_DIR_MAP[iw['door_side']]
      hinted_door_dirs.add(dir) if dir
    end

    # Precompute main_component centroid for direction checks
    main_cx = main_component.sum { |x, _| x }.to_f / main_component.size
    main_cy = main_component.sum { |_, y| y }.to_f / main_component.size

    # For each locked-off area, find the best wall hex to punch through
    components.each do |locked_area|
      next if locked_area.size < min_area_size

      best_gap = nil
      best_score = Float::INFINITY # lower = better (weakness + distance)

      # Check all wall hexes adjacent to this locked area
      locked_area.each do |lx, ly|
        HexGrid.hex_neighbors(lx, ly).each do |wx, wy|
          next unless all_coords.include?([wx, wy])
          wall_type = typed_map[[wx, wy]]
          next unless WALL_EXTENSION_TYPES.include?(wall_type)

          # BFS through wall hexes toward main component
          punch_visited = Set.new([[wx, wy]])
          punch_queue = [[wx, wy]]
          found = false

          while (pc = punch_queue.shift)
            px, py = pc
            HexGrid.hex_neighbors(px, py).each do |nx, ny|
              if main_component.include?([nx, ny])
                found = true
                break
              end
              next unless all_coords.include?([nx, ny])
              next if punch_visited.include?([nx, ny])
              next unless WALL_EXTENSION_TYPES.include?(typed_map[[nx, ny]])
              punch_visited.add([nx, ny])
              punch_queue << [nx, ny]
            end
            break if found
          end

          next unless found

          # Prefer punching through hexes with low wall coverage (weaker walls).
          # Add a large penalty for hexes adjacent to off_map (outer perimeter) so
          # inner rooms near a corner don't get doors punched into the outer wall.
          wall_strength = @hex_wall_coverage&.dig([wx, wy]) || (hex_zones[[wx, wy]] == 1 ? 1.0 : 0.0)
          outer_penalty = HexGrid.hex_neighbors(wx, wy).any? { |nx, ny|
            typed_map[[nx, ny]] == 'off_map'
          } ? 10.0 : 0.0

          # L1 hint bonus: if this wall hex aligns with a hinted door direction,
          # reduce its score slightly to prefer it. Hint-only — never blocks a candidate.
          hint_bonus = 0.0
          if hinted_door_dirs.any?
            dx = wx - main_cx
            dy = wy - main_cy
            wall_dir = approx_compass_direction(dx, dy)
            hint_bonus = -0.3 if hinted_door_dirs.include?(wall_dir)
          end

          score = wall_strength + punch_visited.size * 0.5 + outer_penalty + hint_bonus

          if score < best_score
            best_score = score
            best_gap = punch_visited
          end
        end
      end

      next unless best_gap

      # Convert -- single hex becomes open_floor, multi-hex becomes door
      gap_type = best_gap.size == 1 ? 'open_floor' : 'door'
      best_gap.each { |coord| gaps[coord] = gap_type }
    end

    gaps
  end

  # Normalize v3: 9-pass shape-aware pipeline.
  # Replaces normalize_v2 with smarter passes using a shape map
  # that identifies structural boundaries via contour detection.
  #
  # @param chunk_results [Array<Hash>] [{ 'x' => hx, 'y' => hy, 'hex_type' => type }, ...]
  # @param image [Vips::Image] the battle map image
  # @param pixel_map [Hash] hex pixel mapping info (must include :hex_size)
  # @param hex_coords [Array] all hex coordinates
  # @param min_x [Numeric] minimum hex x
  # @param min_y [Numeric] minimum hex y
  # @param context [NormalizationContext, nil] grouped analysis artifacts and hints
  # @param edge_map [Vips::Image, nil] legacy compatibility keyword; prefer context:
  # @param zone_map [Vips::Image, nil] legacy compatibility keyword; prefer context:
  # @param depth_map [Vips::Image, nil] legacy compatibility keyword; prefer context:
  # @param image_path [String, nil] legacy compatibility keyword; prefer context:
  # @return [Array<Hash>] normalized results
  def normalize_v3(chunk_results, image, pixel_map, hex_coords, min_x, min_y, context: nil,
                   edge_map: nil, zone_map: nil, depth_map: nil, image_path: nil,
                   type_properties: {}, present_type_names: [], prefetched_sam_threads: {}, l1_hints: {})
    hex_size = pixel_map[:hex_size]
    return chunk_results if hex_size.nil? || chunk_results.empty?

    context ||= NormalizationContext.new(
      edge_map: edge_map,
      zone_map: zone_map,
      depth_map: depth_map,
      image_path: image_path,
      type_properties: type_properties,
      present_type_names: present_type_names,
      prefetched_sam_threads: prefetched_sam_threads,
      l1_hints: l1_hints
    )
    edge_map = context.edge_map
    zone_map = context.zone_map
    depth_map = context.depth_map
    image_path = context.image_path
    type_properties = context.type_properties
    present_type_names = context.present_type_names
    prefetched_sam_threads = context.prefetched_sam_threads
    l1_hints = context.l1_hints

    @inspection_norm_passes = []

    # Build typed_map and ascending_directions from chunk results
    typed_map = {}
    ascending_directions = {}
    chunk_results.each do |r|
      next unless r['x'] && r['y']
      coord = [r['x'], r['y']]
      typed_map[coord] = r['hex_type']
      ascending_directions[coord] = r['ascending_direction'] if r['ascending_direction']
    end

    all_coords = Set.new(hex_coords)

    # Kick off SAM2 auto-segmentation in a background thread while other setup continues.
    # SAM2 masks replace both depth shapes and bilateral/Sobel image shapes.
    sam2_masks_dir = nil
    sam2_thread = nil
    if image_path && File.exist?(image_path.to_s) && ReplicateSam2Service.available?
      sam2_tmp = Dir.mktmpdir('sam2_masks_')
      sam2_thread = Thread.new do
        result = ReplicateSam2Service.auto_segment(image_path, masks_dir: sam2_tmp)
        if result[:success]
          warn "[AIBattleMapGenerator] SAM2: #{result[:mask_count]} masks downloaded"
          sam2_tmp
        else
          warn "[AIBattleMapGenerator] SAM2 failed: #{result[:error]} — falling back to depth+bilateral shapes"
          FileUtils.rm_rf(sam2_tmp) rescue nil
          nil
        end
      rescue StandardError => e
        warn "[AIBattleMapGenerator] SAM2 thread error: #{e.message}"
        nil
      end
    end

    # Pre-compute per-hex zone from pixel-level zone map
    # Zone IDs: 0=off_map, 1=wall, 2=floor, 3=object
    hex_zones = {}
    hex_shapes = {}
    hex_image_shapes = {}
    if @zone_map_path && File.exist?(@zone_map_path)
      # Join SAM2 thread — it runs in parallel with zone map generation upstream
      sam2_masks_dir = sam2_thread&.value
      classification = classify_hexes_with_overlap(
        @zone_map_path, hex_size,
        depth_path: @depth_estimation_path,
        image_path: image_path,
        sam2_masks_dir: sam2_masks_dir,
        debug_dir: inspection_dir
      )
      if classification
        hex_zones = classification[:hex_zones]
        hex_shapes = classification[:hex_shapes] || {}
        hex_image_shapes = classification[:hex_image_shapes] || {}
        warn "[AIBattleMapGenerator] Normalize v3: pixel classification (#{hex_zones.length} hexes: #{hex_zones.values.tally}, #{hex_shapes.values.uniq.length} depth shapes, #{hex_image_shapes.values.uniq.length} image shapes)"
        save_inspection_metadata(:pixel_classification, {
          total_hexes: hex_zones.length,
          zone_distribution: hex_zones.values.tally,
          depth_shapes_count: hex_shapes.values.uniq.length,
          hexes_in_shapes: hex_shapes.length,
          image_shapes_count: hex_image_shapes.values.uniq.length,
          hexes_in_image_shapes: hex_image_shapes.length,
        }) rescue nil
      end
    end
    # Clean up SAM2 temp dir now that classification is done
    FileUtils.rm_rf(sam2_masks_dir) if sam2_masks_dir && Dir.exist?(sam2_masks_dir.to_s)

    if hex_zones.empty? && zone_map
      hex_zones = build_hex_zone_map(zone_map, hex_size)
      warn "[AIBattleMapGenerator] Normalize v3: zone map sampled fallback (#{hex_zones.length} hexes: #{hex_zones.values.tally})" if hex_zones.any?
    end
    hex_zones ||= {}

    # Pre-compute per-hex depth values from depth map
    hex_depths = build_hex_depth_map(depth_map, hex_size) if depth_map
    hex_depths ||= {}
    warn "[AIBattleMapGenerator] Normalize v3: depth map sampled (#{hex_depths.length} hexes)" if hex_depths.any?

    # Color features no longer needed (terrain color pass removed)
    color_features = {}

    # --- Pass 1: Off-map flood ---
    off_map_fills = norm_v3_off_map_flood(typed_map, all_coords, image: image, hex_size: hex_size, hex_zones: hex_zones)
    off_map_fills.each { |coord| typed_map[coord] = 'off_map' }
    warn "[AIBattleMapGenerator] Pass 1 (off-map flood): #{off_map_fills.length}" if off_map_fills.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_01_offmap.png') rescue nil
    @inspection_norm_passes << { name: 'off_map_flood', count: off_map_fills.length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 2: Zone validation ---
    zv = norm_v3_zone_validation(typed_map, hex_zones: hex_zones, type_properties: type_properties)
    zv[:demotions].each { |coord| typed_map.delete(coord) }
    zv[:overrides].each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 2 (zone validation): #{zv[:demotions].length} demoted, #{zv[:overrides].length} overridden" if zv[:demotions].any? || zv[:overrides].any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_02_zone_validation.png') rescue nil
    @inspection_norm_passes << { name: 'zone_validation', count: zv[:demotions].length + zv[:overrides].length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 2.5: Border wall guarantee ---
    # Enclosed (indoor) rooms must have wall on the outermost row of hexes
    # on each edge. This catches edges where zone map wall coverage is thin
    # or objects sit against the wall and break the elevation band.
    unless room.outdoor_room?
      border_walls = norm_v3_border_walls(typed_map, all_coords)
      border_walls.each { |coord, type| typed_map[coord] = type }
      warn "[AIBattleMapGenerator] Pass 2.5 (border walls): #{border_walls.length} enforced" if border_walls.any?
      render_inspection_overlay(typed_map, @inspection_base, '07_norm_02_5_border_walls.png') rescue nil
      @inspection_norm_passes << { name: 'border_walls', count: border_walls.length, distribution: typed_map.values.tally } rescue nil
    end

    # --- Pass 3: Shape snapping ---
    snap = norm_v3_shape_snap(typed_map, all_coords, hex_zones: hex_zones, hex_shapes: hex_shapes)
    snap[:additions].each { |coord, type| typed_map[coord] = type }
    snap[:trims].each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 3 (shape snap): #{snap[:additions].length} added, #{snap[:trims].length} trimmed" if snap[:additions].any? || snap[:trims].any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_03_shape_snap.png') rescue nil
    @inspection_norm_passes << { name: 'shape_snap', count: snap[:additions].length + snap[:trims].length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 3b: Flat shape snap ---
    flat_snap = norm_v3_flat_shape_snap(typed_map, all_coords,
                                        hex_image_shapes: hex_image_shapes,
                                        hex_zones: hex_zones)
    flat_snap[:additions].each { |coord, type| typed_map[coord] = type }
    if flat_snap[:additions].any?
      warn "[AIBattleMapGenerator] Pass 3b (flat shape snap): #{flat_snap[:additions].length} added"
      render_inspection_overlay(typed_map, @inspection_base, '07_norm_03b_flat_snap.png') rescue nil
      @inspection_norm_passes << { name: 'flat_shape_snap', count: flat_snap[:additions].length, distribution: typed_map.values.tally } rescue nil
    end

    # --- Pass 4: Wall flood ---
    wall_ext = norm_v3_wall_flood(typed_map, all_coords, hex_zones: hex_zones)
    wall_ext.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 4 (wall flood): #{wall_ext.length} extended" if wall_ext.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_04_wall_flood.png') rescue nil
    @inspection_norm_passes << { name: 'wall_flood', count: wall_ext.length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 5: Elevation fix ---
    elevations = norm_v3_elevation_fix(typed_map, all_coords, ascending_directions, hex_depths: hex_depths, hex_zones: hex_zones)
    warn "[AIBattleMapGenerator] Pass 5 (elevation fix): #{elevations.length} hexes with elevation" if elevations.any?

    # --- Pass 6: Elevated objects ---
    elev_updates = norm_v3_elevated_objects(typed_map, elevations)
    elevations.merge!(elev_updates)
    warn "[AIBattleMapGenerator] Pass 6 (elevated objects): #{elev_updates.length} stacked" if elev_updates.any?

    # --- Pass 7: Terrain color pass --- REMOVED (replaced by shape snapping)
    # Shadow boundaries caused more harm than good.

    # --- Pass 7.5: SAM authoritative features (windows, water) ---
    if image_path
      sam_detections = norm_v3_sam_features(typed_map, all_coords,
                                            hex_zones: hex_zones, image_path: image_path, hex_size: hex_size,
                                            present_type_names: present_type_names,
                                            prefetched_sam_threads: prefetched_sam_threads)
      sam_detections.each { |coord, type| typed_map[coord] = type }
      warn "[AIBattleMapGenerator] Pass 7.5 (SAM features): #{sam_detections.length} detected" if sam_detections.any?
      render_inspection_overlay(typed_map, @inspection_base, '07_norm_07_5_sam.png') rescue nil
      @inspection_norm_passes << { name: 'sam_features', count: sam_detections.length, distribution: typed_map.values.tally } rescue nil
    end

    # --- Pass 7.5c: Exit-guided door placement ---
    exit_doors = norm_v3_exit_guided_doors(typed_map, all_coords, hex_zones: hex_zones, l1_hints: l1_hints)
    exit_doors.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 7.5c (exit doors): #{exit_doors.length} placed" if exit_doors.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_07_5c_exit_doors.png') rescue nil
    @inspection_norm_passes << { name: 'exit_doors', count: exit_doors.length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 7.6: Wall thinning → door detection ---
    wall_doors = norm_v3_wall_door_detection(typed_map, all_coords)
    wall_doors.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 7.6 (wall doors): #{wall_doors.length} detected" if wall_doors.any?

    # --- Pass 7.7: Door joining — fill single-wall gaps between door hexes ---
    door_joins = norm_v3_door_join(typed_map, all_coords, hex_zones: hex_zones)
    door_joins.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 7.7 (door join): #{door_joins.length} gaps filled" if door_joins.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_07_7_doorjoin.png') rescue nil

    # --- Pass 8: Door/window passthrough ---
    # Compute narrow axes so passthrough doesn't punch through thin walls to off-grid.
    # Use visual row count (rows/2) since offset hex grids double Y values.
    cols_count = all_coords.map(&:first).uniq.size
    rows_count = all_coords.map(&:last).uniq.size
    visual_rows_count = (rows_count + 1) / 2
    narrow = []
    narrow << :x if cols_count < 5
    narrow << :y if visual_rows_count < 5
    passthroughs = norm_v3_passthrough(typed_map, all_coords, narrow_axes: narrow)
    passthroughs.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 8 (passthrough): #{passthroughs.length} converted" if passthroughs.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_08_passthrough.png') rescue nil
    @inspection_norm_passes << { name: 'passthrough', count: passthroughs.length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 9: Lockoff detection ---
    lock_gaps = norm_v3_lockoff_detection(typed_map, all_coords, hex_zones: hex_zones, l1_hints: l1_hints)
    lock_gaps.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 9 (lockoff): #{lock_gaps.length} gaps punched" if lock_gaps.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_09_lockoff.png') rescue nil
    @inspection_norm_passes << { name: 'lockoff', count: lock_gaps.length, distribution: typed_map.values.tally } rescue nil

    # --- Pass 9.5: Cleanup errant object hexes in wall/off_map zones ---
    errant = norm_v3_cleanup_errant(typed_map, all_coords, hex_zones: hex_zones)
    errant.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 9.5 (errant cleanup): #{errant.length} cleared" if errant.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_09_5_cleanup.png') rescue nil

    # --- Pass 9.8: Inaccessible hex removal ---
    inaccessible = norm_v3_inaccessible(typed_map, all_coords, hex_zones: hex_zones)
    inaccessible.each { |coord, type| typed_map[coord] = type }
    warn "[AIBattleMapGenerator] Pass 9.8 (inaccessible): #{inaccessible.length} removed" if inaccessible.any?
    render_inspection_overlay(typed_map, @inspection_base, '07_norm_09_8_inaccessible.png') rescue nil

    # --- Pass 10: Off-map to wall shell ---
    # For indoor rooms, convert the innermost ring of off_map hexes to walls.
    # This ensures wall-interacting abilities (bouncing shots, etc.) work while
    # the off_map boundary prevented wall flood from eating narrow interiors.
    unless room.outdoor_room?
      shell_walls = norm_v3_off_map_wall_shell(typed_map)
      shell_walls.each { |coord| typed_map[coord] = 'wall' }
      warn "[AIBattleMapGenerator] Pass 10 (off_map wall shell): #{shell_walls.length} converted" if shell_walls.any?
    end

    # --- Assemble result ---
    result = typed_map.map do |(hx, hy), hex_type|
      entry = { 'x' => hx, 'y' => hy, 'hex_type' => hex_type }
      entry['elevation'] = elevations[[hx, hy]] if elevations[[hx, hy]]
      entry['ascending_direction'] = ascending_directions[[hx, hy]] if ascending_directions[[hx, hy]]
      entry
    end

    # Save final normalization overlay and metadata for inspection
    begin
      render_inspection_overlay(typed_map, @inspection_base, '08_norm_final.png')
      @inspection_norm_passes << { name: 'final', count: result.length, distribution: typed_map.values.tally }
      save_inspection_metadata(:normalization_passes, @inspection_norm_passes)
    rescue StandardError => e
      warn "[AIBattleMapGenerator] Final norm inspection save failed: #{e.message}"
    end

    warn "[AIBattleMapGenerator] Normalize v3: #{chunk_results.length} → #{result.length}"
    result
  end

  # ==================================================
  # Orchestration: Overview-Based Hex Classification
  # ==================================================

  # Main entry point for advanced hex classification.
  # Uses overview pre-pass + spatial chunking + constrained classification + normalization.
  # Falls back to legacy analysis if overview fails.
  #
  # @param local_path [String] path to the battle map image (unlabeled)
  # @return [Array<Hash>] hex data ready for persist_hex_data
  def analyze_hexes_with_overview(local_path)
    return [] unless local_path && File.exist?(local_path)

    require 'vips'

    hex_coords = generate_hex_coordinates
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min
    room_w, room_h = inflated_room_dimensions

    warn "[AIBattleMapGenerator] Overview pipeline: #{hex_coords.length} hexes, room #{room_w}x#{room_h}ft (inflated)"

    # Step 1: Compute hex grid + pixel map from image dimensions
    base = Vips::Image.new_from_file(local_path)
    @inspection_base = base
    img_width = base.width
    img_height = base.height
    hex_pixel_map = build_hex_pixel_map(hex_coords, min_x, min_y, img_width, img_height)

    @coord_lookup = {}
    @inspection_hex_size = hex_pixel_map[:hex_size]
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]
      @coord_lookup[[info[:hx], info[:hy]]] = info
    end

    # Step 2: Build spatial chunks
    chunks = build_spatial_chunks(hex_coords, CHUNK_SIZE)

    # Step 3: Run overview pass (scene understanding, type discovery)
    overview_data = run_overview_pass(local_path)
    unless overview_data
      warn "[AIBattleMapGenerator] Overview pass failed, falling back to legacy"
      return analyze_hexes_legacy(local_path)
    end
    @overview_classification_data = overview_data

    scene_description = overview_data['scene_description'] || ''
    map_layout = overview_data['map_layout'] || ''
    present_types = overview_data['present_types'] || []
    # Build constrained type list — add off_map if missing, remove open_floor/other
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('open_floor')
    type_names.delete('other')
    type_names << 'off_map' unless type_names.include?('off_map')
    type_names.uniq!

    # Filter out custom types with no tactical effect (traversable floor decorations)
    standard_types = SIMPLE_HEX_TYPES.to_set
    present_types.reject! do |t|
      name = t['type_name']
      next false if standard_types.include?(name) # always keep standard types

      # Drop custom types that are just floor: traversable, no cover/concealment, no wall/exit, no hazards, no elevation
      t['traversable'] &&
        !t['provides_cover'] &&
        !t['provides_concealment'] &&
        !t['is_wall'] &&
        !t['is_exit'] &&
        !t['difficult_terrain'] &&
        (t['elevation'] || 0).zero? &&
        (t['hazards'].nil? || t['hazards'].empty?)
    end
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('off_map')
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
      props['hazards'] = Array(t['hazards']).select { |h| OVERVIEW_HAZARD_TYPES.include?(h) } if t['hazards']
      overview_type_properties[t['type_name']] = props
    end

    warn "[AIBattleMapGenerator] Overview found #{type_names.length} types: #{type_names.join(', ')}"

    # Step 4: Fire edge detection in parallel (non-blocking)
    # Depth estimation — runs in parallel with edge detection and classification
    depth_thread = Thread.new do
      if ReplicateDepthService.available?
        depth_source = @shadowed_image_path || local_path
        ReplicateDepthService.estimate(depth_source)
      else
        { success: false, error: 'Replicate not available' }
      end
    end

    # Priority: shadow-aware (OpenCV) → Replicate Canny → local Sobel
    edge_thread = Thread.new do
      warn "[AIBattleMapGenerator] Starting parallel edge detection (shadow-aware primary)"
      shadow_edge = generate_shadow_aware_edge_map(local_path)
      if shadow_edge
        { success: true, edge_map: shadow_edge, source: :shadow_aware }
      else
        local = generate_local_edge_map(base)
        if local
          { success: true, edge_map: local, source: :local_sobel }
        else
          { success: false, error: 'all edge detection methods failed' }
        end
      end
    end

    # Step 5: Run chunk workers in parallel (Haiku with tool calling)
    api_key = AIProviderService.api_key_for('anthropic')
    all_chunk_results = []
    results_mutex = Mutex.new
    semaphore = Mutex.new
    active_count = 0
    max_wait = 300

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
          # Filter out hexes that extend beyond the image boundary
          visible_chunk = filter_partial_edge_hexes(chunk, img_width, img_height)
          next if visible_chunk.empty?

          # Build sequential labels for this chunk
          seq = build_sequential_labels(visible_chunk)
          hex_list_str = visible_chunk.sort_by { |hx, hy| [hy, hx] }.map { |hx, hy| seq[:labels][[hx, hy]] }.join(', ')

          # Crop image, overlay sequential labels on crop
          crop_result = crop_image_for_chunk(base, visible_chunk, hex_pixel_map, img_width, img_height)
          labeled_crop = overlay_sequential_labels_on_crop(crop_result, visible_chunk, seq[:labels])
          cropped_base64 = Base64.strict_encode64(labeled_crop)

          # Build prompt and tool with full type list (no per-chunk filtering)
          chunk_tools = build_chunk_tool(type_names)
          prompt = build_grouped_chunk_prompt(hex_list_str, scene_description, type_names,
                                              grid_pos: grid_pos, map_layout: map_layout)

          messages = [{
            role: 'user',
            content: [
              { type: 'image', source: { type: 'base64', media_type: 'image/png', data: cropped_base64 } },
              { type: 'text', text: prompt }
            ]
          }]

          response = LLM::Adapters::AnthropicAdapter.generate(
            messages: messages,
            model: CLASSIFICATION_MODEL,
            api_key: api_key,
            tools: chunk_tools,
            options: { max_tokens: 4096, timeout: 120, temperature: 0 }
          )

          if response[:tool_calls]&.any?
            args = response[:tool_calls].first[:arguments]
            objects = args['objects'] || []
            content = { 'objects' => objects }.to_json
            chunk_results = parse_grouped_chunk(content, seq[:reverse], allowed_types: chunk_types)
            results_mutex.synchronize { all_chunk_results.concat(chunk_results) }
          else
            warn "[AIBattleMapGenerator] Chunk #{chunk_idx + 1}/#{chunks.length} failed: #{response[:error] || 'no tool call returned'}"
          end
        ensure
          semaphore.synchronize { active_count -= 1 }
        end
      end
    end

    threads.each { |t| t.join(max_wait) }

    warn "[AIBattleMapGenerator] Classification complete: #{all_chunk_results.length} notable hexes from #{chunks.length} chunks"

    # Collect edge detection and depth estimation results (should be done by now)
    edge_map = collect_edge_result(edge_thread, base)
    depth_map, zone_map = collect_depth_result(depth_thread, edge_map, base, hex_pixel_map[:hex_size], local_path)

    # Step 6: Visual similarity normalization
    pre_norm_dist = type_distribution(all_chunk_results)
    warn "[AIBattleMapGenerator] Pre-normalization type distribution: #{pre_norm_dist.sort_by { |_, v| -v }.to_h}"

    if @debug
      warn "[AIBattleMapGenerator] DEBUG: Skipping normalization (#{all_chunk_results.length} raw results)"
    else
      before_count = all_chunk_results.length
      normalization_context = NormalizationContext.new(
        edge_map: edge_map,
        zone_map: zone_map,
        depth_map: depth_map,
        image_path: local_path,
        type_properties: overview_type_properties,
        present_type_names: type_names
      )
      all_chunk_results = normalize_v3(all_chunk_results, base, hex_pixel_map, hex_coords, min_x, min_y,
                                       context: normalization_context)
      delta = all_chunk_results.length - before_count
      post_norm_dist = type_distribution(all_chunk_results)
      warn "[AIBattleMapGenerator] Post-normalization type distribution: #{post_norm_dist.sort_by { |_, v| -v }.to_h}"
      warn "[AIBattleMapGenerator] Normalization v3: #{before_count} → #{all_chunk_results.length} (#{delta >= 0 ? "+#{delta}" : delta})"
    end

    @final_typed_map = all_chunk_results.each_with_object({}) { |r, h| h[[r['x'], r['y']]] = r['hex_type'] }

    # Step 7: Map results to RoomHex format
    map_results_to_room_hex(all_chunk_results, hex_coords, min_x, min_y, overview_type_properties)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Overview pipeline failed: #{e.class}: #{e.message}"
    warn e.backtrace&.first(5)&.join("\n")
    # Fall back to legacy analysis
    analyze_hexes_legacy(local_path)
  end


  # CV-first hex classification pipeline.
  # Uses Grounded SAM for segmentation + Depth Anything v2 for elevation.
  # Falls back to analyze_hexes_with_overview if Replicate unavailable.
  #
  # @param local_path [String] path to the battle map image (shadow-free preferred)
  # @param depth_image_path [String, nil] path to image for depth estimation (use shadowed version if available, shadows help depth models)
  # @return [Array<Hash>] hex data ready for persist_hex_data
  def analyze_hexes_with_cv(local_path, depth_image_path: nil)
    return analyze_hexes_with_overview(local_path) unless ReplicateSamService.available?
    return [] unless local_path && File.exist?(local_path)

    require 'vips'

    hex_coords = generate_hex_coordinates
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min

    # Step 1: Build hex pixel map
    base = Vips::Image.new_from_file(local_path)
    img_width = base.width
    img_height = base.height
    hex_pixel_map = build_hex_pixel_map(hex_coords, min_x, min_y, img_width, img_height)

    @coord_lookup = {}
    @inspection_hex_size = hex_pixel_map[:hex_size]
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]
      @coord_lookup[[info[:hx], info[:hy]]] = info
    end

    # Step 2: L1 overview (type discovery)
    overview_data = run_overview_pass(local_path)
    unless overview_data
      warn "[AIBattleMapGenerator] CV pipeline: L1 failed, falling back to chunk pipeline"
      return analyze_hexes_with_overview(local_path)
    end

    present_types = overview_data['present_types'] || []
    type_names = present_types.map { |t| t['type_name'] }
    type_names.delete('open_floor')
    type_names.delete('other')
    type_names.uniq!

    # Build properties lookup
    overview_type_properties = {}
    present_types.each do |t|
      props = {}
      %w[traversable provides_cover provides_concealment is_wall is_exit difficult_terrain].each do |key|
        props[key] = t[key] unless t[key].nil?
      end
      props['elevation'] = t['elevation'] unless t['elevation'].nil?
      props['water_depth'] = t['water_depth'] if WATER_DEPTHS.include?(t['water_depth'])
      props['hazards'] = Array(t['hazards']).select { |h| OVERVIEW_HAZARD_TYPES.include?(h) } if t['hazards']
      overview_type_properties[t['type_name']] = props
    end

    # Step 3: Fire SAM call per type + depth + edges in parallel
    # One SAM call per individual type gives us a clean mask for each object type
    warn "[AIBattleMapGenerator] CV pipeline: #{type_names.length} SAM calls + depth + edges"

    threads = {}

    # SAM calls — one per type name (e.g., "barrel", "chair", "wall")
    type_names.each do |type_name|
      threads["sam_#{type_name}"] = Thread.new do
        ReplicateSamService.segment_with_samg_fallback(local_path, type_name, suffix: "_sam_#{type_name}")
      end
    end

    # Depth estimation — use shadowed image if available (shadows help depth models)
    depth_source = depth_image_path || local_path
    threads[:depth] = Thread.new do
      ReplicateDepthService.estimate(depth_source)
    end

    # Edge detection (shadow-aware)
    threads[:edges] = Thread.new do
      shadow_edge = generate_shadow_aware_edge_map(local_path)
      if shadow_edge
        { success: true, edge_map: shadow_edge }
      else
        local = generate_local_edge_map(base)
        local ? { success: true, edge_map: local } : { success: false }
      end
    end

    # Step 4: Collect results
    max_wait = 120
    threads.each { |_, t| t.join(max_wait) }

    # Collect per-type masks: { "wall" => Vips::Image, "barrel" => Vips::Image, ... }
    sam_type_masks = {}
    type_names.each do |type_name|
      result = threads["sam_#{type_name}"]&.value
      if result&.dig(:success) && result[:mask_path] && File.exist?(result[:mask_path])
        mask = Vips::Image.new_from_file(result[:mask_path])
        # Resize to match base image if needed
        if mask.width != base.width || mask.height != base.height
          mask = mask.resize(base.width.to_f / mask.width, vscale: base.height.to_f / mask.height)
        end
        sam_type_masks[type_name] = mask
        warn "[AIBattleMapGenerator] SAM #{type_name}: mask loaded (#{mask.width}x#{mask.height})"
      elsif result&.dig(:no_detections)
        warn "[AIBattleMapGenerator] SAM #{type_name}: no detections"
      else
        warn "[AIBattleMapGenerator] SAM #{type_name}: failed (#{result&.dig(:error) || 'timeout'})"
      end
    end

    depth_map = nil
    depth_result = threads[:depth]&.value
    if depth_result&.dig(:success) && depth_result[:depth_path]
      depth_map = Vips::Image.new_from_file(depth_result[:depth_path])
      warn "[AIBattleMapGenerator] Depth map loaded: #{depth_map.width}x#{depth_map.height}"
      room.update(depth_map_path: depth_result[:depth_path])
    end

    edge_map = nil
    edge_result = threads[:edges]&.value
    if edge_result&.dig(:success) && edge_result[:edge_map]
      edge_map = edge_result[:edge_map]
    end

    # Step 5: Map per-type masks to hex types
    hex_size = hex_pixel_map[:hex_size]
    all_coords = Set.new(hex_coords)
    typed_map = map_type_masks_to_hexes(sam_type_masks, hex_size, all_coords)

    warn "[AIBattleMapGenerator] CV pipeline: #{typed_map.length} hexes classified from #{sam_type_masks.length} type masks"

    # Step 6: Off-map assignment (hexes not covered by any mask)
    all_coords.each do |coord|
      typed_map[coord] = 'off_map' unless typed_map.key?(coord)
    end

    # Step 7: Elevation from depth map
    elevations = {}
    if depth_map
      elevations = map_depth_to_elevation(depth_map, typed_map, hex_size)
    end

    # Step 8: Simplified normalization (passthrough + lockoff only)
    passthroughs = norm_v3_passthrough(typed_map, all_coords)
    passthroughs.each { |coord, type| typed_map[coord] = type }

    lock_gaps = norm_v3_lockoff_detection(typed_map, all_coords)
    lock_gaps.each { |coord, type| typed_map[coord] = type }

    # Step 9: Assemble results
    result = typed_map.map do |(hx, hy), hex_type|
      entry = { 'x' => hx, 'y' => hy, 'hex_type' => hex_type }
      entry['elevation'] = elevations[[hx, hy]] if elevations[[hx, hy]]
      entry
    end

    warn "[AIBattleMapGenerator] CV pipeline complete: #{result.length} hexes"
    map_results_to_room_hex(result, hex_coords, min_x, min_y, overview_type_properties)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] CV pipeline failed: #{e.class}: #{e.message}"
    warn e.backtrace&.first(5)&.join("\n")
    analyze_hexes_with_overview(local_path)
  end

  # Map SAM segmentation masks to hex types.
  # For each hex, checks coverage from each category mask.
  # Uses 50% overlap for standard types, skeleton for walls.
  #
  # @param sam_masks [Hash] { category => Vips::Image }
  # @param sam_categories [Hash] { category => "dot . sep . query" }
  # @param hex_size [Numeric] pixel size of hexes
  # @param all_coords [Set] all valid hex coordinates
  # @return [Hash] { [hx,hy] => hex_type }
  def map_sam_masks_to_hexes(sam_masks, sam_categories, hex_size, all_coords)
    typed_map = {}
    return typed_map if sam_masks.empty?

    # For each category, convert mask to binary and compute per-hex overlap
    category_results = {} # { category => { [hx,hy] => overlap_pct } }

    sam_masks.each do |category, mask_image|
      # Convert to grayscale binary (any non-black pixel = mask)
      gray = mask_image.bands > 1 ? mask_image.colourspace(:b_w).extract_band(0) : mask_image
      binary = (gray > 30).ifthenelse(255, 0).cast(:uchar)

      # Handle wall category specially via skeleton
      if category == :structure
        wall_hexes = detect_wall_hexes_via_skeleton(binary, hex_size)
        wall_hexes.each { |coord| typed_map[coord] = 'wall' }
      end

      hex_overlaps = {}
      @coord_lookup.each do |(hx, hy), info|
        r = (hex_size * 0.9).to_i
        x1 = [info[:px].round - r, 0].max
        y1 = [info[:py].round - r, 0].max
        w = [r * 2, binary.width - x1].min
        h = [r * 2, binary.height - y1].min
        next if w < 2 || h < 2

        patch = binary.crop(x1, y1, w, h)
        coverage = patch.avg / 255.0
        hex_overlaps[[hx, hy]] = coverage if coverage > 0.05
      end

      category_results[category] = hex_overlaps
    end

    # Assign types by priority (higher priority categories override lower)
    SAM_CATEGORY_PRIORITY.each do |category|
      overlaps = category_results[category]
      next unless overlaps

      query_types = (sam_categories[category] || '').split(' . ').map(&:strip)
      primary_type = query_types.first
      next unless primary_type

      overlaps.each do |(hx, hy), coverage|
        next if typed_map[[hx, hy]] && SAM_CATEGORY_PRIORITY.index(category).to_i <=
                SAM_CATEGORY_PRIORITY.index(type_category(typed_map[[hx, hy]])).to_i

        if category == :structure
          # Walls already handled by skeleton. Non-wall structure types use 50% threshold.
          next if typed_map[[hx, hy]] == 'wall'
          typed_map[[hx, hy]] = primary_type if coverage >= 0.5
        else
          typed_map[[hx, hy]] = primary_type if coverage >= 0.5
        end
      end
    end

    typed_map
  end

  # Map per-type SAM masks to hex types.
  # Each mask corresponds to a single object type (e.g., "barrel", "wall", "chair").
  # For each hex, check coverage from each type mask.
  # Wall type uses skeleton detection for precision; others use 40% overlap threshold.
  # When multiple types overlap a hex, higher-priority category wins.
  #
  # @param type_masks [Hash] { "type_name" => Vips::Image }
  # @param hex_size [Numeric] pixel size of hexes
  # @param all_coords [Set] all valid hex coordinates
  # @return [Hash] { [hx,hy] => hex_type }
  def map_type_masks_to_hexes(type_masks, hex_size, all_coords)
    typed_map = {}
    return typed_map if type_masks.empty?

    # Compute per-hex coverage for each type
    type_coverages = {} # { "type_name" => { [hx,hy] => coverage_pct } }

    type_masks.each do |type_name, mask_image|
      gray = mask_image.bands > 1 ? mask_image.colourspace(:b_w).extract_band(0) : mask_image
      binary = (gray > 30).ifthenelse(255, 0).cast(:uchar)

      # Wall type gets skeleton detection for precision
      if type_name == 'wall'
        wall_hexes = detect_wall_hexes_via_skeleton(binary, hex_size)
        wall_hexes.each { |coord| typed_map[coord] = 'wall' }
      end

      hex_overlaps = {}
      @coord_lookup.each do |(hx, hy), info|
        r = (hex_size * 0.9).to_i
        x1 = [info[:px].round - r, 0].max
        y1 = [info[:py].round - r, 0].max
        w = [r * 2, binary.width - x1].min
        h = [r * 2, binary.height - y1].min
        next if w < 2 || h < 2

        patch = binary.crop(x1, y1, w, h)
        coverage = patch.avg / 255.0
        hex_overlaps[[hx, hy]] = coverage if coverage > 0.05
      end

      type_coverages[type_name] = hex_overlaps
    end

    # Assign types by priority — higher-priority category types override lower
    # Sort types so higher-priority categories are applied last (overriding)
    sorted_types = type_coverages.keys.sort_by do |tn|
      SAM_CATEGORY_PRIORITY.index(type_category(tn)).to_i
    end

    sorted_types.each do |type_name|
      overlaps = type_coverages[type_name]
      category = type_category(type_name)

      overlaps.each do |(hx, hy), coverage|
        existing = typed_map[[hx, hy]]
        if existing
          existing_cat_idx = SAM_CATEGORY_PRIORITY.index(type_category(existing)).to_i
          new_cat_idx = SAM_CATEGORY_PRIORITY.index(category).to_i
          # Skip if existing type has equal or higher priority
          next if existing_cat_idx >= new_cat_idx
        end

        # Wall hexes from skeleton already assigned — skip re-assignment for wall type
        next if type_name == 'wall' && typed_map[[hx, hy]] == 'wall'

        typed_map[[hx, hy]] = type_name if coverage >= 0.4
      end
    end

    typed_map
  end

  # Detect wall hexes using skeleton crossing length.
  # Shells out to wall_skeleton.py.
  #
  # @param wall_mask [Vips::Image] binary wall mask
  # @param hex_size [Numeric]
  # @return [Set] hex coordinates that are wall hexes
  def detect_wall_hexes_via_skeleton(wall_mask, hex_size)
    script = File.expand_path('../../../lib/cv/wall_skeleton.py', __dir__)
    return Set.new unless File.exist?(script)

    require 'tempfile'

    mask_file = Tempfile.new(['wall_mask', '.png'])
    wall_mask.write_to_file(mask_file.path)

    coords_data = @coord_lookup.map do |(hx, hy), info|
      [hx, hy, info[:px].to_i, info[:py].to_i]
    end
    coords_file = Tempfile.new(['hex_coords', '.json'])
    coords_file.write(JSON.generate(coords_data))
    coords_file.close

    output_file = Tempfile.new(['wall_hexes', '.json'])
    output_file.close

    success = system('python3', script, mask_file.path, coords_file.path,
                     hex_size.to_s, output_file.path,
                     out: File::NULL, err: File::NULL)

    return Set.new unless success && File.exist?(output_file.path) && File.size(output_file.path) > 2

    raw = JSON.parse(File.read(output_file.path))
    wall_coords = Set.new
    raw.each_key do |key|
      hx, hy = key.split(',').map(&:to_i)
      wall_coords.add([hx, hy])
    end
    wall_coords
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Wall skeleton detection failed: #{e.message}"
    Set.new
  ensure
    mask_file&.unlink
    coords_file&.unlink
    output_file&.unlink
  end

  # Look up which SAM category a type belongs to.
  def type_category(type_name)
    SAM_CATEGORIES.each do |cat, types|
      return cat if types.include?(type_name)
    end
    :furniture # default for custom types
  end

  # Map depth values from Depth Anything v2 to hex elevation in feet.
  # Depth is relative (0-255 grayscale). We detect elevation changes
  # relative to the median floor depth.
  #
  # @param depth_map [Vips::Image] grayscale depth image
  # @param typed_map [Hash] { [hx,hy] => hex_type }
  # @param hex_size [Numeric]
  # @return [Hash] { [hx,hy] => Integer } elevation in feet
  def map_depth_to_elevation(depth_map, typed_map, hex_size)
    elevations = {}
    return elevations unless depth_map

    gray = depth_map.bands > 1 ? depth_map.extract_band(0) : depth_map

    # Resize depth map to match base image if needed
    if @coord_lookup&.any?
      # Sample depth at each hex center
      hex_depths = {}
      @coord_lookup.each do |(hx, hy), info|
        r = [(hex_size * 0.3).to_i, 2].max
        x1 = [info[:px].round - r, 0].max
        y1 = [info[:py].round - r, 0].max
        w = [r * 2, gray.width - x1].min
        h = [r * 2, gray.height - y1].min
        next if w < 2 || h < 2

        hex_depths[[hx, hy]] = gray.crop(x1, y1, w, h).avg
      rescue Vips::Error
        next
      end

      return elevations if hex_depths.empty?

      # Find floor-level depth (median of floor hexes)
      floor_depths = hex_depths.select { |coord, _| typed_map[coord].nil? || typed_map[coord] == 'open_floor' }
      if floor_depths.empty?
        floor_depths = hex_depths
      end
      sorted = floor_depths.values.sort
      floor_median = sorted[sorted.length / 2]

      # Assign elevation based on depth difference from floor
      # Depth Anything: brighter = closer to camera = higher elevation
      hex_depths.each do |(hx, hy), depth|
        diff = depth - floor_median
        next if diff.abs < 8 # noise threshold

        # Map depth difference to feet (rough approximation)
        elevation = if diff > 40
          12 # high platform / balcony
        elsif diff > 25
          8  # balcony / raised area
        elsif diff > 15
          4  # staircase step / raised platform
        elsif diff > 8
          3  # table height
        elsif diff < -25
          -8 # deep pit
        elsif diff < -15
          -4 # pit / sunken area
        else
          0
        end

        elevations[[hx, hy]] = elevation if elevation != 0
      end
    end

    elevations
  end

  # Convert all classification results to RoomHex-compatible format.
  # Classified hexes get type-mapped properties; unclassified hexes get open_floor defaults.
  #
  # @param chunk_results [Array<Hash>] classified hexes with 'label', 'hex_type', 'x', 'y'
  # @param hex_coords [Array<Array>] all hex coordinate pairs
  # @param min_x [Integer] minimum hex x
  # @param min_y [Integer] minimum hex y
  # @param overview_props [Hash] type properties from overview pass
  # @return [Array<Hash>] hex data for persist_hex_data
  def map_results_to_room_hex(chunk_results, hex_coords, min_x, min_y, overview_props)
    # Build lookup of classified hexes
    classified = {}
    off_map_coords = Set.new
    chunk_results.each do |r|
      key = "#{r['x']},#{r['y']}"
      classified[key] = r
      off_map_coords.add([r['x'], r['y']]) if r['hex_type'] == 'off_map'
    end

    # BFS from classified interior hexes to find all reachable floor hexes.
    # Unclassified hexes not reachable from any interior hex are dead zone (off_map area).
    all_coords = Set.new(hex_coords)
    interior_coords = Set.new
    queue = []

    # Seed: every classified hex that isn't off_map
    classified.each do |_key, r|
      coord = [r['x'], r['y']]
      next if r['hex_type'] == 'off_map'
      next unless all_coords.include?(coord)
      interior_coords.add(coord)
      queue << coord
    end

    # Flood fill through unclassified hexes (but stop at off_map boundaries)
    while (coord = queue.shift)
      HexGrid.hex_neighbors(coord[0], coord[1]).each do |nx, ny|
        nc = [nx, ny]
        next unless all_coords.include?(nc)
        next if interior_coords.include?(nc)
        next if off_map_coords.include?(nc)
        interior_coords.add(nc)
        queue << nc unless classified["#{nx},#{ny}"]  # Only BFS through unclassified
      end
    end

    hex_data = hex_coords.filter_map do |hx, hy|
      next nil unless interior_coords.include?([hx, hy])
      key = "#{hx},#{hy}"
      if classified[key]
        map_simple_type_to_room_hex(classified[key]['hex_type'], hx, hy, overview_props)
      else
        map_simple_type_to_room_hex('open_floor', hx, hy, overview_props)
      end
    end

    apply_additive_elevation(hex_data)
  end

  # Map a simple classification type to RoomHex database fields.
  # Uses SIMPLE_TYPE_TO_ROOM_HEX for known types, with overview properties as fallback enrichment.
  #
  # @param simple_type [String] e.g. 'treetrunk', 'wall', 'open_floor'
  # @param hx [Integer] hex x coordinate
  # @param hy [Integer] hex y coordinate
  # @param overview_props [Hash] type properties from overview pass
  # @return [Hash] RoomHex-compatible hash with :x, :y, :hex_type, etc.
  def map_simple_type_to_room_hex(simple_type, hx, hy, overview_props = {})
    mapping = SIMPLE_TYPE_TO_ROOM_HEX[simple_type] || SIMPLE_TYPE_TO_ROOM_HEX['open_floor']

    result = {
      x: hx,
      y: hy,
      hex_type: mapping[:hex_type],
      traversable: mapping.fetch(:traversable, true),
      difficult_terrain: mapping.fetch(:difficult_terrain, false),
      cover_object: mapping[:cover_object],
      has_cover: mapping.key?(:has_cover) ? mapping[:has_cover] : (mapping[:hex_type] == 'cover'),
      elevation_level: mapping[:elevation_level] || 0,
      surface_type: mapping[:surface_type] || 'stone',
      hazard_type: mapping[:hazard_type],
      water_type: mapping[:water_type],
      danger_level: mapping[:danger_level] || (mapping[:hazard_type] ? 2 : 0),
      _simple_type: simple_type
    }

    # Enrich with overview-detected properties for custom types not in our mapping
    unless SIMPLE_TYPE_TO_ROOM_HEX.key?(simple_type)
      props = overview_props[simple_type]
      if props
        result[:traversable] = props['traversable'] unless props['traversable'].nil?
        result[:difficult_terrain] = props['difficult_terrain'] unless props['difficult_terrain'].nil?
        result[:elevation_level] = props['elevation'] if props['elevation']
        if props['water_depth'] && props['water_depth'] != 'none'
          result[:water_type] = props['water_depth']
          result[:hex_type] = 'water'
        end
        if props['hazards'] && !props['hazards'].empty?
          result[:hazard_type] = props['hazards'].first
          result[:danger_level] = 2
        end
        result[:hex_type] = 'wall' if props['is_wall']
        result[:hex_type] = 'door' if props['is_exit']
      end
    end

    result
  end

  # Types whose elevation represents object height (table=3ft, chest=2ft) rather than
  # floor level. When these sit on an elevated area, their elevation should be additive.
  OBJECT_ELEVATION_TYPES = Set.new(%w[table chest]).freeze

  # Post-process hex data: for furniture/object types on elevated areas,
  # add the surrounding area's base elevation to the object's intrinsic elevation.
  def apply_additive_elevation(hex_data)
    return hex_data if hex_data.empty?

    # Build coordinate lookup
    lookup = {}
    hex_data.each { |h| lookup[[h[:x], h[:y]]] = h }

    hex_data.each do |h|
      next unless OBJECT_ELEVATION_TYPES.include?(h[:_simple_type])

      # Find base elevation from neighbors (non-furniture, non-zero elevation)
      neighbor_elevations = HexGrid.hex_neighbors(h[:x], h[:y]).filter_map do |nx, ny|
        n = lookup[[nx, ny]]
        next unless n && n[:hex_type] != 'furniture' && (n[:elevation_level] || 0) != 0
        n[:elevation_level]
      end
      next if neighbor_elevations.empty?

      h[:elevation_level] = (h[:elevation_level] || 0) + neighbor_elevations.max
    end

    hex_data
  end

  # Legacy analysis pipeline (pre-overview). Used as fallback.
  def analyze_hexes_legacy(image_path)
    return [] unless image_path && File.exist?(image_path)

    # Legacy requires a labeled image — overlay labels first
    labeled_image_path = overlay_hex_labels(image_path)
    return [] unless labeled_image_path

    begin
      hex_coords = generate_hex_coordinates
      min_x = room.min_x
      min_y = room.min_y

      hex_data = if hex_coords.length > GameConfig::BattleMap::AI_GENERATION[:chunk_threshold]
        all_hex_data = []
        hex_coords.each_slice(GameConfig::BattleMap::AI_GENERATION[:chunk_size]) do |chunk|
          chunk_labels = chunk.map { |x, y| coord_to_label(x, y, min_x, min_y) }
          result = analyze_hex_chunk(labeled_image_path, chunk_labels, chunk, GameConfig::BattleMap::AI_GENERATION[:chunk_size])
          all_hex_data.concat(result) if result
        end
        all_hex_data
      else
        all_labels = hex_coords.map { |x, y| coord_to_label(x, y, min_x, min_y) }
        analyze_all_hexes(labeled_image_path, all_labels, hex_coords)
      end

      hex_data
    ensure
      File.delete(labeled_image_path) if labeled_image_path && File.exist?(labeled_image_path)
    end
  end

  # ==================================================
  # ==================================================
  # Border cropping with image alignment
  # ==================================================

  # Crop non-traversable border hexes AND crop the background image to match,
  # so the hex grid stays aligned with the image after coordinate shifting.
  # Returns [cropped_hex_data, image_path] (image_path may be modified in-place).
  def crop_border_with_image(hex_data, image_path)
    @last_border_crop = nil
    return [hex_data, image_path] if hex_data.empty? || !@coord_lookup

    traversable = hex_data.select { |h| h[:traversable] != false }
    return [hex_data, image_path] if traversable.empty?

    # Build keep set: traversable + 1-hex neighbor buffer
    keep_coords = Set.new
    traversable.each do |h|
      keep_coords.add([h[:x], h[:y]])
      HexGrid.hex_neighbors(h[:x], h[:y]).each { |nx, ny| keep_coords.add([nx, ny]) }
    end

    kept = hex_data.select { |h| keep_coords.include?([h[:x], h[:y]]) }
    return [hex_data, image_path] if kept.size == hex_data.size # nothing to crop

    # Calculate pixel bounds of kept hexes from the analysis pixel map
    hs = @analysis_hex_size || 30
    hh = hs * Math.sqrt(3)
    pixel_infos = kept.filter_map { |h| @coord_lookup[[h[:x], h[:y]]] }
    unless pixel_infos.empty?
      min_px = pixel_infos.map { |i| i[:px] }.min - hs
      max_px = pixel_infos.map { |i| i[:px] }.max + hs
      min_py = pixel_infos.map { |i| i[:py] }.min - hh / 2.0
      max_py = pixel_infos.map { |i| i[:py] }.max + hh / 2.0

      # Crop the image to these pixel bounds
      # IMPORTANT: Write to a temp file first, then rename. Writing to the same
      # file that vips has open causes a native Bus Error (SIGBUS) in libwebpdemux.
      begin
        require 'vips'
        image = Vips::Image.new_from_file(image_path)
        left = [min_px.floor, 0].max
        top = [min_py.floor, 0].max
        right = [max_px.ceil, image.width].min
        bottom = [max_py.ceil, image.height].min
        width = [right - left, 1].max
        height = [bottom - top, 1].max

        if width < image.width || height < image.height
          ext = File.extname(image_path)
          tmp_path = image_path.sub(ext, "_cropped#{ext}")
          cropped_image = image.crop(left, top, width, height)
          cropped_image.write_to_file(tmp_path)
          # Release vips handles before overwriting
          cropped_image = nil
          image = nil
          GC.start
          FileUtils.mv(tmp_path, image_path)
          @last_border_crop = {
            left: left, top: top, width: width, height: height,
            source_width: right, source_height: bottom
          }
          warn "[AIBattleMapGenerator] Cropped image to #{width}x#{height} (from original)"
        end
      rescue StandardError => e
        warn "[AIBattleMapGenerator] Image crop failed (non-fatal): #{e.message}"
      end
    end

    # Shift hex coordinates to start at (0,0) using parity-safe origin
    min_x = kept.map { |h| h[:x] }.min
    min_y = kept.map { |h| h[:y] }.min
    min_x, min_y = HexGrid.parity_safe_origin(min_x, min_y)
    shifted = kept.map { |h| h.merge(x: h[:x] - min_x, y: h[:y] - min_y) }

    [shifted, image_path]
  rescue StandardError => e
    warn "[AIBattleMapGenerator] crop_border_with_image failed (non-fatal): #{e.message}"
    # Fall back to standard crop without image
    [crop_non_traversable_border(hex_data), image_path]
  end

  # Step 4: Persistence
  # ==================================================

  # Build the object metadata hash from L1/overview classification data.
  # @param l1_data [Hash, nil] parsed L1 grid response
  # @param overview [Hash, nil] parsed overview response
  # @param typed_map [Hash] final {[hx,hy] => type_name} after normalization
  # @return [Hash] metadata ready for JSONB persistence
  def build_object_metadata(l1_data: nil, overview: nil, typed_map: {})
    metadata = {}

    if l1_data
      metadata['scene_description'] = l1_data['scene_description']
      metadata['wall_visual'] = l1_data['wall_visual']
      metadata['floor_visual'] = l1_data['floor_visual']
      metadata['lighting_direction'] = l1_data['lighting_direction']
      metadata['has_perimeter_wall'] = l1_data['has_perimeter_wall']
      metadata['has_inner_walls'] = l1_data['has_inner_walls']
      metadata['light_sources'] = l1_data['light_sources']

      types = []
      (l1_data['standard_types_present'] || []).each do |t|
        types << {
          'type_name' => t['type_name'],
          'visual_description' => t['visual_description'],
          'short_description' => t['short_description'],
          'standard' => true
        }
      end
      (l1_data['custom_types'] || []).each do |c|
        entry = {
          'type_name' => c['type_name'],
          'visual_description' => c['visual_description'],
          'short_description' => c['short_description'],
          'standard' => false,
          'provides_cover' => c['provides_cover'],
          'is_exit' => c['is_exit'],
          'difficult_terrain' => c['difficult_terrain'],
          'elevation' => c['elevation'],
          'hazards' => c['hazards']
        }
        types << entry
      end
      metadata['types'] = types

    elsif overview
      metadata['scene_description'] = overview['scene_description']
      metadata['map_layout'] = overview['map_layout']

      types = []
      (overview['present_types'] || []).each do |t|
        types << {
          'type_name' => t['type_name'],
          'visual_description' => t['visual_description'],
          'short_description' => t['short_description'],
          'standard' => false,
          'provides_cover' => t['provides_cover'],
          'is_exit' => t['is_exit'],
          'difficult_terrain' => t['difficult_terrain'],
          'elevation' => t['elevation'],
          'hazards' => t['hazards']
        }
      end
      metadata['types'] = types
    end

    # Build color legend from object types in the final typed_map (exclude floor/off_map)
    unique_types = typed_map.values.uniq.sort - %w[normal open_floor off_map]
    color_legend = {}
    unique_types.each do |type_name|
      color_legend[type_name] = type_name_to_rgb(type_name)
    end
    metadata['color_legend'] = color_legend

    metadata
  end

  # Render a raw object type mask — solid-colored hex polygons on transparent background.
  # @param typed_map [Hash] {[hx,hy] => type_name}
  # @param color_legend [Hash] {type_name => [r,g,b]}
  # @param width [Integer] image width in pixels
  # @param height [Integer] image height in pixels
  # @return [Vips::Image] RGBA image
  def render_object_type_mask(typed_map, color_legend, width, height)
    hex_size = @inspection_hex_size || 20

    svg_elements = typed_map.filter_map do |(hx, hy), ht|
      info = @coord_lookup[[hx, hy]]
      next unless info
      rgb = color_legend[ht]
      next unless rgb
      px, py = info[:px], info[:py]
      points = inspection_hex_points(px, py, hex_size)
      "<polygon points='#{points}' fill='rgb(#{rgb[0]},#{rgb[1]},#{rgb[2]})' stroke='none'/>"
    end.join("\n")

    svg = "<svg xmlns='http://www.w3.org/2000/svg' width='#{width}' height='#{height}'>#{svg_elements}</svg>"
    mask = Vips::Image.svgload_buffer(svg)
    if mask.width != width
      mask = mask.resize(width.to_f / mask.width, vscale: height.to_f / mask.height)
    end

    # Ensure RGBA output
    mask.bands >= 4 ? mask : mask.bandjoin(255)
  end

  # Build and persist object metadata + raw type mask on the room.
  # @param typed_map [Hash] {[hx,hy] => type_name} — final normalized map
  # @param base_image [Vips::Image] the base battlemap image (for dimensions)
  # @param l1_data [Hash, nil] parsed L1 grid response
  # @param overview [Hash, nil] parsed overview response
  def persist_object_metadata_and_mask(typed_map, base_image, l1_data: nil, overview: nil)
    return unless typed_map&.any?

    metadata = build_object_metadata(l1_data: l1_data, overview: overview, typed_map: typed_map)
    color_legend = metadata['color_legend'] || {}

    # Render raw mask
    mask_image = render_object_type_mask(typed_map, color_legend, base_image.width, base_image.height)

    # Save to inspection dir (same location as other masks)
    mask_path = File.join(inspection_dir, 'object_map.png')
    mask_image.write_to_file(mask_path)

    # Build URL for web serving
    mask_url = mask_path.sub(%r{^public/?}, '')
    mask_url = "/#{mask_url}" unless mask_url.start_with?('/')

    # Persist on room
    updates = {}
    room_columns = Room.columns
    if room_columns.include?(:battle_map_object_metadata)
      updates[:battle_map_object_metadata] = Sequel.pg_jsonb_wrap(metadata)
    end
    if room_columns.include?(:battle_map_object_map_url)
      updates[:battle_map_object_map_url] = mask_url
    end
    room.update(updates) if updates.any?

    warn "[AIBattleMapGenerator] Persisted object metadata (#{metadata['types']&.length || 0} types) and mask to #{mask_url}"
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to persist object metadata/mask: #{e.message}"
  end

  def persist_hex_data(hex_data)
    DB.transaction do
      # Clear existing hexes
      room.room_hexes_dataset.delete

      # Prepare and insert new hex data
      now = Time.now
      hex_records = hex_data.map do |data|
        ht = data[:hex_type] || 'normal'
        {
          room_id: room.id,
          hex_x: data[:x],
          hex_y: data[:y],
          hex_type: ht,
          cover_object: data[:cover_object],
          has_cover: data.key?(:has_cover) ? data[:has_cover] : (ht == 'cover'),
          hazard_type: data[:hazard_type],
          elevation_level: data[:elevation_level] || 0,
          water_type: data[:water_type],
          surface_type: data[:surface_type] || 'stone',
          traversable: data.key?(:traversable) ? data[:traversable] : !%w[wall pit].include?(ht),
          difficult_terrain: data.key?(:difficult_terrain) ? data[:difficult_terrain] : (ht == 'difficult'),
          danger_level: data.key?(:danger_level) ? data[:danger_level] : (data[:hazard_type] ? 2 : 0),
          wall_feature: data[:wall_feature],
          is_stairs: data[:is_stairs] || false,
          is_ladder: data[:is_ladder] || false,
          passable_edges: data[:passable_edges],
          majority_floor: data[:majority_floor],
          created_at: now,
          updated_at: now
        }
      end

      RoomHex.multi_insert(hex_records) if hex_records.any?
    end
  end

  # Apply the same post-classification crop rectangle to auxiliary assets so
  # effect masks, wall masks, depth maps, and light sources stay aligned.
  def apply_border_crop_to_aux_assets!
    crop = @last_border_crop
    return unless crop

    # Effect masks and wall mask are web-served asset URLs
    url_columns = %i[
      battle_map_water_mask_url
      battle_map_foliage_mask_url
      battle_map_fire_mask_url
      battle_map_wall_mask_url
      battle_map_object_map_url
    ]
    url_columns.each do |column|
      next unless room.respond_to?(column)
      path = resolve_asset_local_path(room.send(column))
      crop_aux_image_file!(path, crop) if path
    end

    # Depth maps are local file paths (not URLs); crop depth + zone map if present
    if room.respond_to?(:depth_map_path) && room.depth_map_path && File.exist?(room.depth_map_path)
      crop_aux_image_file!(room.depth_map_path, crop)
      zone_map_path = room.depth_map_path.sub(/(\.\w+)$/, '_zone_map.png')
      crop_aux_image_file!(zone_map_path, crop) if File.exist?(zone_map_path)
    end

    adjust_detected_light_sources_for_crop!(crop)

    # Keep stored wall-mask dimensions in sync with the cropped mask
    if room.respond_to?(:battle_map_wall_mask_url) && room.battle_map_wall_mask_url
      wall_mask_path = resolve_asset_local_path(room.battle_map_wall_mask_url)
      if wall_mask_path && File.exist?(wall_mask_path)
        img = Vips::Image.new_from_file(wall_mask_path)
        room.update(
          battle_map_wall_mask_width: img.width,
          battle_map_wall_mask_height: img.height
        )
      end
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Auxiliary crop sync failed: #{e.message}"
  ensure
    @last_border_crop = nil
  end

  def resolve_asset_local_path(url_or_path)
    return nil if url_or_path.nil? || url_or_path.to_s.strip.empty?
    raw = url_or_path.to_s
    candidate = if raw.start_with?('/')
      File.join('public', raw.sub(%r{^/}, ''))
    else
      raw
    end
    File.exist?(candidate) ? candidate : nil
  end

  def crop_aux_image_file!(path, crop)
    return unless path && File.exist?(path)
    img = Vips::Image.new_from_file(path)
    left = [crop[:left].to_i, 0].max
    top = [crop[:top].to_i, 0].max
    right = [left + crop[:width].to_i, img.width].min
    bottom = [top + crop[:height].to_i, img.height].min
    width = [right - left, 1].max
    height = [bottom - top, 1].max
    return if width >= img.width && height >= img.height

    ext = File.extname(path)
    tmp = path.sub(ext, "_cropped#{ext}")
    cropped = img.crop(left, top, width, height)
    cropped.write_to_file(tmp)
    cropped = nil
    img = nil
    GC.start
    FileUtils.mv(tmp, path)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to crop aux asset #{path}: #{e.message}"
  end

  def adjust_detected_light_sources_for_crop!(crop)
    return unless room.respond_to?(:detected_light_sources)

    sources = room.detected_light_sources
    return unless sources.respond_to?(:any?) && sources.any?

    width = crop[:width].to_f
    height = crop[:height].to_f

    adjusted = sources.filter_map do |source|
      s = source.respond_to?(:to_h) ? source.to_h : source
      cx = s['center_x'].to_f - crop[:left].to_f
      cy = s['center_y'].to_f - crop[:top].to_f
      next if cx < 0 || cy < 0 || cx >= width || cy >= height
      s.merge('center_x' => cx.round(1), 'center_y' => cy.round(1))
    end

    room.update(detected_light_sources: Sequel.pg_jsonb_wrap(JSON.parse(adjusted.to_json)))
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to adjust cropped light sources: #{e.message}"
  end

  # Compute edge-level movement passability from the pixel wall mask.
  # Applies to all hexes so internal walls can block movement between floor hexes.
  def refresh_wall_passability_edges!
    mask_svc = WallMaskService.for_room(room)
    return unless mask_svc

    room.room_hexes_dataset.each do |hex|
      edges = mask_svc.compute_passable_edges(hex.hex_x, hex.hex_y)
      px, py = mask_svc.hex_to_pixel(hex.hex_x, hex.hex_y)
      majority = !mask_svc.wall_pixel?(px, py)
      hex.update(passable_edges: edges, majority_floor: majority)
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to refresh wall passability: #{e.message}"
  end

  def persist_image(image_url)
    room.update(
      battle_map_image_url: image_url,
      has_battle_map: true
    )
  end

  # Persist SAM feature mask URLs on the room for downstream services.
  # Joins prefetched SAM threads to ensure mask files exist before checking.
  # @param local_path [String] base image path
  # @param prefetched_sam_threads [Hash] SAM threads keyed by type
  def persist_sam_mask_urls(local_path, prefetched_sam_threads = {})
    updates = {}

    # Join water SAM thread if running, then check for mask file
    join_sam_thread(prefetched_sam_threads['water'])
    water_path = local_path.sub(/(\.\w+)$/, '_sam_water.png')
    if File.exist?(water_path)
      url = water_path.sub(%r{^public/?}, '')
      url = "/#{url}" unless url.start_with?('/')
      updates[:battle_map_water_mask_url] = url
    end

    # Join light SAM threads, then threshold fire mask to binary.
    # SAM returns confidence values (gray); threshold at 200 to keep only
    # high-confidence fire regions and avoid tinting the entire room.
    prefetched_sam_threads.each do |key, thread|
      next unless key.start_with?('light_')
      join_sam_thread(thread)
    end
    fire_path = persist_combined_fire_mask(local_path)
    if fire_path && File.exist?(fire_path)
      url = fire_path.sub(%r{^public/?}, '')
      url = "/#{url}" unless url.start_with?('/')
      updates[:battle_map_fire_mask_url] = url
    end

    # Join foliage SAM threads, then combine tree + bush masks
    join_sam_thread(prefetched_sam_threads['foliage_tree'])
    join_sam_thread(prefetched_sam_threads['foliage_bush'])
    foliage_path = combine_foliage_masks(local_path)
    if foliage_path && File.exist?(foliage_path)
      url = foliage_path.sub(%r{^public/?}, '')
      url = "/#{url}" unless url.start_with?('/')
      updates[:battle_map_foliage_mask_url] = url
    end

    room.update(updates) if updates.any?
    warn "[AIBattleMapGenerator] Persisted SAM mask URLs: #{updates.keys.join(', ')}" if updates.any?
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to persist SAM mask URLs: #{e.message}"
  end

  # Build a canonical fire effect mask from light-source SAM masks.
  # Prefers fire, but falls back to torch so wall torches still animate.
  #
  # @param local_path [String] base battlemap path
  # @return [String, nil] persisted fire mask path (sam_light_fire), or nil
  def persist_combined_fire_mask(local_path)
    require 'vips'

    fire_path = local_path.sub(/(\.\w+)$/, '_sam_light_fire.png')
    torch_path = local_path.sub(/(\.\w+)$/, '_sam_light_torch.png')

    source_paths = [fire_path, torch_path].select { |path| File.exist?(path) }
    return nil if source_paths.empty?

    mask = Vips::Image.new_from_file(source_paths.first)
    mask = mask.extract_band(0) if mask.bands > 1

    source_paths[1..].each do |path|
      other = Vips::Image.new_from_file(path)
      other = other.extract_band(0) if other.bands > 1
      if other.width != mask.width || other.height != mask.height
        other = other.resize(mask.width.to_f / other.width,
                             vscale: mask.height.to_f / other.height)
      end
      mask = (mask | other)
    end

    # SAM outputs confidence grayscale; keep only high-confidence fire/torch regions.
    if mask.avg > 20
      mask = (mask > 200).ifthenelse(255, 0).cast(:uchar)
    end

    coverage = mask.avg / 255.0
    if coverage > 0.20
      warn "[AIBattleMapGenerator] Fire mask rejected: covers #{(coverage * 100).round(1)}% of image (max 20%)"
      File.delete(fire_path) if File.exist?(fire_path)
      return nil
    end

    File.binwrite(fire_path, mask.write_to_buffer('.png'))
    fire_path
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to persist combined fire mask: #{e.message}"
    nil
  end

  # Combine tree and bush SAM masks into a single foliage mask.
  # @param local_path [String] base image path
  # @return [String, nil] combined mask path, or nil
  def combine_foliage_masks(local_path)
    require 'vips'
    tree_path = local_path.sub(/(\.\w+)$/, '_sam_foliage_tree.png')
    bush_path = local_path.sub(/(\.\w+)$/, '_sam_foliage_bush.png')
    output_path = local_path.sub(/(\.\w+)$/, '_sam_foliage.png')

    masks = []
    masks << Vips::Image.new_from_file(tree_path) if File.exist?(tree_path)
    masks << Vips::Image.new_from_file(bush_path) if File.exist?(bush_path)
    return nil if masks.empty?

    combined = masks.first
    masks[1..].each do |m|
      # Resize if dimensions don't match
      m = m.resize(combined.width.to_f / m.width) if m.width != combined.width
      combined = (combined | m)
    end

    # Ensure single-band grayscale
    combined = combined.extract_band(0) if combined.bands > 1
    combined.write_to_file(output_path)
    output_path
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Failed to combine foliage masks: #{e.message}"
    nil
  end

  # Join a SAM thread with timeout, swallowing exceptions.
  # @param thread [Thread, nil] the thread to join
  # @param timeout [Integer] max seconds to wait
  def join_sam_thread(thread, timeout: 120)
    return unless thread
    thread.join(timeout)&.value
  rescue StandardError => e
    warn "[AIBattleMapGenerator] SAM thread failed: #{e.message}"
    nil
  end

  # Extract light source positions from SAM masks generated during classification.
  # Uses a Python script to find contour centers/radii from each binary mask.
  # Stores results in room.detected_light_sources for the lighting service.
  #
  # @param local_path [String] battlemap image path (for deriving mask paths)
  # @param l1_light_sources [Array] L1-reported light sources with source_type + description
  # @param prefetched_sam_threads [Hash] SAM threads keyed by "light_TYPE"
  def extract_and_store_light_sources(local_path, l1_light_sources, prefetched_sam_threads)
    return if l1_light_sources.nil? || l1_light_sources.empty?

    sources = []
    seen_light_types = Set.new
    processed_masks = Set.new  # avoid extracting same mask twice (fire+torch share a mask)

    l1_light_sources.each do |ls|
      stype = ls['source_type']
      next if seen_light_types.include?(stype)
      seen_light_types.add(stype)

      thread_key = "light_#{stype}"
      thread = prefetched_sam_threads[thread_key]
      next unless thread

      result = join_sam_thread(thread)
      next unless result&.dig(:success) && result[:mask_path] && !result[:no_detections]
      next unless File.exist?(result[:mask_path])
      # Skip if we already extracted this mask (e.g. fire+torch share "fire OR flame")
      next if processed_masks.include?(result[:mask_path])
      processed_masks.add(result[:mask_path])

      # Extract contour centers from the SAM mask using Python/OpenCV
      positions = extract_positions_from_mask(result[:mask_path])
      next if positions.empty?

      # Map SAM light type to lighting colour and intensity from constants
      light_color = LIGHT_COLORS[stype] || LIGHT_COLOR_DEFAULT
      light_intensity = LIGHT_INTENSITIES[stype] || LIGHT_INTENSITY_DEFAULT

      positions.each do |pos|
        sources << {
          'type' => stype,
          'center_x' => pos[:cx],
          'center_y' => pos[:cy],
          'radius_px' => [pos[:radius] * 3, 60].max, # light radius is ~3x object radius, min 60px
          'intensity' => light_intensity,
          'color' => light_color,
          'description' => ls['description']
        }
      end

      warn "[AIBattleMapGenerator] SAM light #{stype}: #{positions.length} sources detected"
    end

    if sources.any?
      room.update(detected_light_sources: Sequel.pg_jsonb_wrap(sources))
      warn "[AIBattleMapGenerator] Stored #{sources.length} L1+SAM light sources"
    end
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Light source extraction failed: #{e.message}"
  end

  # Delegates to the public class method for backward compatibility.
  def extract_positions_from_mask(mask_path)
    self.class.extract_positions_from_mask(mask_path)
  end

  # Publish progress update to Redis for WebSocket clients
  # @param fight_id [Integer] the fight ID
  # @param progress [Integer] percentage complete (0-100)
  # @param step [String] description of current step
  # publish_progress provided by BattleMapPubsub

  # ==================================================
  # Grid Classification: Geometry Helpers
  # ==================================================

  # Returns flat-top hex vertices as [[x,y], ...] for polygon intersection
  def hexagon_points_array(cx, cy, size)
    6.times.map do |i|
      angle = Math::PI / 3 * i
      [cx + size * Math.cos(angle), cy + size * Math.sin(angle)]
    end
  end

  # Compute intersection area of two convex polygons (Sutherland-Hodgman + shoelace)
  def polygon_intersection_area(subject, clip)
    output = subject.dup
    clip.length.times do |i|
      return 0.0 if output.empty?
      input = output
      output = []
      edge_start = clip[i]
      edge_end = clip[(i + 1) % clip.length]
      input.length.times do |j|
        current = input[j]
        prev = input[(j - 1) % input.length]
        curr_inside = grid_cross_2d(edge_start, edge_end, current) >= 0
        prev_inside = grid_cross_2d(edge_start, edge_end, prev) >= 0
        if curr_inside
          output << grid_line_intersect(prev, current, edge_start, edge_end) unless prev_inside
          output << current
        elsif prev_inside
          output << grid_line_intersect(prev, current, edge_start, edge_end)
        end
      end
    end
    return 0.0 if output.length < 3
    grid_shoelace_area(output)
  end

  def grid_cross_2d(a, b, p)
    (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
  end

  def grid_line_intersect(p1, p2, p3, p4)
    x1, y1 = p1; x2, y2 = p2; x3, y3 = p3; x4, y4 = p4
    denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    return p1 if denom.abs < 1e-10
    t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom
    [x1 + t * (x2 - x1), y1 + t * (y2 - y1)]
  end

  def grid_shoelace_area(polygon)
    n = polygon.length
    area = 0.0
    n.times do |i|
      j = (i + 1) % n
      area += polygon[i][0] * polygon[j][1]
      area -= polygon[j][0] * polygon[i][1]
    end
    area.abs / 2.0
  end

  # ==================================================
  # Grid Classification: Image Utilities
  # ==================================================

  # Overlay a numbered NxN grid on a Vips image.
  # inset: { x:, y:, w:, h: } — grid only covers this sub-region (for blur buffer)
  # Returns { image:, cells: { 1 => { x:, y:, w:, h:, cx:, cy: }, ... } }
  def overlay_square_grid(image, n, label_offset: 0, inset: nil)
    img_w = image.width
    img_h = image.height

    gx = inset ? inset[:x] : 0
    gy = inset ? inset[:y] : 0
    gw = inset ? inset[:w] : img_w
    gh = inset ? inset[:h] : img_h

    cell_w = gw.to_f / n
    cell_h = gh.to_f / n
    font_size = [([cell_w, cell_h].min * 0.3).round, 12].max

    cells = {}
    svg_parts = []
    svg_parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{img_w}" height="#{img_h}">)

    (1...n).each do |i|
      x = gx + (i * cell_w).round
      y = gy + (i * cell_h).round
      svg_parts << %(<line x1="#{x}" y1="#{gy}" x2="#{x}" y2="#{gy + gh}" stroke="black" stroke-width="4"/>)
      svg_parts << %(<line x1="#{x}" y1="#{gy}" x2="#{x}" y2="#{gy + gh}" stroke="white" stroke-width="2"/>)
      svg_parts << %(<line x1="#{gx}" y1="#{y}" x2="#{gx + gw}" y2="#{y}" stroke="black" stroke-width="4"/>)
      svg_parts << %(<line x1="#{gx}" y1="#{y}" x2="#{gx + gw}" y2="#{y}" stroke="white" stroke-width="2"/>)
    end

    svg_parts << %(<rect x="#{gx}" y="#{gy}" width="#{gw}" height="#{gh}" fill="none" stroke="black" stroke-width="4"/>)
    svg_parts << %(<rect x="#{gx}" y="#{gy}" width="#{gw}" height="#{gh}" fill="none" stroke="white" stroke-width="2"/>)

    cell_num = 1
    n.times do |row|
      n.times do |col|
        label = cell_num + label_offset
        cx = gx + ((col + 0.5) * cell_w).round
        cy = gy + ((row + 0.5) * cell_h).round
        cells[cell_num] = {
          x: gx + (col * cell_w).round, y: gy + (row * cell_h).round,
          w: cell_w.round, h: cell_h.round,
          cx: cx, cy: cy
        }
        svg_parts << %(<text x="#{cx}" y="#{cy + font_size * 0.35}" text-anchor="middle" fill="white" stroke="black" stroke-width="3" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
        svg_parts << %(<text x="#{cx}" y="#{cy + font_size * 0.35}" text-anchor="middle" fill="white" font-size="#{font_size}" font-family="sans-serif" font-weight="bold">#{label}</text>)
        cell_num += 1
      end
    end

    svg_parts << '</svg>'
    overlay = Vips::Image.svgload_buffer(svg_parts.join("\n"))
    overlay = overlay.resize(img_w.to_f / overlay.width) if overlay.width != img_w || overlay.height != img_h

    base_rgba = image.bands >= 4 ? image : image.bandjoin(255)
    overlay_rgba = overlay.bands >= 4 ? overlay : overlay.bandjoin(255)
    composited = base_rgba.composite(overlay_rgba, :over)

    { image: composited, cells: cells }
  end

  # Crop a cell with blurred border buffer for context.
  # Returns { image:, origin_x:, origin_y:, inner_x:, inner_y:, inner_w:, inner_h: }
  def crop_cell_with_blur(image, cell, blur_pct: 0.25)
    cx = [cell[:x], 0].max
    cy = [cell[:y], 0].max
    cw = [cell[:w], 1].max
    ch = [cell[:h], 1].max
    cw = [cw, image.width - cx].min
    ch = [ch, image.height - cy].min

    expand_x = (cw * blur_pct).round
    expand_y = (ch * blur_pct).round

    ex = [cx - expand_x, 0].max
    ey = [cy - expand_y, 0].max
    ex2 = [cx + cw + expand_x, image.width].min
    ey2 = [cy + ch + expand_y, image.height].min
    ew = ex2 - ex
    eh = ey2 - ey

    if ew <= 0 || eh <= 0
      return { image: image.crop(cx, cy, cw, ch), origin_x: cx, origin_y: cy,
               inner_x: 0, inner_y: 0, inner_w: cw, inner_h: ch }
    end

    expanded = image.crop(ex, ey, ew, eh)

    sigma = [cw, ch].min * 0.08
    sigma = [sigma, 2.0].max
    blurred = expanded.gaussblur(sigma)

    inner_x = cx - ex
    inner_y = cy - ey

    mask = Vips::Image.black(ew, eh)
    white_rect = Vips::Image.black(cw, ch).invert
    mask = mask.insert(white_rect, inner_x, inner_y)

    feather = [sigma * 0.5, 1.0].max
    mask = mask.gaussblur(feather)

    mask_f = mask.cast(:float) / 255.0
    sharp_f = expanded.cast(:float)
    blurred_f = blurred.cast(:float)

    if sharp_f.bands > 1 && mask_f.bands == 1
      mask_f = mask_f.bandjoin([mask_f] * (sharp_f.bands - 1))
    end

    result = (sharp_f * mask_f + blurred_f * (mask_f * -1 + 1)).cast(:uchar)
    { image: result, origin_x: ex, origin_y: ey,
      inner_x: inner_x, inner_y: inner_y, inner_w: cw, inner_h: ch }
  end

  # ==================================================
  # Grid Classification: Response Schemas
  # ==================================================

  def grid_l1_schema
    {
      type: 'OBJECT',
      properties: {
        scene_description: { type: 'STRING' },
        has_perimeter_wall: { type: 'BOOLEAN', description: 'Does this map have an outer perimeter wall enclosing the space? FALSE for open terrain (forest, field, street), TRUE for rooms/buildings with visible boundary walls.' },
        has_inner_walls: { type: 'BOOLEAN', description: 'Are there interior partition walls INSIDE the space dividing it into sub-rooms or corridors? Do NOT count the outer perimeter wall. TRUE only if you can see structural walls that divide the interior.' },
        wall_visual: { type: 'STRING', description: 'Brief description of what walls look like on this map (color, material, texture)' },
        floor_visual: { type: 'STRING', description: 'Brief description of what the floor looks like (color, material, texture)' },
        lighting_direction: { type: 'STRING', description: 'Direction shadows are cast (e.g. "shadows fall to the southeast") or "no visible shadows"' },
        standard_types_present: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: {
              type_name: { type: 'STRING' },
              visual_description: { type: 'STRING', description: 'What this type looks like on this specific map (color, shape, material)' },
              short_description: { type: 'STRING', description: '2-4 word visual phrase for image segmentation (e.g. "dark wooden table", "grey stone pillar")' }
            },
            required: %w[type_name visual_description short_description]
          },
          description: 'Standard types visible on this map, each with a visual description'
        },
        custom_types: {
          type: 'ARRAY',
          description: 'Custom types are ALWAYS traversable. If something blocks movement, use wall instead.',
          items: {
            type: 'OBJECT',
            properties: {
              type_name: { type: 'STRING' },
              visual_description: { type: 'STRING' },
              short_description: { type: 'STRING', description: '2-4 word visual phrase for image segmentation (e.g. "iron-banded barrel", "stone forge pit")' },
              provides_cover: { type: 'BOOLEAN', description: 'Does this provide cover from ranged attacks?' },
              is_exit: { type: 'BOOLEAN', description: 'Is this a door, gate, or passage?' },
              difficult_terrain: { type: 'BOOLEAN', description: 'Does this slow movement?' },
              elevation: { type: 'INTEGER', description: 'Height in feet above floor (0 for floor-level objects)' },
              hazards: { type: 'ARRAY', items: { type: 'STRING' }, description: 'Hazard types if any: fire, acid, cold, lightning, poison, necrotic, radiant, psychic, thunder, force' }
            },
            required: %w[type_name visual_description short_description provides_cover is_exit difficult_terrain elevation hazards]
          }
        },
        light_sources: {
          type: 'ARRAY',
          description: 'Light-emitting objects visible on the map. Do NOT include windows or ambient light.',
          items: {
            type: 'OBJECT',
            properties: {
              source_type: { type: 'STRING', enum: LIGHT_SOURCE_TYPES,
                             description: 'fire=campfire/fireplace/brazier, torch=wall sconce/torch, candle=candle/candelabra, gaslamp=oil lamp/lantern/streetlamp, electric_light=fluorescent/spotlight, magical_light=glowing crystal/rune/orb' },
              description: { type: 'STRING', description: 'What it looks like (e.g. "iron wall sconce with flame", "candelabra on table")' },
              short_description: { type: 'STRING', description: '2-4 word visual phrase for image segmentation (e.g. "iron wall sconce", "stone hearth fire")' },
              squares: { type: 'ARRAY', items: { type: 'INTEGER' }, description: 'Which grid squares (1-9) contain this light source' }
            },
            required: %w[source_type description short_description squares]
          }
        },
        squares: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: {
              square: { type: 'INTEGER' },
              description: { type: 'STRING' },
              has_walls: { type: 'BOOLEAN' },
              wall_description: { type: 'STRING' },
              has_interior_walls: { type: 'BOOLEAN' },
              interior_wall_description: { type: 'STRING' },
              objects: { type: 'ARRAY', items: {
                type: 'OBJECT',
                properties: {
                  type: { type: 'STRING' },
                  count: { type: 'INTEGER' },
                  location: { type: 'STRING' }
                },
                required: %w[type count location]
              }}
            },
            required: %w[square description has_walls wall_description has_interior_walls interior_wall_description objects]
          }
        },
        perimeter_wall_doors: {
          type: 'ARRAY',
          description: 'Directions where doors, archways, or openings exist in the outer perimeter wall. May be incomplete — only include directions you are confident about.',
          items: { type: 'STRING', enum: %w[n s e w nw ne sw se] }
        },
        internal_walls: {
          type: 'ARRAY',
          description: 'Interior partition walls that divide the space. Only include walls you can clearly see. May be incomplete.',
          items: {
            type: 'OBJECT',
            properties: {
              location: { type: 'STRING', enum: %w[n s e w nw ne sw se center],
                          description: 'Which part of the room this wall is in' },
              has_door: { type: 'BOOLEAN', description: 'Does this interior wall have a door or opening?' },
              door_side: { type: 'STRING', enum: %w[n s e w nw ne sw se none],
                           description: 'Which side of the wall the door is on, or "none" if no door' }
            },
            required: %w[location has_door door_side]
          }
        }
      },
      required: %w[scene_description has_perimeter_wall has_inner_walls wall_visual floor_visual lighting_direction standard_types_present custom_types light_sources squares perimeter_wall_doors internal_walls]
    }
  end

  def grid_l2_schema(feature_list)
    sub_props = {
      square: { type: 'INTEGER' },
      description: { type: 'STRING' },
      has_walls: { type: 'BOOLEAN' },
      wall_pct: { type: 'INTEGER', description: 'Percentage of subsquare area covered by wall structures (0-100)' },
      floor_pct: { type: 'INTEGER', description: 'Percentage of subsquare area that is open floor (0-100)' }
    }
    sub_required = %w[square description has_walls wall_pct floor_pct]

    if feature_list.any?
      sub_props[:objects] = { type: 'ARRAY', items: {
        type: 'OBJECT',
        properties: {
          type: { type: 'STRING', enum: feature_list },
          count: { type: 'INTEGER' },
          location: { type: 'STRING' },
          coverage_pct: { type: 'INTEGER', description: 'Percentage of subsquare area this object takes up (0-100)' }
        },
        required: %w[type count location coverage_pct]
      }}
      sub_required << 'objects'
    end

    {
      type: 'OBJECT',
      properties: {
        subsquares: {
          type: 'ARRAY',
          items: {
            type: 'OBJECT',
            properties: sub_props,
            required: sub_required
          }
        }
      },
      required: %w[subsquares]
    }
  end

  def grid_l3_schema(feature_list, allow_walls: true)
    props = { area_description: { type: 'STRING' } }
    req = %w[area_description]

    if allow_walls
      props[:walls] = { type: 'ARRAY', items: { type: 'INTEGER' } }
      req << 'walls'
    end

    if feature_list.any?
      feat_props = {
        type: { type: 'STRING', enum: feature_list },
        description: { type: 'STRING' },
        cells: { type: 'ARRAY', items: { type: 'INTEGER' } }
      }
      feat_required = %w[type description cells]

      if feature_list.any? { |f| %w[staircase ladder].include?(f) }
        feat_props[:ascending_direction] = {
          type: 'STRING',
          enum: %w[north south east west northeast northwest southeast southwest],
          description: 'Direction the staircase/ladder ascends toward (only for staircase/ladder features)'
        }
      end

      props[:features] = {
        type: 'ARRAY',
        items: {
          type: 'OBJECT',
          properties: feat_props,
          required: feat_required
        }
      }
      req << 'features'
    end
    {
      type: 'OBJECT',
      properties: props,
      required: req
    }
  end

  # ==================================================
  # Grid Classification: Prompts
  # ==================================================

  def grid_l1_prompt(grid_n = 3)
    total_squares = grid_n * grid_n
    GamePrompts.get('battle_maps.grid.l1_analysis',
      grid_n: grid_n, total_squares: total_squares,
      standard_feature_types: STANDARD_FEATURE_TYPES.join(', '))
  end

  def grid_l2_prompt(l1_square, custom_types, grid_state)
    context = ["This section contains: #{l1_square['description']}"]

    wall_visual = grid_state[:wall_visual] || ''
    if l1_square['has_walls']
      desc = l1_square['wall_description']
      wall_info = desc && !desc.empty? ? desc : 'present along edges'
      wall_info += " (#{wall_visual})" if !wall_visual.empty?
      context << "Walls: #{wall_info}"
    else
      context << "No walls in this section."
    end

    if l1_square['has_interior_walls']
      desc = l1_square['interior_wall_description']
      context << "Interior partition walls: #{desc && !desc.empty? ? desc : 'present'}"
    end

    objects = l1_square['objects'] || []
    if objects.any?
      obj_list = objects.map { |o| "#{o['count']} #{o['type']}#{o['count'] > 1 ? 's' : ''} (#{o['location']})" }.join(', ')
      context << "Objects: #{obj_list}"
    end

    square_types = objects.map { |o| o['type'] }.uniq

    type_visuals = (grid_state[:type_visuals] || {}).select { |k, _| square_types.include?(k) }
    if type_visuals.any?
      type_info = type_visuals.map { |name, desc| "- #{name}: #{desc}" }.join("\n")
      context << "What each type looks like:\n#{type_info}"
    end

    wall_inheritance = l1_square['has_walls'] ? '' : ' The parent section has NO walls, so has_walls should be false for all subsquares.'
    types_instruction = if square_types.any?
                          "\nObject types to place: #{square_types.join(', ')}. ONLY use these types — do not invent new ones."
                        else
                          "\nNo objects in this section — all subsquares should have empty objects lists."
                        end

    GamePrompts.get('battle_maps.grid.l2_refinement',
      context: context.join("\n"), wall_inheritance: wall_inheritance,
      types_instruction: types_instruction)
  end

  def grid_l3_prompt(l2_data, custom_types, grid_state, allow_walls: true)
    tasks = []
    wall_visual = grid_state[:wall_visual] || ''
    if allow_walls && l2_data['has_walls']
      wall_pct = l2_data['wall_pct'] || 0
      wall_look = wall_visual.empty? ? '' : " (#{wall_visual})"
      tasks << "Mark which cells are wall#{wall_look}#{wall_pct > 0 ? " — walls cover ~#{wall_pct}% of this area" : ''}"
    end

    objects = l2_data['objects'] || []
    objects.each do |obj|
      count = obj['count'] || 1
      coverage = obj['coverage_pct']
      size_hint = coverage ? " (~#{coverage}% of area)" : ''
      visual = (grid_state[:type_visuals] || {})[obj['type']]
      look = visual ? " — looks like: #{visual}" : ''
      tasks << "Place #{count} #{obj['type']}#{count > 1 ? 's' : ''} (#{obj['location']})#{size_hint}#{look}"
    end

    if tasks.empty?
      tasks << "This area is open floor — no walls or features to mark"
    end

    floor_pct = l2_data['floor_pct']
    floor_hint = floor_pct ? "\nThis area is ~#{floor_pct}% open floor. Most cells should be left unassigned (floor)." : ''

    floor_visual = grid_state[:floor_visual] || ''
    lighting = grid_state[:lighting] || ''

    wall_rule = if allow_walls
                  "\"walls\" = areas where characters CANNOT stand on or walk through — room perimeter walls, structural barriers, impassable borders. Walls are typically 1 cell thick. Only mark cells whose CENTER is on the actual wall structure, not floor next to a wall.#{wall_visual.empty? ? '' : " Walls look like: #{wall_visual}."}"
                else
                  'No walls exist in this area — do not classify any cells as wall.'
                end
    floor_visual_rule = floor_visual.empty? ? '' : "\n- The floor looks like: #{floor_visual}. Do NOT confuse floor texture with walls."
    lighting_rule = lighting.empty? ? '' : " #{lighting}."

    GamePrompts.get('battle_maps.grid.l3_placement',
      tasks: tasks.map { |t| "• #{t}" }.join("\n"),
      floor_hint: floor_hint, wall_rule: wall_rule,
      floor_visual_rule: floor_visual_rule, lighting_rule: lighting_rule)
  end

  # ==================================================
  # Grid Classification: Batch LLM Helper
  # ==================================================

  # Submit LLM classification calls via Sidekiq batch queue.
  # Each item must have [:base64] and [:prompt]. Block returns schema per item.
  # Returns array of { success:, parsed:, text: } or { success: false, error: } (nil for missing).
  def run_grid_batch_classify(items, &schema_block)
    return [] if items.empty?

    requests = items.each_with_index.map do |item, idx|
      schema = schema_block.call(item)
      messages = [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/png', data: item[:base64] },
        { type: 'text', text: item[:prompt] }
      ]}]

      {
        messages: messages,
        provider: 'google_gemini',
        model: GRID_BATCH_MODEL,
        options: { max_tokens: 4096, timeout: 300, temperature: 0, thinking_budget: 0 },
        response_schema: schema,
        context: { index: idx }
      }
    end

    batch = LLM::Client.batch_submit(requests)
    warn "[AIBattleMapGenerator] Grid batch: submitted #{requests.length} requests, waiting..."
    completed = batch.wait!(timeout: 300)
    unless completed
      warn "[AIBattleMapGenerator] Grid batch: timed out after 300s"
    end

    results = Array.new(items.length)
    batch.results.each do |req|
      ctx = req.parsed_context
      idx = ctx['index'] || ctx[:index]
      next unless idx

      if req.completed?
        text = req.response_text
        parsed = text ? (JSON.parse(text) rescue nil) : nil
        results[idx] = { success: true, parsed: parsed, text: text }
      else
        results[idx] = { success: false, error: req.error_message }
      end
    end

    results
  end

  # ==================================================
  # Grid Classification: Pipeline Stages
  # ==================================================

  # L2: Per-square 2x2 refinement. Returns actionable subsquares for L3.
  def run_grid_l2(non_empty_l1, l1_cells, feature_types, base_image, grid_state)
    warn "[AIBattleMapGenerator] [Grid L2] Refining #{non_empty_l1.length} L1 squares (batch)..."
    t0 = Time.now

    l2_prepared = non_empty_l1.filter_map do |l1_square|
      sq_num = l1_square['square']
      cell = l1_cells[sq_num]
      next unless cell

      blur_result = crop_cell_with_blur(base_image, cell, blur_pct: 0.25)
      inset = { x: blur_result[:inner_x], y: blur_result[:inner_y],
                w: blur_result[:inner_w], h: blur_result[:inner_h] }
      l2_result = overlay_square_grid(blur_result[:image], 2, inset: inset)

      # Encode to PNG for LLM
      l2_buf = l2_result[:image].write_to_buffer('.png')
      l2_base64 = Base64.strict_encode64(l2_buf)

      sq_types = (l1_square['objects'] || []).map { |o| o['type'] }.uniq
      prompt = grid_l2_prompt(l1_square, grid_state[:custom_types] || [], grid_state)

      { sq_num: sq_num, cell: cell, l1_square: l1_square, cells: l2_result[:cells],
        base64: l2_base64, sq_types: sq_types, prompt: prompt,
        l1_has_walls: !!l1_square['has_walls'],
        blur_origin_x: blur_result[:origin_x], blur_origin_y: blur_result[:origin_y] }
    end

    all_l2_subsquares = []
    failed = 0

    batch_results = run_grid_batch_classify(l2_prepared) do |prep|
      grid_l2_schema(prep[:sq_types].uniq)
    end

    l2_prepared.each_with_index do |prep, idx|
      result = batch_results[idx]
      parsed = result&.dig(:parsed) if result&.dig(:success)

      if parsed
        subsquares = parsed['subsquares'] || []
        subsquares.each do |sub|
          l2_cell = prep[:cells][sub['square']]
          next unless l2_cell
          sub['has_walls'] = false unless prep[:l1_has_walls]
          all_l2_subsquares << {
            l1_square: prep[:sq_num], l1_cell: prep[:cell],
            l2_square: sub['square'], l2_cell: l2_cell, data: sub,
            l1_has_walls: prep[:l1_has_walls],
            l2_blur_origin_x: prep[:blur_origin_x], l2_blur_origin_y: prep[:blur_origin_y]
          }
        end
      else
        fail_reason = result&.dig(:error) || 'no response'
        warn "[AIBattleMapGenerator] L2 sq#{prep[:sq_num]}: FAILED - #{fail_reason}"
        failed += 1
      end
    end

    elapsed = Time.now - t0
    warn "[AIBattleMapGenerator] L2 done in #{elapsed.round(1)}s (#{l2_prepared.length} squares, #{failed} failed)"

    # Filter: skip pure floor subsquares
    actionable = all_l2_subsquares.select do |s|
      d = s[:data]
      d['has_walls'] || (d['objects'] || []).any?
    end
    skipped = all_l2_subsquares.length - actionable.length
    warn "[AIBattleMapGenerator] #{actionable.length} need L3, #{skipped} pure floor skipped"

    actionable
  end

  # L3: Per-subsquare adaptive grid classification. Returns grid_cell_results.
  def run_grid_l3(actionable_subsquares, feature_types, base_image, hex_pixel_map, grid_state)
    warn "[AIBattleMapGenerator] [Grid L3] Classifying #{actionable_subsquares.length} actionable subsquares (batch)..."
    t0 = Time.now

    l3_prepared = actionable_subsquares.filter_map do |sub|
      l2_cell = sub[:l2_cell]
      l2_data = sub[:data]

      l2_origin_x = sub[:l2_blur_origin_x]
      l2_origin_y = sub[:l2_blur_origin_y]
      abs_x = l2_origin_x + l2_cell[:x]
      abs_y = l2_origin_y + l2_cell[:y]
      abs_w = l2_cell[:w]
      abs_h = l2_cell[:h]

      # Grid size based on pixel dimensions — target ~hex_diameter per cell
      hex_size = hex_pixel_map[:hex_size]
      cells_across = (abs_w / (hex_size * 1.5)).ceil
      cells_down = (abs_h / (hex_size * 1.5)).ceil
      grid_n = [[([cells_across, cells_down].max), 2].max, 5].min

      cell_info = { x: abs_x, y: abs_y, w: abs_w, h: abs_h }
      blur_result = crop_cell_with_blur(base_image, cell_info, blur_pct: 0.25)
      inset = { x: blur_result[:inner_x], y: blur_result[:inner_y],
                w: blur_result[:inner_w], h: blur_result[:inner_h] }
      l3_result = overlay_square_grid(blur_result[:image], grid_n, inset: inset)

      l3_buf = l3_result[:image].write_to_buffer('.png')
      l3_base64 = Base64.strict_encode64(l3_buf)

      sub_types = (l2_data['objects'] || []).map { |o| o['type'] }.uniq
      allow_walls = !!l2_data['has_walls']
      prompt = grid_l3_prompt(l2_data, grid_state[:custom_types] || [], grid_state, allow_walls: allow_walls)

      { l1_sq: sub[:l1_square], l2_sq: sub[:l2_square],
        blur_origin_x: blur_result[:origin_x], blur_origin_y: blur_result[:origin_y],
        abs_w: abs_w, abs_h: abs_h,
        grid_n: grid_n, cells: l3_result[:cells],
        base64: l3_base64, sub_types: sub_types,
        prompt: prompt, l2_data: l2_data, allow_walls: allow_walls }
    end

    grid_cell_results = []
    failed = 0

    batch_results = run_grid_batch_classify(l3_prepared) do |prep|
      grid_l3_schema(prep[:sub_types].uniq, allow_walls: prep[:allow_walls])
    end

    l3_prepared.each_with_index do |prep, idx|
      result = batch_results[idx]
      parsed = result&.dig(:parsed) if result&.dig(:success)

      if parsed
        # Wall capping: cap at 1.5x L2's wall_pct estimate
        walls = parsed['walls'] || []
        wall_pct = prep[:l2_data]['wall_pct'] || 0
        total_cells = prep[:grid_n] ** 2
        max_wall_cells = ((wall_pct / 100.0) * total_cells * 1.5).ceil
        max_wall_cells = [max_wall_cells, 1].max if wall_pct > 0
        if walls.length > max_wall_cells && max_wall_cells < walls.length
          grid_n = prep[:grid_n]
          walls_with_edge_dist = walls.map do |c|
            row = (c - 1) / grid_n
            col = (c - 1) % grid_n
            edge_dist = [row, col, grid_n - 1 - row, grid_n - 1 - col].min
            [c, edge_dist]
          end
          walls_with_edge_dist.sort_by! { |_, d| d }
          parsed['walls'] = walls_with_edge_dist.first(max_wall_cells).map(&:first)
          warn "[AIBattleMapGenerator] L3 #{prep[:l1_sq]}_#{prep[:l2_sq]}: wall cap #{walls.length}->#{parsed['walls'].length} (wall_pct=#{wall_pct}, max=#{max_wall_cells})"
        end

        grid_cell_results << {
          blur_origin_x: prep[:blur_origin_x], blur_origin_y: prep[:blur_origin_y],
          abs_w: prep[:abs_w], abs_h: prep[:abs_h],
          grid_n: prep[:grid_n], cells: prep[:cells], data: parsed
        }
      else
        fail_reason = result&.dig(:error) || 'no response'
        warn "[AIBattleMapGenerator] L3 #{prep[:l1_sq]}_#{prep[:l2_sq]}: FAILED - #{fail_reason}"
        failed += 1
      end
    end

    elapsed = Time.now - t0
    warn "[AIBattleMapGenerator] L3 done in #{elapsed.round(1)}s (#{l3_prepared.length} subsquares, #{failed} failed)"

    grid_cell_results
  end

  # Map grid cell results to hex assignments using polygon intersection.
  # Returns array of chunk_results hashes: [{ 'x' => hx, 'y' => hy, 'hex_type' => type }, ...]
  def map_grid_to_hexes(grid_cell_results, hex_pixel_map)
    return [] if grid_cell_results.nil? || grid_cell_results.empty?

    hex_positions = @coord_lookup.filter_map do |(hx, hy), info|
      next unless info.is_a?(Hash) && info[:px]
      [hx, hy, info[:px], info[:py]]
    end

    hex_coverage_threshold = 0.50
    hex_size = hex_pixel_map[:hex_size]
    hex_area = (3.0 * Math.sqrt(3) / 2.0) * hex_size * hex_size

    # Build flat list of classified cell rectangles with types
    classified_rects = []
    grid_cell_results.each do |result|
      origin_x = result[:blur_origin_x]
      origin_y = result[:blur_origin_y]
      cells = result[:cells]
      data = result[:data]
      next unless data && cells

      cell_types = {}
      (data['walls'] || []).each { |c| cell_types[c] = { type: 'wall' } }
      (data['features'] || []).each do |feat|
        meta = { type: feat['type'] }
        meta[:ascending_direction] = feat['ascending_direction'] if feat['ascending_direction']
        (feat['cells'] || []).each { |c| cell_types[c] = meta }
      end

      cell_types.each do |cell_num, meta|
        cell = cells[cell_num]
        next unless cell
        rect = {
          x: origin_x + cell[:x], y: origin_y + cell[:y],
          w: cell[:w], h: cell[:h], type: meta[:type]
        }
        rect[:ascending_direction] = meta[:ascending_direction] if meta[:ascending_direction]
        classified_rects << rect
      end
    end

    # For each hex, find overlapping rects and compute intersection area
    hex_assignments = {}
    hex_positions.each do |hx, hy, px, py|
      hex_poly = hexagon_points_array(px, py, hex_size)
      type_areas = Hash.new(0.0)
      type_meta = {}

      classified_rects.each do |rect|
        # Quick bounding box check
        next if px + hex_size < rect[:x] || px - hex_size > rect[:x] + rect[:w]
        next if py + hex_size < rect[:y] || py - hex_size > rect[:y] + rect[:h]

        rect_poly = [
          [rect[:x], rect[:y]], [rect[:x] + rect[:w], rect[:y]],
          [rect[:x] + rect[:w], rect[:y] + rect[:h]], [rect[:x], rect[:y] + rect[:h]]
        ]
        area = polygon_intersection_area(hex_poly, rect_poly)
        if area > 0
          type_areas[rect[:type]] += area
          if !type_meta[rect[:type]] || area > (type_meta[rect[:type]][:best_area] || 0)
            type_meta[rect[:type]] = { best_area: area, ascending_direction: rect[:ascending_direction] }
          end
        end
      end

      next if type_areas.empty?
      best_type, best_area = type_areas.max_by { |_, a| a }
      coverage = best_area / hex_area
      if coverage >= hex_coverage_threshold
        assignment = { type: best_type, distance: 0 }
        if type_meta[best_type]&.dig(:ascending_direction)
          assignment[:ascending_direction] = type_meta[best_type][:ascending_direction]
        end
        hex_assignments[[hx, hy]] = assignment
      end
    end

    # Convert to standard chunk_results format
    hex_assignments.map do |(hx, hy), info|
      result = { 'x' => hx, 'y' => hy, 'hex_type' => info[:type] }
      result['ascending_direction'] = info[:ascending_direction] if info[:ascending_direction]
      result
    end
  end

  # ==================================================
  # Grid Classification: Main Orchestrator
  # ==================================================

  # Grid-based hex classification pipeline.
  # L1 (full image NxN with thinking) → L2 (per-square 2x2 refinement) → L3 (per-subsquare adaptive grid)
  # Then polygon intersection to map grid cells to hex coordinates.
  #
  # @param local_path [String] path to the battle map image
  # @return [Array<Hash>] hex data ready for persist_hex_data
  def analyze_hexes_with_grid(local_path)
    return [] unless local_path && File.exist?(local_path)

    require 'vips'

    hex_coords = generate_hex_coordinates
    min_x = hex_coords.map { |x, _| x }.min
    min_y = hex_coords.map { |_, y| y }.min

    base = Vips::Image.new_from_file(local_path)
    @inspection_base = base
    img_width = base.width
    img_height = base.height
    hex_pixel_map = build_hex_pixel_map(hex_coords, min_x, min_y, img_width, img_height)

    @coord_lookup = {}
    @inspection_hex_size = hex_pixel_map[:hex_size]
    hex_pixel_map.each do |_label, info|
      next unless info.is_a?(Hash) && info[:hx]
      @coord_lookup[[info[:hx], info[:hy]]] = info
    end

    hex_size = hex_pixel_map[:hex_size]

    warn "[AIBattleMapGenerator] Grid pipeline: #{hex_coords.length} hexes, image #{img_width}x#{img_height}"

    # Save hex grid metadata for inspection
    save_inspection_metadata(:hex_grid, {
      hex_count: hex_coords.length, image_size: "#{img_width}x#{img_height}",
      hex_size: hex_size
    }) rescue nil

    # --- Detect small rooms ---
    total_pixels = img_width * img_height
    pixels_per_hex = total_pixels.to_f / hex_coords.length
    is_small_room = pixels_per_hex < SMALL_ROOM_THRESHOLD

    l1_grid_n = is_small_room ? 4 : 3
    warn "[AIBattleMapGenerator] Room: #{total_pixels} px, #{hex_coords.length} hexes, #{pixels_per_hex.round(1)} px/hex → #{is_small_room ? 'SMALL (4x4 L1)' : 'normal (3x3 L1)'}"

    # === Parallel fan-out: edge detection + depth estimation start now ===
    depth_thread = Thread.new do
      if ReplicateDepthService.available?
        depth_source = @shadowed_image_path || local_path
        ReplicateDepthService.estimate(depth_source)
      else
        { success: false, error: 'Replicate not available' }
      end
    end

    edge_thread = Thread.new do
      shadow_edge = generate_shadow_aware_edge_map(local_path)
      if shadow_edge
        { success: true, edge_map: shadow_edge, source: :shadow_aware }
      else
        local = generate_local_edge_map(base)
        local ? { success: true, edge_map: local, source: :local_sobel } : { success: false }
      end
    end

    # --- Level 1: Overview + NxN Grid (discovers types + scene) ---
    warn "[AIBattleMapGenerator] [Grid L1] Full image #{l1_grid_n}x#{l1_grid_n} (with thinking)..."
    t0_l1 = Time.now

    l1_result = overlay_square_grid(base, l1_grid_n)
    l1_cells = l1_result[:cells]

    # Encode L1 image to PNG for LLM
    l1_buf = l1_result[:image].write_to_buffer('.png')
    l1_base64 = Base64.strict_encode64(l1_buf)
    l1_prompt_text = grid_l1_prompt(l1_grid_n)

    response = LLM::Adapters::GeminiAdapter.generate(
      messages: [{ role: 'user', content: [
        { type: 'image', mime_type: 'image/png', data: l1_base64 },
        { type: 'text', text: l1_prompt_text }
      ]}],
      model: GRID_L1_MODEL,
      api_key: AIProviderService.api_key_for('google_gemini'),
      response_schema: grid_l1_schema,
      options: { max_tokens: 32768, timeout: 300, temperature: 0, thinking_level: 'MEDIUM' }
    )

    l1_data = nil
    l1_text = response[:text] || response[:content]
    if l1_text
      l1_data = JSON.parse(l1_text) rescue nil
    end

    unless l1_data
      warn "[AIBattleMapGenerator] Grid L1 failed, falling back to overview pipeline"
      edge_thread.kill rescue nil
      depth_thread.kill rescue nil
      return analyze_hexes_with_overview(local_path)
    end

    @l1_classification_data = l1_data
    squares = l1_data['squares'] || []
    grid_standard_types = l1_data['standard_types_present'] || []
    standard = grid_standard_types.map { |t| t['type_name'] }
    grid_custom_types = l1_data['custom_types'] || []
    custom = grid_custom_types.map { |c| c['type_name'] }

    # Build visual descriptions lookup
    type_visuals = {}
    grid_standard_types.each { |t| type_visuals[t['type_name']] = t['visual_description'] }
    grid_custom_types.each { |c| type_visuals[c['type_name']] = c['visual_description'] }

    feature_types = (standard + custom).uniq
    warn "[AIBattleMapGenerator] L1: #{squares.length} squares, #{feature_types.length} types (#{(Time.now - t0_l1).round(1)}s)"
    warn "[AIBattleMapGenerator] Standard: #{standard.join(', ')}"
    warn "[AIBattleMapGenerator] Custom: #{custom.join(', ')}" if custom.any?

    # Save L1 grid image and metadata for inspection
    begin
      save_inspection_image(l1_result[:image], '04_l1_grid.png')
      save_inspection_metadata(:l1, {
        grid_n: l1_grid_n, squares: squares.length,
        standard_types: standard, custom_types: custom,
        scene: l1_data['scene_description'],
        wall_visual: l1_data['wall_visual'],
        floor_visual: l1_data['floor_visual'],
        duration_s: (Time.now - t0_l1).round(1)
      })
    rescue StandardError => e
      warn "[AIBattleMapGenerator] L1 inspection save failed: #{e.message}"
    end

    # Grid state passed to L2/L3 prompts
    grid_state = {
      wall_visual: l1_data['wall_visual'] || '',
      floor_visual: l1_data['floor_visual'] || '',
      lighting: l1_data['lighting_direction'] || '',
      type_visuals: type_visuals,
      custom_types: grid_custom_types
    }

    # Build type properties for custom types (for map_results_to_room_hex)
    grid_type_properties = {}
    grid_custom_types.each do |ct|
      props = {}
      props['traversable'] = true  # custom types are always traversable
      props['provides_cover'] = ct['provides_cover'] if ct['provides_cover']
      props['is_exit'] = ct['is_exit'] if ct['is_exit']
      props['difficult_terrain'] = ct['difficult_terrain'] if ct['difficult_terrain']
      props['elevation'] = ct['elevation'] if ct['elevation'] && ct['elevation'] > 0
      props['hazards'] = ct['hazards'] if ct['hazards'] && !ct['hazards'].empty?
      grid_type_properties[ct['type_name']] = props
    end

    non_empty_l1 = squares

    # --- Pre-fire SAM for windows/water/lights (runs in parallel with L2/L3) ---
    prefetched_sam_threads = {}
    l1_light_sources = l1_data['light_sources'] || []
    if ReplicateSamService.available?
      has_windows = (feature_types & SAM_WINDOW_TYPES).any?
      has_water = (feature_types & SAM_WATER_TYPES).any?
      if has_windows
        prefetched_sam_threads['glass_window'] = Thread.new do
          ReplicateSamService.segment_with_samg_fallback(local_path, 'window', suffix: '_sam_glass_window')
        end
        warn "[AIBattleMapGenerator] Pre-fired SAM for windows (parallel with L2/L3)"
      end
      if has_water
        prefetched_sam_threads['water'] = Thread.new do
          ReplicateSamService.segment_with_samg_fallback(local_path, 'water', suffix: '_sam_water')
        end
        warn "[AIBattleMapGenerator] Pre-fired SAM for water (parallel with L2/L3)"
      end
      has_foliage = (feature_types & SAM_FOLIAGE_TYPES).any?
      if has_foliage
        prefetched_sam_threads['foliage_tree'] = Thread.new do
          ReplicateSamService.segment_with_samg_fallback(local_path, 'tree', suffix: '_sam_foliage_tree')
        end
        prefetched_sam_threads['foliage_bush'] = Thread.new do
          ReplicateSamService.segment_with_samg_fallback(local_path, 'bush', suffix: '_sam_foliage_bush')
        end
        warn "[AIBattleMapGenerator] Pre-fired SAM for foliage (tree + bush, parallel with L2/L3)"
      end

      # Fire SAM for each unique light source type L1 identified.
      # Dedup by SAM query string — if two types map to the same query, share the thread.
      seen_queries = {}  # query_string => thread
      l1_light_sources.each do |ls|
        stype = ls['source_type']
        query = SAM_LIGHT_QUERIES[stype] || stype
        suffix = "_sam_light_#{stype}"

        if seen_queries[query]
          # Reuse existing thread for identical SAM query
          prefetched_sam_threads["light_#{stype}"] = seen_queries[query]
        else
          thread = Thread.new do
            ReplicateSamService.segment_with_samg_fallback(local_path, query, suffix: suffix)
          end
          prefetched_sam_threads["light_#{stype}"] = thread
          seen_queries[query] = thread
          warn "[AIBattleMapGenerator] Pre-fired SAM for light source: #{stype} (parallel with L2/L3)"
        end
      end
    end

    # --- Level 2/3 ---
    grid_cell_results = if is_small_room
      # Small rooms: L1 4x4 → L3 directly (skip L2)
      actionable_as_l2 = non_empty_l1.filter_map do |sq|
        l1_cell = l1_cells[sq['square']]
        next unless l1_cell
        {
          l1_square: sq['square'], l1_cell: l1_cell,
          l2_square: 1, l2_cell: l1_cell, data: sq,
          l1_has_walls: !!sq['has_walls'],
          l2_blur_origin_x: 0, l2_blur_origin_y: 0
        }
      end
      actionable = actionable_as_l2.select { |s| s[:data]['has_walls'] || (s[:data]['objects'] || []).any? }
      warn "[AIBattleMapGenerator] Small room: #{actionable.length}/#{non_empty_l1.length} L1 cells → L3 directly"
      run_grid_l3(actionable, feature_types, base, hex_pixel_map, grid_state)
    else
      actionable = run_grid_l2(non_empty_l1, l1_cells, feature_types, base, grid_state)
      run_grid_l3(actionable, feature_types, base, hex_pixel_map, grid_state)
    end

    # --- Map grid cells to hexes ---
    all_chunk_results = map_grid_to_hexes(grid_cell_results, hex_pixel_map)
    warn "[AIBattleMapGenerator] Grid classification: #{all_chunk_results.length} hexes classified"

    dist = all_chunk_results.each_with_object(Hash.new(0)) { |r, h| h[r['hex_type']] += 1 }
      .sort_by { |_, v| -v }.to_h
    warn "[AIBattleMapGenerator] Grid pre-normalization: #{dist}"

    # Save pre-normalization metadata and overlay for inspection
    begin
      save_inspection_metadata(:pre_normalization, { hex_count: all_chunk_results.length, distribution: dist })
      pre_norm_map = {}
      all_chunk_results.each { |r| pre_norm_map[[r['x'], r['y']]] = r['hex_type'] if r['x'] && r['y'] }
      render_inspection_overlay(pre_norm_map, base, '06_classify_raw.png')
    rescue StandardError => e
      warn "[AIBattleMapGenerator] Pre-norm inspection save failed: #{e.message}"
    end

    # --- Collect edge + depth results (fired in parallel at start) ---
    edge_map = collect_edge_result(edge_thread, base)

    # Save edge map for inspection
    begin
      save_inspection_image(edge_map, '05a_edge_map.png') if edge_map
    rescue StandardError => e
      warn "[AIBattleMapGenerator] Edge map inspection save failed: #{e.message}"
    end

    depth_result_raw = depth_thread.join(120)&.value

    # Save depth map for inspection
    begin
      if depth_result_raw&.dig(:success) && depth_result_raw[:depth_path]
        copy_inspection_file(depth_result_raw[:depth_path], '05b_depth_map.png')
      end
    rescue StandardError => e
      warn "[AIBattleMapGenerator] Depth map inspection save failed: #{e.message}"
    end

    depth_map, zone_map = process_depth_result(depth_result_raw, edge_map, base, hex_size, local_path)

    # Persist depth map path for downstream services (dynamic lighting)
    if depth_result_raw&.dig(:success) && depth_result_raw[:depth_path]
      room.update(depth_map_path: depth_result_raw[:depth_path])
    end

    # --- Normalization ---
    before_count = all_chunk_results.length
    normalization_context = NormalizationContext.new(
      edge_map: edge_map,
      zone_map: zone_map,
      depth_map: depth_map,
      image_path: local_path,
      type_properties: grid_type_properties,
      present_type_names: feature_types,
      prefetched_sam_threads: prefetched_sam_threads,
      l1_hints: {
        perimeter_wall_doors: l1_data['perimeter_wall_doors'] || [],
        internal_walls:       l1_data['internal_walls'] || []
      }
    )
    all_chunk_results = normalize_v3(all_chunk_results, base, hex_pixel_map, hex_coords, min_x, min_y,
                                     context: normalization_context)
    delta = all_chunk_results.length - before_count
    post_dist = all_chunk_results.each_with_object(Hash.new(0)) { |r, h| h[r['hex_type']] += 1 }
      .sort_by { |_, v| -v }.to_h
    warn "[AIBattleMapGenerator] Grid post-normalization: #{post_dist} (#{before_count} → #{all_chunk_results.length}, #{delta >= 0 ? "+#{delta}" : delta})"

    @final_typed_map = all_chunk_results.each_with_object({}) { |r, h| h[[r['x'], r['y']]] = r['hex_type'] }

    # Save post-normalization metadata for inspection
    save_inspection_metadata(:post_normalization, {
      hex_count: all_chunk_results.length, distribution: post_dist,
      delta: delta
    }) rescue nil

    # --- Persist SAM mask URLs for downstream services (effects, lighting) ---
    persist_sam_mask_urls(local_path, prefetched_sam_threads)

    # --- Extract and store light sources from L1 + SAM ---
    extract_and_store_light_sources(local_path, l1_light_sources, prefetched_sam_threads)

    # --- Map to RoomHex format ---
    map_results_to_room_hex(all_chunk_results, hex_coords, min_x, min_y, grid_type_properties)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Grid pipeline failed: #{e.class}: #{e.message}"
    warn e.backtrace&.first(5)&.join("\n")
    analyze_hexes_with_overview(local_path)
  end

  # V2 pipeline: L1 + SAM2G + Gemini wall/door recolor
  # Replaces the L1/L2/L3 grid classification + normalization pipeline.
  def analyze_hexes_v2(local_path, fight_id: nil)
    return [] unless local_path && File.exist?(local_path)

    stage_pct = { l1_done: 75, sam_done: 85, wall_done: 90, hex_done: 93 }
    on_progress = if fight_id
      ->(stage, msg) { publish_progress(fight_id, stage_pct[stage] || 80, msg) }
    end

    pipeline = BattlemapV2::PipelineService.new(room: room, image_path: local_path, on_progress: on_progress)
    hex_data = pipeline.run
    return [] if hex_data.empty?

    hex_data
  rescue StandardError => e
    warn "[AIBattleMapGenerator] V2 pipeline failed: #{e.class}: #{e.message}"
    warn e.backtrace&.first(5)&.join("\n")
    []
  end

  # Publish completion message to Redis
  # @param fight_id [Integer] the fight ID
  # @param success [Boolean] whether generation succeeded
  # @param fallback [Boolean] whether procedural fallback was used
  # publish_completion provided by BattleMapPubsub

  # ---------------------------------------------------------------------------
  # Landscape rotation support
  #
  # Landscape rooms (width > 1.5× height) generate poorly as 16:9 images.
  # Instead, we temporarily swap the room to portrait orientation, run the full
  # generation pipeline, then rotate everything 90° CW back to landscape.
  # ---------------------------------------------------------------------------

  # Detect if room is landscape (width significantly exceeds height).
  def landscape_room?
    return false unless room_has_bounds?
    w = (room.max_x - room.min_x).to_f
    h = (room.max_y - room.min_y).to_f
    h > 0 && (w / h) > 1.5
  end

  # Swap room bounds to portrait orientation for generation.
  # Returns the original bounds hash for later restoration.
  def swap_to_portrait!
    orig = { min_x: room.min_x, max_x: room.max_x, min_y: room.min_y, max_y: room.max_y }
    room_w = room.max_x - room.min_x
    room_h = room.max_y - room.min_y
    room.update(max_x: room.min_x + room_h, max_y: room.min_y + room_w)
    warn "[AIBattleMapGenerator] Landscape room detected (#{room_w}×#{room_h}ft) — swapped to portrait for generation"
    orig
  end

  # Restore room bounds to original landscape orientation.
  def restore_bounds!(orig)
    room.update(min_x: orig[:min_x], max_x: orig[:max_x], min_y: orig[:min_y], max_y: orig[:max_y])
  end

  # Rotate everything from portrait back to landscape after generation.
  # Rotates: image file, mask files, hex data coordinates, light source positions.
  def rotate_landscape_to_final!
    room.reload
    image_url = room.battle_map_image_url
    return unless image_url

    image_path = File.join('public', image_url.sub(%r{^/}, ''))

    # Read image height BEFORE rotation (needed for light source coordinate transform)
    orig_h = File.exist?(image_path) ? Vips::Image.new_from_file(image_path).height : nil

    # Rotate the main image 90° CW
    rotate_image_cw!(image_path)

    # Rotate mask files (SAM effect masks + wall mask)
    wall_mask_url = room.respond_to?(:battle_map_wall_mask_url) ? room.battle_map_wall_mask_url : nil
    [room.battle_map_water_mask_url, room.battle_map_foliage_mask_url,
     room.battle_map_fire_mask_url, wall_mask_url].compact.each do |mask_url|
      mask_path = File.join('public', mask_url.sub(%r{^/}, ''))
      rotate_image_cw!(mask_path)
    end

    # Rotate depth maps used by lighting (if present)
    if room.respond_to?(:depth_map_path) && room.depth_map_path && File.exist?(room.depth_map_path)
      rotate_image_cw!(room.depth_map_path)
      zone_map_path = room.depth_map_path.sub(/(\.\w+)$/, '_zone_map.png')
      rotate_image_cw!(zone_map_path) if File.exist?(zone_map_path)
    end

    # Rotate hex data: portrait grid → landscape grid
    portrait_w = (room.max_y - room.min_y).to_f  # portrait width = landscape height
    portrait_h = (room.max_x - room.min_x).to_f  # portrait height = landscape width
    landscape_w = (room.max_x - room.min_x).to_f
    landscape_h = (room.max_y - room.min_y).to_f
    rotate_room_hex_data_cw!(portrait_w, portrait_h, landscape_w, landscape_h)

    # Rotate light source pixel coordinates
    if orig_h
      sources = room.respond_to?(:detected_light_sources) ? (room.detected_light_sources || []) : []
      if sources.respond_to?(:any?) && sources.any?
        rotated = sources.map do |s|
          s_hash = s.respond_to?(:to_h) ? s.to_h : s
          s_hash.merge(
            'center_x' => orig_h - s_hash['center_y'].to_f,
            'center_y' => s_hash['center_x'].to_f
          )
        end
        room.update(detected_light_sources: Sequel.pg_jsonb_wrap(JSON.parse(rotated.to_json)))
      end
    end

    # Keep stored wall mask dimensions in sync after rotation
    if wall_mask_url
      wall_mask_path = File.join('public', wall_mask_url.sub(%r{^/}, ''))
      if File.exist?(wall_mask_path)
        wall_mask_img = Vips::Image.new_from_file(wall_mask_path)
        room.update(
          battle_map_wall_mask_width: wall_mask_img.width,
          battle_map_wall_mask_height: wall_mask_img.height
        )
      end
    end

    # Update arena dims on active fights
    hex_count = room.room_hexes_dataset.count
    if hex_count > 0
      hex_data = room.room_hexes_dataset.all.map { |h| { x: h.hex_x, y: h.hex_y } }
      new_w, new_h = arena_dimensions_from_hex_data(hex_data)
      Fight.where(room_id: room.id).exclude(status: 'ended').update(arena_width: new_w, arena_height: new_h)
    end

    warn "[AIBattleMapGenerator] Rotated portrait → landscape (#{landscape_w}×#{landscape_h}ft)"
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Landscape rotation failed: #{e.message}"
  end

  # Rotate an image file 90° CW in-place using libvips.
  def rotate_image_cw!(path)
    return unless path && File.exist?(path)
    ext = File.extname(path)
    tmp = path.sub(ext, "_rot#{ext}")
    img = Vips::Image.new_from_file(path)
    img.rot(:d90).write_to_file(tmp)
    img = nil
    GC.start
    FileUtils.mv(tmp, path)
  rescue StandardError => e
    warn "[AIBattleMapGenerator] Image rotation failed for #{path}: #{e.message}"
  end

  # Rotate hex data from a portrait grid to a landscape grid.
  # Uses fractional position mapping: 90° CW rotation (fx, fy) → (1-fy, fx).
  def rotate_room_hex_data_cw!(portrait_w, portrait_h, landscape_w, landscape_h)
    portrait_hexes = room.room_hexes_dataset.all.map do |hex|
      { data: hex, x: hex.hex_x, y: hex.hex_y }
    end
    return if portrait_hexes.empty?

    # Compute portrait grid coordinate ranges
    port_coords = HexGrid.hex_coords_for_room(0, 0, portrait_w, portrait_h)
    port_max_x = port_coords.map(&:first).max.to_f
    port_max_y = port_coords.map(&:last).max.to_f

    # Compute landscape grid
    land_coords = HexGrid.hex_coords_for_room(0, 0, landscape_w, landscape_h)
    land_max_x = land_coords.map(&:first).max.to_f
    land_max_y = land_coords.map(&:last).max.to_f

    # Map portrait hexes to fractional positions and rotate CW
    port_frac = portrait_hexes.map do |ph|
      fx = port_max_x > 0 ? ph[:x].to_f / port_max_x : 0.5
      fy = port_max_y > 0 ? ph[:y].to_f / port_max_y : 0.5
      { rot_fx: 1.0 - fy, rot_fy: fx, hex: ph[:data] }
    end

    # Map landscape hexes to fractional positions
    land_frac = land_coords.map do |lx, ly|
      fx = land_max_x > 0 ? lx.to_f / land_max_x : 0.5
      fy = land_max_y > 0 ? ly.to_f / land_max_y : 0.5
      { hx: lx, hy: ly, fx: fx, fy: fy }
    end

    # Match each landscape hex to the closest rotated portrait hex
    used = Set.new
    now = Time.now
    rows = []

    land_frac.each do |lh|
      best = nil
      best_dist = Float::INFINITY
      port_frac.each_with_index do |ph, idx|
        next if used.include?(idx)
        dist = (ph[:rot_fx] - lh[:fx])**2 + (ph[:rot_fy] - lh[:fy])**2
        if dist < best_dist
          best_dist = dist
          best = idx
        end
      end

      if best
        used.add(best)
        src = port_frac[best][:hex]
        rows << {
          room_id: room.id, hex_x: lh[:hx], hex_y: lh[:hy],
          hex_type: src.hex_type, traversable: src.traversable,
          danger_level: src.danger_level, elevation_level: src.elevation_level,
          has_cover: src.has_cover, cover_object: src.cover_object,
          surface_type: src.surface_type, difficult_terrain: src.difficult_terrain,
          hazard_type: src.hazard_type, water_type: src.water_type,
          wall_feature: src.wall_feature,
          passable_edges: src.passable_edges,
          majority_floor: src.majority_floor,
          created_at: now, updated_at: now
        }
      else
        rows << {
          room_id: room.id, hex_x: lh[:hx], hex_y: lh[:hy],
          hex_type: 'normal', traversable: true,
          danger_level: 0, elevation_level: 0,
          has_cover: false, cover_object: nil,
          surface_type: 'stone', difficult_terrain: false,
          hazard_type: nil, water_type: nil,
          passable_edges: nil, majority_floor: false,
          created_at: now, updated_at: now
        }
      end
    end

    DB.transaction do
      room.room_hexes_dataset.delete
      RoomHex.multi_insert(rows) if rows.any?
    end
  end
end
