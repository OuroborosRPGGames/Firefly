# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

# Service for calculating room adjacency from polygon geometry.
# Replaces explicit RoomExit records with spatial calculations.
class RoomAdjacencyService
  ADJACENCY_TOLERANCE = 2.0  # feet - allows for builder imprecision
  DIRECTION_TOLERANCE = 5.0  # feet - for determining which side an edge is on

  class << self
    # =========================================================================
    # Cached public API — delegates through RoomExitCacheService
    # =========================================================================

    def navigable_exits(room)
      RoomExitCacheService.navigable_exits(room)
    end

    def adjacent_rooms(room)
      RoomExitCacheService.adjacent_rooms(room)
    end

    def contained_rooms(room)
      RoomExitCacheService.contained_rooms(room)
    end

    def containing_room(room)
      RoomExitCacheService.containing_room(room)
    end

    # =========================================================================
    # Compute methods — uncached implementations
    # =========================================================================

    # Extract edges from a polygon as pairs of points
    # @param polygon [Array<Hash>] array of {x:, y:} or {'x' =>, 'y' =>} points
    # @return [Array<Array<Hash>>] array of edges, each edge is [point1, point2]
    def edges_from_polygon(polygon)
      return [] if polygon.nil? || polygon.length < 3

      normalized = normalize_polygon(polygon)
      edges = []

      normalized.each_with_index do |point, i|
        next_point = normalized[(i + 1) % normalized.length]
        edges << [point, next_point]
      end

      edges
    end

    # Check if two edges overlap (are collinear and share some span)
    # @param edge_a [Array<Hash>] first edge as [point1, point2]
    # @param edge_b [Array<Hash>] second edge as [point1, point2]
    # @param tolerance [Float] maximum distance between edges to consider them collinear
    # @return [Boolean] true if edges overlap
    def edges_overlap?(edge_a, edge_b, tolerance: ADJACENCY_TOLERANCE)
      a1, a2 = normalize_edge(edge_a)
      b1, b2 = normalize_edge(edge_b)

      return false unless edges_collinear?(a1, a2, b1, b2, tolerance)
      edges_share_span?(a1, a2, b1, b2)
    end

    # Find all rooms adjacent to the given room, grouped by direction
    # @param room [Room] the source room
    # @return [Hash<Symbol, Array<Room>>] { north: [rooms], south: [rooms], ... }
    def compute_adjacent_rooms(room)
      result = Hash.new { |h, k| h[k] = [] }

      # Pre-filter: only rooms whose bounding boxes overlap or touch within tolerance
      t = ADJACENCY_TOLERANCE
      candidates = spatial_group_filter(
        Room.where(location_id: room.location_id)
            .exclude(id: room.id)
            .where { max_x >= room.min_x - t }
            .where { min_x <= room.max_x + t }
            .where { max_y >= room.min_y - t }
            .where { min_y <= room.max_y + t },
        room
      ).all

      room_polygon = room.shape_polygon
      room_edges = edges_from_polygon(room_polygon)

      candidates.each do |candidate|
        # Skip if one contains the other (but allow overlapping outdoor city rooms
        # like streets and intersections to be considered adjacent)
        is_overlapping_outdoor = false
        if room_contains?(room, candidate) || room_contains?(candidate, room)
          next unless room.outdoor_room? && candidate.outdoor_room?
          is_overlapping_outdoor = true
        end

        # For overlapping outdoor rooms (e.g., intersection within street),
        # add via center-to-center direction. Edge-based adjacency may miss
        # directions where the larger room extends beyond the smaller one.
        if is_overlapping_outdoor
          center_dir = direction_from_room_to_room(room, candidate)
          result[center_dir] << candidate unless result[center_dir].include?(candidate)
        end

        candidate_polygon = candidate.shape_polygon
        candidate_edges = edges_from_polygon(candidate_polygon)

        # Find shared edges
        room_edges.each do |room_edge|
          candidate_edges.each do |cand_edge|
            if edges_overlap?(room_edge, cand_edge)
              direction = direction_of_edge(room, room_edge)
              result[direction] << candidate unless result[direction].include?(candidate)
            end
          end
        end
      end

      result
    end

    # Check if outer room fully contains inner room
    # @param outer [Room] potential containing room
    # @param inner [Room] potential contained room
    # @return [Boolean]
    def room_contains?(outer, inner)
      # Use bounds-based containment with tolerance for shared boundaries
      # This handles the common case where interior rooms share exact edges
      # with their containing building
      tolerance = ADJACENCY_TOLERANCE

      # Inner room bounds must be within or equal to outer room bounds
      # (with tolerance for floating point comparison)
      inner.min_x.to_f >= outer.min_x.to_f - tolerance &&
        inner.max_x.to_f <= outer.max_x.to_f + tolerance &&
        inner.min_y.to_f >= outer.min_y.to_f - tolerance &&
        inner.max_y.to_f <= outer.max_y.to_f + tolerance &&
        # Inner must be strictly smaller in at least one dimension
        # (otherwise they're the same room, not contained)
        (inner.min_x.to_f > outer.min_x.to_f + tolerance ||
         inner.max_x.to_f < outer.max_x.to_f - tolerance ||
         inner.min_y.to_f > outer.min_y.to_f + tolerance ||
         inner.max_y.to_f < outer.max_y.to_f - tolerance)
    end

    # Find all rooms contained within the given room
    # @param room [Room] the outer room
    # @return [Array<Room>] rooms inside this one
    def compute_contained_rooms(room)
      # Pre-filter: only rooms whose bounds are within this room's bounds (+ tolerance)
      t = ADJACENCY_TOLERANCE
      spatial_group_filter(
        Room.where(location_id: room.location_id)
            .exclude(id: room.id)
            .where { min_x >= room.min_x - t }
            .where { max_x <= room.max_x + t }
            .where { min_y >= room.min_y - t }
            .where { max_y <= room.max_y + t },
        room
      ).all
       .select { |candidate| room_contains?(room, candidate) }
    end

    # Find the smallest room that contains the given room
    # @param room [Room] the inner room
    # @return [Room, nil] the containing room or nil
    def compute_containing_room(room)
      # Pre-filter: only rooms whose bounds enclose this room's bounds (+ tolerance)
      t = ADJACENCY_TOLERANCE
      spatial_group_filter(
        Room.where(location_id: room.location_id)
            .exclude(id: room.id)
            .where { min_x <= room.min_x + t }
            .where { max_x >= room.max_x - t }
            .where { min_y <= room.min_y + t }
            .where { max_y >= room.max_y - t },
        room
      ).all
       .reject { |candidate| sky_room?(candidate) }
       .select { |candidate| room_contains?(candidate, room) }
       .min_by { |r| PolygonClippingService.polygon_area(r.shape_polygon) }
    end

    # Find the most specific room to enter when moving into a room
    # Recursively descends through contained rooms to find the actual destination
    # @param room [Room] the target room
    # @param from_direction [Symbol, nil] direction we're coming from (to pick entry point)
    # @param max_depth [Integer] prevent infinite recursion
    # @return [Room] the most specific room to actually enter
    def resolve_entry_room(room, from_direction: nil, max_depth: 10)
      return room if max_depth <= 0

      # Find rooms contained within this one
      contained = compute_contained_rooms(room)
      return room if contained.empty?

      # Find the best entry room among contained rooms
      entry = find_entry_among_contained(room, contained, from_direction)
      return room unless entry

      # Recurse to find even more specific room
      resolve_entry_room(entry, from_direction: from_direction, max_depth: max_depth - 1)
    end

    # Find the best entry room among contained rooms
    # Priority: Entry Hall/Lobby > closest to entry direction > smallest room
    # @param container [Room] the containing room
    # @param contained [Array<Room>] rooms inside the container
    # @param from_direction [Symbol, nil] direction entering from
    # @return [Room, nil] best entry room or nil
    def find_entry_among_contained(container, contained, from_direction)
      # Priority 1: Look for explicitly named entry rooms
      entry_names = ['entry hall', 'lobby', 'foyer', 'entrance', 'reception']
      entry_room = contained.find do |r|
        room_suffix = r.name&.split(' - ')&.last&.downcase
        entry_names.any? { |name| room_suffix&.include?(name) }
      end
      return entry_room if entry_room

      # Priority 2: If coming from a direction, find room closest to that edge
      if from_direction
        opposite = opposite_direction(from_direction)
        edge_rooms = contained.select { |r| room_touches_edge?(r, container, opposite) }
        return edge_rooms.min_by { |r| polygon_area(r) } if edge_rooms.any?
      end

      # No clear entry point found — return nil so the container itself is used
      nil
    end

    # Check if a room touches a specific edge of its container
    # @param room [Room] the inner room
    # @param container [Room] the outer room
    # @param edge [Symbol] which edge (:north, :south, :east, :west)
    # @return [Boolean]
    def room_touches_edge?(room, container, edge)
      tolerance = ADJACENCY_TOLERANCE

      case edge
      when :north
        (room.max_y - container.max_y).abs < tolerance
      when :south
        (room.min_y - container.min_y).abs < tolerance
      when :east
        (room.max_x - container.max_x).abs < tolerance
      when :west
        (room.min_x - container.min_x).abs < tolerance
      else
        false
      end
    end

    # Get opposite direction
    # @param direction [Symbol]
    # @return [Symbol]
    def opposite_direction(direction)
      CanvasHelper.opposite_direction(direction.to_s.downcase).to_sym
    end

    # Calculate polygon area (simple bounding box for now)
    # @param room [Room]
    # @return [Float]
    def polygon_area(room)
      (room.max_x.to_f - room.min_x.to_f) * (room.max_y.to_f - room.min_y.to_f)
    end

    # Resolve movement in a cardinal direction
    # Priority: adjacent room > exit to containing room
    # @param from_room [Room] the room to move from
    # @param direction [Symbol, String] the direction to move (:north, :south, etc.)
    # @return [Room, nil] the destination room or nil if movement not possible
    def resolve_direction_movement(from_room, direction)
      direction = direction.to_sym

      # For up/down: use feature connections and vertical adjacency (not polygon adjacency)
      if direction == :up || direction == :down
        return resolve_vertical_movement(from_room, direction)
      end

      # 1. Check rooms in that direction
      # For outdoor rooms, prefer navigable_exits (center-to-center direction) to match
      # what the exits display shows. compute_adjacent_rooms uses edge-based direction
      # which can disagree for overlapping outdoor rooms (e.g., intersections).
      # Fall back to compute_adjacent_rooms for non-outdoor destinations (indoor rooms).
      if from_room.outdoor_room?
        nav_exits = compute_navigable_exits(from_room)[direction] || []
        nav_exits.each do |room|
          return room if RoomPassabilityService.can_pass?(from_room, room, direction)
        end
      end

      adjacent = compute_adjacent_rooms(from_room)[direction] || []
      adjacent.each do |room|
        if from_room.outdoor_room? && !room.outdoor_room?
          destination = if has_contained_rooms?(room) && !room_contains?(room, from_room)
                          resolve_entry_room(room, from_direction: direction)
                        else
                          room
                        end

          next unless building_entry_passable_from_direction?(from_room, room, destination, direction)

          return destination
        end

        return room if RoomPassabilityService.can_pass?(from_room, room, direction)
      end

      # 2. For "exit" direction, go to the containing room or nearest outdoor room
      #    (contained rooms don't need physical room features to exit)
      if direction == :exit
        container = compute_containing_room(from_room)
        return container if container

        # No container found - find the nearest adjacent outdoor room (street/avenue)
        # This handles buildings without a proper container room
        all_exits = compute_navigable_exits(from_room)
        nearest_outdoor = nil
        nearest_dist = Float::INFINITY
        all_exits.each do |_dir, rooms|
          rooms.each do |r|
            next unless r.outdoor_room?
            dist = distance_between(from_room, r)
            if dist < nearest_dist
              nearest_dist = dist
              nearest_outdoor = r
            end
          end
        end
        return nearest_outdoor if nearest_outdoor
      end

      # 3. Check exit to containing room via a physical opening in that direction
      if RoomPassabilityService.opening_in_direction?(from_room, direction)
        container = compute_containing_room(from_room)
        return container if container
      end

      nil
    end

    # Resolve vertical movement (up/down) using feature connections and vertical adjacency.
    # @param from_room [Room] the room to move from
    # @param direction [Symbol] :up or :down
    # @return [Room, nil] the destination room or nil
    def resolve_vertical_movement(from_room, direction)
      # 1. Check feature-connected exits (stairs, elevators, hatches)
      feature_exits = feature_connected_exits(from_room)
      targets = feature_exits[direction] || []
      return targets.first if targets.any?

      # 2. Check if this is a floor room (open pass-through)
      if from_room.room_type == 'floor'
        vertical_neighbor = find_vertical_neighbor(from_room, direction)
        return vertical_neighbor if vertical_neighbor
      end

      nil
    end

    # Find a vertically adjacent sibling room with the same XY footprint.
    # Used for floor rooms that act as open pass-throughs.
    # @param room [Room] the source room
    # @param direction [Symbol] :up or :down
    # @return [Room, nil] the vertically adjacent room or nil
    def find_vertical_neighbor(room, direction)
      return nil unless room.inside_room_id

      t = ADJACENCY_TOLERANCE
      siblings = Room.where(inside_room_id: room.inside_room_id)
                     .where(location_id: room.location_id)
                     .exclude(id: room.id)
                     .all

      siblings.select do |sibling|
        # Must overlap in XY
        x_overlap = sibling.max_x.to_f > room.min_x.to_f + t &&
                    sibling.min_x.to_f < room.max_x.to_f - t
        y_overlap = sibling.max_y.to_f > room.min_y.to_f + t &&
                    sibling.min_y.to_f < room.max_y.to_f - t
        next false unless x_overlap && y_overlap

        # Must be vertically adjacent
        if direction == :up
          (sibling.min_z.to_f - room.max_z.to_f).abs < t
        else # :down
          (room.min_z.to_f - sibling.max_z.to_f).abs < t
        end
      end.min_by { |s| direction == :up ? s.min_z.to_f : -s.max_z.to_f }
    end

    # Resolve movement by room name (for entering contained rooms or adjacent rooms)
    # @param from_room [Room] the room to move from
    # @param name [String] partial name to match (case-insensitive)
    # @return [Room, nil] the matching room or nil
    def resolve_named_movement(from_room, name)
      name_pattern = name.downcase

      # Check contained rooms first (priority)
      compute_contained_rooms(from_room).each do |room|
        return room if room.name.downcase.include?(name_pattern)
      end

      # Then check adjacent rooms
      compute_adjacent_rooms(from_room).values.flatten.uniq.each do |room|
        if room.name.downcase.include?(name_pattern)
          direction = direction_to_room(from_room, room)
          return room if direction && RoomPassabilityService.can_pass?(from_room, room, direction)
        end
      end

      nil
    end

    # Find the direction from one room to an adjacent room
    # Returns the direction with the most significant edge overlap
    # @param from_room [Room] the source room
    # @param to_room [Room] the destination room
    # @return [Symbol, nil] direction or nil if not adjacent
    def direction_to_room(from_room, to_room)
      # Find all directions where to_room appears
      matching_directions = []
      compute_adjacent_rooms(from_room).each do |direction, rooms|
        matching_directions << direction if rooms.include?(to_room)
      end

      return nil if matching_directions.empty?
      return matching_directions.first if matching_directions.length == 1

      # Multiple directions - find the one with most significant overlap
      # Calculate overlap length for each direction
      from_poly = from_room.shape_polygon
      to_poly = to_room.shape_polygon
      from_edges = edges_from_polygon(from_poly)
      to_edges = edges_from_polygon(to_poly)

      best_direction = nil
      best_overlap = 0

      matching_directions.each do |direction|
        from_edges.each do |from_edge|
          edge_dir = direction_of_edge(from_room, from_edge)
          next unless edge_dir == direction

          to_edges.each do |to_edge|
            next unless edges_overlap?(from_edge, to_edge)

            overlap = calculate_overlap_length(from_edge, to_edge)
            if overlap > best_overlap
              best_overlap = overlap
              best_direction = direction
            end
          end
        end
      end

      best_direction || matching_directions.first
    end

    # Calculate the overlap length between two edges
    # @param edge_a [Array<Hash>] first edge
    # @param edge_b [Array<Hash>] second edge
    # @return [Float] overlap length
    def calculate_overlap_length(edge_a, edge_b)
      a1, a2 = normalize_edge(edge_a)
      b1, b2 = normalize_edge(edge_b)

      # Determine which axis to project onto
      if (a2[:x] - a1[:x]).abs > (a2[:y] - a1[:y]).abs
        # Horizontal edge - project onto X
        a_min, a_max = [a1[:x], a2[:x]].minmax
        b_min, b_max = [b1[:x], b2[:x]].minmax
      else
        # Vertical edge - project onto Y
        a_min, a_max = [a1[:y], a2[:y]].minmax
        b_min, b_max = [b1[:y], b2[:y]].minmax
      end

      # Calculate overlap
      overlap_start = [a_min, b_min].max
      overlap_end = [a_max, b_max].min
      [overlap_end - overlap_start, 0].max
    end

    # Determine which direction an edge is relative to room center
    # @param room [Room] the room to check against
    # @param edge [Array<Hash>] edge as [point1, point2]
    # @return [Symbol] :north, :south, :east, :west, :northeast, :southeast, :northwest, :southwest
    def direction_of_edge(room, edge)
      center_x = (room.min_x.to_f + room.max_x.to_f) / 2.0
      center_y = (room.min_y.to_f + room.max_y.to_f) / 2.0

      edge_mid_x = (edge[0][:x] + edge[1][:x]) / 2.0
      edge_mid_y = (edge[0][:y] + edge[1][:y]) / 2.0

      dx = edge_mid_x - center_x
      dy = edge_mid_y - center_y

      if dx.abs > dy.abs
        dx > 0 ? :east : :west
      elsif dy.abs > dx.abs
        dy > 0 ? :north : :south
      else
        # Diagonal - equal displacement in both axes
        if dx > 0 && dy > 0
          :northeast
        elsif dx > 0 && dy < 0
          :southeast
        elsif dx < 0 && dy > 0
          :northwest
        else
          :southwest
        end
      end
    end

    # ============================================================================
    # EXIT FILTERING - Determines which adjacent rooms should be navigable exits
    # ============================================================================
    #
    # Navigation Rules:
    # - Outdoor → Outdoor: Line of sight + distance (not polygon adjacency)
    # - Outdoor → Building: Distance to entrance + line of sight to entrance
    # - Indoor → Indoor: Door/feature connections OR nesting-based logic
    # ============================================================================

    # Maximum distance (in feet) for exits between outdoor/street rooms
    MAX_OUTDOOR_EXIT_DISTANCE = 150.0

    # Maximum distance for building entrances visible from outdoor areas
    MAX_BUILDING_ENTRANCE_DISTANCE = 100.0

    # Room types that are building entrances (not interior rooms)
    BUILDING_ENTRANCE_TYPES = RoomTypeConfig.tagged(:building_entrance).freeze

    # Get filtered navigable exits from a room
    # Uses different logic for outdoor vs indoor rooms
    # @param room [Room] the source room
    # @return [Hash<Symbol, Array<Room>>] filtered exits by direction
    def compute_navigable_exits(room)
      # Clear cache for fresh calculation
      @contained_rooms_cache = {}

      if room.outdoor_room?
        outdoor_navigable_exits(room)
      else
        indoor_navigable_exits(room)
      end
    end

    # Get navigable exits for an outdoor room
    # Uses line of sight + distance instead of polygon adjacency
    # @param room [Room] the outdoor source room
    # @return [Hash<Symbol, Array<Room>>] exits by direction
    def outdoor_navigable_exits(room)
      result = Hash.new { |h, k| h[k] = [] }

      # Pre-filter: only rooms whose bounding boxes are within max exit distance.
      # Uses edge-to-edge distance (not center-to-center) so long rooms like
      # streets can still reach buildings along their length.
      max_dist = [MAX_OUTDOOR_EXIT_DISTANCE, MAX_BUILDING_ENTRANCE_DISTANCE].max
      t = max_dist + ADJACENCY_TOLERANCE
      candidates = spatial_group_filter(
        Room.where(location_id: room.location_id)
            .exclude(id: room.id)
            .where { min_x <= room.max_x + t }
            .where { max_x >= room.min_x - t }
            .where { min_y <= room.max_y + t }
            .where { max_y >= room.min_y - t },
        room
      ).all

      candidates.each do |candidate|
        next if sky_room?(candidate)

        direction = direction_from_room_to_room(room, candidate)

        if candidate.outdoor_room?
          # Outdoor → Outdoor: center distance + line of sight
          # Skip distance check for overlapping outdoor rooms (e.g., intersections within streets)
          center_dist = distance_between(room, candidate)
          overlaps = room_contains?(room, candidate) || room_contains?(candidate, room)
          next if !overlaps && center_dist > MAX_OUTDOOR_EXIT_DISTANCE
          next unless has_line_of_sight?(room, candidate)

          result[direction] << candidate
        elsif building_entrance?(candidate)
          # Outdoor → Building entrance: edge distance + line of sight.
          # Use edge distance so long streets can reach buildings along their length.
          edge_dist = edge_distance_between(room, candidate)
          next if edge_dist > MAX_BUILDING_ENTRANCE_DISTANCE
          next unless has_line_of_sight?(room, candidate)

          # Resolve to the actual entry room (lobby, etc.)
          actual_destination = resolve_entry_room(candidate, from_direction: direction)
          next unless building_entry_passable_from_direction?(room, candidate, actual_destination, direction)

          result[direction] << actual_destination unless result[direction].include?(actual_destination)
        end
        # Interior rooms (room - Hallway, etc.) not directly accessible from outdoor
      end

      # Also include overlapping outdoor rooms that the center-distance pre-filter missed
      add_overlapping_outdoor_exits(room, result)

      # Limit to nearest per direction per category
      limit_outdoor_exits(room, result)
    end

    # Check whether a building can be entered from an outdoor room in a given direction.
    # This prevents entering through non-door edges when the building boundary is walled.
    # @param source_room [Room] outdoor room we are moving from
    # @param building_room [Room] outer building room
    # @param entry_room [Room] resolved interior entry destination
    # @param movement_direction [Symbol] movement direction from source_room toward building_room
    # @return [Boolean]
    def building_entry_passable_from_direction?(source_room, building_room, entry_room, movement_direction)
      approach_edge = opposite_direction(movement_direction)

      # If entry resolution chose a contained room that touches the approached boundary,
      # honor that room's wall/door configuration first.
      if entry_room &&
         entry_room.id != building_room.id &&
         room_touches_edge?(entry_room, building_room, approach_edge)
        return RoomPassabilityService.can_pass?(entry_room, building_room, approach_edge)
      end

      # Otherwise, fall back to boundary features on the outer building room.
      RoomPassabilityService.can_pass?(building_room, source_room, approach_edge)
    end

    # Add overlapping outdoor rooms that the center-distance pre-filter may have missed.
    # For example, an intersection (25x25) within a street (525x25) — the center-to-center
    # distance can exceed MAX_OUTDOOR_EXIT_DISTANCE, but they share physical space.
    # @param room [Room] the outdoor source room
    # @param result [Hash] exits hash to add to (mutated in place)
    def add_overlapping_outdoor_exits(room, result)
      # Find outdoor rooms whose bounding boxes overlap with this room
      t = ADJACENCY_TOLERANCE
      overlapping = spatial_group_filter(
        Room.where(location_id: room.location_id)
            .exclude(id: room.id)
            .where { max_x >= room.min_x - t }
            .where { min_x <= room.max_x + t }
            .where { max_y >= room.min_y - t }
            .where { min_y <= room.max_y + t },
        room
      ).all
       .select { |c| c.outdoor_room? }

      overlapping.each do |candidate|
        next if sky_room?(candidate)

        direction = direction_from_room_to_room(room, candidate)
        result[direction] << candidate unless result[direction].include?(candidate)
      end
    end

    # Get navigable exits for an indoor room
    # Uses door/feature connections, polygon adjacency (for open walls), and nesting logic
    # @param room [Room] the indoor source room
    # @return [Hash<Symbol, Array<Room>>] exits by direction
    def indoor_navigable_exits(room)
      result = Hash.new { |h, k| h[k] = [] }

      # 1. Exits via door/feature connections (explicit connected_room_id)
      feature_exits = feature_connected_exits(room)
      feature_exits.each do |direction, rooms|
        result[direction].concat(rooms)
      end

      # 2. Exits via polygon adjacency where passage is allowed (no wall or has opening)
      polygon_exits = polygon_adjacent_exits(room)
      polygon_exits.each do |direction, rooms|
        rooms.each do |r|
          result[direction] << r unless result[direction].include?(r)
        end
      end

      # 3. Exits via nesting (entering contained rooms or exiting to container)
      nesting_exits = nesting_based_exits(room)
      nesting_exits.each do |direction, rooms|
        rooms.each do |r|
          result[direction] << r unless result[direction].include?(r)
        end
      end

      # 4. Vertical exits for floor rooms (open pass-through)
      if room.room_type == 'floor'
        %i[up down].each do |dir|
          neighbor = find_vertical_neighbor(room, dir)
          if neighbor && RoomPassabilityService.can_pass?(room, neighbor, dir)
            result[dir] << neighbor unless result[dir].include?(neighbor)
          end
        end
      end

      result
    end

    # Find exits through polygon adjacency where walls don't block passage
    # This handles open-plan rooms and adjacent rooms without explicit door features
    # @param room [Room] the source room
    # @return [Hash<Symbol, Array<Room>>] exits by direction
    def polygon_adjacent_exits(room)
      result = Hash.new { |h, k| h[k] = [] }

      # Get all rooms that share an edge with this room
      raw_adjacent = compute_adjacent_rooms(room)

      raw_adjacent.each do |direction, rooms|
        rooms.each do |candidate|
          next if sky_room?(candidate)

          # Check if passage is allowed via RoomPassabilityService
          # This checks for walls and openings
          next unless RoomPassabilityService.can_pass?(room, candidate, direction)

          # Don't show container rooms directly (resolve to entry room)
          if !candidate.outdoor_room? && has_contained_rooms?(candidate) && !room_contains?(candidate, room)
            # Resolve to the entry room
            actual_destination = resolve_entry_room(candidate, from_direction: direction)
            result[direction] << actual_destination unless result[direction].include?(actual_destination)
          else
            result[direction] << candidate unless result[direction].include?(candidate)
          end
        end
      end

      result
    end

    # Find exits through door/feature connections
    # @param room [Room] the source room
    # @return [Hash<Symbol, Array<Room>>] exits by direction
    def feature_connected_exits(room)
      result = Hash.new { |h, k| h[k] = [] }

      # Find all passable features in this room that connect to another room
      room.room_features.each do |feature|
        next unless feature.connected_room_id
        next unless passable_feature?(feature)

        connected_room = feature.connected_room
        next unless connected_room

        direction = feature.direction&.to_sym || direction_from_room_to_room(room, connected_room)
        result[direction] << connected_room unless result[direction].include?(connected_room)
      end

      # Also check features in other rooms that connect TO this room
      RoomFeature.where(connected_room_id: room.id).each do |feature|
        next unless passable_feature?(feature)

        source_room = feature.room
        next unless source_room

        # The direction to exit would be the opposite of the feature's direction
        direction = opposite_direction(feature.direction&.to_sym || direction_from_room_to_room(room, source_room))
        result[direction] << source_room unless result[direction].include?(source_room)
      end

      result
    end

    # Find exits based on room nesting (container/contained relationships)
    # @param room [Room] the source room
    # @return [Hash<Symbol, Array<Room>>] exits by direction
    def nesting_based_exits(room)
      result = Hash.new { |h, k| h[k] = [] }

      # Check if we can exit to our containing room
      container = compute_containing_room(room)
      if container
        # Can exit to container if there's a door/opening leading "outward"
        # or if there's no wall in that direction
        can_exit = false
        VALID_DIRECTIONS.each do |dir_str|
          direction = dir_str.to_sym
          if RoomPassabilityService.opening_in_direction?(room, direction) ||
             !RoomPassabilityService.wall_in_direction?(room, direction)
            can_exit = true
            break
          end
        end

        # Use "exit" as the direction label for container room exits
        # This is more intuitive than a cardinal direction when exiting a nested room
        if can_exit
          result[:exit] << container unless result[:exit].include?(container)
        end
      end

      # Check contained rooms - can we enter them?
      contained = compute_contained_rooms(room)
      contained.each do |child|
        # Can enter a contained room if:
        # - It has a door/opening facing us, OR
        # - It has no wall facing us (open plan)
        VALID_DIRECTIONS.each do |dir_str|
          direction = dir_str.to_sym
          if child_accessible_from_direction?(room, child, direction)
            result[direction] << child unless result[direction].include?(child)
          end
        end
      end

      result
    end

    # Check if a contained child room is accessible from a direction
    # @param parent [Room] the containing room
    # @param child [Room] the contained room
    # @param direction [Symbol] the direction from parent center
    # @return [Boolean]
    def child_accessible_from_direction?(parent, child, direction)
      # First check if child is actually in this direction from parent center
      return false unless direction_from_room_to_room(parent, child) == direction

      # Check if child has an opening facing the opposite direction (toward parent)
      opposite = opposite_direction(direction)

      # Child is accessible if it has an opening or no wall in the direction facing parent
      RoomPassabilityService.opening_in_direction?(child, opposite) ||
        !RoomPassabilityService.wall_in_direction?(child, opposite)
    end

    # Check if a direction from room leads toward another room
    # @param from_room [Room] source room
    # @param to_room [Room] target room
    # @param direction [Symbol] direction to check
    # @return [Boolean]
    def direction_leads_to_room?(from_room, to_room, direction)
      actual_direction = direction_from_room_to_room(from_room, to_room)
      actual_direction == direction || adjacent_directions(direction).include?(actual_direction)
    end

    # Get adjacent cardinal directions (for fuzzy matching)
    # @param direction [Symbol]
    # @return [Array<Symbol>]
    def adjacent_directions(direction)
      {
        north: %i[northeast northwest],
        south: %i[southeast southwest],
        east: %i[northeast southeast],
        west: %i[northwest southwest],
        northeast: %i[north east],
        northwest: %i[north west],
        southeast: %i[south east],
        southwest: %i[south west],
        up: [],
        down: []
      }[direction] || []
    end

    # Valid directions for iteration
    # Compass directions only (excludes up/down/exit/enter which are non-spatial)
    VALID_DIRECTIONS = (CanvasHelper::VALID_DIRECTIONS - %w[up down exit enter]).freeze

    # Check if a feature allows passage
    # @param feature [RoomFeature] the feature to check
    # @return [Boolean]
    def passable_feature?(feature)
      case feature.feature_type
      when 'wall', 'window'
        false
      when 'opening', 'archway', 'staircase', 'elevator'
        true
      when 'door', 'gate', 'hatch', 'portal'
        feature.open?
      else
        false
      end
    end

    # Check line of sight between two rooms (for outdoor navigation)
    # A room has line of sight to another if no buildings block the path
    # @param from_room [Room] source room
    # @param to_room [Room] destination room
    # @return [Boolean]
    def has_line_of_sight?(from_room, to_room)
      # Get centers
      from_center = room_center(from_room)
      to_center = room_center(to_room)

      # Pre-filter: only rooms whose bounding box overlaps the line's bounding box
      line_min_x = [from_center[:x], to_center[:x]].min
      line_max_x = [from_center[:x], to_center[:x]].max
      line_min_y = [from_center[:y], to_center[:y]].min
      line_max_y = [from_center[:y], to_center[:y]].max

      blockers = spatial_group_filter(
        Room.where(location_id: from_room.location_id)
            .exclude(id: [from_room.id, to_room.id])
            .where { max_x >= line_min_x }
            .where { min_x <= line_max_x }
            .where { max_y >= line_min_y }
            .where { min_y <= line_max_y },
        from_room
      ).all
       .select { |r| !r.outdoor_room? && has_contained_rooms?(r) }

      # Check if any blocker intersects the line between rooms
      blockers.none? { |blocker| room_blocks_line?(blocker, from_center, to_center) }
    end

    # Check if a room's bounding box blocks a line between two points
    # @param room [Room] potential blocking room
    # @param from_point [Hash] start point {x:, y:}
    # @param to_point [Hash] end point {x:, y:}
    # @return [Boolean]
    def room_blocks_line?(room, from_point, to_point)
      # Simple AABB line intersection test
      min_x = room.min_x.to_f
      max_x = room.max_x.to_f
      min_y = room.min_y.to_f
      max_y = room.max_y.to_f

      # Use parametric line clipping (Cohen-Sutherland simplified)
      line_intersects_aabb?(from_point[:x], from_point[:y],
                            to_point[:x], to_point[:y],
                            min_x, min_y, max_x, max_y)
    end

    # Check if a line segment intersects an axis-aligned bounding box
    # Uses Liang-Barsky algorithm
    # @return [Boolean]
    def line_intersects_aabb?(x1, y1, x2, y2, min_x, min_y, max_x, max_y)
      dx = x2 - x1
      dy = y2 - y1

      # Parameters for line clipping
      p = [-dx, dx, -dy, dy]
      q = [x1 - min_x, max_x - x1, y1 - min_y, max_y - y1]

      t0 = 0.0
      t1 = 1.0

      4.times do |i|
        if p[i] == 0
          # Line is parallel to this edge
          return false if q[i] < 0
        else
          t = q[i].to_f / p[i]
          if p[i] < 0
            t0 = [t0, t].max
          else
            t1 = [t1, t].min
          end
          return false if t0 > t1
        end
      end

      true
    end

    # Calculate direction from one room to another
    # @param from_room [Room] source room
    # @param to_room [Room] destination room
    # @return [Symbol] direction (:north, :south, etc.)
    def direction_from_room_to_room(from_room, to_room)
      from_center = room_center(from_room)
      to_center = room_center(to_room)

      dx = to_center[:x] - from_center[:x]
      dy = to_center[:y] - from_center[:y]

      # Use 22.5 degree sectors for 8 directions
      angle = Math.atan2(dy, dx) * 180 / Math::PI

      case angle
      when -22.5..22.5
        :east
      when 22.5..67.5
        :northeast
      when 67.5..112.5
        :north
      when 112.5..157.5
        :northwest
      when -67.5..-22.5
        :southeast
      when -112.5..-67.5
        :south
      when -157.5..-112.5
        :southwest
      else
        :west
      end
    end

    # Limit exits from outdoor rooms to nearest per direction per category
    # Categories: outdoor (streets/intersections), building entrances
    # @param room [Room] the source room
    # @param exits [Hash] exits by direction
    # @return [Hash] filtered exits
    def limit_outdoor_exits(room, exits)
      result = Hash.new { |h, k| h[k] = [] }

      exits.each do |direction, rooms|
        # Separate into categories
        outdoor_exits = rooms.select { |r| r.outdoor_room? }
        building_exits = rooms.select { |r| building_entrance?(r) || interior_room?(r) }
        other_exits = rooms - outdoor_exits - building_exits

        # Keep nearest outdoor room in this direction
        if outdoor_exits.any?
          nearest = outdoor_exits.min_by { |r| distance_between(room, r) }
          result[direction] << nearest
        end

        # Keep nearest building entrance in this direction
        if building_exits.any?
          nearest = building_exits.min_by { |r| distance_between(room, r) }
          result[direction] << nearest
        end

        # Keep all other exits (interior rooms, etc.)
        result[direction].concat(other_exits)
      end

      result
    end

    # Get all visible exits (for look commands - includes blocked exits)
    # @param room [Room] the source room
    # @return [Hash<Symbol, Array<Room>>] visible exits by direction
    def visible_exits(room)
      # Clear cache for fresh calculation
      @contained_rooms_cache = {}

      if room.outdoor_room?
        # Outdoor rooms: same as navigable_exits (use line of sight)
        outdoor_navigable_exits(room)
      else
        # Indoor rooms: use polygon adjacency without passability filter
        visible_indoor_exits(room)
      end
    end

    # Get all visible exits for indoor rooms (includes blocked exits like closed doors)
    # @param room [Room] the indoor source room
    # @return [Hash<Symbol, Array<Room>>] exits by direction
    def visible_indoor_exits(room)
      result = Hash.new { |h, k| h[k] = [] }

      # 1. Exits via door/feature connections (even if closed)
      room.room_features.each do |feature|
        next unless feature.connected_room_id
        next if feature.is_wall? # Walls don't provide exits
        next if feature.feature_type == 'window' # Windows don't provide exits

        connected_room = feature.connected_room
        next unless connected_room

        direction = feature.direction&.to_sym || direction_from_room_to_room(room, connected_room)
        result[direction] << connected_room unless result[direction].include?(connected_room)
      end

      # Also check features in other rooms that connect TO this room
      RoomFeature.where(connected_room_id: room.id).each do |feature|
        next if feature.is_wall?
        next if feature.feature_type == 'window'

        source_room = feature.room
        next unless source_room

        direction = opposite_direction(feature.direction&.to_sym || direction_from_room_to_room(room, source_room))
        result[direction] << source_room unless result[direction].include?(source_room)
      end

      # 2. Polygon adjacent rooms (check for walls/openings, but include closed doors)
      raw_adjacent = compute_adjacent_rooms(room)
      raw_adjacent.each do |direction, rooms|
        rooms.each do |candidate|
          next if sky_room?(candidate)

          # Check if there's any connection (wall with door, or no wall)
          has_wall = RoomPassabilityService.wall_in_direction?(room, direction)
          has_any_opening = room.room_features_dataset
                                .where(direction: direction.to_s)
                                .exclude(feature_type: 'wall')
                                .exclude(feature_type: 'window')
                                .any?

          # Include if: no wall, or has a door/opening (even if closed)
          next if has_wall && !has_any_opening

          # Resolve container rooms to entry rooms
          if !candidate.outdoor_room? && has_contained_rooms?(candidate) && !room_contains?(candidate, room)
            actual_destination = resolve_entry_room(candidate, from_direction: direction)
            result[direction] << actual_destination unless result[direction].include?(actual_destination)
          else
            result[direction] << candidate unless result[direction].include?(candidate)
          end
        end
      end

      # 3. Nesting exits (entering contained rooms or exiting to container)
      nesting_exits = nesting_based_exits(room)
      nesting_exits.each do |direction, rooms|
        rooms.each do |r|
          result[direction] << r unless result[direction].include?(r)
        end
      end

      result
    end

    # Check if movement from source to target should be a navigable exit
    # Check if a room has any rooms contained within it
    # @param room [Room]
    # @return [Boolean]
    def has_contained_rooms?(room)
      # Cache this check to avoid repeated queries
      @contained_rooms_cache ||= {}
      return @contained_rooms_cache[room.id] if @contained_rooms_cache.key?(room.id)

      @contained_rooms_cache[room.id] = compute_contained_rooms(room).any?
    end

    # Check if a room is a "sky" or aerial room (shouldn't have normal exits)
    # @param room [Room] the room to check
    # @return [Boolean]
    def sky_room?(room)
      return true if room.name&.downcase&.include?('sky above')
      return true if room.room_type == 'sky'

      false
    end

    # Check if a room is a building entrance (not an interior room)
    # @param room [Room] the room to check
    # @return [Boolean]
    def building_entrance?(room)
      # Has city_role 'building' but no ' - ' in name
      return true if room.city_role == 'building' && !room.name&.include?(' - ')

      # Or has entrance room type
      BUILDING_ENTRANCE_TYPES.include?(room.room_type) && !room.name&.include?(' - ')
    end

    # Check if a room is an interior room (inside a building, not entrance)
    # @param room [Room] the room to check
    # @return [Boolean]
    def interior_room?(room)
      # Has ' - ' in name indicating it's a sub-room of a building
      return true if room.name&.include?(' - ')

      # Or city_role is building but not an outdoor type
      room.city_role == 'building' && !room.outdoor_room? && !building_entrance?(room)
    end

    # Check if two rooms are in the same building (by name prefix)
    # @param room_a [Room]
    # @param room_b [Room]
    # @return [Boolean]
    def same_building?(room_a, room_b)
      prefix_a = building_prefix(room_a)
      prefix_b = building_prefix(room_b)

      return false if prefix_a.nil? || prefix_b.nil?

      prefix_a == prefix_b
    end

    # Get the building prefix for a room (name before ' - ')
    # @param room [Room]
    # @return [String, nil]
    def building_prefix(room)
      return nil if room.name.nil?

      # If name contains ' - ', the prefix is the building name
      if room.name.include?(' - ')
        room.name.split(' - ').first
      elsif room.city_role == 'building'
        # It's a building entrance, the whole name is the prefix
        room.name
      else
        nil
      end
    end

    # Find the entrance room for an interior room
    # @param room [Room] an interior room
    # @return [Room, nil] the building entrance room
    def building_entrance_for(room)
      prefix = building_prefix(room)
      return nil unless prefix

      # Find the room with just the prefix name (no ' - ')
      spatial_group_filter(
        Room.where(location_id: room.location_id, name: prefix),
        room
      ).first
    end

    # Calculate center-to-center distance between two rooms
    # @param room_a [Room]
    # @param room_b [Room]
    # @return [Float] distance in feet
    def distance_between(room_a, room_b)
      center_a = room_center(room_a)
      center_b = room_center(room_b)

      Math.sqrt((center_b[:x] - center_a[:x])**2 + (center_b[:y] - center_a[:y])**2)
    end

    # Minimum distance between the edges of two rooms' bounding boxes.
    # Returns 0 if the bounding boxes overlap or touch.
    # More accurate than center-to-center for long/narrow rooms (e.g., streets).
    def edge_distance_between(room_a, room_b)
      dx = [room_a.min_x.to_f - room_b.max_x.to_f, room_b.min_x.to_f - room_a.max_x.to_f, 0.0].max
      dy = [room_a.min_y.to_f - room_b.max_y.to_f, room_b.min_y.to_f - room_a.max_y.to_f, 0.0].max
      Math.sqrt(dx * dx + dy * dy)
    end

    # Get the center point of a room
    # @param room [Room]
    # @return [Hash] { x:, y: }
    def room_center(room)
      {
        x: (room.min_x.to_f + room.max_x.to_f) / 2.0,
        y: (room.min_y.to_f + room.max_y.to_f) / 2.0
      }
    end

    private

    # Apply spatial group isolation to a room candidate query.
    # - NULL group rooms only see other NULL group rooms
    # - Non-null group rooms only see rooms in the same group
    # - Available pool rooms are always excluded
    def spatial_group_filter(dataset, room)
      ds = dataset.exclude(pool_status: 'available')
      if room.spatial_group_id.nil?
        ds.where(spatial_group_id: nil)
      else
        ds.where(spatial_group_id: room.spatial_group_id)
      end
    end

    # Normalize polygon to consistent format with symbol keys and float values
    # @param polygon [Array<Hash>] array of points
    # @return [Array<Hash>] normalized array with {x: Float, y: Float}
    def normalize_polygon(polygon)
      polygon.map do |p|
        { x: (p['x'] || p[:x]).to_f, y: (p['y'] || p[:y]).to_f }
      end
    end

    # Normalize edge points to consistent format
    # @param edge [Array<Hash>] edge as [point1, point2]
    # @return [Array<Hash>] normalized edge
    def normalize_edge(edge)
      [
        { x: (edge[0]['x'] || edge[0][:x]).to_f, y: (edge[0]['y'] || edge[0][:y]).to_f },
        { x: (edge[1]['x'] || edge[1][:x]).to_f, y: (edge[1]['y'] || edge[1][:y]).to_f }
      ]
    end

    # Check if two edges are collinear (on the same infinite line within tolerance)
    # @param a1 [Hash] first point of edge A
    # @param a2 [Hash] second point of edge A
    # @param b1 [Hash] first point of edge B
    # @param b2 [Hash] second point of edge B
    # @param tolerance [Float] maximum distance from line to be considered collinear
    # @return [Boolean]
    def edges_collinear?(a1, a2, b1, b2, tolerance)
      # Check that both points of edge B are within tolerance of line defined by edge A
      dist1 = point_to_line_distance(b1, a1, a2)
      dist2 = point_to_line_distance(b2, a1, a2)
      dist1 <= tolerance && dist2 <= tolerance
    end

    # Calculate perpendicular distance from a point to a line defined by two points
    # Uses the cross product formula for distance
    # @param point [Hash] the point to measure from
    # @param line_start [Hash] first point defining the line
    # @param line_end [Hash] second point defining the line
    # @return [Float] perpendicular distance
    def point_to_line_distance(point, line_start, line_end)
      dx = line_end[:x] - line_start[:x]
      dy = line_end[:y] - line_start[:y]
      length_sq = dx * dx + dy * dy

      # If the line is essentially a point, return distance to that point
      if length_sq < 0.0001
        return Math.sqrt((point[:x] - line_start[:x])**2 + (point[:y] - line_start[:y])**2)
      end

      # Cross product gives parallelogram area; divide by base length for height (distance)
      cross = (point[:x] - line_start[:x]) * dy - (point[:y] - line_start[:y]) * dx
      cross.abs / Math.sqrt(length_sq)
    end

    # Minimum overlap length (in feet) for edges to be considered adjacent
    # Prevents corner-touching from being treated as adjacent
    MIN_EDGE_OVERLAP = 1.0

    # Check if two collinear edges share any portion of their span
    # Projects both edges onto their dominant axis (X for horizontal, Y for vertical)
    # @param a1 [Hash] first point of edge A
    # @param a2 [Hash] second point of edge A
    # @param b1 [Hash] first point of edge B
    # @param b2 [Hash] second point of edge B
    # @return [Boolean]
    def edges_share_span?(a1, a2, b1, b2)
      # Determine which axis to project onto based on edge orientation
      # Use the axis with greater variation (more horizontal = use X, more vertical = use Y)
      if (a2[:x] - a1[:x]).abs > (a2[:y] - a1[:y]).abs
        # Project onto X axis (horizontal or mostly horizontal)
        a_min, a_max = [a1[:x], a2[:x]].minmax
        b_min, b_max = [b1[:x], b2[:x]].minmax
      else
        # Project onto Y axis (vertical or mostly vertical)
        a_min, a_max = [a1[:y], a2[:y]].minmax
        b_min, b_max = [b1[:y], b2[:y]].minmax
      end

      # Calculate actual overlap length
      overlap_start = [a_min, b_min].max
      overlap_end = [a_max, b_max].min
      overlap_length = overlap_end - overlap_start

      # Require minimum overlap to prevent corner-touching from being treated as adjacent
      overlap_length >= MIN_EDGE_OVERLAP
    end
  end
end
