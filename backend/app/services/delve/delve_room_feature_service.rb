# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

# Wires RoomFeature records (walls and doors) onto a real Room based on
# delve grid connectivity. Handles wall placement, door positioning,
# and open/closed states for trapped passages.
class DelveRoomFeatureService
  # Door positions relative to room bounds (center of each wall)
  DOOR_POSITIONS = {
    'north' => ->(room) { { x: midpoint(room.min_x, room.max_x), y: room.max_y.to_f } },
    'south' => ->(room) { { x: midpoint(room.min_x, room.max_x), y: room.min_y.to_f } },
    'east'  => ->(room) { { x: room.max_x.to_f, y: midpoint(room.min_y, room.max_y) } },
    'west'  => ->(room) { { x: room.min_x.to_f, y: midpoint(room.min_y, room.max_y) } }
  }.freeze

  # Cardinal directions only (delve grids use 4 directions, not 8)
  CARDINAL_DIRECTIONS = CanvasHelper::VALID_DIRECTIONS.select { |d| %w[north south east west].include?(d) }.freeze

  class << self
    # Wire wall and door features onto a room based on delve connectivity.
    #
    # Every cardinal direction gets a wall. Directions with adjacent rooms get
    # a door (open by default). Blocked directions get a closed door.
    # Directions with no adjacent room get only a wall.
    #
    # @param room [Room] the room to wire features onto
    # @param open_directions [Array<String>] directions with passable adjacent rooms
    # @param blocked_directions [Hash<String, Symbol>] directions blocked by traps/etc
    #   e.g., { 'south' => :trap, 'east' => :blocker }
    def wire_features!(room, open_directions:, blocked_directions:)
      # Clear any existing features for this room
      RoomFeature.where(room_id: room.id).delete

      CARDINAL_DIRECTIONS.each do |direction|
        # Every direction gets a wall
        create_wall(room, direction)

        if open_directions.include?(direction)
          # Open passage - create an open door
          create_door(room, direction, open: true)
        elsif blocked_directions.key?(direction)
          # Blocked passage (trap, etc.) - create a closed door
          create_door(room, direction, open: false)
        end
        # No adjacent room = wall only, no door
      end
    end

    # Open a closed door in a given direction.
    #
    # @param room [Room] the room containing the door
    # @param direction [String] the direction of the door to open
    def open_door!(room, direction)
      door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: direction)
      return unless door

      door.update(open_state: 'open')
      RoomExitCacheService.invalidate_door_state!(room.id) if defined?(RoomExitCacheService)
      if defined?(RoomExitCacheService) && door.connected_room_id
        RoomExitCacheService.invalidate_door_state!(door.connected_room_id)
      end
    end

    private

    # Create a wall feature in a given direction.
    #
    # @param room [Room] the room
    # @param direction [String] cardinal direction
    def create_wall(room, direction)
      RoomFeature.create(
        room_id: room.id,
        feature_type: 'wall',
        name: "#{direction.capitalize} Wall",
        direction: direction,
        x: 0.0,
        y: 0.0,
        z: 0.0,
        open_state: 'closed',
        allows_sight: false,
        allows_movement: false
      )
    end

    # Create a door feature in a given direction.
    #
    # @param room [Room] the room
    # @param direction [String] cardinal direction
    # @param open [Boolean] whether the door starts open
    def create_door(room, direction, open:)
      pos = door_position(room, direction)

      RoomFeature.create(
        room_id: room.id,
        feature_type: 'door',
        name: "#{direction.capitalize} Door",
        direction: direction,
        x: pos[:x],
        y: pos[:y],
        z: 0.0,
        open_state: open ? 'open' : 'closed',
        allows_sight: true,
        allows_movement: true
      )
    end

    # Calculate door position for a given direction.
    #
    # @param room [Room] the room
    # @param direction [String] cardinal direction
    # @return [Hash] { x:, y: } coordinates
    def door_position(room, direction)
      calculator = DOOR_POSITIONS[direction]
      return { x: 0.0, y: 0.0 } unless calculator

      calculator.call(room)
    end

    # Calculate midpoint between two values.
    #
    # @param min_val [Numeric] minimum value
    # @param max_val [Numeric] maximum value
    # @return [Float] midpoint
    def midpoint(min_val, max_val)
      ((min_val.to_f + max_val.to_f) / 2.0)
    end
  end
end
