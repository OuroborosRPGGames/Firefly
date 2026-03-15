# frozen_string_literal: true

require 'msgpack'

module WeatherGrid
  # GridService - Manages the 64×64 macro weather grid in Redis
  #
  # The macro grid is the primary data structure for world-scale weather simulation.
  # Each cell stores weather fields (temperature, humidity, pressure, wind, clouds, etc.)
  # that are simulated every 15 seconds and interpolated to individual hexes on demand.
  #
  # Usage:
  #   Weather::GridService.load(world)           # Load grid from Redis
  #   Weather::GridService.save(world, grid)     # Save grid to Redis
  #   Weather::GridService.initialize_world(world) # Create new grid for world
  #   Weather::GridService.cell_at(world, x, y) # Get single cell data
  #
  # Redis Keys:
  #   weather:{world_id}:grid  - MessagePack binary blob (~160KB)
  #   weather:{world_id}:lock  - Simulation lock (10s TTL)
  #   weather:{world_id}:meta  - JSON metadata (last tick, season, etc.)
  #
  module GridService
    extend self

    GRID_SIZE = 64
    GRID_TOTAL_CELLS = GRID_SIZE * GRID_SIZE # 4,096 cells

    # Default values for new cells
    DEFAULTS = {
      temperature: 15.0,    # °C (mild default)
      humidity: 50.0,       # % (moderate)
      pressure: 1013.0,     # hPa (sea level average)
      wind_dir: 0,          # degrees (north)
      wind_speed: 5.0,      # kph (light breeze)
      cloud_cover: 30.0,    # % (partly cloudy)
      precip_rate: 0.0,     # mm/hr (no precipitation)
      instability: 20.0     # 0-100 (stable)
    }.freeze

    # Field ranges for clamping
    FIELD_RANGES = {
      temperature: [-60.0, 60.0],
      humidity: [0.0, 100.0],
      pressure: [920.0, 1080.0],
      wind_dir: [0, 359],
      wind_speed: [0.0, 200.0],
      cloud_cover: [0.0, 100.0],
      precip_rate: [0.0, 100.0],
      instability: [0.0, 100.0]
    }.freeze

    # Load grid from Redis
    #
    # @param world [World] The world to load grid for
    # @return [Hash] Grid data with :cells array and :meta hash, or nil if not found
    def load(world)
      return nil unless world&.id
      return nil unless redis_available?

      REDIS_POOL.with do |redis|
        packed = redis.get(grid_key(world.id))
        return nil unless packed

        cells = MessagePack.unpack(packed)
        meta = load_meta(world.id, redis)

        { cells: cells, meta: meta }
      end
    rescue StandardError => e
      warn "[Weather::GridService] Failed to load grid for world #{world&.id}: #{e.message}"
      nil
    end

    # Save grid to Redis
    #
    # @param world [World] The world to save grid for
    # @param grid [Hash] Grid data with :cells array
    # @return [Boolean] Success status
    def save(world, grid)
      return false unless world&.id && grid
      return false unless redis_available?

      cells = grid[:cells] || grid['cells']
      return false unless cells

      REDIS_POOL.with do |redis|
        packed = MessagePack.pack(cells)
        redis.set(grid_key(world.id), packed)

        # Merge provided meta with existing, add timestamp
        existing_meta = load_meta(world.id, redis) || {}
        grid_meta = grid[:meta] || grid['meta'] || {}
        meta = existing_meta.merge(grid_meta.transform_keys(&:to_s))
        meta['last_saved_at'] = Time.now.iso8601
        redis.set(meta_key(world.id), meta.to_json)

        true
      end
    rescue StandardError => e
      warn "[Weather::GridService] Failed to save grid for world #{world&.id}: #{e.message}"
      false
    end

    # Initialize a new weather grid for a world
    #
    # @param world [World] The world to initialize
    # @param options [Hash] Options for initialization
    # @option options [Float] :base_temperature Base temperature for the world
    # @option options [Float] :humidity_factor Humidity multiplier (1.0 = normal)
    # @return [Hash] The newly created grid
    def initialize_world(world, options = {})
      return nil unless world&.id

      base_temp = options[:base_temperature] || DEFAULTS[:temperature]
      humidity_factor = options[:humidity_factor] || 1.0

      cells = Array.new(GRID_TOTAL_CELLS) do |i|
        x, y = index_to_coords(i)
        create_default_cell(x, y, base_temp: base_temp, humidity_factor: humidity_factor)
      end

      meta = {
        'world_id' => world.id,
        'grid_size' => GRID_SIZE,
        'created_at' => Time.now.iso8601,
        'last_tick_at' => nil,
        'tick_count' => 0,
        'season' => calculate_season(world)
      }

      grid = { cells: cells, meta: meta }

      # Save to Redis immediately
      if redis_available?
        REDIS_POOL.with do |redis|
          redis.set(grid_key(world.id), MessagePack.pack(cells))
          redis.set(meta_key(world.id), meta.to_json)
        end
      end

      grid
    end

    # Get a single cell from the grid
    #
    # @param world [World] The world
    # @param x [Integer] Cell X coordinate (0-63)
    # @param y [Integer] Cell Y coordinate (0-63)
    # @return [Hash, nil] Cell data or nil
    def cell_at(world, x, y)
      return nil unless valid_coords?(x, y)

      grid = load(world)
      return nil unless grid

      index = coords_to_index(x, y)
      grid[:cells][index]
    end

    # Set a single cell in the grid (for testing/debugging)
    #
    # @param world [World] The world
    # @param x [Integer] Cell X coordinate (0-63)
    # @param y [Integer] Cell Y coordinate (0-63)
    # @param data [Hash] Cell data to set
    # @return [Boolean] Success status
    def set_cell(world, x, y, data)
      return false unless valid_coords?(x, y)

      grid = load(world)
      return false unless grid

      index = coords_to_index(x, y)
      grid[:cells][index] = clamp_cell(data)

      save(world, grid)
    end

    # Acquire simulation lock (prevents concurrent simulation runs)
    #
    # @param world [World] The world to lock
    # @param ttl [Integer] Lock TTL in seconds (default 10)
    # @return [Boolean] True if lock acquired
    def acquire_lock(world, ttl: 10)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        result = redis.set(lock_key(world.id), Time.now.to_i, nx: true, ex: ttl)
        result == true || result == 'OK'
      end
    rescue StandardError => e
      warn "[Weather::GridService] Failed to acquire lock for world #{world&.id}: #{e.message}"
      false
    end

    # Release simulation lock
    #
    # @param world [World] The world to unlock
    # @return [Boolean] Success status
    def release_lock(world)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        redis.del(lock_key(world.id))
        true
      end
    rescue StandardError => e
      warn "[Weather::GridService] Failed to release lock for world #{world&.id}: #{e.message}"
      false
    end

    # Update metadata for a world's grid
    #
    # @param world [World] The world
    # @param updates [Hash] Metadata updates to merge
    # @return [Boolean] Success status
    def update_meta(world, updates)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        meta = load_meta(world.id, redis) || {}
        meta.merge!(updates.transform_keys(&:to_s))
        redis.set(meta_key(world.id), meta.to_json)
        true
      end
    rescue StandardError => e
      warn "[Weather::GridService] Failed to update meta for world #{world&.id}: #{e.message}"
      false
    end

    # Get the 4 nearest cells for bilinear interpolation
    #
    # @param world [World] The world
    # @param grid_x [Float] Fractional X position (0.0-63.999)
    # @param grid_y [Float] Fractional Y position (0.0-63.999)
    # @return [Hash] Hash with :cells (4 cells), :fx/:fy (fractional parts)
    def interpolation_cells(world, grid_x, grid_y)
      grid = load(world)
      return nil unless grid

      # Clamp to valid range
      grid_x = grid_x.clamp(0.0, GRID_SIZE - 1.001)
      grid_y = grid_y.clamp(0.0, GRID_SIZE - 1.001)

      # Get integer coordinates for 4 corners
      x0 = grid_x.floor
      y0 = grid_y.floor
      x1 = [x0 + 1, GRID_SIZE - 1].min
      y1 = [y0 + 1, GRID_SIZE - 1].min

      # Fractional parts for interpolation weights
      fx = grid_x - x0
      fy = grid_y - y0

      cells = grid[:cells]

      {
        top_left: cells[coords_to_index(x0, y0)],
        top_right: cells[coords_to_index(x1, y0)],
        bottom_left: cells[coords_to_index(x0, y1)],
        bottom_right: cells[coords_to_index(x1, y1)],
        fx: fx,
        fy: fy
      }
    end

    # Clear all weather data for a world (for testing)
    #
    # @param world [World] The world to clear
    # @return [Boolean] Success status
    def clear(world)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        redis.del(grid_key(world.id))
        redis.del(meta_key(world.id))
        redis.del(lock_key(world.id))
        true
      end
    rescue StandardError => e
      warn "[Weather::GridService] Failed to clear data for world #{world&.id}: #{e.message}"
      false
    end

    # Check if a grid exists for a world
    #
    # @param world [World] The world to check
    # @return [Boolean]
    def exists?(world)
      return false unless world&.id && redis_available?

      REDIS_POOL.with do |redis|
        redis.exists?(grid_key(world.id))
      end
    rescue StandardError => e
      warn "[Weather::GridService] Exists check failed for world #{world&.id}: #{e.message}"
      false
    end

    # ========================================
    # Coordinate Helpers
    # ========================================

    # Convert 1D index to 2D coordinates
    def index_to_coords(index)
      x = index % GRID_SIZE
      y = index / GRID_SIZE
      [x, y]
    end

    # Convert 2D coordinates to 1D index
    def coords_to_index(x, y)
      y * GRID_SIZE + x
    end

    # Check if coordinates are valid
    def valid_coords?(x, y)
      x.is_a?(Integer) && y.is_a?(Integer) &&
        x >= 0 && x < GRID_SIZE && y >= 0 && y < GRID_SIZE
    end

    # Map latitude/longitude to grid cell coordinates
    #
    # @param latitude [Float] Latitude in degrees (-90 to +90)
    # @param longitude [Float] Longitude in degrees (-180 to +180)
    # @return [Array<Float>] [grid_x, grid_y] fractional coordinates (0.0 to 63.999)
    def latlon_to_grid_coords(latitude, longitude)
      # Longitude (-180 to +180) → grid X (0.0 to 63.999)
      grid_x = ((longitude.to_f + 180.0) / 360.0) * GRID_SIZE

      # Latitude (-90 to +90) → grid Y (0.0 to 63.999), south at 0, north at 63
      grid_y = ((latitude.to_f + 90.0) / 180.0) * GRID_SIZE

      [grid_x.clamp(0.0, GRID_SIZE - 0.001), grid_y.clamp(0.0, GRID_SIZE - 0.001)]
    end

    # Reverse: grid coordinates to lat/lon (for display/debugging)
    #
    # @param grid_x [Float] Grid X (0-63)
    # @param grid_y [Float] Grid Y (0-63)
    # @return [Array<Float>] [latitude, longitude]
    def grid_coords_to_latlon(grid_x, grid_y)
      longitude = (grid_x.to_f / GRID_SIZE) * 360.0 - 180.0
      latitude = (grid_y.to_f / GRID_SIZE) * 180.0 - 90.0
      [latitude.clamp(-90.0, 90.0), longitude.clamp(-180.0, 180.0)]
    end

    private

    # ========================================
    # Redis Key Helpers
    # ========================================

    def grid_key(world_id)
      "weather:#{world_id}:grid"
    end

    def meta_key(world_id)
      "weather:#{world_id}:meta"
    end

    def lock_key(world_id)
      "weather:#{world_id}:lock"
    end

    def redis_available?
      defined?(REDIS_POOL) && REDIS_POOL
    end

    # Load metadata from Redis
    def load_meta(world_id, redis)
      json = redis.get(meta_key(world_id))
      return nil unless json

      JSON.parse(json)
    rescue JSON::ParserError
      nil
    end

    # ========================================
    # Cell Creation
    # ========================================

    # Create a default cell with optional variations
    def create_default_cell(x, y, base_temp: DEFAULTS[:temperature], humidity_factor: 1.0)
      # Add some natural variation based on position
      # Latitude effect: temperature decreases towards poles (y = 0 and y = 63)
      latitude_factor = 1.0 - (2.0 * (y - GRID_SIZE / 2).abs / GRID_SIZE)
      temp_variation = latitude_factor * 15.0 # ±15°C from equator to poles

      # Small random noise for variety (deterministic based on position)
      noise = Math.sin(x * 0.5) * Math.cos(y * 0.7) * 3.0

      {
        'temperature' => clamp_field(:temperature, base_temp + temp_variation + noise),
        'humidity' => clamp_field(:humidity, DEFAULTS[:humidity] * humidity_factor + noise * 2),
        'pressure' => clamp_field(:pressure, DEFAULTS[:pressure]),
        'wind_dir' => clamp_field(:wind_dir, DEFAULTS[:wind_dir]),
        'wind_speed' => clamp_field(:wind_speed, DEFAULTS[:wind_speed]),
        'cloud_cover' => clamp_field(:cloud_cover, DEFAULTS[:cloud_cover] + noise * 3),
        'precip_rate' => clamp_field(:precip_rate, DEFAULTS[:precip_rate]),
        'instability' => clamp_field(:instability, DEFAULTS[:instability])
      }
    end

    # Clamp all fields in a cell to valid ranges
    def clamp_cell(cell)
      result = {}
      cell.each do |key, value|
        sym_key = key.to_sym
        if FIELD_RANGES.key?(sym_key)
          result[key.to_s] = clamp_field(sym_key, value)
        else
          result[key.to_s] = value
        end
      end
      result
    end

    # Clamp a single field to its valid range
    def clamp_field(field, value)
      range = FIELD_RANGES[field]
      return value unless range

      if field == :wind_dir
        value.to_i % 360
      else
        value.to_f.clamp(range[0], range[1])
      end
    end

    # Calculate current season based on world time
    def calculate_season(world)
      # Default to summer if world time isn't available
      return 'summer' unless world.respond_to?(:current_time)

      time = world.current_time
      return 'summer' unless time

      month = time.month
      case month
      when 12, 1, 2 then 'winter'
      when 3, 4, 5 then 'spring'
      when 6, 7, 8 then 'summer'
      else 'autumn'
      end
    end
  end
end
