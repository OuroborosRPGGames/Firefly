# frozen_string_literal: true

class BattleMapGeneratorService
  # Constants now in GameConfig::BattleMap
  CATEGORY_DEFAULTS = GameConfig::BattleMap::CATEGORY_DEFAULTS
  CATEGORY_HAZARDS = GameConfig::BattleMap::CATEGORY_HAZARDS
  WATER_TYPE_WEIGHTS = GameConfig::BattleMap::WATER_TYPE_WEIGHTS

  include BattleMapConnectivity
  include BattleMapPubsub

  attr_reader :room, :config, :category

  # Initialize with a room to generate a battle map for
  # @param room [Room] the room to generate a battle map for
  def initialize(room)
    @room = room
    @config = build_config
    @category = room.battle_map_category
  end

  # Generate the battle map
  # Clears existing hex data and creates new procedural content
  # @return [Boolean] success
  def generate!
    return false unless room_has_bounds?

    DB.transaction do
      clear_existing_hexes
      generate_base_terrain
      place_cover_objects
      add_hazards
      generate_elevation if config[:elevation_variance].to_i > 0
      add_water_features if config[:water_chance].to_f > 0
      ensure_traversable_connectivity_in_db(room)
      crop_non_traversable_border_in_db(room)
      mark_battle_map_ready
    end

    true
  rescue StandardError => e
    warn "[BattleMapGeneratorService] generate! failed: #{e.message}"
    false
  end

  # Generate without transaction wrapper (for use in larger transactions)
  def generate_without_transaction!
    return false unless room_has_bounds?

    clear_existing_hexes
    generate_base_terrain
    place_cover_objects
    add_hazards
    generate_elevation if config[:elevation_variance].to_i > 0
    add_water_features if config[:water_chance].to_f > 0
    ensure_traversable_connectivity_in_db(room)
    crop_non_traversable_border_in_db(room)
    mark_battle_map_ready

    true
  end

  # Generate battle map with progress updates (for procedural fallback)
  # @param fight_id [Integer] the fight ID for progress publishing
  def generate_with_progress(fight_id)
    publish_progress(fight_id, 0, "Generating procedural battle map...")

    begin
      # Call existing generate! method
      success = generate!
      unless success
        publish_completion(fight_id, success: false, fallback: true)
        raise StandardError, 'Procedural generation returned false'
      end

      publish_progress(fight_id, 100, "Complete")
      publish_completion(fight_id, success: true, fallback: true)
    rescue StandardError => e
      warn "[BattleMapGenerator] Failed for room #{room.id}: #{e.message}"
      publish_completion(fight_id, success: false, fallback: true)
      raise
    end
  end

  private

  # publish_progress and publish_completion provided by BattleMapPubsub

  # Build configuration hash from room type and category defaults
  # Uses .key? checks for numeric fields so that explicit 0/0.0 values in
  # room configs are preserved, while missing keys fall through to category defaults.
  def build_config
    room_config = Room::ROOM_TYPE_CONFIGS[room.room_type] || Room::DEFAULT_ROOM_CONFIG
    category_config = CATEGORY_DEFAULTS[room.battle_map_category] || CATEGORY_DEFAULTS[:indoor]

    # Merge with category defaults filling in missing values.
    # For numeric fields, use .key? so that an explicit 0 or 0.0 in a room-specific
    # config is kept, but keys absent from the hash fall through to category defaults.
    {
      surfaces: room_config[:surfaces] || ['floor'],
      objects: room_config.key?(:objects) ? room_config[:objects] : category_objects(category_config),
      density: ((room_config[:density] || category_config[:cover_density]) * GameConfig::BattleMap::COVER_DENSITY_SCALE),
      dark: room_config[:dark] || false,
      difficult_terrain: room_config[:difficult_terrain] || false,
      water_chance: room_config.key?(:water_chance) ? room_config[:water_chance] : category_config[:water_chance],
      hazard_chance: room_config.key?(:hazard_chance) ? room_config[:hazard_chance] : category_config[:hazard_chance],
      explosive_chance: room_config.key?(:explosive_chance) ? room_config[:explosive_chance] : 0.0,
      elevation_variance: room_config.key?(:elevation_variance) ? room_config[:elevation_variance] : category_config[:elevation_variance],
      combat_optimized: room_config[:combat_optimized] || false
    }
  end

  # Default objects when a room config doesn't specify any
  def category_objects(_category_config)
    []
  end

  # Check if room has valid bounds for generation
  def room_has_bounds?
    room.min_x && room.max_x && room.min_y && room.max_y
  end

  # Clear any existing hex data
  def clear_existing_hexes
    room.room_hexes_dataset.delete
  end

  # Generate base terrain grid with surface types
  def generate_base_terrain
    surfaces = config[:surfaces]
    default_difficult = config[:difficult_terrain]

    # Generate proper offset hex coordinates for the room
    hex_coords = HexGrid.hex_coords_for_room(room.min_x, room.min_y, room.max_x, room.max_y)

    now = Time.now
    hex_data = hex_coords.map do |hex_x, hex_y|
      {
        room_id: room.id,
        hex_x: hex_x,
        hex_y: hex_y,
        hex_type: 'normal',
        traversable: true,
        danger_level: 0,
        surface_type: surfaces.sample,
        difficult_terrain: default_difficult,
        elevation_level: 0,
        cover_value: 0,
        created_at: now,
        updated_at: now
      }
    end

    # Bulk insert for performance
    RoomHex.multi_insert(hex_data) if hex_data.any?
  end

  # Place cover objects at ~20% density
  def place_cover_objects
    available_objects = config[:objects]
    return if available_objects.empty?

    target_density = config[:density]
    hexes = room.room_hexes_dataset.all
    target_count = (hexes.count * target_density).ceil

    # Get cover object type data for each available object
    cover_types = CoverObjectType.where(name: available_objects).to_hash(:name)

    # Shuffle and pick hexes to place cover
    hexes_to_cover = hexes.sample(target_count)

    hexes_to_cover.each do |hex|
      object_name = available_objects.sample
      cover_type = cover_types[object_name]

      # Skip multi-hex objects for simplicity (they'd need more complex placement)
      next if cover_type&.multi_hex?

      # Determine cover properties
      cover_value = cover_type&.default_cover_value || rand(1..3)
      cover_height = cover_type&.default_height || 1
      blocks_los = cover_type&.blocks_los || cover_value >= 3
      is_destroyable = cover_type&.is_destroyable || false
      hit_points = cover_type&.default_hp || 0
      is_explosive = cover_type&.is_explosive || false
      is_flammable = cover_type&.is_flammable || false

      update_attrs = {
        hex_type: 'cover',
        cover_object: object_name,
        has_cover: true,
        cover_value: cover_value,
        cover_height: cover_height,
        blocks_line_of_sight: blocks_los,
        traversable: false, # Cover hexes are not walkable
        danger_level: is_explosive ? 5 : 0
      }

      hex.update(update_attrs)
    end
  end

  # Add hazards based on room type and category
  def add_hazards
    hazard_chance = config[:hazard_chance]
    return if hazard_chance <= 0

    available_hazards = CATEGORY_HAZARDS[category] || %w[fire]
    traversable_hexes = room.room_hexes_dataset.where(traversable: true, hex_type: 'normal').all

    target_hazards = (traversable_hexes.count * hazard_chance).ceil
    hexes_to_hazard = traversable_hexes.sample(target_hazards)

    hexes_to_hazard.each do |hex|
      hazard_type = available_hazards.sample

      # Determine hazard properties based on type.
      # hazard_damage_per_round and hazard_type are real columns on room_hexes.
      base_attrs = { traversable: true }

      case hazard_type
      when 'fire'
        base_attrs.merge!(hex_type: 'fire', hazard_type: 'fire', hazard_damage_per_round: rand(1..3),
                           danger_level: 3, damage_potential: rand(1..3))
      when 'electricity'
        base_attrs.merge!(hex_type: 'hazard', hazard_type: 'electricity', hazard_damage_per_round: rand(2..4),
                           danger_level: 4, damage_potential: rand(2..4))
      when 'sharp'
        base_attrs.merge!(hex_type: 'hazard', hazard_type: 'sharp', hazard_damage_per_round: rand(1..2),
                           danger_level: 2, difficult_terrain: true, damage_potential: rand(1..2))
      when 'gas'
        base_attrs.merge!(hex_type: 'hazard', hazard_type: 'gas', hazard_damage_per_round: 1,
                           danger_level: 2, damage_potential: 1)
      when 'poison'
        base_attrs.merge!(hex_type: 'hazard', hazard_type: 'poison', hazard_damage_per_round: rand(1..2),
                           danger_level: 3, damage_potential: rand(1..2))
      when 'spike_trap'
        base_attrs.merge!(hex_type: 'trap', hazard_type: 'spike_trap', hazard_damage_per_round: rand(2..4),
                           danger_level: 4, damage_potential: rand(2..4))
      when 'pressure_plate'
        base_attrs.merge!(hex_type: 'trap', hazard_type: 'pressure_plate', is_potential_hazard: true,
                           danger_level: 1)
      when 'unstable_floor'
        base_attrs.merge!(hex_type: 'hazard', hazard_type: 'unstable_floor', is_potential_hazard: true,
                           danger_level: 2)
      end

      hex.update(base_attrs)
    end

    # Add explosives based on explosive_chance
    add_explosives if config[:explosive_chance].to_f > 0
  end

  # Add explosive hexes (gas tanks, barrels, etc.)
  def add_explosives
    explosive_chance = config[:explosive_chance]
    traversable_hexes = room.room_hexes_dataset.where(traversable: true, hex_type: 'normal').all

    target_explosives = (traversable_hexes.count * explosive_chance).ceil
    hexes_to_explode = traversable_hexes.sample(target_explosives)

    hexes_to_explode.each do |hex|
      hex.update(
        hex_type: 'explosive',
        cover_object: 'barrel',
        cover_value: 1,
        danger_level: 5,
        damage_potential: rand(5..15),
        traversable: false,
        is_explosive: true,
        explosion_radius: rand(1..2),
        explosion_damage: rand(5..15),
        explosion_trigger: %w[hit fire].sample
      )
    end
  end

  # Generate elevation clusters for varied terrain
  def generate_elevation
    variance = config[:elevation_variance]
    return if variance <= 0

    # For underground/outdoor, create elevation clusters
    hexes = room.room_hexes_dataset.where(traversable: true).all
    return if hexes.empty?

    # Create elevation "zones"
    num_zones = rand(GameConfig::BattleMap::ELEVATION_ZONES)
    zone_seeds = hexes.sample(num_zones)

    zone_seeds.each do |seed_hex|
      target_elevation = rand(-variance..variance)
      next if target_elevation == 0

      # Spread elevation to nearby hexes
      spread_elevation(seed_hex, target_elevation, rand(GameConfig::BattleMap::ELEVATION_SPREAD_RADIUS))
    end

    # Add ramps/stairs between different elevation levels
    add_elevation_transitions
  end

  # Spread elevation from a seed hex to neighbors
  def spread_elevation(seed_hex, elevation, radius)
    affected_hexes = [seed_hex]
    current_layer = [seed_hex]

    radius.times do |distance|
      next_layer = []
      current_layer.each do |hex|
        neighbors = HexGrid.hex_neighbors(hex.hex_x, hex.hex_y)
        neighbors.each do |nx, ny|
          neighbor = room.room_hexes_dataset.first(hex_x: nx, hex_y: ny)
          next unless neighbor
          next if affected_hexes.include?(neighbor)
          next unless neighbor.traversable

          affected_hexes << neighbor
          next_layer << neighbor

          # Gradual elevation change as we move away from center
          neighbor_elevation = elevation > 0 ? [elevation - distance, 0].max : [elevation + distance, 0].min
          neighbor.update(elevation_level: neighbor_elevation)
        end
      end
      current_layer = next_layer
    end

    # Set seed hex elevation
    seed_hex.update(elevation_level: elevation)
  end

  # Add ramps and stairs at elevation transitions
  def add_elevation_transitions
    hexes_with_elevation = room.room_hexes_dataset.exclude(elevation_level: 0).all

    hexes_with_elevation.each do |hex|
      neighbors = HexGrid.hex_neighbors(hex.hex_x, hex.hex_y)
      neighbors.each do |nx, ny|
        neighbor = room.room_hexes_dataset.first(hex_x: nx, hex_y: ny)
        next unless neighbor

        elevation_diff = (hex.elevation_level.to_i - neighbor.elevation_level.to_i).abs
        next unless elevation_diff > 1

        # Mark one hex as a ramp for transition
        if rand < GameConfig::BattleMap::TRANSITION_FEATURE_CHANCE
          transition_type = %w[ramp stairs ladder].sample
          attrs = { furniture_type: transition_type }
          attrs[:is_ramp]    = true if transition_type == 'ramp'
          attrs[:is_stairs]  = true if transition_type == 'stairs'
          attrs[:is_ladder]  = true if transition_type == 'ladder'
          hex.update(attrs)
        end
      end
    end
  end

  # Add water features (puddles, pools, etc.)
  def add_water_features
    water_chance = config[:water_chance]
    return if water_chance <= 0

    traversable_hexes = room.room_hexes_dataset.where(traversable: true, hex_type: 'normal').all
    target_water = (traversable_hexes.count * water_chance).ceil

    hexes_for_water = traversable_hexes.sample(target_water)

    hexes_for_water.each do |hex|
      water_type = weighted_water_type

      depth = case water_type
              when 'puddle' then rand(1..6) # inches
              when 'wading' then rand(1..3) * 12 # 1-3 feet
              when 'swimming' then rand(4..6) * 12 # 4-6 feet
              when 'deep' then rand(7..20) * 12 # 7-20 feet
              end

      hex.update(
        hex_type: 'water',
        water_type: water_type,
        water_depth: depth,
        difficult_terrain: %w[wading swimming deep].include?(water_type),
        traversable: water_type != 'deep' # Deep water blocks non-swimmers
      )
    end

    # Create water clusters (water tends to pool together)
    expand_water_features
  end

  # Expand water features to create more natural clusters
  def expand_water_features
    water_hexes = room.room_hexes_dataset.where(hex_type: 'water').all

    water_hexes.each do |water_hex|
      neighbors = HexGrid.hex_neighbors(water_hex.hex_x, water_hex.hex_y)
      neighbors.each do |nx, ny|
        neighbor = room.room_hexes_dataset.first(hex_x: nx, hex_y: ny)
        next unless neighbor
        next unless neighbor.hex_type == 'normal' && neighbor.traversable
        next unless rand < GameConfig::BattleMap::WATER_SPREAD_CHANCE

        # Spread to a shallower water type
        spread_type = case water_hex.water_type
                      when 'deep' then 'swimming'
                      when 'swimming' then 'wading'
                      when 'wading' then 'puddle'
                      else 'puddle'
                      end

        depth = case spread_type
                when 'puddle' then rand(1..6)
                when 'wading' then rand(1..3) * 12
                when 'swimming' then rand(4..6) * 12
                else rand(1..6)
                end

        neighbor.update(
          hex_type: 'water',
          water_type: spread_type,
          water_depth: depth,
          difficult_terrain: spread_type != 'puddle',
          traversable: true
        )
      end
    end
  end

  # Pick a water type based on weighted probability
  def weighted_water_type
    total = WATER_TYPE_WEIGHTS.values.sum
    roll = rand(total)

    cumulative = 0
    WATER_TYPE_WEIGHTS.each do |type, weight|
      cumulative += weight
      return type if roll < cumulative
    end

    'puddle' # Fallback
  end

  # Mark the battle map as ready
  def mark_battle_map_ready
    room.update(has_battle_map: true)
  end

  # Called by the scheduler to recover fights whose battle map generation has stalled.
  STUCK_GENERATION_TIMEOUT = 180 # 3 minutes — AI gen timeout is 120s + buffer

  def self.recover_stuck!
    return unless defined?(Fight)

    recovered = 0
    errors = []

    cutoff = Time.now - STUCK_GENERATION_TIMEOUT
    Fight.where(battle_map_generating: true).where { updated_at < cutoff }.each do |fight|
      begin
        room = fight.room
        warn "[BattleMapWatchdog] Fight ##{fight.id} stuck generating for >#{STUCK_GENERATION_TIMEOUT}s, " \
             "falling back to procedural generation"

        if room
          begin
            new(room).generate_with_progress(fight.id)
          rescue StandardError => fallback_err
            warn "[BattleMapWatchdog] Procedural fallback failed for fight ##{fight.id}: #{fallback_err.message}"
          end
        end

        fight.complete_battle_map_generation!
        FightService.revalidate_participant_positions(fight)
        FightService.push_quickmenus_to_participants(fight)
        recovered += 1
      rescue StandardError => e
        errors << { fight_id: fight.id, error: e.message }
      end
    end

    warn "[BattleMapWatchdog] Recovered #{recovered} stuck generation(s)" if recovered > 0
    errors.each { |err| warn "[BattleMapWatchdog] Error for fight ##{err[:fight_id]}: #{err[:error]}" }
  rescue StandardError => e
    warn "[BattleMapWatchdog] Error in watchdog: #{e.message}"
  end
end
