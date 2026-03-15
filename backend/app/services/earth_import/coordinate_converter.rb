# frozen_string_literal: true

module EarthImport
  # Converts geographic coordinates (latitude/longitude) to hex positions
  # on the icosahedral globe grid.
  #
  # This service handles:
  # - Point-to-hex conversion for placing features
  # - Line-to-hexes conversion for rivers and roads with entry/exit directions
  # - Polygon containment testing for region-based terrain assignment
  #
  # Usage:
  #   converter = EarthImport::CoordinateConverter.new
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #
  #   # Find hex for a point (degrees)
  #   hex = converter.point_to_hex(45.0, -122.0, grid)
  #
  #   # Trace a river through hexes
  #   coords = [[48.0, -122.0], [47.0, -121.0], [46.0, -120.0]]
  #   river_hexes = converter.line_to_hexes(coords, grid)
  #
  class CoordinateConverter
    # Direction names for hex edges (matching WorldHex conventions)
    DIRECTIONS = %w[n ne se s sw nw].freeze

    def initialize
      @hex_cache = {}
    end

    # Convert degrees to radians.
    #
    # @param degrees [Float] Angle in degrees
    # @return [Float] Angle in radians
    def degrees_to_radians(degrees)
      degrees * Math::PI / 180.0
    end

    # Convert radians to degrees.
    #
    # @param radians [Float] Angle in radians
    # @return [Float] Angle in degrees
    def radians_to_degrees(radians)
      radians * 180.0 / Math::PI
    end

    # Find the hex containing a given latitude/longitude point.
    # Coordinates are in degrees (standard geographic notation).
    #
    # @param lat [Float] Latitude in degrees (-90 to 90)
    # @param lon [Float] Longitude in degrees (-180 to 180)
    # @param grid [WorldGeneration::GlobeHexGrid] The hex grid to search
    # @return [WorldGeneration::HexData, nil] The nearest hex, or nil if grid is empty
    def point_to_hex(lat, lon, grid)
      return nil if grid.nil? || grid.hexes.empty?

      # Convert to radians for the grid's hex_at_latlon method
      lat_rad = degrees_to_radians(lat)
      lon_rad = degrees_to_radians(lon)

      # Use the grid's built-in method which uses 3D dot product for accuracy
      grid.hex_at_latlon(lat_rad, lon_rad)
    end

    # Convert a polyline to a sequence of hexes with entry/exit directions.
    # Useful for tracing rivers, roads, or other linear features.
    #
    # @param coords [Array<Array<Float>>] Array of [lat, lon] pairs in degrees
    # @param grid [WorldGeneration::GlobeHexGrid] The hex grid
    # @return [Array<Hash>] Array of {hex: HexData, directions: Array<String>}
    #   where directions indicate which edges the line crosses
    def line_to_hexes(coords, grid)
      return [] if coords.nil? || coords.length < 2

      result = []
      prev_hex = nil

      coords.each_cons(2) do |start_coord, end_coord|
        # Sample points along segment to catch all hexes it crosses
        samples = interpolate_segment(start_coord, end_coord, 10)

        samples.each do |lat, lon|
          hex = point_to_hex(lat, lon, grid)
          next unless hex
          next if hex == prev_hex

          entry_dir = prev_hex ? direction_from(prev_hex, hex) : nil

          # Update previous hex's exit direction
          if result.any? && entry_dir
            exit_dir = opposite_direction(entry_dir)
            result.last[:directions] << exit_dir unless result.last[:directions].include?(exit_dir)
          end

          result << { hex: hex, directions: entry_dir ? [entry_dir] : [] }
          prev_hex = hex
        end
      end

      result
    end

    # Check if a point is inside a polygon using ray casting algorithm.
    # Works for simple polygons (convex or concave, but not self-intersecting).
    #
    # @param polygon [Array<Array<Float>>] Array of [lat, lon] vertices
    # @param lat [Float] Test point latitude
    # @param lon [Float] Test point longitude
    # @return [Boolean] true if point is inside polygon
    def polygon_contains?(polygon, lat, lon)
      return false if polygon.nil? || polygon.length < 3

      inside = false
      j = polygon.length - 1

      polygon.each_with_index do |(xi, yi), i|
        xj, yj = polygon[j]

        # Ray casting: count edge crossings
        if ((yi > lat) != (yj > lat)) &&
           (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)
          inside = !inside
        end

        j = i
      end

      inside
    end

    # Find all hexes whose centers are within a polygon.
    # Useful for assigning terrain to regions.
    #
    # @param polygon [Array<Array<Float>>] Array of [lat, lon] vertices in degrees
    # @param grid [WorldGeneration::GlobeHexGrid] The hex grid
    # @return [Array<WorldGeneration::HexData>] Hexes inside the polygon
    def hexes_in_polygon(polygon, grid)
      return [] if polygon.nil? || polygon.length < 3 || grid.nil?

      grid.hexes.select do |hex|
        # Convert hex lat/lon from radians to degrees for comparison
        lat_deg = radians_to_degrees(hex.lat)
        lon_deg = radians_to_degrees(hex.lon)
        polygon_contains?(polygon, lat_deg, lon_deg)
      end
    end

    private

    # Calculate the great circle distance between two points on a sphere.
    # Uses the Haversine formula for accuracy.
    #
    # @param lat1 [Float] First point latitude in radians
    # @param lon1 [Float] First point longitude in radians
    # @param lat2 [Float] Second point latitude in radians
    # @param lon2 [Float] Second point longitude in radians
    # @return [Float] Angular distance in radians
    def spherical_distance(lat1, lon1, lat2, lon2)
      dlat = lat2 - lat1
      dlon = lon2 - lon1

      a = Math.sin(dlat / 2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dlon / 2)**2
      2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end

    # Interpolate points along a line segment.
    # Uses linear interpolation in lat/lon space (adequate for short segments).
    #
    # @param start_coord [Array<Float>] Start [lat, lon]
    # @param end_coord [Array<Float>] End [lat, lon]
    # @param num_samples [Integer] Number of points to generate
    # @return [Array<Array<Float>>] Interpolated points
    def interpolate_segment(start_coord, end_coord, num_samples)
      lat1, lon1 = start_coord
      lat2, lon2 = end_coord

      (0..num_samples).map do |i|
        t = i.to_f / num_samples
        lat = lat1 + t * (lat2 - lat1)
        lon = lon1 + t * (lon2 - lon1)
        [lat, lon]
      end
    end

    # Determine the direction from one hex to another.
    # Returns one of: 'n', 'ne', 'se', 's', 'sw', 'nw'
    #
    # @param from_hex [WorldGeneration::HexData] Origin hex
    # @param to_hex [WorldGeneration::HexData] Destination hex
    # @return [String] Direction name
    def direction_from(from_hex, to_hex)
      # Calculate bearing from one hex to another
      # Note: hex.lat and hex.lon are in radians
      dlat = to_hex.lat - from_hex.lat
      dlon = to_hex.lon - from_hex.lon

      # Convert to angle in degrees (0 = north, clockwise)
      angle = Math.atan2(dlon * Math.cos(from_hex.lat), dlat) * 180.0 / Math::PI
      angle += 360 if angle < 0

      # Map angle to hex direction
      # For flat-topped hexes: N=0, NE=60, SE=120, S=180, SW=240, NW=300
      case angle
      when 330..360, 0...30 then 'n'
      when 30...90 then 'ne'
      when 90...150 then 'se'
      when 150...210 then 's'
      when 210...270 then 'sw'
      when 270...330 then 'nw'
      else 'n'
      end
    end

    # Get the opposite direction.
    #
    # @param dir [String] Direction name
    # @return [String] Opposite direction
    def opposite_direction(dir)
      opposites = {
        'n' => 's',
        's' => 'n',
        'ne' => 'sw',
        'sw' => 'ne',
        'se' => 'nw',
        'nw' => 'se'
      }
      opposites[dir] || dir
    end
  end
end
