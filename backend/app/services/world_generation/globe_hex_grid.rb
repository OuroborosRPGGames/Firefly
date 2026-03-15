# frozen_string_literal: true

require 'set'

module WorldGeneration
  # Represents a single hex on the globe with 3D coordinates and generation data.
  # Used during world generation to hold intermediate values before persisting to WorldHex.
  HexData = Struct.new(
    :id,           # Unique identifier
    :x, :y, :z,    # 3D coordinates on unit sphere
    :lat, :lon,    # Latitude/longitude in radians
    :face_index,   # Icosahedral face (0-19)
    :plate_id,     # Tectonic plate assignment
    :elevation,    # Normalized elevation (-1.0 to 1.0)
    :temperature,  # Normalized temperature (0.0 to 1.0)
    :moisture,     # Normalized moisture (0.0 to 1.0)
    :terrain_type, # Terrain classification string
    :river_directions, # Set of directions for river flow (e.g., Set['n', 'se'])
    :river_width,  # River width: 1=stream, 2=river, 3=major river
    keyword_init: true
  ) do
    # Radians to degrees conversion constant (memoized at class level)
    RAD_TO_DEG = 180.0 / Math::PI

    # Check if this hex is ocean (below sea level)
    def ocean?
      elevation.nil? ? false : elevation < 0.0
    end

    # Check if this hex is land (at or above sea level)
    def land?
      !ocean?
    end

    # Get latitude in degrees (memoized to avoid repeated conversion).
    #
    # @return [Float] Latitude in degrees
    def lat_deg
      @lat_deg ||= lat * RAD_TO_DEG
    end

    # Get longitude in degrees (memoized to avoid repeated conversion).
    #
    # @return [Float] Longitude in degrees
    def lon_deg
      @lon_deg ||= lon * RAD_TO_DEG
    end

    # Clear memoized values (call after modifying lat/lon)
    def clear_memo!
      @lat_deg = nil
      @lon_deg = nil
    end
  end

  # In-memory icosahedral hex grid for procedural world generation.
  # Generates hexes on a sphere using recursive icosahedron subdivision.
  #
  # Algorithm:
  # 1. Start with an icosahedron (12 vertices, 20 triangular faces)
  # 2. Subdivide each face N times (each subdivision creates 4 sub-triangles)
  # 3. Project all vertices to unit sphere
  # 4. Use face centroids as hex centers
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   grid.each_hex { |hex| puts "#{hex.lat}, #{hex.lon}" }
  #
  class GlobeHexGrid
    # Golden ratio for icosahedron geometry
    PHI = (1.0 + Math.sqrt(5.0)) / 2.0

    attr_reader :world, :subdivisions, :hexes

    # Initialize a new globe hex grid.
    #
    # @param world [World] The world object this grid belongs to
    # @param subdivisions [Integer] Number of recursive subdivisions (default: 5)
    #   - 0 subdivisions = 20 hexes (icosahedron faces)
    #   - 1 subdivision = 80 hexes
    #   - 2 subdivisions = 320 hexes
    #   - 3 subdivisions = 1,280 hexes
    #   - 4 subdivisions = 5,120 hexes
    #   - 5 subdivisions = 20,480 hexes (default)
    #   - Each subdivision multiplies hex count by 4: 20 * 4^n
    # @param skip_neighbors [Boolean] Skip building neighbor cache (faster for Earth import)
    # @param face_range [Range, nil] Only generate hexes for specific faces (0-19)
    #   Use this for batched processing to reduce memory usage.
    #   Example: face_range: 0..4 generates only the first 5 faces
    # @param start_hex_id [Integer] Starting hex ID for batched processing
    def initialize(world, subdivisions: 5, skip_neighbors: false, face_range: nil, start_hex_id: 0, on_progress: nil)
      @world = world
      @subdivisions = subdivisions
      @skip_neighbors = skip_neighbors
      @face_range = face_range
      @start_hex_id = start_hex_id
      @on_progress = on_progress
      @hexes = []
      @hex_by_id = {}
      @neighbors_cache = {}

      generate_grid
    end

    # Returns total number of hexes in the grid.
    #
    # @return [Integer]
    def hex_count
      @hexes.size
    end

    # Iterate over all hexes.
    #
    # @yield [HexData] Each hex in the grid
    def each_hex(&block)
      @hexes.each(&block)
    end

    # Look up a hex by its ID.
    #
    # @param id [Integer] Hex identifier
    # @return [HexData, nil]
    def hex_by_id(id)
      @hex_by_id[id]
    end

    # Get neighbors of a hex (approximately 6, may be 5 at icosahedron vertices).
    # Uses cached adjacency computed during grid generation.
    #
    # @param hex [HexData] The hex to find neighbors for
    # @return [Array<HexData>]
    def neighbors_of(hex)
      neighbor_ids = @neighbors_cache[hex.id] || []
      neighbor_ids.map { |id| @hex_by_id[id] }.compact
    end

    # Find the nearest hex to a given latitude/longitude.
    #
    # @param lat [Float] Latitude in radians
    # @param lon [Float] Longitude in radians
    # @return [HexData, nil]
    def hex_at_latlon(lat, lon)
      # Convert lat/lon to 3D coordinates
      target_x = Math.cos(lat) * Math.cos(lon)
      target_y = Math.cos(lat) * Math.sin(lon)
      target_z = Math.sin(lat)

      # Find nearest hex by dot product (smaller angle = larger dot product)
      best_hex = nil
      best_dot = -2.0

      @hexes.each do |hex|
        dot = target_x * hex.x + target_y * hex.y + target_z * hex.z
        if dot > best_dot
          best_dot = dot
          best_hex = hex
        end
      end

      best_hex
    end

    # Get latitude of a hex in radians.
    #
    # @param hex [HexData]
    # @return [Float]
    def latitude_of(hex)
      hex.lat
    end

    # Get longitude of a hex in radians.
    #
    # @param hex [HexData]
    # @return [Float]
    def longitude_of(hex)
      hex.lon
    end

    # Convert grid to WorldHex database records for bulk insert.
    #
    # Globe hexes use globe_hex_id as their unique identifier.
    # No flat-grid coordinates (hex_x/hex_y) or icosahedral coords (ico_*) are stored.
    #
    # @return [Array<Hash>] Array of hashes suitable for WorldHex.multi_insert
    def to_db_records
      @hexes.map do |hex|
        # Convert lat/lon from radians to degrees
        lat_deg = hex.lat * 180.0 / Math::PI
        lon_deg = hex.lon * 180.0 / Math::PI

        # Initialize all feature columns to nil (required for multi_insert to work
        # properly - it only inserts columns present in ALL records)
        record = {
          world_id: @world.id,
          # Globe hex unique identifier - this is what makes each hex unique
          globe_hex_id: hex.id,
          terrain_type: hex.terrain_type || WorldHex::DEFAULT_TERRAIN,
          # Database column is 'altitude', scale normalized elevation to integer meters
          altitude: ((hex.elevation || 0.0) * 1000).to_i,
          # Climate data from simulation
          temperature: hex.temperature,
          moisture: hex.moisture,
          # Geographic coordinates for lookups and rendering
          latitude: lat_deg,
          longitude: lon_deg,
          # Directional feature columns (rivers, roads, etc.)
          # Must be present in all records for multi_insert to work
          feature_n: nil,
          feature_ne: nil,
          feature_se: nil,
          feature_s: nil,
          feature_sw: nil,
          feature_nw: nil
        }

        # Convert river_directions Set to feature columns
        # e.g., Set['n', 'se'] becomes feature_n: 'river', feature_se: 'river'
        if hex.river_directions&.any?
          hex.river_directions.each do |dir|
            feature_key = :"feature_#{dir}"
            record[feature_key] = 'river'
          end
        end

        # Add river width if set (1=stream, 2=river, 3=major)
        record[:river_width] = hex.river_width if hex.river_width

        record
      end
    end

    private

    # Generate the icosahedral grid
    def generate_grid
      hexes_per_face = 4**@subdivisions

      # Determine which faces to process
      faces_to_process = @face_range || (0..19)
      face_count = faces_to_process.size

      # Pre-calculate expected hex count for array pre-allocation
      expected_count = face_count * hexes_per_face
      @hexes = Array.new(expected_count)
      @hex_index = 0
      @global_hex_id = @start_hex_id

      # Create icosahedron vertices (normalized to unit sphere)
      vertices = icosahedron_vertices

      # Create 20 triangular faces and process selected ones recursively
      all_faces = icosahedron_faces
      total_faces = faces_to_process.size
      faces_to_process.each_with_index do |face_index, i|
        face_vertices, _ = all_faces[face_index]
        subdivide_and_create_hex(face_vertices[0], face_vertices[1], face_vertices[2], @subdivisions, face_index)
        # Report subdivision progress (0-70% of grid building)
        @on_progress&.call(:subdivide, (i + 1).to_f / total_faces)
      end

      # Trim array if needed and build lookup hash
      @hexes = @hexes[0...@hex_index] if @hex_index < expected_count
      @hexes.each { |hex| @hex_by_id[hex.id] = hex }

      # Build neighbor relationships (skip for Earth import which doesn't need them)
      @on_progress&.call(:neighbors, 0.0)
      build_neighbor_cache unless @skip_neighbors
      @on_progress&.call(:neighbors, 1.0)
    end

    # Generate the 12 vertices of an icosahedron on a unit sphere.
    # Uses golden ratio for proper vertex placement.
    #
    # @return [Array<Array<Float>>] Array of [x, y, z] coordinates
    def icosahedron_vertices
      # Normalize factor for unit sphere
      norm = Math.sqrt(1.0 + PHI * PHI)

      [
        # Top and bottom poles
        [0, 1, PHI].map { |c| c / norm },
        [0, -1, PHI].map { |c| c / norm },
        [0, 1, -PHI].map { |c| c / norm },
        [0, -1, -PHI].map { |c| c / norm },
        # Middle ring (rotated rectangles)
        [1, PHI, 0].map { |c| c / norm },
        [-1, PHI, 0].map { |c| c / norm },
        [1, -PHI, 0].map { |c| c / norm },
        [-1, -PHI, 0].map { |c| c / norm },
        # Other vertices
        [PHI, 0, 1].map { |c| c / norm },
        [-PHI, 0, 1].map { |c| c / norm },
        [PHI, 0, -1].map { |c| c / norm },
        [-PHI, 0, -1].map { |c| c / norm }
      ]
    end

    # Define the 20 triangular faces of an icosahedron.
    # Each face is defined by 3 vertex indices.
    #
    # @return [Array<Array>] Array of [[v0, v1, v2], face_index]
    def icosahedron_faces
      vertices = icosahedron_vertices

      # Face indices (counterclockwise winding)
      face_indices = [
        # 5 faces around top vertex (0)
        [0, 8, 1], [0, 1, 9], [0, 9, 5], [0, 5, 4], [0, 4, 8],
        # 5 adjacent faces
        [1, 8, 6], [9, 1, 7], [5, 9, 11], [4, 5, 2], [8, 4, 10],
        # 5 faces around bottom vertex (3)
        [3, 6, 7], [3, 7, 11], [3, 11, 2], [3, 2, 10], [3, 10, 6],
        # 5 adjacent faces
        [6, 8, 10], [7, 6, 1], [11, 7, 9], [2, 11, 5], [10, 2, 4]
      ]

      face_indices.each_with_index.map do |indices, face_index|
        [indices.map { |i| vertices[i] }, face_index]
      end
    end

    # Recursive subdivision that creates hexes directly at leaf nodes.
    # Avoids storing intermediate triangles by processing immediately at depth 0.
    #
    # @param v0, v1, v2 [Array<Float>] Three vertices [x,y,z]
    # @param depth [Integer] Remaining subdivision levels
    # @param face_index [Integer] Original face index (0-19)
    def subdivide_and_create_hex(v0, v1, v2, depth, face_index)
      if depth == 0
        # Leaf node - create hex from triangle centroid
        cx = (v0[0] + v1[0] + v2[0]) / 3.0
        cy = (v0[1] + v1[1] + v2[1]) / 3.0
        cz = (v0[2] + v1[2] + v2[2]) / 3.0

        # Normalize to unit sphere
        len = Math.sqrt(cx * cx + cy * cy + cz * cz)
        if len < 1e-10
          x, y, z = 0.0, 0.0, 1.0
        else
          inv_len = 1.0 / len
          x, y, z = cx * inv_len, cy * inv_len, cz * inv_len
        end

        # Convert to lat/lon (in radians)
        lat = Math.asin(z.clamp(-1.0, 1.0))
        lon = Math.atan2(y, x)

        # Create hex directly into pre-allocated array
        # Use Set for river_directions for O(1) lookup and automatic uniqueness
        # Use @global_hex_id for consistent IDs across batched processing
        @hexes[@hex_index] = HexData.new(
          id: @global_hex_id,
          x: x,
          y: y,
          z: z,
          lat: lat,
          lon: lon,
          face_index: face_index,
          plate_id: nil,
          elevation: nil,
          temperature: nil,
          moisture: nil,
          terrain_type: nil,
          river_directions: Set.new
        )
        @hex_index += 1
        @global_hex_id += 1
        return
      end

      # Calculate midpoints and normalize to sphere
      m01x = (v0[0] + v1[0]) * 0.5
      m01y = (v0[1] + v1[1]) * 0.5
      m01z = (v0[2] + v1[2]) * 0.5
      len = Math.sqrt(m01x * m01x + m01y * m01y + m01z * m01z)
      inv_len = 1.0 / len
      m01 = [m01x * inv_len, m01y * inv_len, m01z * inv_len]

      m12x = (v1[0] + v2[0]) * 0.5
      m12y = (v1[1] + v2[1]) * 0.5
      m12z = (v1[2] + v2[2]) * 0.5
      len = Math.sqrt(m12x * m12x + m12y * m12y + m12z * m12z)
      inv_len = 1.0 / len
      m12 = [m12x * inv_len, m12y * inv_len, m12z * inv_len]

      m20x = (v2[0] + v0[0]) * 0.5
      m20y = (v2[1] + v0[1]) * 0.5
      m20z = (v2[2] + v0[2]) * 0.5
      len = Math.sqrt(m20x * m20x + m20y * m20y + m20z * m20z)
      inv_len = 1.0 / len
      m20 = [m20x * inv_len, m20y * inv_len, m20z * inv_len]

      # Recurse into 4 sub-triangles
      next_depth = depth - 1
      subdivide_and_create_hex(v0, m01, m20, next_depth, face_index)
      subdivide_and_create_hex(m01, v1, m12, next_depth, face_index)
      subdivide_and_create_hex(m20, m12, v2, next_depth, face_index)
      subdivide_and_create_hex(m01, m12, m20, next_depth, face_index)
    end

    # Build neighbor cache using 2D lat/lon grid with 9-cell lookup.
    # Cell size is based on neighbor distance, ensuring each cell lookup
    # returns only immediate neighbor candidates.
    def build_neighbor_cache
      return if @hexes.empty?
      return build_neighbor_cache_simple if @hexes.size <= 500

      # Calculate neighbor distance threshold
      hex_count_theoretical = 20 * (4**@subdivisions)
      approx_hex_area = 4.0 * Math::PI / hex_count_theoretical
      approx_hex_radius = Math.sqrt(approx_hex_area / Math::PI)
      neighbor_angle = approx_hex_radius * 3.0
      threshold_dot = Math.cos(neighbor_angle)

      # Cell size = neighbor_angle so that 3x3 cells cover the neighbor radius
      # This ensures each hex only checks hexes that could possibly be neighbors
      lat_cell_size = neighbor_angle
      lon_cell_size = neighbor_angle

      num_lat_cells = (Math::PI / lat_cell_size).ceil
      num_lon_cells = (2.0 * Math::PI / lon_cell_size).ceil

      # Build 2D grid: cells[lat_idx][lon_idx] = [hex1, hex2, ...]
      cells = Array.new(num_lat_cells) { Array.new(num_lon_cells) { [] } }

      @hexes.each do |hex|
        lat_idx = ((hex.lat + Math::PI / 2) / lat_cell_size).floor
        lat_idx = lat_idx.clamp(0, num_lat_cells - 1)
        lon_idx = ((hex.lon + Math::PI) / lon_cell_size).floor
        lon_idx = lon_idx.clamp(0, num_lon_cells - 1)
        cells[lat_idx][lon_idx] << hex
      end

      # For each hex, check cells around it
      # Near poles, expand longitude search to compensate for convergence
      @hexes.each do |hex|
        hx, hy, hz = hex.x, hex.y, hex.z
        hex_id = hex.id

        lat_idx = ((hex.lat + Math::PI / 2) / lat_cell_size).floor.clamp(0, num_lat_cells - 1)
        lon_idx = ((hex.lon + Math::PI) / lon_cell_size).floor.clamp(0, num_lon_cells - 1)

        # Calculate longitude expansion factor based on latitude
        # At poles, 1 degree of longitude covers much less distance
        # cos(lat) gives the scaling factor (0 at poles, 1 at equator)
        cos_lat = Math.cos(hex.lat).abs
        lon_expand = cos_lat < 0.1 ? 5 : (cos_lat < 0.3 ? 3 : 1)

        neighbors = []

        # Check neighborhood of cells (expanded at poles)
        (-1..1).each do |dlat|
          next_lat = lat_idx + dlat
          next if next_lat < 0 || next_lat >= num_lat_cells

          (-lon_expand..lon_expand).each do |dlon|
            next_lon = (lon_idx + dlon) % num_lon_cells

            cells[next_lat][next_lon].each do |other|
              next if other.id == hex_id
              dot = hx * other.x + hy * other.y + hz * other.z
              neighbors << [other.id, dot] if dot > threshold_dot
            end
          end
        end

        # Sort and take top 7
        if neighbors.size > 7
          neighbors.sort_by! { |_, d| -d }
          @neighbors_cache[hex_id] = neighbors[0, 7].map!(&:first)
        else
          @neighbors_cache[hex_id] = neighbors.map(&:first)
        end
      end
    end

    # Simple O(n^2) neighbor cache for small grids (<= 500 hexes).
    def build_neighbor_cache_simple
      return if @hexes.empty?

      hex_count_theoretical = 20 * (4**@subdivisions)
      approx_hex_area = 4.0 * Math::PI / hex_count_theoretical
      approx_hex_radius = Math.sqrt(approx_hex_area / Math::PI)
      threshold_dot = Math.cos(approx_hex_radius * 3.0)

      @hexes.each do |hex|
        hx, hy, hz = hex.x, hex.y, hex.z
        hex_id = hex.id
        neighbors = []

        @hexes.each do |other|
          next if other.id == hex_id
          dot = hx * other.x + hy * other.y + hz * other.z
          neighbors << [other.id, dot] if dot > threshold_dot
        end

        if neighbors.size > 7
          neighbors.sort_by! { |_, d| -d }
          @neighbors_cache[hex_id] = neighbors[0, 7].map!(&:first)
        else
          @neighbors_cache[hex_id] = neighbors.map(&:first)
        end
      end
    end
  end
end
