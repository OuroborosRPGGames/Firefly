# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'dem_elevation_sampler'
require_relative 'lake_detector'
require_relative 'region_hex_grid'
require_relative 'terrain_classifier'
require_relative 'data_downloader'
require_relative 'river_tracer'
require_relative 'coordinate_converter'

module EarthImport
  # Imports real Earth geography onto an existing game world's hexes for a bounded region.
  #
  # Pipeline:
  # 1. Find ocean placement at ~46°N on the target world
  # 2. Download earth data (DEM, lakes, rivers)
  # 3. For each target hex: sample real elevation → apply sea-level cutoff → classify terrain → detect lakes
  # 4. Trace rivers via RegionHexGrid adapter
  # 5. Bulk-update database via temp table
  #
  # Usage:
  #   service = EarthImport::RegionImportService.new(world_id: 3)
  #   service.run
  #
  class RegionImportService
    # Sea level cutoff in meters — Earth elevation below this becomes ocean in-game
    DEFAULT_SEA_LEVEL = 300

    # Target latitude band for ocean placement (degrees)
    # Wide enough to encompass Switzerland + taper zone
    PLACEMENT_LAT_MIN = 43.0
    PLACEMENT_LAT_MAX = 51.0

    # Earth bounding box — wider than Switzerland to allow natural taper
    # Switzerland bbox is ~45.8-47.8°N, 5.95-10.47°E; we add ~2.5° padding
    DEFAULT_EARTH_BOUNDS = {
      min_lat: 43.0,
      max_lat: 50.5,
      min_lon:  3.0,
      max_lon: 13.5
    }.freeze

    # Path to Natural Earth country boundaries shapefile
    COUNTRIES_SHP_DIR = 'data/earth/ne_countries'

    # How far outside the Swiss border the taper extends before becoming ocean (degrees)
    # ~1.5° ≈ 167km at 47°N latitude
    TAPER_DISTANCE_DEG = 1.5

    # Maximum elevation penalty at the outer edge of the taper zone (meters)
    # Must exceed real elevation of surrounding lowlands (~200-600m) to push them to ocean
    MAX_TAPER_PENALTY = 1500

    # Elevation smoothing — same approach as world_generation's ElevationGenerator#apply_erosion
    # Gentle: 2 passes at 15% avoids flattening mountains while still smoothing valleys
    EROSION_PASSES = 2
    EROSION_FACTOR = 0.15

    # Terrain smoothing — majority-vote passes to clean up noise
    TERRAIN_SMOOTH_PASSES = 2
    TERRAIN_SMOOTH_THRESHOLD = 4  # Flip if 4+ of ~6 neighbors disagree

    # Minimum connected land hexes to keep (smaller clusters get converted to ocean)
    MIN_LAND_CLUSTER_SIZE = 15

    # Altitude assigned to ocean hexes (meters, stored in DB)
    OCEAN_ALTITUDE = -4000

    # Temp table name for bulk updates
    TMP_TABLE = :_tmp_hex_import

    attr_reader :world_id, :sea_level, :earth_bounds

    # @param world_id   [Integer, nil] DB id of the target World (nil for testing)
    # @param sea_level  [Integer]      Earth elevation (m) that maps to in-game sea level
    # @param earth_bounds [Hash]       Override bounding box { min_lat:, max_lat:, min_lon:, max_lon: }
    # @param target_lon [Float, nil]   Pin the island's center longitude (skip auto-placement)
    # @param lake_detector [LakeDetector, nil] Pre-built detector (mainly for testing)
    # @param dem_sampler   [DemElevationSampler, nil] Pre-built sampler (mainly for testing)
    def initialize(world_id:, sea_level: DEFAULT_SEA_LEVEL, earth_bounds: DEFAULT_EARTH_BOUNDS,
                   target_lon: nil, lake_detector: nil, dem_sampler: nil)
      @world_id      = world_id
      @sea_level     = sea_level
      @earth_bounds  = earth_bounds
      @target_lon    = target_lon
      @lake_detector = lake_detector
      @dem_sampler   = dem_sampler
      @swiss_border  = nil
    end

    # Run the full import pipeline.
    #
    # @param skip_rivers [Boolean] Skip river tracing
    # @param skip_lakes [Boolean] Skip lake detection
    # @param dry_run [Boolean] Classify hexes but don't write to DB
    # @return [Hash] Summary of what was imported
    def run(skip_rivers: false, skip_lakes: false, dry_run: false)
      warn "[RegionImportService] Starting import for world #{world_id}"

      world = World[world_id]
      raise "World #{world_id} not found" unless world

      # Step 1: Find placement (game hexes that map to the source Earth region)
      warn '[RegionImportService] Step 1: Finding ocean placement at ~46°N'
      placement = find_placement(world)
      unless placement
        warn '[RegionImportService] No suitable ocean hexes found in target latitude band'
        return { hexes_updated: 0 }
      end
      warn "[RegionImportService] Placement found: #{placement[:hex_ids].size} ocean hexes, " \
           "lon offset #{placement[:lon_offset].round(2)}°"

      # Step 2: Download earth data
      warn '[RegionImportService] Step 2: Downloading earth data'
      natural_earth = downloader.download_natural_earth
      hydrosheds = skip_rivers ? {} : downloader.download_hydrosheds

      # Step 3: Load DEM sampler
      warn '[RegionImportService] Step 3: Loading DEM elevation sampler'
      sampler = ensure_dem_sampler!

      # Step 4: Build lake detector if not injected and not skipped
      warn '[RegionImportService] Step 4: Building lake detector'
      ld = if skip_lakes
             LakeDetector.new(nil, bounds: earth_bounds)
           else
             ensure_lake_detector!(natural_earth[:lakes])
           end

      # Step 5: Load terrain classifier and Swiss border
      warn '[RegionImportService] Step 5: Loading terrain classifier and Swiss border'
      clf = TerrainClassifier.new
      load_swiss_border!

      # Step 6: Fetch target hexes from DB and classify each
      warn '[RegionImportService] Step 6: Classifying hexes'
      target_hexes = fetch_target_hexes(world, placement)
      classified   = classify_hexes(target_hexes, sampler, ld, clf, placement[:lon_offset])

      # Step 6b: Smooth terrain - remove ocean/land noise and small fragments
      warn '[RegionImportService] Step 6b: Smoothing terrain boundaries'
      smooth_terrain!(classified)

      # Log terrain distribution
      log_terrain_distribution(classified)

      # Step 7: Trace rivers
      unless skip_rivers
        warn '[RegionImportService] Step 7: Tracing rivers'
        grid = build_region_grid(classified)
        apply_rivers!(grid, hydrosheds[:rivers], placement[:lon_offset])
      end

      if dry_run
        warn '[RegionImportService] DRY RUN — skipping database write'
        return { hexes_updated: 0 }
      end

      # Step 8: Backup original data
      warn '[RegionImportService] Step 8: Backing up original hex data'
      backup_hexes(world, target_hexes.map { |h| h[:id] })

      # Step 9: Bulk update DB
      warn '[RegionImportService] Step 9: Writing to database'
      grid ||= build_region_grid(classified)
      updated = bulk_update!(grid, world)

      # Step 10: Recalculate zoom regions
      warn '[RegionImportService] Step 10: Recalculating world regions'
      begin
        WorldRegionAggregationService.new.aggregate_for_world(world)
      rescue StandardError => e
        warn "[RegionImportService] Region aggregation failed (non-fatal): #{e.message}"
      end

      warn "[RegionImportService] Import complete: #{updated} hexes updated"
      { hexes_updated: updated }
    rescue StandardError => e
      warn "[RegionImportService] Import failed: #{e.message}"
      raise
    end

    # Classify a single hex given real Earth elevation and coordinates.
    # This is the core per-hex logic and is public for testability.
    #
    # @param real_elevation [Float]  Raw DEM elevation in meters
    # @param earth_lat      [Float]  Earth latitude in degrees
    # @param earth_lon      [Float]  Earth longitude in degrees
    # @return [Hash] { terrain_type:, altitude:, lake_id:, normalized_elevation: }
    def classify_hex(real_elevation:, earth_lat:, earth_lon:)
      # Ocean: any elevation below sea level cutoff
      if real_elevation < sea_level
        return {
          terrain_type: 'ocean',
          altitude: OCEAN_ALTITUDE,
          lake_id: nil,
          normalized_elevation: -1.0
        }
      end

      # Check for lake (must happen before classifier, which also emits 'lake')
      lake_id = lake_detector.lake_id_at(lat: earth_lat, lon: earth_lon)
      if lake_id
        altitude = (real_elevation - sea_level).round
        return {
          terrain_type: 'lake',
          altitude: altitude,
          lake_id: lake_id,
          normalized_elevation: 0.0
        }
      end

      # Normalize elevation for the classifier (-1.0 to 1.0)
      normalized = ((real_elevation - sea_level) / DemElevationSampler::MAX_ELEVATION).clamp(-1.0, 1.0)
      terrain    = classifier.classify(elevation: normalized, lat: earth_lat, lon: earth_lon)

      # Override classifier's false-positive lakes: if classifier says 'lake'
      # but LakeDetector found no lake here, reclassify as coast/plains.
      if terrain == 'lake' && lake_id.nil?
        terrain = normalized >= 0.015 ? 'grassy_plains' : 'sandy_coast'
      end

      altitude = (real_elevation - sea_level).round

      {
        terrain_type: terrain,
        altitude: altitude,
        lake_id: nil,
        normalized_elevation: normalized
      }
    end

    private

    # -------------------------------------------------------------------------
    # Placement helpers
    # -------------------------------------------------------------------------

    # Find a longitude band for placement, or use pinned target_lon.
    #
    # @param world [World]
    # @return [Hash, nil] { hex_ids:, lon_offset:, game_lat_center: }
    def find_placement(world)
      window_width = (earth_bounds[:max_lon] - earth_bounds[:min_lon]).abs
      earth_center_lon = (earth_bounds[:min_lon] + earth_bounds[:max_lon]) / 2.0

      if @target_lon
        # Pinned placement: center the island at the given longitude
        best_lon_start = @target_lon - window_width / 2.0
        warn "[RegionImportService] Using pinned placement at lon #{@target_lon}"
      else
        # Auto placement: scan for the largest ocean patch at target latitude
        ocean_hexes = DB[:world_hexes]
          .where(world_id: world.id, terrain_type: 'ocean')
          .where { latitude >= PLACEMENT_LAT_MIN }
          .where { latitude <= PLACEMENT_LAT_MAX }
          .select(:id, :latitude, :longitude)
          .all

        return nil if ocean_hexes.empty?

        best_lon_start = nil
        best_count     = 0

        (-180.0..180.0).step(1.0).each do |lon_start|
          lon_end = lon_start + window_width
          count = ocean_hexes.count { |h| h[:longitude] >= lon_start && h[:longitude] < lon_end }
          if count > best_count
            best_count     = count
            best_lon_start = lon_start
          end
        end

        return nil if best_count.zero?
      end

      lon_offset = best_lon_start - earth_bounds[:min_lon]

      # Load ALL hexes in the target region (not just ocean — we overwrite everything)
      target_hexes = DB[:world_hexes]
        .where(world_id: world.id)
        .where { latitude >= PLACEMENT_LAT_MIN }
        .where { latitude <= PLACEMENT_LAT_MAX }
        .where { longitude >= best_lon_start }
        .where { longitude < best_lon_start + window_width }
        .select(:id, :latitude, :longitude)
        .all

      {
        hex_ids: target_hexes.map { |h| h[:id] },
        lon_offset: lon_offset,
        game_lat_center: (PLACEMENT_LAT_MIN + PLACEMENT_LAT_MAX) / 2.0
      }
    end

    # -------------------------------------------------------------------------
    # Hex fetching
    # -------------------------------------------------------------------------

    # Fetch all world hexes in the target latitude/longitude band.
    #
    # @param world     [World]
    # @param placement [Hash]
    # @return [Array<Hash>]
    def fetch_target_hexes(world, placement)
      lon_min = placement[:lon_offset] + earth_bounds[:min_lon]
      lon_max = placement[:lon_offset] + earth_bounds[:max_lon]

      DB[:world_hexes]
        .where(world_id: world.id)
        .where { latitude  >= PLACEMENT_LAT_MIN }
        .where { latitude  <= PLACEMENT_LAT_MAX }
        .where { longitude >= lon_min }
        .where { longitude <  lon_max }
        .select(:id, :latitude, :longitude)
        .all
    end

    # -------------------------------------------------------------------------
    # Classification
    # -------------------------------------------------------------------------

    # Classify all target hexes, returning RegionHexGrid::HexData structs.
    # Pipeline: sample elevation → apply taper → smooth elevation → classify terrain → smooth terrain.
    #
    # @param hexes      [Array<Hash>]
    # @param sampler    [DemElevationSampler]
    # @param ld         [LakeDetector]
    # @param clf        [TerrainClassifier]
    # @param lon_offset [Float]
    # @return [Array<RegionHexGrid::HexData>]
    def classify_hexes(hexes, sampler, ld, clf, lon_offset)
      # Phase 1: Sample elevations and build spatial index
      hex_data = hexes.map do |hex|
        earth_lat = hex[:latitude]
        earth_lon = hex[:longitude] - lon_offset + earth_bounds[:min_lon]
        real_elev = sampler.sample(earth_lat, earth_lon)
        penalty = border_taper_penalty(earth_lat, earth_lon)

        {
          id: hex[:id],
          game_lat: hex[:latitude], game_lon: hex[:longitude],
          earth_lat: earth_lat, earth_lon: earth_lon,
          elevation: real_elev - penalty
        }
      end

      # Phase 2: Elevation smoothing (like world_generation's apply_erosion).
      # Blend each hex's elevation toward its neighbor average over multiple passes.
      # This eliminates isolated valleys/peaks that cause noisy ocean/land boundaries.
      spatial = build_spatial_index(hex_data)
      EROSION_PASSES.times do
        snapshot = hex_data.map { |h| h[:elevation] }
        hex_data.each_with_index do |h, i|
          neighbors = find_neighbors(h, spatial)
          next if neighbors.empty?

          neighbor_avg = neighbors.sum { |n| snapshot[n[:_idx]] } / neighbors.size.to_f
          h[:elevation] = snapshot[i] * (1.0 - EROSION_FACTOR) + neighbor_avg * EROSION_FACTOR
        end
      end
      warn "[RegionImportService] Applied #{EROSION_PASSES} erosion passes"

      # Phase 3: Classify terrain from smoothed elevations
      classified = hex_data.map do |h|
        result = classify_hex_with_deps(
          real_elevation: h[:elevation],
          earth_lat: h[:earth_lat],
          earth_lon: h[:earth_lon],
          lake_detector: ld,
          classifier: clf
        )

        RegionHexGrid::HexData.new(
          id:              h[:id],
          lat:             h[:game_lat] * Math::PI / 180.0,
          lon:             h[:game_lon] * Math::PI / 180.0,
          elevation:       result[:normalized_elevation],
          terrain_type:    result[:terrain_type],
          river_directions: nil,
          river_width:     nil
        )
      end

      classified
    rescue StandardError => e
      warn "[RegionImportService] classify_hexes failed: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      []
    end

    # Internal classify implementation that accepts explicit dependencies.
    # This allows classify_hex (the public method) to use instance-level deps
    # while classify_hexes passes per-call deps.
    def classify_hex_with_deps(real_elevation:, earth_lat:, earth_lon:, lake_detector:, classifier:)
      if real_elevation < sea_level
        return {
          terrain_type: 'ocean',
          altitude: OCEAN_ALTITUDE,
          lake_id: nil,
          normalized_elevation: -1.0
        }
      end

      lake_id = lake_detector.lake_id_at(lat: earth_lat, lon: earth_lon)
      if lake_id
        altitude = (real_elevation - sea_level).round
        return {
          terrain_type: 'lake',
          altitude: altitude,
          lake_id: lake_id,
          normalized_elevation: 0.0
        }
      end

      normalized = ((real_elevation - sea_level) / DemElevationSampler::MAX_ELEVATION).clamp(-1.0, 1.0)
      terrain    = classifier.classify(elevation: normalized, lat: earth_lat, lon: earth_lon)

      if terrain == 'lake' && lake_id.nil?
        terrain = normalized >= 0.015 ? 'grassy_plains' : 'sandy_coast'
      end

      altitude = (real_elevation - sea_level).round

      {
        terrain_type: terrain,
        altitude: altitude,
        lake_id: nil,
        normalized_elevation: normalized
      }
    end

    # -------------------------------------------------------------------------
    # River tracing
    # -------------------------------------------------------------------------

    def build_region_grid(hex_data_array)
      RegionHexGrid.new(hex_data_array)
    end

    # Minimum upstream area (km²) for rivers to include.
    # 10,000 km² captures ~6-10 major rivers: Rhine, Rhône, Aare, Reuss, Limmat, Inn
    RIVER_MIN_UPSTREAM_AREA = 10_000

    def apply_rivers!(grid, rivers_dir, lon_offset)
      return unless rivers_dir && File.directory?(rivers_dir)

      shp_path = Dir.glob(File.join(rivers_dir, '**/*.shp')).first
      return unless shp_path

      require 'rgeo-shapefile'
      require_relative 'regional_river_generator'

      # Load major rivers filtered by region and upstream area
      bounds = earth_bounds
      rivers = []

      warn "[RegionImportService] Loading rivers from #{File.basename(shp_path)} (>#{RIVER_MIN_UPSTREAM_AREA} km²)..."
      RGeo::Shapefile::Reader.open(shp_path) do |file|
        file.each do |record|
          next unless record&.geometry

          area = (record['UPLAND_SKM'] || record['UP_AREA'] || 0).to_f
          next if area < RIVER_MIN_UPSTREAM_AREA

          coords = extract_river_coords(record.geometry)
          next if coords.nil? || coords.length < 2
          next unless coords.any? { |lat, lon| lat.between?(bounds[:min_lat], bounds[:max_lat]) && lon.between?(bounds[:min_lon], bounds[:max_lon]) }

          # Shift from Earth to game coordinates
          game_coords = coords.map { |lat, lon| [lat, lon + lon_offset - bounds[:min_lon]] }

          rivers << { upstream_area: area, coords: game_coords }
        end
      end

      warn "[RegionImportService] Found #{rivers.size} river segments, generating paths..."
      return if rivers.empty?

      # Use waypoint-guided pathfinding instead of raw polyline tracing
      generator = RegionalRiverGenerator.new(grid, rivers, sea_level_normalized: 0.0)
      generator.generate

      river_count = grid.hexes.count { |h| h.river_directions && !h.river_directions.empty? }
      warn "[RegionImportService] Rivers on #{river_count} hexes"
    rescue StandardError => e
      warn "[RegionImportService] River generation failed: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end

    def extract_river_coords(geometry)
      coords = []
      case geometry.geometry_type.type_name
      when 'LineString'
        geometry.points.each { |p| coords << [p.y, p.x] }
      when 'MultiLineString'
        geometry.each { |line| line.points.each { |p| coords << [p.y, p.x] } }
      end
      coords
    end

    # -------------------------------------------------------------------------
    # Backup
    # -------------------------------------------------------------------------

    def backup_hexes(world, hex_ids)
      return if hex_ids.empty?

      backup_dir  = File.join(__dir__, '../../../../tmp/earth_import_backups')
      FileUtils.mkdir_p(backup_dir)
      backup_file = File.join(backup_dir, "world_#{world.id}_backup_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")

      rows = DB[:world_hexes]
        .where(id: hex_ids)
        .select(:id, :terrain_type, :altitude, :latitude, :longitude)
        .all

      File.write(backup_file, JSON.generate(rows))
      warn "[RegionImportService] Backup written to #{backup_file} (#{rows.size} hexes)"
    rescue StandardError => e
      warn "[RegionImportService] Backup failed (non-fatal): #{e.message}"
    end

    # -------------------------------------------------------------------------
    # Bulk DB update
    # -------------------------------------------------------------------------

    # Write classified hexes to the database via a temp table join-update.
    # Uses Sequel query builder — no raw SQL string interpolation.
    #
    # @param grid  [RegionHexGrid]
    # @param world [World]
    # @return [Integer] Number of rows updated
    def bulk_update!(grid, world)
      return 0 if grid.hexes.empty?

      DB.transaction do
        DB.run(<<~SQL)
          CREATE TEMP TABLE #{TMP_TABLE} (
            id         INTEGER NOT NULL,
            terrain    VARCHAR(64),
            altitude   INTEGER,
            feature_n  VARCHAR(32),
            feature_ne VARCHAR(32),
            feature_se VARCHAR(32),
            feature_s  VARCHAR(32),
            feature_sw VARCHAR(32),
            feature_nw VARCHAR(32),
            river_width INTEGER
          ) ON COMMIT DROP
        SQL

        rows = grid.hexes.map do |hex|
          row = {
            id: hex.id,
            terrain: hex.terrain_type,
            altitude: altitude_from_hex(hex),
            feature_n: nil, feature_ne: nil, feature_se: nil,
            feature_s: nil, feature_sw: nil, feature_nw: nil,
            river_width: hex.river_width
          }
          # Copy river direction features from the traced data
          if hex.river_directions && !hex.river_directions.empty?
            hex.river_directions.each do |dir|
              row[:"feature_#{dir}"] = 'river'
            end
          end
          row
        end

        rows.each_slice(5_000) do |batch|
          DB[TMP_TABLE].multi_insert(batch)
        end

        DB.run(<<~SQL)
          UPDATE world_hexes wh
          SET    terrain_type = t.terrain,
                 altitude     = t.altitude,
                 feature_n    = t.feature_n,
                 feature_ne   = t.feature_ne,
                 feature_se   = t.feature_se,
                 feature_s    = t.feature_s,
                 feature_sw   = t.feature_sw,
                 feature_nw   = t.feature_nw,
                 river_width  = t.river_width
          FROM   #{TMP_TABLE} t
          WHERE  wh.id = t.id
            AND  wh.world_id = #{world.id.to_i}
        SQL

        rows.size
      end
    rescue StandardError => e
      warn "[RegionImportService] bulk_update! failed: #{e.message}"
      raise
    end

    # Convert normalized elevation back to game altitude (meters).
    def altitude_from_hex(hex)
      return OCEAN_ALTITUDE if hex.terrain_type == 'ocean'

      # elevation field in HexData is already normalized; convert back
      (hex.elevation.to_f * DemElevationSampler::MAX_ELEVATION).round
    end

    # -------------------------------------------------------------------------
    # Lazy helpers
    # -------------------------------------------------------------------------

    def downloader
      @downloader ||= DataDownloader.new
    end

    def ensure_dem_sampler!
      return @dem_sampler if @dem_sampler

      dem_path = DemElevationSampler.ensure_downloaded!
      @dem_sampler = DemElevationSampler.new(dem_path)
    end

    def ensure_lake_detector!(lakes_dir)
      return @lake_detector if @lake_detector

      @lake_detector = LakeDetector.new(lakes_dir, bounds: earth_bounds)
    end

    # Return the lake detector (used by the public classify_hex method).
    def lake_detector
      @lake_detector ||= LakeDetector.new(nil, bounds: earth_bounds)
    end

    # Return a terrain classifier (lazily created, shared across calls).
    def classifier
      @classifier ||= TerrainClassifier.new
    end

    # -------------------------------------------------------------------------
    # Swiss border polygon and elevation taper
    # -------------------------------------------------------------------------

    # Load Switzerland's political border from Natural Earth shapefile.
    # Returns the geometry and its boundary linestring for distance calculations.
    def load_swiss_border!
      return if @swiss_border

      require 'rgeo'
      require 'rgeo-shapefile'

      factory = RGeo::Geos.factory(srid: 4326)
      shp_dir = File.join(__dir__, '../../../', COUNTRIES_SHP_DIR)
      shp_path = Dir.glob(File.join(shp_dir, '**/*.shp')).first

      unless shp_path
        warn '[RegionImportService] Country shapefile not found, no taper will be applied'
        return
      end

      RGeo::Shapefile::Reader.open(shp_path, factory: factory) do |file|
        file.each do |record|
          name = record['NAME'] || record['name'] || ''
          next unless name =~ /switzerland/i

          @swiss_border = record.geometry
          @swiss_boundary = record.geometry.boundary
          @border_factory = factory
          warn "[RegionImportService] Loaded Swiss border polygon (#{record.geometry.geometry_type.type_name})"
          break
        end
      end
    rescue StandardError => e
      warn "[RegionImportService] Failed to load Swiss border: #{e.message}"
    end

    # Calculate elevation penalty based on distance from Switzerland's border.
    #
    # - Inside Switzerland: 0 penalty (full real elevation)
    # - 0 to TAPER_DISTANCE_DEG outside: linear ramp from 0 to MAX_TAPER_PENALTY
    # - Beyond TAPER_DISTANCE_DEG: MAX_TAPER_PENALTY (almost certainly ocean)
    #
    # @param earth_lat [Float] Earth latitude in degrees
    # @param earth_lon [Float] Earth longitude in degrees
    # @return [Float] Meters to subtract from real elevation
    def border_taper_penalty(earth_lat, earth_lon)
      return 0.0 unless @swiss_border

      point = @border_factory.point(earth_lon, earth_lat)

      # Inside Switzerland: no penalty
      return 0.0 if @swiss_border.contains?(point)

      # Distance from point to Switzerland's border (in degrees)
      dist = @swiss_boundary.distance(point)

      if dist >= TAPER_DISTANCE_DEG
        MAX_TAPER_PENALTY.to_f
      else
        # Linear interpolation: 0 at border, MAX_TAPER_PENALTY at TAPER_DISTANCE_DEG
        (dist / TAPER_DISTANCE_DEG) * MAX_TAPER_PENALTY
      end
    end

    # -------------------------------------------------------------------------
    # Spatial helpers for elevation smoothing
    # -------------------------------------------------------------------------

    # Build a spatial hash index for fast neighbor lookups.
    # Keys: [lat_bucket, lon_bucket] → array of hex_data entries.
    # Each entry gets an :_idx field for array indexing.
    # Bucket size and neighbor distance are computed from actual hex spacing.

    def estimate_hex_spacing(hex_data)
      return 0.045 if hex_data.size < 10

      # Estimate from world's subdivision level via hex count
      # Formula: vertex count = 10 * 4^N + 2, spacing ≈ 180 / (2^N * sqrt(5))
      world_hex_count = DB[:world_hexes].where(world_id: @world_id).count
      subdivisions = (Math.log(([world_hex_count - 2, 10].max) / 10.0) / Math.log(4)).round
      spacing = 180.0 / (2**subdivisions * Math.sqrt(5))
      warn "[RegionImportService] World has #{world_hex_count} hexes → subdivision #{subdivisions} → spacing ~#{spacing.round(5)}°"
      spacing
    end

    def build_spatial_index(hex_data)
      @hex_spacing ||= estimate_hex_spacing(hex_data)
      @spatial_bucket_deg = @hex_spacing * 1.5
      @max_neighbor_dist_deg = @hex_spacing * 1.8 # ~1 ring of neighbors

      index = Hash.new { |h, k| h[k] = [] }
      hex_data.each_with_index do |h, i|
        h[:_idx] = i
        bk = [(h[:game_lat] / @spatial_bucket_deg).floor, (h[:game_lon] / @spatial_bucket_deg).floor]
        index[bk] << h
      end
      warn "[RegionImportService] Hex spacing: #{@hex_spacing.round(5)}°, bucket: #{@spatial_bucket_deg.round(5)}°, neighbor dist: #{@max_neighbor_dist_deg.round(5)}°"
      index
    end

    def find_neighbors(hex, spatial)
      bucket = @spatial_bucket_deg
      max_dist = @max_neighbor_dist_deg
      lat_b = (hex[:game_lat] / bucket).floor
      lon_b = (hex[:game_lon] / bucket).floor
      results = []

      (-1..1).each do |dlat|
        (-1..1).each do |dlon|
          (spatial[[lat_b + dlat, lon_b + dlon]] || []).each do |other|
            next if other[:_idx] == hex[:_idx]

            dist = Math.sqrt((other[:game_lat] - hex[:game_lat])**2 +
                             (other[:game_lon] - hex[:game_lon])**2)
            results << other if dist < max_dist
          end
        end
      end
      results
    end

    # -------------------------------------------------------------------------
    # Terrain smoothing (post-classification)
    # -------------------------------------------------------------------------

    # Smooth terrain types using majority-vote neighbor passes, then remove
    # small disconnected land/ocean fragments. Modeled on how procedural
    # world generation produces clean coastlines.
    def smooth_terrain!(classified)
      # Compute spacing in radians from the degree-based spacing estimate
      spacing_rad = (@hex_spacing || 0.03) * Math::PI / 180.0
      bucket_rad = spacing_rad * 1.5
      neighbor_dist_rad = spacing_rad * 1.8

      spatial = {}
      classified.each_with_index do |h, i|
        bk = [(h.lat / bucket_rad).floor, (h.lon / bucket_rad).floor]
        spatial[bk] = [] unless spatial.key?(bk)
        spatial[bk] << i
      end

      # Helper to find neighbor indices
      find_neighbor_indices = lambda do |hex_idx|
        h = classified[hex_idx]
        lat_b = (h.lat / bucket_rad).floor
        lon_b = (h.lon / bucket_rad).floor
        neighbors = []
        (-1..1).each do |dlat|
          (-1..1).each do |dlon|
            (spatial[[lat_b + dlat, lon_b + dlon]] || []).each do |other_idx|
              next if other_idx == hex_idx

              other = classified[other_idx]
              dist = Math.sqrt((other.lat - h.lat)**2 + (other.lon - h.lon)**2)
              neighbors << other_idx if dist < neighbor_dist_rad
            end
          end
        end
        neighbors
      end

      # Pass 1 & 2: Majority-vote smoothing
      TERRAIN_SMOOTH_PASSES.times do |pass|
        flips = 0
        classified.each_with_index do |hex, i|
          neighbor_indices = find_neighbor_indices.call(i)
          next if neighbor_indices.size < 3

          is_ocean = hex.terrain_type == 'ocean'
          ocean_count = neighbor_indices.count { |ni| classified[ni].terrain_type == 'ocean' }
          land_count = neighbor_indices.size - ocean_count

          if is_ocean && land_count >= TERRAIN_SMOOTH_THRESHOLD
            # Ocean surrounded by land → pick most common neighbor land type
            land_terrains = neighbor_indices
              .map { |ni| classified[ni].terrain_type }
              .reject { |t| t == 'ocean' }
            hex.terrain_type = land_terrains.max_by { |t| land_terrains.count(t) } || 'grassy_plains'
            flips += 1
          elsif !is_ocean && hex.terrain_type != 'lake' && ocean_count >= TERRAIN_SMOOTH_THRESHOLD
            # Land surrounded by ocean → convert to ocean
            hex.terrain_type = 'ocean'
            hex.elevation = -1.0
            flips += 1
          end
        end
        warn "[RegionImportService] Terrain smooth pass #{pass + 1}: #{flips} flips"
      end

      # Pass 3: Remove small disconnected land clusters
      visited = Array.new(classified.size, false)
      clusters = []

      classified.each_index do |i|
        next if visited[i] || classified[i].terrain_type == 'ocean'

        # BFS to find connected land component
        cluster = []
        queue = [i]
        while (idx = queue.shift)
          next if visited[idx] || classified[idx].terrain_type == 'ocean'

          visited[idx] = true
          cluster << idx
          find_neighbor_indices.call(idx).each do |ni|
            queue << ni unless visited[ni] || classified[ni].terrain_type == 'ocean'
          end
        end
        clusters << cluster
      end

      # Keep only the largest cluster(s), remove small fragments
      clusters.sort_by! { |c| -c.size }
      removed = 0
      clusters.each do |cluster|
        next if cluster.size >= MIN_LAND_CLUSTER_SIZE

        cluster.each do |idx|
          classified[idx].terrain_type = 'ocean'
          classified[idx].elevation = -1.0
        end
        removed += cluster.size
      end
      warn "[RegionImportService] Removed #{removed} hexes in #{clusters.count { |c| c.size < MIN_LAND_CLUSTER_SIZE }} small fragments"

      # Pass 4: Lake expansion — if a hex is adjacent to 2+ lake hexes and
      # is at low elevation, convert it to lake for continuity
      classified.each_with_index do |hex, i|
        next if hex.terrain_type == 'ocean' || hex.terrain_type == 'lake'
        next if hex.elevation > 0.02  # Only low-elevation hexes near lakes

        neighbor_indices = find_neighbor_indices.call(i)
        lake_count = neighbor_indices.count { |ni| classified[ni].terrain_type == 'lake' }
        if lake_count >= 2
          hex.terrain_type = 'lake'
        end
      end
    end

    # Log terrain type distribution for verification.
    def log_terrain_distribution(classified)
      counts = classified.group_by(&:terrain_type)
                         .transform_values(&:count)
                         .sort_by { |_, v| -v }

      warn '[RegionImportService] Terrain distribution:'
      counts.each { |terrain, count| warn "  #{terrain}: #{count}" }
    end
  end
end
