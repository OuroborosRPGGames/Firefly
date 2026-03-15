# frozen_string_literal: true

require 'msgpack'

module WeatherGrid
  # TerrainService - Pre-aggregates WorldHex terrain data for weather simulation
  #
  # Each macro grid cell (64×64 total) covers many world hexes. This service
  # computes aggregate terrain statistics per cell that affect weather:
  # - Average/max/min altitude
  # - Water percentage (ocean, lake)
  # - Forest percentage (light_forest, dense_forest, jungle)
  # - Mountain percentage
  # - Desert percentage
  # - Urban percentage
  # - Albedo (heat absorption)
  # - Evaporation rate (moisture source)
  # - Roughness (affects wind speed)
  #
  # Usage:
  #   WeatherGrid::TerrainService.aggregate(world)        # Recompute all terrain stats
  #   WeatherGrid::TerrainService.load(world)             # Load cached stats
  #   WeatherGrid::TerrainService.cell_at(world, x, y)   # Get single cell terrain
  #
  # Redis Keys:
  #   weather:{world_id}:terrain - MessagePack binary blob (~120KB)
  #
  module TerrainService
    extend self

    GRID_SIZE = GridService::GRID_SIZE

    # Terrain type classifications for aggregation
    WATER_TYPES = %w[ocean lake].freeze
    FOREST_TYPES = %w[light_forest dense_forest jungle].freeze
    MOUNTAIN_TYPES = %w[mountain rocky_hills].freeze
    DESERT_TYPES = %w[desert tundra].freeze
    URBAN_TYPES = %w[urban light_urban].freeze
    COASTAL_TYPES = %w[rocky_coast sandy_coast].freeze
    WETLAND_TYPES = %w[swamp].freeze

    # Albedo values (0 = absorbs all heat, 1 = reflects all heat)
    # Lower albedo = warmer surface
    TERRAIN_ALBEDO = {
      'ocean' => 0.06,         # Very dark, absorbs heat
      'lake' => 0.08,
      'dense_forest' => 0.12,
      'jungle' => 0.12,
      'light_forest' => 0.18,
      'swamp' => 0.12,
      'grassy_plains' => 0.25,
      'grassy_hills' => 0.25,
      'rocky_plains' => 0.30,
      'rocky_hills' => 0.30,
      'rocky_coast' => 0.30,
      'sandy_coast' => 0.35,
      'desert' => 0.40,        # Sand reflects more
      'tundra' => 0.80,        # Snow/ice reflects a lot
      'mountain' => 0.35,
      'volcanic' => 0.10,      # Dark rock
      'urban' => 0.15,         # Asphalt/concrete
      'light_urban' => 0.20
    }.freeze

    # Evaporation rate multipliers (water sources add humidity)
    TERRAIN_EVAPORATION = {
      'ocean' => 3.0,          # Major moisture source
      'lake' => 2.5,
      'swamp' => 2.0,
      'jungle' => 1.5,         # Transpiration
      'dense_forest' => 1.2,
      'light_forest' => 1.1,
      'grassy_plains' => 0.8,
      'desert' => 0.1          # Very low evaporation
    }.freeze

    # Roughness values (affects wind speed reduction)
    # Higher roughness = more friction = slower wind
    TERRAIN_ROUGHNESS = {
      'ocean' => 0.1,          # Very smooth
      'lake' => 0.1,
      'sandy_coast' => 0.15,
      'desert' => 0.2,
      'grassy_plains' => 0.3,
      'rocky_plains' => 0.35,
      'tundra' => 0.25,
      'grassy_hills' => 0.5,
      'rocky_hills' => 0.6,
      'light_forest' => 0.7,
      'swamp' => 0.6,
      'dense_forest' => 0.9,
      'jungle' => 1.0,         # Very rough
      'mountain' => 1.0,
      'urban' => 0.8,
      'light_urban' => 0.6
    }.freeze

    # Load terrain stats from Redis
    #
    # @param world [World] The world
    # @return [Array, nil] Array of terrain cell hashes, or nil if not cached
    def load(world)
      return nil unless world&.id
      return nil unless redis_available?

      REDIS_POOL.with do |redis|
        packed = redis.get(terrain_key(world.id))
        return nil unless packed

        MessagePack.unpack(packed)
      end
    rescue StandardError => e
      warn "[WeatherGrid::TerrainService] Failed to load terrain for world #{world&.id}: #{e.message}"
      nil
    end

    # Save terrain stats to Redis
    #
    # @param world [World] The world
    # @param cells [Array] Array of terrain cell hashes
    # @return [Boolean] Success status
    def save(world, cells)
      return false unless world&.id && cells
      return false unless redis_available?

      REDIS_POOL.with do |redis|
        packed = MessagePack.pack(cells)
        redis.set(terrain_key(world.id), packed)
        true
      end
    rescue StandardError => e
      warn "[WeatherGrid::TerrainService] Failed to save terrain for world #{world&.id}: #{e.message}"
      false
    end

    # Aggregate terrain data from WorldHex into macro grid cells
    # This is expensive - only run when terrain changes or on startup
    #
    # @param world [World] The world to aggregate
    # @return [Array] Array of terrain cell hashes
    def aggregate(world)
      return nil unless world&.id

      cells = Array.new(GRID_SIZE * GRID_SIZE) do |i|
        x, y = GridService.index_to_coords(i)
        aggregate_cell(world, x, y)
      end

      save(world, cells)
      cells
    end

    # Get terrain stats for a single cell
    #
    # @param world [World] The world
    # @param x [Integer] Grid cell X (0-63)
    # @param y [Integer] Grid cell Y (0-63)
    # @return [Hash, nil] Terrain stats for the cell
    def cell_at(world, x, y)
      return nil unless GridService.valid_coords?(x, y)

      cells = load(world)
      return nil unless cells

      index = GridService.coords_to_index(x, y)
      cells[index]
    end

    # Check if terrain data is cached
    #
    # @param world [World] The world
    # @return [Boolean]
    def cached?(world)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        redis.exists?(terrain_key(world.id))
      end
    rescue StandardError => e
      warn "[WeatherGrid::TerrainService] Cache check failed for world #{world&.id}: #{e.message}"
      false
    end

    # Clear cached terrain data
    #
    # @param world [World] The world
    # @return [Boolean] Success status
    def clear(world)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        redis.del(terrain_key(world.id))
        true
      end
    rescue StandardError => e
      warn "[WeatherGrid::TerrainService] Failed to clear terrain for world #{world&.id}: #{e.message}"
      false
    end

    # Get or aggregate terrain (lazy load)
    #
    # @param world [World] The world
    # @return [Array, nil] Terrain cells
    def load_or_aggregate(world)
      cells = load(world)
      return cells if cells

      aggregate(world)
    end

    # Interpolate terrain stats for fractional grid coordinates
    # (used for hex-level lookups)
    #
    # @param world [World] The world
    # @param grid_x [Float] Fractional X (0.0-63.999)
    # @param grid_y [Float] Fractional Y (0.0-63.999)
    # @return [Hash] Interpolated terrain stats
    def interpolate(world, grid_x, grid_y)
      cells = load(world)
      return default_terrain_cell unless cells

      # Clamp to valid range
      grid_x = grid_x.clamp(0.0, GRID_SIZE - 1.001)
      grid_y = grid_y.clamp(0.0, GRID_SIZE - 1.001)

      # Get integer coordinates
      x0 = grid_x.floor
      y0 = grid_y.floor
      x1 = [x0 + 1, GRID_SIZE - 1].min
      y1 = [y0 + 1, GRID_SIZE - 1].min

      # Fractional parts
      fx = grid_x - x0
      fy = grid_y - y0

      # Get 4 corner cells
      tl = cells[GridService.coords_to_index(x0, y0)]
      tr = cells[GridService.coords_to_index(x1, y0)]
      bl = cells[GridService.coords_to_index(x0, y1)]
      br = cells[GridService.coords_to_index(x1, y1)]

      bilinear_interpolate_terrain(tl, tr, bl, br, fx, fy)
    end

    private

    def terrain_key(world_id)
      "weather:#{world_id}:terrain"
    end

    def redis_available?
      defined?(REDIS_POOL) && REDIS_POOL
    end

    # Aggregate terrain data for a single macro grid cell
    def aggregate_cell(world, cell_x, cell_y)
      # Get lat/lon bounds for this cell
      bounds = cell_latlon_bounds(cell_x, cell_y)

      # Query hexes in this region by latitude/longitude
      hexes = WorldHex.where(world_id: world.id)
                     .where { latitude >= bounds[:min_lat] }
                     .where { latitude < bounds[:max_lat] }
                     .where { longitude >= bounds[:min_lon] }
                     .where { longitude < bounds[:max_lon] }
                     .select(:terrain_type, :altitude)
                     .all

      return default_terrain_cell if hexes.empty?

      # Calculate aggregates
      terrain_counts = Hash.new(0)
      altitudes = []

      hexes.each do |hex|
        terrain_counts[hex.terrain_type] += 1
        altitudes << (hex.altitude || 0)
      end

      total = hexes.length.to_f

      # Calculate percentages
      water_pct = terrain_counts.select { |t, _| WATER_TYPES.include?(t) }.values.sum / total
      forest_pct = terrain_counts.select { |t, _| FOREST_TYPES.include?(t) }.values.sum / total
      mountain_pct = terrain_counts.select { |t, _| MOUNTAIN_TYPES.include?(t) }.values.sum / total
      desert_pct = terrain_counts.select { |t, _| DESERT_TYPES.include?(t) }.values.sum / total
      urban_pct = terrain_counts.select { |t, _| URBAN_TYPES.include?(t) }.values.sum / total

      # Calculate weighted averages for physical properties
      albedo = 0.0
      evaporation = 0.0
      roughness = 0.0

      terrain_counts.each do |terrain, count|
        weight = count / total
        albedo += (TERRAIN_ALBEDO[terrain] || 0.25) * weight
        evaporation += (TERRAIN_EVAPORATION[terrain] || 0.5) * weight
        roughness += (TERRAIN_ROUGHNESS[terrain] || 0.5) * weight
      end

      {
        'cell_x' => cell_x,
        'cell_y' => cell_y,
        'avg_altitude' => (altitudes.sum / altitudes.length.to_f).round(1),
        'max_altitude' => altitudes.max,
        'min_altitude' => altitudes.min,
        'water_pct' => (water_pct * 100).round(1),
        'forest_pct' => (forest_pct * 100).round(1),
        'mountain_pct' => (mountain_pct * 100).round(1),
        'desert_pct' => (desert_pct * 100).round(1),
        'urban_pct' => (urban_pct * 100).round(1),
        'albedo' => albedo.round(3),
        'evaporation_rate' => evaporation.round(2),
        'roughness' => roughness.round(2),
        'hex_count' => total.to_i
      }
    end

    # Get latitude/longitude bounds for a macro grid cell
    # Each cell covers a rectangular region of the globe
    # X maps to longitude (-180 to +180), Y maps to latitude (-90 to +90)
    def cell_latlon_bounds(cell_x, cell_y)
      cell_lon_width = 360.0 / GRID_SIZE    # 5.625 degrees per cell
      cell_lat_height = 180.0 / GRID_SIZE   # 2.8125 degrees per cell

      {
        min_lon: -180.0 + (cell_x * cell_lon_width),
        max_lon: -180.0 + ((cell_x + 1) * cell_lon_width),
        min_lat: -90.0 + (cell_y * cell_lat_height),
        max_lat: -90.0 + ((cell_y + 1) * cell_lat_height)
      }
    end

    # Default terrain cell when no hex data exists
    def default_terrain_cell
      {
        'avg_altitude' => 0,
        'max_altitude' => 0,
        'min_altitude' => 0,
        'water_pct' => 0.0,
        'forest_pct' => 30.0,  # Assume some vegetation
        'mountain_pct' => 0.0,
        'desert_pct' => 0.0,
        'urban_pct' => 0.0,
        'albedo' => 0.25,
        'evaporation_rate' => 0.8,
        'roughness' => 0.3,
        'hex_count' => 0
      }
    end

    # Bilinear interpolation for terrain properties
    def bilinear_interpolate_terrain(tl, tr, bl, br, fx, fy)
      result = {}

      # Interpolate numeric fields
      numeric_fields = %w[avg_altitude max_altitude min_altitude water_pct forest_pct
                          mountain_pct desert_pct urban_pct albedo evaporation_rate roughness]

      numeric_fields.each do |field|
        # Get values (default to 0 if missing)
        v_tl = (tl&.dig(field) || 0).to_f
        v_tr = (tr&.dig(field) || 0).to_f
        v_bl = (bl&.dig(field) || 0).to_f
        v_br = (br&.dig(field) || 0).to_f

        # Bilinear interpolation
        top = v_tl * (1 - fx) + v_tr * fx
        bottom = v_bl * (1 - fx) + v_br * fx
        result[field] = (top * (1 - fy) + bottom * fy).round(3)
      end

      result
    end
  end
end
