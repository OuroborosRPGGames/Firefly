# frozen_string_literal: true

# Handles fog of war visibility calculations for delve exploration.
# - Full visibility: when in room (see everything)
# - Danger visibility: within 3 squares (see monsters, dead-ends)
# - No visibility: beyond 3 squares (completely hidden)
class DelveVisibilityService
  DANGER_VISIBILITY_RANGE = 3

  class << self
    # Get all rooms visible to a participant with visibility flags
    # @param participant [DelveParticipant]
    # @return [Array<Hash>] room data with visibility flags
    def visible_rooms(participant)
      return [] unless participant.current_room

      delve = participant.delve
      current_room = participant.current_room
      level = current_room.level

      all_rooms = delve.rooms_on_level(level).all
      current_pos = [current_room.grid_x, current_room.grid_y]

      all_rooms.map do |room|
        room_pos = [room.grid_x, room.grid_y]
        distance = manhattan_distance(current_pos, room_pos)

        visibility = determine_visibility(room, distance, room.explored?)

        {
          room: room,
          grid_x: room.grid_x,
          grid_y: room.grid_y,
          distance: distance,
          visibility: visibility,
          show_type: visibility != :hidden,
          show_contents: visibility == :full,
          show_danger: visibility == :full || visibility == :danger
        }
      end
    end

    # Check if participant can see room contents (items, full description)
    # @param participant [DelveParticipant]
    # @param room [DelveRoom]
    # @return [Boolean]
    def can_see_contents?(participant, room)
      return false unless participant.current_room

      participant.current_room.id == room.id
    end

    # Check if participant can see danger indicators (monsters, traps)
    # @param participant [DelveParticipant]
    # @param room [DelveRoom]
    # @return [Boolean]
    def can_see_danger?(participant, room)
      return true if can_see_contents?(participant, room)
      return false unless participant.current_room

      distance = manhattan_distance(
        [participant.current_room.grid_x, participant.current_room.grid_y],
        [room.grid_x, room.grid_y]
      )

      distance <= DANGER_VISIBILITY_RANGE
    end

    # Get rooms that should be revealed on the map
    # @param participant [DelveParticipant]
    # @return [Array<DelveRoom>] explored + visible rooms
    def revealed_rooms(participant)
      return [] unless participant.current_room

      visible = visible_rooms(participant)
      visible.select { |v| v[:visibility] != :hidden || v[:room].explored? }.map { |v| v[:room] }
    end

    # Get danger warnings for nearby rooms
    # @param participant [DelveParticipant]
    # @return [Array<String>] warning messages
    def danger_warnings(participant)
      return [] unless participant.current_room

      warnings = []
      visible = visible_rooms(participant)

      visible.each do |v|
        next unless v[:show_danger] && !v[:show_contents]

        room = v[:room]
        dir = direction_from(participant.current_room, room)

        if room.has_monster?
          warnings << "You sense danger to the #{dir}..."
        end

        if room.is_exit
          warnings << "You see stairs leading down to the #{dir}."
        end
      end

      warnings
    end

    private

    def manhattan_distance(pos1, pos2)
      (pos1[0] - pos2[0]).abs + (pos1[1] - pos2[1]).abs
    end

    def determine_visibility(room, distance, explored)
      return :full if distance == 0
      return :danger if distance <= DANGER_VISIBILITY_RANGE
      return :explored if explored

      :hidden
    end

    # Get approximate direction from one room to another
    def direction_from(from_room, to_room)
      dx = to_room.grid_x - from_room.grid_x
      dy = to_room.grid_y - from_room.grid_y

      if dx.abs > dy.abs
        dx > 0 ? 'east' : 'west'
      else
        dy > 0 ? 'south' : 'north'
      end
    end
  end
end
