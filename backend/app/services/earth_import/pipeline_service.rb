# frozen_string_literal: true

require 'timeout'

module EarthImport
  # Orchestrates the full Earth data import pipeline:
  # 1. Download data (Natural Earth, HydroSHEDS)
  # 2. Generate icosahedral hex grid
  # 3. Apply elevation from geographic data
  # 4. Classify terrain types
  # 5. Trace major rivers
  # 6. Write to database
  #
  # Updates job progress as it runs, and marks job as failed on error.
  #
  # REQUIRES: GDAL must be installed for accurate coastlines.
  # Without GDAL, the import will fail with a helpful error message.
  #
  # Usage:
  #   job = WorldGenerationJob.create_earth_import(world, subdivisions: 5)
  #   EarthImport::PipelineService.new(job).run
  #
  class PipelineService
    PHASES = %w[download parse elevation terrain rivers save].freeze
    DEFAULT_SUBDIVISIONS = 6  # 20 * 4^6 = 81,920 hexes (use 10 for full Earth import)

    # Error raised when GDAL is not available
    class GdalRequiredError < StandardError; end

    attr_reader :job, :world, :grid

    # Check if GDAL is available for Earth import.
    #
    # @return [Boolean] true if GDAL can be used
    def self.gdal_available?
      LandMaskService.gdal_available?
    end

    # Initialize the pipeline service.
    #
    # @param job [WorldGenerationJob] The job to run
    def initialize(job)
      @job = job
      @world = job.world
      @config = job.config.is_a?(Hash) ? job.config : (job.config&.to_hash || {})
      @subdivisions = @config['subdivisions'] || DEFAULT_SUBDIVISIONS
    end

    # Threshold for batched processing (subdivisions >= 9 = 5M+ hexes)
    BATCH_THRESHOLD_SUBDIVISIONS = 9

    # Number of faces to process per batch (4 faces = ~4M hexes at subdivisions=10)
    FACES_PER_BATCH = 4

    # Run the full import pipeline.
    #
    # @return [void]
    # @raise [GdalRequiredError] if GDAL is not available
    # @raise [StandardError] Re-raises any error after marking job as failed
    def run
      # Disable statement timeout for the entire pipeline run
      # Earth imports with 21M hexes can take hours
      DB.run('SET statement_timeout = 0')
      warn '[EarthImport] Statement timeout disabled for pipeline'

      @job.update(status: 'running', started_at: Time.now)

      # Check GDAL availability first - fail fast with helpful message
      check_gdal_available!

      # Phase 1: Download data (0-20%)
      update_progress('download', 0)
      data_paths = download_data

      # Use batched processing for large grids to avoid OOM
      if @subdivisions >= BATCH_THRESHOLD_SUBDIVISIONS
        run_batched_pipeline(data_paths)
      else
        run_standard_pipeline(data_paths)
      end

      # Touch world to invalidate texture cache
      @world.update(updated_at: Time.now)

      @job.update(status: 'completed', completed_at: Time.now, progress_percentage: 100.0)

      # Restore default timeout
      DB.run("SET statement_timeout = '5s'")
    rescue StandardError => e
      warn "[EarthImport::PipelineService] Failed: #{e.message}"
      @job.update(
        status: 'failed',
        error_message: "#{e.class}: #{e.message}",
        completed_at: Time.now
      )
      # Restore default timeout even on failure
      DB.run("SET statement_timeout = '5s'") rescue nil
      raise
    end

    # Standard pipeline for smaller grids (< 5M hexes)
    # Generates all hexes in memory, then writes to DB
    def run_standard_pipeline(data_paths)
      # Phase 2: Parse/setup grid (20-30%)
      update_progress('parse', 20)
      setup_grid

      # Phase 3: Apply elevation (30-50%)
      update_progress('elevation', 30)
      apply_elevation(data_paths)

      # Phase 4: Classify terrain (50-70%)
      update_progress('terrain', 50)
      classify_terrain(data_paths)

      # Phase 5: Trace rivers (70-90%)
      update_progress('rivers', 70)
      trace_rivers(data_paths)

      # Phase 6: Save to database (90-100%)
      update_progress('save', 90)
      write_to_database!
    end

    # Batched pipeline for large grids (5M+ hexes)
    # Processes icosahedron faces in batches to reduce memory usage
    def run_batched_pipeline(data_paths)
      total_hexes = 20 * (4**@subdivisions)
      hexes_per_face = 4**@subdivisions
      warn "[EarthImport] Using batched processing for #{total_hexes} hexes (#{@subdivisions} subdivisions)"

      # Initialize shared resources
      elevation_mapper = create_elevation_mapper(data_paths)
      terrain_classifier = TerrainClassifier.new(land_cover_path: data_paths[:land_cover])

      # Clear existing hexes before starting batched inserts
      update_progress('prepare', 20)
      DB.synchronize do |conn|
        conn.execute('SET statement_timeout = 0')
        WorldHex.where(world_id: @world.id).delete
        warn '[EarthImport] Cleared existing hexes'
      end

      # Process faces in batches
      batch_count = (20.0 / FACES_PER_BATCH).ceil
      start_hex_id = 0
      total_written = 0

      (0...20).each_slice(FACES_PER_BATCH).with_index do |face_indices, batch_index|
        face_range = face_indices.first..face_indices.last
        batch_hex_count = face_indices.size * hexes_per_face

        # Progress: 25-90% across all batches
        batch_start_pct = 25 + (batch_index * 65 / batch_count)
        warn "[EarthImport] Batch #{batch_index + 1}/#{batch_count}: faces #{face_range}, ~#{batch_hex_count} hexes"

        # Generate hexes for this batch of faces
        update_progress('generate', batch_start_pct)
        @grid = WorldGeneration::GlobeHexGrid.new(
          @world,
          subdivisions: @subdivisions,
          skip_neighbors: true,
          face_range: face_range,
          start_hex_id: start_hex_id
        )
        warn "[EarthImport] Generated #{@grid.hex_count} hexes for batch"

        # Apply elevation
        update_progress('elevation', batch_start_pct + 5)
        elevation_mapper.apply_to_grid(@grid)

        # Classify terrain
        update_progress('terrain', batch_start_pct + 10)
        terrain_classifier.apply_to_grid(@grid)

        # Write batch to database
        update_progress('save', batch_start_pct + 15)
        written = write_batch_to_database!
        total_written += written
        warn "[EarthImport] Batch #{batch_index + 1} complete: #{written} hexes written (total: #{total_written})"

        # Clear memory for next batch
        start_hex_id += @grid.hex_count
        @grid = nil
        GC.start
      end

      warn "[EarthImport] Batched import complete: #{total_written} total hexes"
    end

    private

    # Update job progress with phase name and percentage.
    # Thread-safe: uses mutex to prevent concurrent database updates.
    #
    # @param phase [String] Current phase name
    # @param percent [Integer] Progress percentage (0-100)
    def update_progress(phase, percent)
      @progress_mutex ||= Mutex.new
      @progress_mutex.synchronize do
        new_config = @config.merge('current_phase' => phase)
        # Refresh the job object to avoid stale data errors in parallel processing
        @job.refresh
        @job.update(
          progress_percentage: percent.to_f,
          config: Sequel.pg_json(new_config)
        )
      end
    end

    # Download all required data files.
    #
    # @return [Hash] Paths to downloaded/extracted data
    def download_data
      downloader = DataDownloader.new

      natural_earth = downloader.download_natural_earth
      hydrosheds = downloader.download_hydrosheds

      natural_earth.merge(hydrosheds)
    end

    # Set up the icosahedral hex grid.
    # Skip neighbor cache since Earth import doesn't use it.
    #
    # @return [void]
    def setup_grid
      @grid = WorldGeneration::GlobeHexGrid.new(@world, subdivisions: @subdivisions, skip_neighbors: true)
    end

    # Check if GDAL is available and raise a helpful error if not.
    #
    # @raise [GdalRequiredError] if GDAL is not available
    def check_gdal_available!
      return if self.class.gdal_available?

      raise GdalRequiredError,
            'Earth Import requires GDAL for accurate coastlines. ' \
            'Install with: sudo apt-get install libgdal-dev && bundle add gdal'
    end

    # Apply elevation data to the hex grid.
    #
    # @param data_paths [Hash] Paths to data files
    def apply_elevation(data_paths)
      mapper = ElevationMapper.new(
        raster_path: data_paths[:land_cover],
        land_dir: data_paths[:land],
        subdivisions: @subdivisions
      )

      # Verify land mask loaded successfully
      unless mapper.land_mask_available?
        raise GdalRequiredError,
              'Failed to load land mask from Natural Earth data. ' \
              'Ensure GDAL is installed and data files exist.'
      end

      progress_callback = lambda do |i, total|
        pct = 30 + (i.to_f / total * 20).to_i
        update_progress('elevation', pct)
      end
      mapper.apply_to_grid(@grid, progress_callback: progress_callback)
    end

    # Classify terrain types for all hexes.
    #
    # @param data_paths [Hash] Paths to data files
    def classify_terrain(data_paths)
      classifier = TerrainClassifier.new(land_cover_path: data_paths[:land_cover])

      classifier.apply_to_grid(@grid) do |i, total|
        pct = 50 + (i.to_f / total * 20).to_i
        update_progress('terrain', pct) if (i % 1000).zero?
      end
    end

    # Trace major rivers onto the hex grid.
    # Rivers are optional and skipped if loading takes too long.
    #
    # @param data_paths [Hash] Paths to data files
    def trace_rivers(data_paths)
      # Skip rivers if disabled in config
      if @config['skip_rivers']
        warn '[EarthImport] Skipping rivers (disabled in config)'
        return
      end

      # Skip if no rivers data available
      rivers_dir = data_paths[:rivers]
      unless rivers_dir && File.directory?(rivers_dir)
        warn '[EarthImport] No rivers data available, skipping'
        return
      end

      tracer = RiverTracer.new

      # Load rivers from shapefile with timeout protection
      # HydroRIVERS is ~3GB and can take a very long time to parse
      begin
        Timeout.timeout(60) do
          all_rivers = tracer.load_from_shapefile(rivers_dir)

          # Filter to major rivers only (10,000+ km² upstream area)
          major_rivers = tracer.filter_major_rivers(all_rivers)

          tracer.apply_to_grid(@grid, major_rivers) do |i, total|
            pct = 70 + (i.to_f / total * 20).to_i
            update_progress('rivers', pct) if (i % 50).zero?
          end
        end
      rescue Timeout::Error
        warn '[EarthImport] River loading timed out - skipping rivers'
      rescue StandardError => e
        warn "[EarthImport] River loading failed: #{e.message} - skipping rivers"
      end
    end

    # Write the hex grid to the database.
    #
    # Globe hexes use globe_hex_id as their unique identifier, NOT hex_x/hex_y.
    # The hex_x/hex_y coordinates are only meaningful for flat-grid worlds.
    # For globe worlds, we set them to nil to avoid the duplicate key issue
    # where multiple globe hexes map to the same (hex_x, hex_y) through rounding.
    #
    # @return [void]
    def write_to_database!
      # Prepare records for bulk insert
      records = @grid.hexes.map.with_index do |hex, idx|
        lat_deg = hex.lat * 180.0 / Math::PI
        lon_deg = hex.lon * 180.0 / Math::PI

        record = {
          world_id: @world.id,
          globe_hex_id: idx,
          latitude: lat_deg,
          longitude: lon_deg,
          terrain_type: hex.terrain_type || WorldHex::DEFAULT_TERRAIN,
          elevation: ((hex.elevation || 0) * 9000).round,
          feature_n: river_feature(hex, 'n'),
          feature_ne: river_feature(hex, 'ne'),
          feature_se: river_feature(hex, 'se'),
          feature_s: river_feature(hex, 's'),
          feature_sw: river_feature(hex, 'sw'),
          feature_nw: river_feature(hex, 'nw')
        }

        # Add river width if set (from upstream area classification)
        record[:river_width] = hex.river_width if hex.river_width && hex.river_width > 0

        record
      end

      total = records.length
      warn "[EarthImport] Writing #{total} hexes to database..."

      # Use DB.synchronize to hold a single connection for all operations
      # Execute SET directly on the connection to ensure it applies
      DB.synchronize do |conn|
        # Disable statement timeout for bulk operations (21M hexes can take a long time)
        conn.execute('SET statement_timeout = 0')
        warn '[EarthImport] Statement timeout disabled for bulk insert'

        # Clear existing hexes for this world
        WorldHex.where(world_id: @world.id).delete
        warn '[EarthImport] Cleared existing hexes'

        # Bulk insert in batches (10K matches world generation for optimal performance)
        batch_count = 0
        records.each_slice(10_000) do |batch|
          WorldHex.multi_insert(batch)
          batch_count += batch.length

          # Log progress every 100K hexes
          if (batch_count % 100_000).zero?
            warn "[EarthImport] Inserted #{batch_count}/#{total} hexes (#{(batch_count * 100.0 / total).round(1)}%)"
          end
        end

        # Restore default timeout
        conn.execute("SET statement_timeout = '5s'")
      end

      warn "[EarthImport] Database write complete: #{total} hexes"
    end

    # Convert a hex's river directions to a feature value.
    #
    # @param hex [WorldGeneration::HexData] The hex
    # @param direction [String] Direction to check
    # @return [String, nil] 'river' if present, nil otherwise
    def river_feature(hex, direction)
      return nil unless hex.river_directions&.include?(direction)

      'river'
    end

    # Create an ElevationMapper for batched processing.
    # Reuses the same mapper across batches to avoid reloading land mask.
    #
    # @param data_paths [Hash] Paths to data files
    # @return [ElevationMapper] The elevation mapper
    def create_elevation_mapper(data_paths)
      mapper = ElevationMapper.new(
        raster_path: data_paths[:land_cover],
        land_dir: data_paths[:land],
        subdivisions: @subdivisions
      )

      # Verify land mask loaded successfully
      unless mapper.land_mask_available?
        raise GdalRequiredError,
              'Failed to load land mask from Natural Earth data. ' \
              'Ensure GDAL is installed and data files exist.'
      end

      mapper
    end

    # Write a batch of hexes to the database (for batched processing).
    # Unlike write_to_database!, this does NOT clear existing hexes.
    # Clearing is done once at the start of batched processing.
    #
    # Uses hex.id as globe_hex_id since GlobeHexGrid sets unique IDs
    # when initialized with start_hex_id parameter.
    #
    # @return [Integer] Number of hexes written
    def write_batch_to_database!
      # Prepare records for bulk insert
      records = @grid.hexes.map do |hex|
        lat_deg = hex.lat * 180.0 / Math::PI
        lon_deg = hex.lon * 180.0 / Math::PI

        record = {
          world_id: @world.id,
          globe_hex_id: hex.id, # Uses ID set by GlobeHexGrid with start_hex_id
          latitude: lat_deg,
          longitude: lon_deg,
          terrain_type: hex.terrain_type || WorldHex::DEFAULT_TERRAIN,
          elevation: ((hex.elevation || 0) * 9000).round,
          feature_n: river_feature(hex, 'n'),
          feature_ne: river_feature(hex, 'ne'),
          feature_se: river_feature(hex, 'se'),
          feature_s: river_feature(hex, 's'),
          feature_sw: river_feature(hex, 'sw'),
          feature_nw: river_feature(hex, 'nw')
        }

        # Add river width if set (from upstream area classification)
        record[:river_width] = hex.river_width if hex.river_width && hex.river_width > 0

        record
      end

      total = records.length

      # Use DB.synchronize to hold a single connection for all operations
      DB.synchronize do |conn|
        # Disable statement timeout for bulk operations
        conn.execute('SET statement_timeout = 0')

        # Bulk insert in batches (10K for optimal performance)
        batch_count = 0
        records.each_slice(10_000) do |batch|
          WorldHex.multi_insert(batch)
          batch_count += batch.length
        end

        # Restore default timeout
        conn.execute("SET statement_timeout = '5s'")
      end

      total
    end
  end
end
