# frozen_string_literal: true

# Computes Voronoi polygon boundaries for world hex centers.
#
# Each hex on the globe is surrounded by neighbors. The Voronoi cell for a hex
# is the polygon containing all points closer to that hex's center than to any
# neighbor. We compute this by intersecting half-planes (perpendicular bisectors)
# using the Sutherland-Hodgman clipping algorithm on a local tangent-plane
# projection.
class WorldHexBoundaryService
    DEG_TO_RAD = Math::PI / 180.0
    RAD_TO_DEG = 180.0 / Math::PI

    # Bounding square half-width in radians on the tangent plane.
    # Must be larger than the max Voronoi vertex distance from center.
    # At subdivision 5 (~10K hexes), hex spacing is ~220km → boundary ~130km → ~0.02 rad.
    # At subdivision 10 (~10M hexes), hex spacing is ~7km → boundary ~4km → ~0.0006 rad.
    # Use 0.1 rad (~637km) to safely cover all subdivision levels.
    BOUND = 0.1

    class << self
      # Compute Voronoi boundary polygon for a single hex.
      #
      # @param center [Hash] { lat:, lon: } in degrees
      # @param neighbors [Array<Hash>] [{ lat:, lon: }, ...] in degrees (6-7 entries)
      # @return [Array<Array(Float, Float)>] polygon vertices [[lat, lon], ...] in degrees
      def compute_boundary(center, neighbors)
        return [] if neighbors.nil? || neighbors.size < 3

        # Convert center to radians
        c_lat = center[:lat] * DEG_TO_RAD
        c_lon = center[:lon] * DEG_TO_RAD
        cos_clat = Math.cos(c_lat)

        # Build half-planes from perpendicular bisectors
        half_planes = neighbors.map do |nb|
          n_lat = nb[:lat] * DEG_TO_RAD
          n_lon = nb[:lon] * DEG_TO_RAD

          # Project neighbor to local tangent plane centered on center
          dlon = n_lon - c_lon
          # Antimeridian normalization
          dlon -= 2 * Math::PI if dlon > Math::PI
          dlon += 2 * Math::PI if dlon < -Math::PI

          nx = dlon * Math.cos(c_lat)
          ny = n_lat - c_lat

          # Midpoint between origin (center) and neighbor projection
          mx = nx * 0.5
          my = ny * 0.5

          # Half-plane: normal points away from neighbor, origin is inside
          # normal = (-mx, -my) simplified: test nx*(x-mx) + ny*(y-my) >= 0
          # where (nx, ny) here is the normal direction = (-mx, -my)
          { nx: -mx, ny: -my, mx: mx, my: my }
        end

        # Start with bounding square
        polygon = [
          [-BOUND, -BOUND],
          [BOUND, -BOUND],
          [BOUND, BOUND],
          [-BOUND, BOUND]
        ]

        # Clip by each half-plane
        half_planes.each do |hp|
          polygon = clip_polygon_by_half_plane(polygon, hp)
          return [] if polygon.size < 3
        end

        return [] if polygon.size < 3

        return [] if polygon.size < 3

        return [] if polygon.size < 3

        # Project back to lat/lon degrees
        cos_c_lat = Math.cos(c_lat)
        polygon.map do |x, y|
          lat_deg = (c_lat + y) * RAD_TO_DEG
          lon_deg = if cos_c_lat.abs < 1e-12
                      center[:lon] # At poles, longitude is degenerate
                    else
                      (c_lon + x / cos_c_lat) * RAD_TO_DEG
                    end
          [lat_deg, lon_deg]
        end
      end

      # Batch compute neighbor IDs for all hexes in a world using GlobeHexGrid.
      #
      # @param world [World] the world record
      # @param traversable_only [Boolean] only process traversable hexes
      # @param face_range [Range] icosahedral face range (default 0..19)
      # @param on_progress [Proc, nil] called with (face_index, total_faces)
      def compute_neighbors_for_world(world, traversable_only: false, face_range: 0..19, on_progress: nil)
        total_faces = face_range.size

        face_range.each_with_index do |face, idx|
          on_progress&.call(idx, total_faces)

          # Build grid for just this face (with neighbors from adjacent faces)
          grid = WorldGeneration::GlobeHexGrid.new(
            world,
            subdivisions: world.respond_to?(:subdivisions) ? world.subdivisions : 5,
            face_range: face..face
          )

          batch = []

          grid.each_hex do |hex|
            neighbor_ids = grid.neighbors_of(hex).map(&:id)
            next if neighbor_ids.empty?

            batch << { globe_hex_id: hex.id, neighbor_ids: neighbor_ids }

            if batch.size >= 5000
              flush_neighbor_batch(world, batch, traversable_only)
              batch = []
            end
          end

          flush_neighbor_batch(world, batch, traversable_only) unless batch.empty?
        end

        on_progress&.call(total_faces, total_faces)
      end

      # Batch compute boundary vertices for hexes that have neighbors but no boundaries.
      #
      # @param world [World] the world record
      # @param traversable_only [Boolean] only process traversable hexes
      # @param batch_size [Integer] number of hexes per DB write batch
      # @param on_progress [Proc, nil] called with (processed_count, total_count)
      def compute_boundaries_for_world(world, traversable_only: false, batch_size: 1000, on_progress: nil)
        base = WorldHex.where(world_id: world.id)
                       .exclude(neighbor_globe_hex_ids: nil)
                       .where(boundary_vertices: nil)
        base = base.where(traversable: true) if traversable_only

        processed = 0
        last_id = 0

        loop do
          # Manual keyset pagination — no cursors, no long transactions
          hexes = base.where { id > last_id }
                      .select(:id, :globe_hex_id, :latitude, :longitude, :neighbor_globe_hex_ids)
                      .order(:id)
                      .limit(5000)
                      .all

          break if hexes.empty?
          last_id = hexes.last.id

          # Bulk-fetch all neighbor coordinates for this page
          all_neighbor_ids = hexes.flat_map { |h| h.neighbor_globe_hex_ids }.uniq
          neighbor_coords = {}
          WorldHex.where(world_id: world.id, globe_hex_id: all_neighbor_ids)
                  .select(:globe_hex_id, :latitude, :longitude)
                  .each do |row|
            neighbor_coords[row.globe_hex_id] = [row.latitude.to_f, row.longitude.to_f]
          end

          updates = []
          hexes.each do |hex|
            nids = hex.neighbor_globe_hex_ids
            next if nids.nil? || nids.empty?

            neighbors = nids.filter_map do |nid|
              coords = neighbor_coords[nid]
              next unless coords
              { lat: coords[0], lon: coords[1] }
            end
            next if neighbors.size < 3

            center = { lat: hex.latitude.to_f, lon: hex.longitude.to_f }
            vertices = compute_boundary(center, neighbors)
            next if vertices.empty?

            rounded = vertices.map { |lat, lon| [lat.round(6), lon.round(6)] }
            updates << { id: hex.id, vertices: rounded }
          end

          flush_boundary_batch(updates) unless updates.empty?
          processed += hexes.size
          on_progress&.call(processed, 0)
        end

        processed
      end

      private

      # Sutherland-Hodgman polygon clipping against a single half-plane.
      #
      # @param polygon [Array<Array(Float, Float)>] vertices as [x, y]
      # @param hp [Hash] half-plane { nx:, ny:, mx:, my: }
      # @return [Array<Array(Float, Float)>] clipped polygon
      def clip_polygon_by_half_plane(polygon, hp)
        return [] if polygon.empty?

        output = []
        n = polygon.length
        n.times do |i|
          current = polygon[i]
          nxt = polygon[(i + 1) % n]
          d_current = hp[:nx] * (current[0] - hp[:mx]) + hp[:ny] * (current[1] - hp[:my])
          d_next = hp[:nx] * (nxt[0] - hp[:mx]) + hp[:ny] * (nxt[1] - hp[:my])

          if d_current >= 0
            output << current
            if d_next < 0
              output << intersect_edge(current, nxt, hp)
            end
          elsif d_next >= 0
            output << intersect_edge(current, nxt, hp)
          end
        end
        output
      end

      # Compute intersection of edge p1->p2 with half-plane boundary.
      def intersect_edge(p1, p2, hp)
        d1 = hp[:nx] * (p1[0] - hp[:mx]) + hp[:ny] * (p1[1] - hp[:my])
        d2 = hp[:nx] * (p2[0] - hp[:mx]) + hp[:ny] * (p2[1] - hp[:my])
        t = d1 / (d1 - d2)
        [p1[0] + t * (p2[0] - p1[0]), p1[1] + t * (p2[1] - p1[1])]
      end

      # Write neighbor IDs to DB in a transaction.
      def flush_neighbor_batch(world, batch, traversable_only)
        DB.transaction do
          batch.each do |item|
            ds = WorldHex.where(world_id: world.id, globe_hex_id: item[:globe_hex_id])
                         .where(neighbor_globe_hex_ids: nil)
            ds = ds.where(traversable: true) if traversable_only

            pg_array = Sequel.pg_array(item[:neighbor_ids], :integer)
            ds.update(neighbor_globe_hex_ids: pg_array)
          end
        end
      end

      # Write boundary vertices to DB in a transaction.
      def flush_boundary_batch(batch)
        DB.transaction do
          batch.each do |item|
            WorldHex.where(id: item[:id])
                    .update(boundary_vertices: Sequel.pg_jsonb_wrap(item[:vertices]))
          end
        end
      end
    end
  end


