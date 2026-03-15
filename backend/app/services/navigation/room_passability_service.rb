# frozen_string_literal: true

# Service for determining if passage is allowed between adjacent rooms.
# Checks walls and openings based on room type (indoor vs outdoor).
#
# Usage:
#   RoomPassabilityService.can_pass?(from_room, to_room, :north)
#   # => true/false
#
# Rules:
# - Outdoor to outdoor: always passable
# - Indoor rooms: check for walls and openings in the direction
# - If no wall exists (open plan), allow passage
# - If wall exists, require an opening (door, archway, etc.)
# - Doors/gates/hatches must be open (check is_open flag)
# - Archways/openings are always passable regardless of is_open
class RoomPassabilityService
  # Feature types that are always passable regardless of is_open state
  ALWAYS_PASSABLE_TYPES = %w[opening archway staircase elevator].freeze

  # Feature types that can provide passage when open
  OPENABLE_TYPES = %w[door gate hatch portal].freeze

  class << self
    # Check if passage is allowed from one room to an adjacent room
    # @param from_room [Room] source room
    # @param to_room [Room] destination room
    # @param direction [Symbol, String] direction of travel (:north, :south, etc.)
    # @return [Boolean]
    def can_pass?(from_room, to_room, direction)
      direction = direction.to_s

      # "enter" direction is for contained rooms - always allow
      # (entering a shop from a mall, moving between sibling rooms)
      return true if direction == 'enter'

      # "exit" direction is for leaving to container - always allow
      return true if direction == 'exit'

      # Outdoor to outdoor: always passable
      return true if from_room.outdoor_room? && to_room.outdoor_room?

      # Floor rooms are open pass-throughs for vertical movement
      if %w[up down].include?(direction) && from_room.room_type == 'floor'
        return true
      end

      # Source side must allow passage in travel direction.
      source_blocked = wall_in_direction?(from_room, direction) &&
                       !opening_in_direction?(from_room, direction, connected_from_room_id: to_room.id)
      return false if source_blocked

      # Destination side must also allow passage from its opposite edge.
      opposite = CanvasHelper.opposite_direction(direction, fallback: nil)
      return true unless opposite

      destination_blocked = wall_in_direction?(to_room, opposite) &&
                            !opening_in_direction?(to_room, opposite, connected_from_room_id: from_room.id)
      !destination_blocked
    end

    # Check if there's a wall feature in the given direction
    # @param room [Room] the room to check
    # @param direction [Symbol, String] the direction to check
    # @return [Boolean]
    def wall_in_direction?(room, direction)
      room.room_features_dataset
          .where(feature_type: 'wall', direction: direction.to_s)
          .any?
    end

    # Check if there's a passable opening in the given direction
    # @param room [Room] the room to check
    # @param direction [Symbol, String] the direction to check
    # @return [Boolean]
    def opening_in_direction?(room, direction, connected_from_room_id: nil)
      direction_str = direction.to_s

      # Check own features (existing logic)
      own_openings = room.room_features_dataset
                         .where(direction: direction_str)
                         .exclude(feature_type: 'wall')
                         .exclude(feature_type: 'window')
                         .all
      return true if own_openings.any? { |opening| passable_opening?(opening) }

      # Check inbound features from adjacent rooms connecting TO this room
      opposite = CanvasHelper.opposite_direction(direction_str)
      inbound_openings = RoomFeature.where(connected_room_id: room.id, direction: opposite)
      inbound_openings = inbound_openings.where(room_id: connected_from_room_id) if connected_from_room_id
      inbound_openings = inbound_openings.exclude(feature_type: 'wall')
                                         .exclude(feature_type: 'window')
                                         .all
      inbound_openings.any? { |opening| passable_opening?(opening) }
    end

    private

    # Check if a feature allows passage
    # @param feature [RoomFeature] the feature to check
    # @return [Boolean]
    def passable_opening?(feature)
      # Always-passable types (archways, openings) don't require is_open
      return true if ALWAYS_PASSABLE_TYPES.include?(feature.feature_type)

      # Openable types require is_open to be true
      return feature.is_open if OPENABLE_TYPES.include?(feature.feature_type)

      # For any other feature type, use the allows_movement_through? method
      feature.allows_movement_through?
    end
  end
end
