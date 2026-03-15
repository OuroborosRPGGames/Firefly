# frozen_string_literal: true

require 'set'

module EarthImport
  # Traces river polylines from shapefiles and converts them to hex directions.
  # Rivers are stored as directional features on hexes (e.g., river enters from NW, exits to SE).
  #
  # Usage:
  #   tracer = EarthImport::RiverTracer.new
  #   rivers = tracer.load_from_shapefile('/path/to/hydrorivers')
  #   major_rivers = tracer.filter_major_rivers(rivers, min_area: 10_000)
  #   tracer.apply_to_grid(grid, major_rivers)
  #
  class RiverTracer
    # Minimum upstream area in km^2 to include a river (~150 rivers globally)
    DEFAULT_MIN_UPSTREAM_AREA = 10_000

    attr_reader :coordinate_converter

    # Initialize a new RiverTracer.
    #
    # @param coordinate_converter [CoordinateConverter] Optional converter instance
    def initialize(coordinate_converter: nil)
      @coordinate_converter = coordinate_converter || CoordinateConverter.new
    end

    # Trace a single river through the hex grid.
    # Returns hex updates with entry/exit directions for river flow.
    #
    # @param coords [Array<Array<Float>>] Array of [lat, lon] pairs in degrees
    # @param grid [WorldGeneration::GlobeHexGrid] The hex grid
    # @return [Array<Hash>] Array of {hex: HexData, directions: Array<String>}
    def trace_river(coords, grid)
      return [] if coords.nil? || coords.length < 2

      coordinate_converter.line_to_hexes(coords, grid)
    end

    # Apply river data to a hex grid, updating river_directions and river_width on each hex.
    #
    # @param grid [WorldGeneration::GlobeHexGrid] The hex grid to update
    # @param rivers [Array<Hash>] Array of river data with :coords or 'coords'
    # @param progress_callback [Proc] Optional callback(current, total) for progress
    def apply_to_grid(grid, rivers, progress_callback: nil)
      return if rivers.nil? || rivers.empty?

      total = rivers.length

      rivers.each_with_index do |river, i|
        coords = river[:coords] || river['coords']
        next unless coords && coords.length >= 2

        updates = trace_river(coords, grid)

        # Calculate river width from upstream area (real drainage data)
        upstream_area = river[:upstream_area] || river['upstream_area'] || 0
        width = width_from_upstream_area(upstream_area)

        updates.each do |update|
          hex = update[:hex]
          next unless hex

          # Initialize river_directions if needed (use Set for O(1) uniqueness)
          hex.river_directions ||= Set.new
          hex.river_directions.merge(update[:directions]) if update[:directions]

          # Set river_width (take max if multiple rivers cross this hex)
          hex.river_width = [hex.river_width || 0, width].max
        end

        # Report progress every 50 rivers
        progress_callback&.call(i, total) if progress_callback && ((i % 50).zero? || i == total - 1)
      end
    end

    # Filter rivers by upstream area to get only major rivers.
    # Using 10,000 km^2 threshold yields approximately 150 rivers globally.
    #
    # @param rivers [Array<Hash>] Array of river data
    # @param min_area [Integer] Minimum upstream area in km^2 (default: 10,000)
    # @return [Array<Hash>] Filtered rivers
    def filter_major_rivers(rivers, min_area: DEFAULT_MIN_UPSTREAM_AREA)
      return [] if rivers.nil? || rivers.empty?

      rivers.select do |river|
        area = river[:upstream_area] || river['upstream_area'] || 0
        area >= min_area
      end
    end

    # Load river data from a shapefile directory (e.g., HydroRIVERS).
    # Looks for .shp files and extracts river polylines with metadata.
    #
    # @param shapefile_dir [String] Path to directory containing shapefile
    # @return [Array<Hash>] Array of river data with :name, :upstream_area, :coords
    def load_from_shapefile(shapefile_dir)
      rivers = []

      return rivers unless shapefile_dir && File.directory?(shapefile_dir)

      # Find the .shp file
      shp_path = Dir.glob(File.join(shapefile_dir, '**/*.shp')).first
      return rivers unless shp_path

      begin
        require 'rgeo-shapefile'

        RGeo::Shapefile::Reader.open(shp_path) do |file|
          file.each do |record|
            next unless record && record.geometry

            # Extract river data from HydroRIVERS attributes
            river = {
              name: extract_river_name(record),
              upstream_area: extract_upstream_area(record),
              coords: extract_coordinates(record.geometry)
            }

            rivers << river if river[:coords] && river[:coords].length >= 2
          end
        end
      rescue LoadError
        warn '[RiverTracer] rgeo-shapefile gem not available - cannot load shapefiles'
      rescue StandardError => e
        warn "[RiverTracer] Failed to load shapefile: #{e.message}"
      end

      rivers
    end

    private

    # Determine river width classification from upstream drainage area.
    # Based on real-world river data from HydroRIVERS:
    #   - Amazon: ~7,000,000 km²
    #   - Mississippi/Nile: ~3,000,000 km²
    #   - Rhine: ~200,000 km²
    #   - Small rivers: 10,000-50,000 km²
    #
    # @param upstream_area [Float] Upstream drainage area in km²
    # @return [Integer] Width classification: 1=stream, 2=river, 3=major
    def width_from_upstream_area(upstream_area)
      case upstream_area
      when 0...25_000      then 1 # Stream (small tributaries)
      when 25_000...100_000 then 2 # River (medium rivers)
      else                      3 # Major river (large drainage basins)
      end
    end

    # Extract river name from shapefile record.
    # Tries common attribute names used in river datasets.
    #
    # @param record [Object] Shapefile record
    # @return [String] River name or 'Unknown'
    def extract_river_name(record)
      # HydroRIVERS uses MAIN_RIV for main river name
      # Other datasets might use NAME, RIVERNAME, etc.
      record['MAIN_RIV'] ||
        record['NAME'] ||
        record['RIVERNAME'] ||
        record['name'] ||
        'Unknown'
    end

    # Extract upstream area from shapefile record.
    # Tries common attribute names used in river datasets.
    #
    # @param record [Object] Shapefile record
    # @return [Float] Upstream area in km^2, or 0
    def extract_upstream_area(record)
      # HydroRIVERS uses UPLAND_SKM for upstream drainage area in sq km
      # Also check for common alternatives
      area = record['UPLAND_SKM'] ||
             record['UP_AREA'] ||
             record['AREA_KM2'] ||
             record['area_sqkm'] ||
             0

      area.to_f
    end

    # Extract coordinates from a geometry as [lat, lon] pairs.
    #
    # @param geometry [RGeo::Geometry] The geometry object
    # @return [Array<Array<Float>>] Array of [lat, lon] pairs
    def extract_coordinates(geometry)
      coords = []

      return coords unless geometry

      case geometry.geometry_type.type_name
      when 'LineString'
        geometry.points.each do |point|
          coords << [point.y, point.x] # lat, lon (y is lat, x is lon)
        end
      when 'MultiLineString'
        # For multi-line strings, concatenate all lines
        # This handles rivers that are split into segments
        geometry.each do |line|
          line.points.each do |point|
            coords << [point.y, point.x]
          end
        end
      when 'Point'
        coords << [geometry.y, geometry.x]
      end

      coords
    end
  end
end
