# frozen_string_literal: true

module WeatherGrid
  # PersistenceService - Handles syncing weather data between Redis and PostgreSQL
  #
  # Weather simulation runs in Redis for speed, but persists to PostgreSQL for
  # durability. This service manages the sync:
  #
  # - Load: On startup, load from DB → Redis
  # - Save: Periodically (every 5 min), save Redis → DB
  # - Fallback: On Redis failure, can read from DB (degraded)
  #
  # Usage:
  #   WeatherGrid::PersistenceService.load_to_redis(world)   # DB → Redis
  #   WeatherGrid::PersistenceService.persist_to_db(world)   # Redis → DB
  #   WeatherGrid::PersistenceService.sync_all               # Sync all active worlds
  #   WeatherGrid::PersistenceService.startup_load           # Load all on server start
  #
  module PersistenceService
    extend self

    # Sync interval in seconds (5 minutes)
    SYNC_INTERVAL = 300

    # Load weather state from PostgreSQL to Redis
    #
    # @param world [World] The world to load
    # @return [Boolean] True if loaded successfully
    def load_to_redis(world)
      return false unless world&.id

      state = WeatherWorldState.find(world_id: world.id)
      return initialize_new_world(world) unless state

      # Load grid data
      grid_hash = state.grid_hash
      if grid_hash && !grid_hash.empty?
        grid = { cells: grid_hash['cells'] || [], meta: grid_hash['meta'] || {} }
        GridService.save(world, grid)
      end

      # Load terrain data
      terrain_hash = state.terrain_hash
      if terrain_hash && !terrain_hash.empty?
        TerrainService.save(world, terrain_hash['cells'] || [])
      end

      # Update meta with load timestamp
      GridService.update_meta(world, {
        'loaded_from_db_at' => Time.now.iso8601,
        'storms' => state.storms,
        **state.meta
      })

      true
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Failed to load world #{world&.id} from DB: #{e.message}"
      false
    end

    # Persist weather state from Redis to PostgreSQL
    #
    # @param world [World] The world to persist
    # @return [Boolean] True if persisted successfully
    def persist_to_db(world)
      return false unless world&.id

      # Load current state from Redis
      grid = GridService.load(world)
      terrain = TerrainService.load(world)

      return false unless grid

      # Find or create DB record
      state = WeatherWorldState.find_or_create(world_id: world.id)

      # Pack grid data
      state.grid_hash = {
        'cells' => grid[:cells],
        'meta' => grid[:meta]
      }

      # Pack terrain data if available
      if terrain
        state.terrain_hash = { 'cells' => terrain }
      end

      # Save storms and meta
      state.storms = grid[:meta]&.dig('storms') || []
      state.meta = extract_meta_for_db(grid[:meta])

      state.save

      true
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Failed to persist world #{world&.id} to DB: #{e.message}"
      false
    end

    # Persist all worlds (scheduler-friendly wrapper)
    #
    # Returns a summary hash with :persisted count
    # @return [Hash] { persisted: Integer }
    def persist_all!
      results = sync_all
      persisted = results.values.count { |v| v == true }
      { persisted: persisted }
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Persist all failed: #{e.message}"
      { persisted: 0 }
    end

    # Sync all worlds with use_grid_weather enabled
    #
    # @return [Hash] Sync results by world_id
    def sync_all
      results = {}

      World.where(use_grid_weather: true).each do |world|
        results[world.id] = persist_to_db(world)
      end

      results
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Sync all failed: #{e.message}"
      {}
    end

    # Load all worlds from DB on server startup
    #
    # @return [Hash] Load results by world_id
    def startup_load
      results = {}

      # Only load worlds with grid weather enabled
      query = if World.columns.include?(:use_grid_weather)
                World.where(use_grid_weather: true)
              else
                World.all
              end

      query.each do |world|
        results[world.id] = load_to_redis(world)
      end

      results
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Startup load failed: #{e.message}"
      {}
    end

    # Check if a world needs to be synced (based on last sync time)
    #
    # @param world [World] The world to check
    # @return [Boolean] True if sync needed
    def needs_sync?(world)
      return false unless world&.id

      grid = GridService.load(world)
      return true unless grid&.dig(:meta, 'last_persisted_at')

      last_sync = Time.parse(grid[:meta]['last_persisted_at'])
      (Time.now - last_sync) > SYNC_INTERVAL
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Failed sync check for world #{world&.id}: #{e.message}"
      true
    end

    # Sync world if needed (called from scheduler)
    #
    # @param world [World] The world to potentially sync
    # @return [Boolean] True if synced, false if not needed or failed
    def sync_if_needed(world)
      return false unless needs_sync?(world)

      result = persist_to_db(world)

      if result
        GridService.update_meta(world, { 'last_persisted_at' => Time.now.iso8601 })
      end

      result
    end

    # Delete all persisted data for a world
    #
    # @param world [World] The world to clean up
    # @return [Boolean] Success status
    def delete_world(world)
      return false unless world&.id

      # Delete from Redis
      GridService.clear(world)
      TerrainService.clear(world)

      # Delete from PostgreSQL
      WeatherWorldState.where(world_id: world.id).delete

      true
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Failed to delete world #{world&.id}: #{e.message}"
      false
    end

    # Get last sync time for a world
    #
    # @param world [World] The world
    # @return [Time, nil] Last sync time or nil
    def last_sync_time(world)
      return nil unless world&.id

      grid = GridService.load(world)
      return nil unless grid&.dig(:meta, 'last_persisted_at')

      Time.parse(grid[:meta]['last_persisted_at'])
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Failed to read last sync for world #{world&.id}: #{e.message}"
      nil
    end

    # Fallback: Read directly from DB when Redis unavailable
    #
    # @param world [World] The world
    # @return [Hash, nil] Weather state or nil
    def read_from_db_fallback(world)
      return nil unless world&.id

      state = WeatherWorldState.find(world_id: world.id)
      return nil unless state

      {
        grid: state.grid_hash,
        terrain: state.terrain_hash,
        storms: state.storms,
        meta: state.meta
      }
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] DB fallback read failed: #{e.message}"
      nil
    end

    private

    # Initialize a new world with fresh weather data
    def initialize_new_world(world)
      # Initialize grid with default data
      GridService.initialize_world(world)

      # Aggregate terrain data
      TerrainService.aggregate(world)

      # Create DB record
      state = WeatherWorldState.create(
        world_id: world.id,
        storms_data: [],
        meta_data: {
          'created_at' => Time.now.iso8601,
          'initialized' => true
        }
      )

      # Persist initial state
      persist_to_db(world)

      true
    rescue StandardError => e
      warn "[WeatherGrid::PersistenceService] Failed to initialize world #{world&.id}: #{e.message}"
      false
    end

    # Extract metadata fields that should be persisted to DB
    def extract_meta_for_db(meta)
      return {} unless meta

      {
        'last_tick_at' => meta['last_tick_at'],
        'tick_count' => meta['tick_count'],
        'season' => meta['season'],
        'world_id' => meta['world_id']
      }.compact
    end
  end
end
