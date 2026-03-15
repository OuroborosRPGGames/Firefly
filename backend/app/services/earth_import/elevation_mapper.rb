# frozen_string_literal: true

require 'parallel'
require_relative 'parallel_grid_processor'

module EarthImport
  # Maps elevation data to globe hexes using Natural Earth data via GDAL.
  #
  # Uses the LandMaskService to accurately determine land vs ocean from
  # actual coastline shapefiles, rather than hardcoded rectangular estimates.
  #
  # Supports parallel processing for multi-core performance.
  #
  class ElevationMapper
    include ParallelGridProcessor
    # Earth's elevation range for normalization
    MAX_ELEVATION = 9000.0   # Slightly above Everest
    MIN_ELEVATION = -11000.0 # Mariana Trench depth

    # Default number of threads for parallel processing
    DEFAULT_THREADS = 8

    attr_reader :raster_path, :land_dir

    # Initialize the elevation mapper.
    #
    # @param raster_path [String] Path to land cover raster (for future use)
    # @param land_dir [String] Path to Natural Earth land shapefile directory
    # @param threads [Integer] Number of threads for parallel processing
    # @param subdivisions [Integer] Subdivision level for adaptive raster resolution
    def initialize(raster_path: nil, land_dir: nil, threads: DEFAULT_THREADS, subdivisions: nil)
      @raster_path = raster_path
      @land_dir = land_dir
      @land_mask = nil
      @threads = threads
      @subdivisions = subdivisions

      load_land_mask if @land_dir
    end

    # Sample elevation at a lat/lon coordinate.
    #
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [Float] Elevation in meters
    def sample(lat, lon)
      if @land_mask&.loaded?
        sample_with_land_mask(lat, lon)
      else
        # Fallback to estimation if GDAL/land mask not available
        estimate_elevation(lat, lon)
      end
    end

    # Normalize an elevation value to -1.0 to 1.0 range.
    #
    # @param elevation_meters [Float] Elevation in meters
    # @return [Float] Normalized elevation
    def normalize(elevation_meters)
      return 0.0 if elevation_meters.nil?

      if elevation_meters >= 0
        [elevation_meters / MAX_ELEVATION, 1.0].min
      else
        # For negative elevations: -11000m -> -1.0, 0m -> 0.0
        [elevation_meters / MIN_ELEVATION.abs, -1.0].max
      end
    end

    # Check if accurate land mask is available.
    #
    # @return [Boolean]
    def land_mask_available?
      @land_mask&.loaded? || false
    end

    private

    # Process a single hex for elevation mapping.
    # Called by ParallelGridProcessor.
    def process_hex(hex, lat_deg, lon_deg)
      elevation_m = sample(lat_deg, lon_deg)
      hex.elevation = normalize(elevation_m)
    end

    # Load the land mask service.
    # Uses rasterized mode for O(1) lookups during elevation mapping.
    def load_land_mask
      @land_mask = LandMaskService.new(
        @land_dir,
        rasterize: true,
        subdivisions: @subdivisions
      )
    rescue LandMaskService::GdalNotAvailableError => e
      warn "[ElevationMapper] #{e.message}"
      @land_mask = nil
    rescue StandardError => e
      warn "[ElevationMapper] Failed to load land mask: #{e.message}"
      @land_mask = nil
    end

    # Sample elevation using the accurate land mask.
    #
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [Float] Elevation in meters
    def sample_with_land_mask(lat, lon)
      abs_lat = lat.abs

      # Polar ice caps
      return 500.0 if abs_lat > 80

      # Use land mask for accurate coastlines
      if @land_mask.ocean?(lat: lat, lon: lon)
        return -4000.0 # Ocean depth
      end

      # It's land - calculate base elevation + mountain bonus
      elevation = base_land_elevation(lat, lon)
      elevation += mountain_bonus(lat, lon)
      elevation
    end

    # Fallback estimation when GDAL is not available.
    # Uses hardcoded rectangular regions - NOT accurate!
    #
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [Float] Elevation in meters
    def estimate_elevation(lat, lon)
      abs_lat = lat.abs

      # Polar regions - ice/low
      return 500.0 if abs_lat > 70

      # Check for known ocean areas (rough rectangles)
      return -4000.0 if ocean_estimate?(lat, lon)

      # Mountain ranges - check specific regions
      elevation = base_land_elevation(lat, lon)

      # Add mountain chain elevation
      elevation += mountain_bonus(lat, lon)

      elevation
    end

    # Rough ocean estimation using rectangular regions.
    # Only used as fallback when GDAL is not available.
    def ocean_estimate?(lat, lon)
      # Pacific Ocean
      return true if lon.between?(-180, -100) && lat.between?(-60, 60)
      return true if lon.between?(100, 180) && lat.between?(-60, 60)

      # Atlantic Ocean (simplified)
      return true if lon.between?(-80, -10) && lat.between?(-60, 0)
      return true if lon.between?(-60, 0) && lat.between?(0, 60)

      # Indian Ocean
      return true if lon.between?(40, 100) && lat.between?(-60, 20)

      # Arctic Ocean
      return true if lat.abs > 75 && !land_at_arctic?(lat, lon)

      false
    end

    def land_at_arctic?(lat, lon)
      # Greenland
      return true if lon.between?(-70, -20) && lat.between?(60, 85)
      # Scandinavia/Russia
      return true if lon.between?(0, 180) && lat.between?(65, 80)
      # Canada/Alaska
      return true if lon.between?(-170, -60) && lat.between?(65, 85)

      false
    end

    def base_land_elevation(lat, lon)
      abs_lat = lat.abs

      # Higher base for interior continents
      base = 200.0

      # Temperate zone land tends to be higher
      base += 100.0 if abs_lat.between?(30, 55)

      base
    end

    def mountain_bonus(lat, lon)
      bonus = 0.0

      # Himalayas/Tibet
      bonus += 2000.0 if lat.between?(25, 40) && lon.between?(70, 105)

      # Andes
      bonus += 1500.0 if lat.between?(-55, 10) && lon.between?(-80, -60)

      # Rocky Mountains
      bonus += 1200.0 if lat.between?(30, 55) && lon.between?(-125, -100)

      # Alps
      bonus += 1500.0 if lat.between?(44, 48) && lon.between?(5, 15)

      # East African Highlands
      bonus += 1000.0 if lat.between?(-10, 15) && lon.between?(30, 45)

      bonus
    end
  end
end
