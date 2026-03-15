# frozen_string_literal: true

require 'parallel'
require_relative 'parallel_grid_processor'

module EarthImport
  # Classifies hexes into terrain types based on elevation, latitude, and moisture.
  # Maps real Earth geography to game terrain types defined in WorldHex::TERRAIN_TYPES.
  #
  # Supports parallel processing for multi-core performance.
  #
  class TerrainClassifier
    include ParallelGridProcessor
    # Path to pre-computed terrain lookup binary
    LOOKUP_PATH = File.join(__dir__, '../../../data/terrain_lookup.bin').freeze

    # Error raised when lookup file is missing
    class LookupMissingError < StandardError; end

    # Elevation thresholds (normalized -1.0 to 1.0)
    MOUNTAIN_THRESHOLD = 0.22  # ~2000m
    HILL_THRESHOLD = 0.055     # ~500m
    ICE_ELEVATION = 0.39       # ~3500m

    # Latitude threshold for polar regions
    POLAR_LATITUDE = 66.0

    # Default number of threads for parallel processing
    DEFAULT_THREADS = 8

    def initialize(land_cover_path: nil, threads: DEFAULT_THREADS)
      @land_cover_path = land_cover_path
      @threads = threads
      load_lookup!
    end

    # Classify terrain based on elevation, latitude, and longitude.
    #
    # Uses pre-computed lookup table for biome classification, with elevation
    # overrides for ocean, mountains, hills, and polar regions.
    #
    # @param elevation [Float] Normalized elevation (-1.0 to 1.0)
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [String] One of WorldHex::TERRAIN_TYPES
    def classify(elevation:, lat:, lon:)
      # Ocean (below sea level)
      return 'ocean' if elevation < 0

      abs_lat = lat.abs

      # Coastal: very low elevation, just above sea level
      if elevation >= 0 && elevation < 0.015
        return abs_lat > 50 ? 'rocky_coast' : 'sandy_coast'
      end

      # Lake: very low elevation inland (narrow band between coast and hills)
      return 'lake' if elevation >= 0.015 && elevation < 0.02

      # Tundra (polar regions or very high altitude)
      return 'tundra' if abs_lat > POLAR_LATITUDE
      return 'tundra' if elevation > ICE_ELEVATION

      # Mountains (high elevation)
      return 'mountain' if elevation > MOUNTAIN_THRESHOLD

      # Hills (moderate elevation)
      if elevation > HILL_THRESHOLD
        return abs_lat > 50 ? 'rocky_hills' : 'grassy_hills'
      end

      # Use lookup table for biome classification
      lookup_terrain(lat, lon)
    end

    private

    # Process a single hex for terrain classification.
    # Called by ParallelGridProcessor.
    def process_hex(hex, lat_deg, lon_deg)
      hex.terrain_type = classify(
        elevation: hex.elevation || 0,
        lat: lat_deg,
        lon: lon_deg
      )
    end

    def load_lookup!
      unless File.exist?(LOOKUP_PATH)
        raise LookupMissingError,
              "Terrain lookup file not found at #{LOOKUP_PATH}. " \
              'Run: python scripts/generate_terrain_lookup.py'
      end

      File.open(LOOKUP_PATH, 'rb') do |f|
        magic, _version = f.read(8).unpack('L<L<')
        raise 'Invalid terrain lookup file: wrong magic number' unless magic == 0x54455252

        @lat_min, @lat_max, @lon_min, @lon_max, @resolution = f.read(20).unpack('eeeee')
        @rows, @cols = f.read(8).unpack('L<L<')
        @lookup_data = f.read
      end
    end

    # Look up terrain type from pre-computed binary data.
    #
    # @param lat [Float] Latitude in degrees
    # @param lon [Float] Longitude in degrees
    # @return [String] Terrain type from WorldHex::TERRAIN_TYPES
    def lookup_terrain(lat, lon)
      return WorldHex::DEFAULT_TERRAIN unless @lookup_data

      lat = lat.clamp(@lat_min, @lat_max - 0.001)
      lon = lon.clamp(@lon_min, @lon_max - 0.001)

      row = ((lat - @lat_min) / @resolution).floor
      col = ((lon - @lon_min) / @resolution).floor
      idx = row * @cols + col

      terrain_idx = @lookup_data.getbyte(idx)
      WorldHex::TERRAIN_TYPES[terrain_idx] || WorldHex::DEFAULT_TERRAIN
    end
  end
end
