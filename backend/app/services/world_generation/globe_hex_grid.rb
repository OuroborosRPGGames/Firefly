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
  # 4. Use unique subdivision VERTICES as hex centers (not triangle centroids)
  #    This produces 10 * 4^N + 2 hexes with natural 6-way adjacency (5 at 12 pentagons)
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   grid.each_hex { |hex| puts "#{hex.lat}, #{hex.lon}" }
  #
  class GlobeHexGrid
    # Golden ratio for icosahedron geometry
    PHI = (1.0 + Math.sqrt(5.0)) / 2.0

    attr_reader :world, :subdivisions, :hexes, :triangle_data, :neighbors_cache

    # Initialize a new globe hex grid.
    #
    # @param world [World] The world object this grid belongs to
    # @param subdivisions [Integer] Number of recursive subdivisions (default: 5)
    #   Hex count = 10 * 4^n + 2 (unique vertices of subdivided icosahedron)
    #   - 0 subdivisions = 12 hexes (icosahedron vertices)
    #   - 1 subdivision = 42 hexes
    #   - 2 subdivisions = 162 hexes
    #   - 3 subdivisions = 642 hexes
    #   - 5 subdivisions = 10,242 hexes (default)
    #   - 10 subdivisions = 10,485,762 hexes
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

    # Export triangle mesh data for a specific icosahedral face.
    # Each triangle maps to 3 vertex hex IDs (since hexes are at vertices).
    #
    # @param face_index [Integer] Icosahedral face index (0-19)
    # @param include_border [Boolean] Include triangles from neighboring faces
    # @return [Hash] { vertices: [[x,y,z],...], triangle_indices: [[i0,i1,i2],...], triangle_vertex_ids: [[id0,id1,id2],...] }
    def triangle_mesh_for_face(face_index, include_border: false)
      face_triangles = @triangle_data.select { |t| t[:face_index] == face_index }

      if include_border
        face_vertex_ids = Set.new(face_triangles.flat_map { |t| t[:vertex_ids] })
        border_triangles = @triangle_data.select do |t|
          t[:face_index] != face_index && t[:vertex_ids].any? { |vid| face_vertex_ids.include?(vid) }
        end
        face_triangles = face_triangles + border_triangles
      end

      # Build shared vertex buffer
      vertex_index_map = {}
      vertices = []
      triangle_indices = []
      triangle_vertex_ids = []

      face_triangles.each do |tri|
        indices = tri[:vertex_ids].map do |vid|
          unless vertex_index_map.key?(vid)
            hex = @hex_by_id[vid]
            vertex_index_map[vid] = vertices.length
            vertices << [hex.x, hex.y, hex.z] if hex
          end
          vertex_index_map[vid]
        end
        triangle_indices << indices
        triangle_vertex_ids << tri[:vertex_ids]
      end

      {
        vertices: vertices,
        triangle_indices: triangle_indices,
        triangle_vertex_ids: triangle_vertex_ids
      }
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

    # Generate the icosahedral grid using vertex-based hex placement.
    # For large grids (subdivisions >= 8), shells out to a Python/NumPy script
    # for memory efficiency. For small grids, uses inline Ruby.
    def generate_grid
      @triangle_data = []

      if @subdivisions >= 8 && !@face_range
        generate_grid_via_python
      else
        generate_grid_inline
      end
    end

    # Generate grid by calling Python script (memory-efficient for large grids).
    # Python generates vertices + edges as a binary file, Ruby reads it.
    def generate_grid_via_python
      require 'tempfile'

      script_path = File.expand_path('../../../scripts/generate_icosahedral_grid.py', __dir__)
      tmpfile = Tempfile.new(['grid', '.bin'])
      tmpfile.close

      @on_progress&.call(:subdivide, 0.0)

      # Run Python grid generator
      result = system('python3', script_path, @subdivisions.to_s, tmpfile.path)
      unless result
        warn "[GlobeHexGrid] Python grid generator failed, falling back to inline Ruby"
        return generate_grid_inline
      end

      @on_progress&.call(:subdivide, 0.7)

      # Read binary output
      File.open(tmpfile.path, 'rb') do |f|
        vertex_count, edge_count = f.read(8).unpack('V2')

        @hexes = Array.new(vertex_count)
        vertex_count.times do |i|
          face_index, lat, lon = f.read(20).unpack('Vd2') # uint32 + 2x float64

          x = Math.cos(lat) * Math.cos(lon)
          y = Math.cos(lat) * Math.sin(lon)
          z = Math.sin(lat)

          hex = HexData.new(
            id: @start_hex_id + i, x: x, y: y, z: z,
            lat: lat, lon: lon, face_index: face_index,
            plate_id: nil, elevation: nil, temperature: nil,
            moisture: nil, terrain_type: nil, river_directions: Set.new
          )
          @hexes[i] = hex
          @hex_by_id[hex.id] = hex
        end

        @on_progress&.call(:neighbors, 0.0)

        unless @skip_neighbors
          edge_count.times do
            id_a, id_b = f.read(8).unpack('V2')
            a = @start_hex_id + id_a
            b = @start_hex_id + id_b
            (@neighbors_cache[a] ||= []) << b
            (@neighbors_cache[b] ||= []) << a
          end
        end

        @hexes.each { |hex| @neighbors_cache[hex.id] ||= [] }
        @on_progress&.call(:neighbors, 1.0)
      end
    ensure
      tmpfile&.unlink
    end

    # Generate grid inline in Ruby (for small grids or face_range batches).
    def generate_grid_inline
      faces_to_process = @face_range || (0..19)

      @vertex_map = {}
      @edge_set = Set.new
      @global_hex_id = @start_hex_id

      all_faces = icosahedron_faces
      total_faces = faces_to_process.size
      faces_to_process.each_with_index do |face_index, i|
        face_vertices, _ = all_faces[face_index]
        subdivide_and_collect_vertices(face_vertices[0], face_vertices[1], face_vertices[2], @subdivisions, face_index)
        @on_progress&.call(:subdivide, (i + 1).to_f / total_faces)
      end

      @hexes = Array.new(@vertex_map.size)
      idx = 0
      @vertex_map.each_value do |entry|
        x, y, z = entry[:coords]
        lat = Math.asin(z.clamp(-1.0, 1.0))
        lon = Math.atan2(y, x)

        hex = HexData.new(
          id: entry[:id], x: x, y: y, z: z,
          lat: lat, lon: lon, face_index: entry[:face_index],
          plate_id: nil, elevation: nil, temperature: nil,
          moisture: nil, terrain_type: nil, river_directions: Set.new
        )
        @hexes[idx] = hex
        @hex_by_id[hex.id] = hex
        idx += 1
      end

      @on_progress&.call(:neighbors, 0.0)
      unless @skip_neighbors
        @edge_set.each do |id_a, id_b|
          (@neighbors_cache[id_a] ||= []) << id_b
          (@neighbors_cache[id_b] ||= []) << id_a
        end
      end
      @hexes.each { |hex| @neighbors_cache[hex.id] ||= [] }
      @on_progress&.call(:neighbors, 1.0)

      @vertex_map = nil
      @edge_set = nil
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

    # Recursive subdivision that collects unique vertices and mesh edges.
    # At leaf level (depth=0), registers 3 triangle vertices and 3 edges.
    # Vertex deduplication uses rounded coordinates as hash keys.
    def subdivide_and_collect_vertices(v0, v1, v2, depth, face_index)
      if depth == 0
        # Register each vertex (deduplicated across faces)
        id0 = register_vertex(v0, face_index)
        id1 = register_vertex(v1, face_index)
        id2 = register_vertex(v2, face_index)

        # Record mesh edges (for neighbor adjacency)
        register_edge(id0, id1)
        register_edge(id1, id2)
        register_edge(id0, id2)

        # Store triangle for mesh export
        @triangle_data << { face_index: face_index, vertex_ids: [id0, id1, id2] }
        return
      end

      # Calculate midpoints and normalize to sphere
      m01 = normalize_midpoint(v0, v1)
      m12 = normalize_midpoint(v1, v2)
      m20 = normalize_midpoint(v2, v0)

      # Recurse into 4 sub-triangles
      next_depth = depth - 1
      subdivide_and_collect_vertices(v0, m01, m20, next_depth, face_index)
      subdivide_and_collect_vertices(m01, v1, m12, next_depth, face_index)
      subdivide_and_collect_vertices(m20, m12, v2, next_depth, face_index)
      subdivide_and_collect_vertices(m01, m12, m20, next_depth, face_index)
    end

    # Register a vertex in the deduplication map. Returns the vertex's hex ID.
    def register_vertex(v, face_index)
      key = [v[0].round(10), v[1].round(10), v[2].round(10)]
      unless @vertex_map.key?(key)
        id = @global_hex_id
        @global_hex_id += 1
        @vertex_map[key] = { id: id, coords: v, face_index: face_index }
      end
      @vertex_map[key][:id]
    end

    # Register a mesh edge between two vertex IDs (canonical order).
    def register_edge(id_a, id_b)
      edge = id_a < id_b ? [id_a, id_b] : [id_b, id_a]
      @edge_set.add(edge)
    end

    # Compute midpoint of two vertices, normalized to unit sphere.
    def normalize_midpoint(v0, v1)
      mx = (v0[0] + v1[0]) * 0.5
      my = (v0[1] + v1[1]) * 0.5
      mz = (v0[2] + v1[2]) * 0.5
      len = Math.sqrt(mx * mx + my * my + mz * mz)
      inv_len = 1.0 / len
      [mx * inv_len, my * inv_len, mz * inv_len]
    end
  end
end
