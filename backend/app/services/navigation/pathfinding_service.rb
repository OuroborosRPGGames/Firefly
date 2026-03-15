# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

class PathfindingService
  MAX_PATH_LENGTH = 50

  # Lightweight struct to represent a spatial exit (no RoomExit record)
  # Provides the same interface as RoomExit for pathfinding
  SpatialExit = Struct.new(:to_room, :direction, :from_room, keyword_init: true) do
    def can_pass?
      true
    end

    def locked?
      false
    end

    def lock_type
      nil
    end

    def visible
      true
    end

    def passable
      true
    end

    def opposite_direction
      CanvasHelper.opposite_direction(direction.to_s.downcase, fallback: 'somewhere')
    end
  end

  class << self
    def find_path(from_room, to_room, max_depth: MAX_PATH_LENGTH)
      return [] if from_room.nil? || to_room.nil?
      return [] if from_room.id == to_room.id

      bfs_find_path(from_room, to_room, max_depth)
    end

    def next_exit_toward(from_room, to_room)
      path = find_path(from_room, to_room)
      path.first
    end

    def distance_between(from_room, to_room)
      path = find_path(from_room, to_room)
      path.empty? ? nil : path.length
    end

    def reachable?(from_room, to_room)
      !find_path(from_room, to_room).empty?
    end

    # Find path to any room satisfying a condition.
    # @param from_room [Room] starting room
    # @param max_depth [Integer] maximum path length
    # @yield [Room] block that returns true for target rooms
    # @return [Array<RoomExit>] path of exits to first room satisfying condition
    def find_path_to_condition(from_room, max_depth: MAX_PATH_LENGTH)
      return [] if from_room.nil?
      return [] unless block_given?

      queue = [[from_room, []]]
      visited = Set.new([from_room.id])

      while queue.any?
        current_room, path = queue.shift
        next if path.length >= max_depth

        passable_exits(current_room).each do |room_exit|
          next_room = room_exit.to_room
          next unless next_room
          next if visited.include?(next_room.id)

          new_path = path + [room_exit]

          # Check if this room satisfies the condition
          return new_path if yield(next_room)

          visited.add(next_room.id)
          queue << [next_room, new_path]
        end
      end

      []
    end

    # Calculate street-only route between two outdoor rooms.
    # Used for taxi routes that stay on streets.
    # @param from_room [Room] starting outdoor room
    # @param to_room [Room] destination outdoor room
    # @return [Array<Room>] list of rooms along the route
    def street_route(from_room, to_room)
      return [] if from_room.nil? || to_room.nil?
      return [from_room] if from_room.id == to_room.id

      # Find path staying on streets as much as possible
      outdoor_types = RoomTypeConfig.tagged(:street) + %w[park plaza outdoor]

      queue = [[from_room, [from_room]]]
      visited = Set.new([from_room.id])

      while queue.any?
        current_room, path = queue.shift
        next if path.length > MAX_PATH_LENGTH

        # Sort exits to prefer outdoor rooms
        exits = passable_exits(current_room).sort_by do |ex|
          outdoor_types.include?(ex.to_room&.room_type&.downcase) ? 0 : 1
        end

        exits.each do |room_exit|
          next_room = room_exit.to_room
          next unless next_room
          next if visited.include?(next_room.id)

          new_path = path + [next_room]

          return new_path if next_room.id == to_room.id

          visited.add(next_room.id)
          queue << [next_room, new_path]
        end
      end

      []
    end

    private

    def bfs_find_path(from_room, to_room, max_depth)
      return [] if max_depth <= 0

      queue = [[from_room, []]]
      visited = Set.new([from_room.id])

      while queue.any?
        current_room, path = queue.shift

        # Skip if we've exceeded max depth
        next if path.length >= max_depth

        passable_exits(current_room).each do |room_exit|
          next_room = room_exit.to_room
          next unless next_room
          next if visited.include?(next_room.id)

          new_path = path + [room_exit]

          if next_room.id == to_room.id
            return new_path
          end

          visited.add(next_room.id)
          queue.push([next_room, new_path])
        end
      end

      []
    end

    def passable_exits(room)
      # Use spatial adjacency only - no explicit RoomExit records
      spatial_exits_for(room)
    end

    # Generate SpatialExit objects from RoomAdjacencyService
    # @param room [Room] the source room
    # @return [Array<SpatialExit>] virtual exits to adjacent rooms
    def spatial_exits_for(room)
      return [] unless room.location_id  # Only works for rooms with a location

      exits = []
      adjacent = RoomAdjacencyService.navigable_exits(room)

      adjacent.each do |direction, rooms|
        rooms.each do |adjacent_room|
          # Check passability via RoomPassabilityService if available
          next unless can_pass_spatially?(room, adjacent_room, direction)

          exits << SpatialExit.new(
            to_room: adjacent_room,
            direction: direction.to_s,
            from_room: room
          )
        end
      end

      exits
    end

    # Check if spatial passage is allowed between two rooms
    # @param from_room [Room] source room
    # @param to_room [Room] destination room
    # @param direction [Symbol] direction of travel
    # @return [Boolean]
    def can_pass_spatially?(from_room, to_room, direction)
      # Use RoomPassabilityService if defined
      if defined?(RoomPassabilityService)
        RoomPassabilityService.can_pass?(from_room, to_room, direction)
      else
        true
      end
    end
  end
end
