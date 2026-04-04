# frozen_string_literal: true

module WorldGeneration
  # Orchestrates the world generation pipeline
  class PipelineService
    PHASES = %w[tectonics elevation climate rivers biomes].freeze
    DEFAULT_SUBDIVISIONS = 5 # Controls hex count (~10,242 hexes at 5) for globe grid

    # Maps world_size to subdivisions for vertex-based icosahedral globe hex grid
    # Formula: hex_count = 10 * 4^subdivisions + 2
    WORLD_SIZE_TO_SUBDIVISIONS = {
      0.1 => 7,   # ~163K hexes (Tiny)
      0.25 => 8,  # ~655K hexes (Small)
      0.5 => 9,   # ~2.6M hexes (Medium)
      0.75 => 10, # ~10.5M hexes (Large)
      1.0 => 10   # ~10.5M hexes (Earth-size)
    }.freeze

    # Batch size for database inserts
    BATCH_SIZE = 10_000

    def initialize(job)
      @job = job
      @world = job.world
      @config = PresetConfig.for(job.config['preset'] || 'earth_like')
      @seed = job.config['seed']&.to_i || Random.new_seed
      @subdivisions = determine_subdivisions(job.config)
      @rng = Random.new(@seed)
      @noise = NoiseGenerator.new(seed: @seed)
      @grid = nil
      @tectonics = nil
      @sea_level = 0.0
    end

    # Determine subdivisions from config (explicit subdivisions or world_size)
    def determine_subdivisions(config)
      # Explicit subdivisions takes priority
      return config['subdivisions'].to_i if config['subdivisions']

      # Map world_size to subdivisions
      world_size = config['world_size']&.to_f
      return DEFAULT_SUBDIVISIONS unless world_size

      # Find closest match in our mapping
      WORLD_SIZE_TO_SUBDIVISIONS[world_size] ||
        WORLD_SIZE_TO_SUBDIVISIONS.min_by { |k, _| (k - world_size).abs }.last
    end

    def run
      @job.update(status: 'running', started_at: Time.now)
      init_config

      estimated_hexes = estimate_hex_count
      @job.update(total_regions: estimated_hexes)

      PHASES.each do |phase|
        send("run_#{phase}_phase")
        mark_phase_complete(phase)
      end

      write_to_database

      # Aggregate regions and generate texture
      aggregate_regions
      generate_texture

      # Touch world to invalidate texture cache
      @world.update(updated_at: Time.now)

      @job.complete!
    rescue StandardError => e
      warn "[WorldGeneration] Pipeline failed: #{e.message}"
      @job.fail!(e.message, e.backtrace&.first(10)&.join("\n"))
    end

    private

    def estimate_hex_count
      # Vertex-based icosahedral grid: 10 * 4^subdivisions + 2 hexes
      10 * (4**@subdivisions) + 2
    end

    def init_config
      @job.update(
        config: @job.config.merge(
          'seed' => @seed,
          'subdivisions' => @subdivisions,
          'phases_complete' => []
        )
      )
    end

    def update_progress(phase, percentage)
      @job.update(
        progress_percentage: percentage,
        config: @job.config.merge('phase' => phase)
      )
    end

    def mark_phase_complete(phase)
      phases = @job.config['phases_complete'] || []
      @job.update(
        config: @job.config.merge('phases_complete' => phases + [phase])
      )
    end

    def run_tectonics_phase
      # Update progress: starting grid generation
      @job.update(
        progress_percentage: 0,
        config: @job.config.merge('phase' => 'tectonics', 'subphase' => 'grid')
      )

      # Grid generation with progress callback
      # Grid building is ~0-10%, neighbor cache is ~10-15%
      last_reported = 0
      grid_progress = proc do |stage, fraction|
        pct = case stage
              when :subdivide then (fraction * 10).round # 0-10%
              when :neighbors then 10 + (fraction * 5).round # 10-15%
              else 0
              end
        # Only update DB when percentage actually changes (avoid excessive writes)
        if pct > last_reported
          last_reported = pct
          subphase = stage == :neighbors ? 'neighbors' : 'grid'
          @job.update(
            progress_percentage: pct,
            config: @job.config.merge('subphase' => subphase)
          )
        end
      end

      @grid = GlobeHexGrid.new(@world, subdivisions: @subdivisions, on_progress: grid_progress)

      # Update progress: grid complete, starting plate generation
      @job.update(
        progress_percentage: 15,
        config: @job.config.merge('subphase' => 'plates')
      )

      @tectonics = TectonicsGenerator.new(@grid, @config, @rng)
      @tectonics.generate

      # Update progress: tectonics complete
      @job.update(progress_percentage: 20)
    end

    def run_elevation_phase
      @job.update(
        progress_percentage: 20,
        config: @job.config.merge('phase' => 'elevation', 'subphase' => nil)
      )
      elevation = ElevationGenerator.new(@grid, @config, @rng, @noise, @tectonics)
      elevation.generate
      @sea_level = elevation.sea_level
      @job.update(progress_percentage: 40)
    end

    def run_climate_phase
      @job.update(
        progress_percentage: 40,
        config: @job.config.merge('phase' => 'climate', 'subphase' => nil)
      )
      climate = ClimateSimulator.new(@grid, @config, @sea_level)
      climate.simulate
      @job.update(progress_percentage: 60)
    end

    def run_rivers_phase
      @job.update(
        progress_percentage: 60,
        config: @job.config.merge('phase' => 'rivers', 'subphase' => nil)
      )
      rivers = RiverGenerator.new(@grid, @config, @rng, @sea_level)
      rivers.generate
      @job.update(progress_percentage: 75)
    end

    def run_biomes_phase
      @job.update(
        progress_percentage: 75,
        config: @job.config.merge('phase' => 'biomes', 'subphase' => nil)
      )
      biomes = BiomeMapper.new(@grid, @config, @sea_level)
      biomes.map_biomes
      @job.update(progress_percentage: 85)
    end

    def write_to_database
      update_progress('saving', 85)

      # Bulk insert new hexes
      records = @grid.to_db_records
      return if records.empty?

      total = records.length

      # Use DB.synchronize to hold a single connection for all operations
      # This ensures SET statement_timeout applies to subsequent queries
      DB.synchronize do |conn|
        # Disable statement timeout for bulk operations (5s default is too short)
        DB.run('SET statement_timeout = 0')

        # Clear existing hexes
        WorldHex.where(world_id: @world.id).delete

        # Insert in batches for memory efficiency
        records.each_slice(BATCH_SIZE).with_index do |batch, index|
          WorldHex.multi_insert(batch)

          # Update progress (still uses same connection due to synchronize block)
          progress = 85 + ((index + 1) * BATCH_SIZE * 10 / total)
          @job.update(
            progress_percentage: progress.clamp(85, 95),
            completed_regions: [(index + 1) * BATCH_SIZE, total].min
          )
        end

        @job.update(
          total_regions: records.length,
          completed_regions: records.length
        )
      ensure
        # Always restore default timeout, even on exception
        DB.run("SET statement_timeout = '5s'")
      end
    end

    def aggregate_regions
      update_progress('aggregating', 96)

      if defined?(WorldRegionAggregationService)
        begin
          # Disable statement timeout — aggregation queries large hex tables
          DB.synchronize do
            DB.run('SET statement_timeout = 0')
            WorldRegionAggregationService.aggregate_for_world(@world)
          ensure
            DB.run("SET statement_timeout = '5s'")
          end
        rescue StandardError => e
          warn "[WorldGeneration] Region aggregation skipped: #{e.message}"
          # Non-fatal - continue with pipeline
        end
      end
    end

    def generate_texture
      update_progress('texture', 98)

      if defined?(TerrainTextureService)
        begin
          # TerrainTextureService manages its own statement timeouts via
          # SET LOCAL inside transactions. No need to hold a DB connection
          # during the CPU-intensive pixel rendering phase.
          TerrainTextureService.new(@world).generate
        rescue StandardError => e
          warn "[WorldGeneration] Texture generation skipped: #{e.message}"
          # Non-fatal - continue with pipeline
        end
      end
    end
  end
end
