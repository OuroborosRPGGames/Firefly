# frozen_string_literal: true

# BuildingNavigationService handles building hierarchy detection and navigation.
# Used to find paths in/out of buildings for smart navigation.
#
# Based on Ravencroft patterns:
# - find_outer_building(room) - Finds outermost building container
# - fetch_leaving_room() - Finds exit to street
class BuildingNavigationService
  class << self
    # Find the outermost building container for a room.
    # Follows the inside_room chain up until we find an outdoor room or reach the top.
    # @param room [Room] the starting room
    # @return [Room, nil] the outermost building room, or nil if already outdoor
    def find_outer_building(room)
      return nil if room.nil?
      return nil if room.outdoor_room?

      # Start with current room
      current = room
      outer = room

      # Walk up the containment chain
      while current.inside_room
        parent = current.inside_room
        break if parent.outdoor_room?

        outer = parent
        current = parent
      end

      outer
    end

    # Find the room that connects a building to the street.
    # This is the room with a passable exit that leads to an outdoor area.
    # @param room [Room] the starting room (can be any room in the building)
    # @param max_depth [Integer] maximum BFS depth to prevent runaway traversals
    # @return [Room, nil] the room with outdoor access, or the room itself if outdoor
    def find_building_exit(room, max_depth: 50)
      return room if room.nil?
      return room if room.outdoor_room?

      # BFS to find the first room with a passable exit to outdoors
      visited = Set.new([room.id])
      queue = [[room, 0]]

      while queue.any?
        current, depth = queue.shift
        next if depth >= max_depth

        # Check if any spatial exit leads to an outdoor room
        current.passable_spatial_exits.each do |exit|
          target = exit[:room]
          next unless target

          return current if target.outdoor_room?

          unless visited.include?(target.id)
            visited.add(target.id)
            queue << [target, depth + 1]
          end
        end
      end

      # No exit found, return original room
      room
    end

    # Find the nearest outdoor (street) room that can access a target room.
    # @param room [Room] the target room
    # @param max_depth [Integer] maximum BFS depth to prevent runaway traversals
    # @return [Room, nil] the nearest street room
    def find_nearest_street(room, max_depth: 50)
      return room if room.nil?
      return room if room.outdoor_room?

      # BFS from target outward to find the first outdoor room
      visited = Set.new([room.id])
      queue = [[room, 0]]

      while queue.any?
        current, depth = queue.shift

        # Check if this room is outdoor
        return current if current.outdoor_room?

        next if depth >= max_depth

        # Check all connected rooms (exits and entries)
        connected_rooms(current).each do |connected|
          next if visited.include?(connected.id)

          visited.add(connected.id)
          queue << [connected, depth + 1]
        end
      end

      nil
    end

    # Find a path from an indoor room to the nearest outdoor room.
    # Returns an array of RoomExits to follow.
    # @param from_room [Room] starting indoor room
    # @return [Array<RoomExit>] path of exits to outdoor, empty if already outdoor
    def path_to_street(from_room)
      return [] if from_room.nil?
      return [] if from_room.outdoor_room?

      find_path_to_condition(from_room) { |room| room.outdoor_room? }
    end

    # Find a path from a street to the inside of a building.
    # @param street_room [Room] the outdoor starting point
    # @param target_room [Room] the indoor destination
    # @return [Array<RoomExit>] path from street to target
    def path_into_building(street_room, target_room)
      return [] if street_room.nil? || target_room.nil?
      return [] if street_room.id == target_room.id

      PathfindingService.find_path(street_room, target_room, max_depth: 20)
    end

    # Check if a room is indoors (not outdoor).
    # @param room [Room]
    # @return [Boolean]
    def indoor_room?(room)
      !room.outdoor_room?
    end

    # Check if a room is outdoors.
    # @param room [Room]
    # @return [Boolean]
    def outdoor_room?(room)
      room.outdoor_room?
    end

    # Find a path from one room to any room satisfying a condition.
    # @param from_room [Room] starting room
    # @param condition [Proc] block that returns true for target rooms
    # @return [Array<Hash>] path of spatial exits, empty if not found
    def find_path_to_condition(from_room, max_depth: 30, &condition)
      return [] if from_room.nil?
      return [] unless block_given?

      queue = [[from_room, []]]
      visited = Set.new([from_room.id])

      while queue.any?
        current_room, path = queue.shift
        next if path.length >= max_depth

        current_room.passable_spatial_exits.each do |exit|
          next_room = exit[:room]
          next unless next_room
          next if visited.include?(next_room.id)

          new_path = path + [exit]

          # Check if this room satisfies the condition
          return new_path if condition.call(next_room)

          visited.add(next_room.id)
          queue << [next_room, new_path]
        end
      end

      []
    end

    # Check if two rooms are in the same building (share common outer building)
    # @param room1 [Room]
    # @param room2 [Room]
    # @return [Boolean]
    def same_building?(room1, room2)
      return false if room1.nil? || room2.nil?

      # Both outdoor = same "building" (the street)
      return true if room1.outdoor_room? && room2.outdoor_room?

      # Find outer buildings
      outer1 = find_outer_building(room1) || room1
      outer2 = find_outer_building(room2) || room2

      outer1.id == outer2.id
    end

    # Get the building name for a room (the outer container's name)
    # @param room [Room] the room
    # @return [String, nil] the building name
    def building_name(room)
      return nil if room.nil?
      return nil if room.outdoor_room?

      outer = find_outer_building(room)
      outer&.name
    end

    private

    def connected_rooms(room)
      rooms = []

      # Rooms reachable via spatial adjacency
      room.spatial_exits.each do |_direction, adjacent_rooms|
        rooms.concat(adjacent_rooms)
      end

      # Parent room (containing room)
      container = RoomAdjacencyService.containing_room(room)
      rooms << container if container

      # Child rooms (contained within this room)
      rooms.concat(RoomAdjacencyService.contained_rooms(room))

      rooms.uniq
    end
  end
end
