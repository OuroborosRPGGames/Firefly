# frozen_string_literal: true

# Determines which buildings are adjacent to a street room and formats
# left/right messages based on walking direction.
class StreetContextService
  LEFT_RIGHT = {
    'north' => { left: :west, right: :east },
    'south' => { left: :east, right: :west },
    'east'  => { left: :north, right: :south },
    'west'  => { left: :south, right: :north },
    'northeast' => { left: :northwest, right: :east },
    'northwest' => { left: :west, right: :northeast },
    'southeast' => { left: :east, right: :southwest },
    'southwest' => { left: :southeast, right: :west }
  }.freeze

  BUILDING_ROOM_TYPES = RoomTypeConfig.tagged(:building_entrance).freeze

  class << self
    # Returns an array of transit message strings about buildings along the street
    # @param room [Room] the street room being traversed
    # @param direction [String] the walking direction
    # @return [Array<String>] messages like "  You pass The Rusty Sword on your right."
    def buildings_along_street(room, direction)
      return [] unless LEFT_RIGHT.key?(direction.to_s)

      messages = []
      lr = LEFT_RIGHT[direction.to_s]
      adjacent = RoomAdjacencyService.adjacent_rooms(room)

      adjacent.each do |adj_dir, rooms|
        rooms.each do |r|
          next unless building_entrance?(r)
          side = determine_side(adj_dir.to_sym, lr)
          next unless side
          messages << "  You pass #{r.name} on your #{side}."
        end
      end

      messages
    end

    private

    # A building entrance is a top-level building room (not an interior room like "Tavern - Kitchen")
    def building_entrance?(room)
      return false if room.name&.include?(' - ')

      room.city_role == 'building' ||
        BUILDING_ROOM_TYPES.include?(room.room_type)
    end

    # Determine if an adjacent direction is on the left or right side
    def determine_side(adj_dir, lr)
      return 'left' if adj_dir == lr[:left] || diagonal_matches?(adj_dir, lr[:left])
      return 'right' if adj_dir == lr[:right] || diagonal_matches?(adj_dir, lr[:right])

      nil # behind or ahead, not left/right
    end

    # Check if a diagonal direction includes the target cardinal direction
    def diagonal_matches?(dir, target)
      adjacents = {
        north: %i[northeast northwest],
        south: %i[southeast southwest],
        east: %i[northeast southeast],
        west: %i[northwest southwest]
      }
      adjacents[target]&.include?(dir) || false
    end
  end
end
