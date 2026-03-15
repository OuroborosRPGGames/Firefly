# frozen_string_literal: true

# Handles typing a room name directly to walk there
# Only matches adjacent rooms (rooms connected via exits) for safety
#
# Example: If player is in "Town Square" with exits to "Tavern" and "Market",
#          typing "tavern" will be rewritten to "walk Tavern"
#
# Matching: Exact match only (case-insensitive)
# This ensures commands always take priority - the fallback only runs
# when the command registry doesn't recognize the input.
class RoomNameFallbackService
  class << self
    # Returns rewritten command ("walk <room_name>") or nil if no match
    # @param character_instance [CharacterInstance] the player's instance
    # @param input [String] the raw command input
    # @return [String, nil] rewritten walk command or nil
    def try_fallback(character_instance, input)
      return nil if input.nil? || input.strip.empty?

      input_lower = input.strip.downcase
      room = character_instance.current_room
      return nil unless room

      # Get adjacent room names via spatial exits
      adjacent_rooms = room.spatial_exits.flat_map do |_direction, rooms|
        rooms.map do |to_room|
          {
            name: to_room.name,
            name_lower: to_room.name.downcase
          }
        end
      end.uniq { |r| r[:name_lower] }

      return nil if adjacent_rooms.empty?

      # Exact match only - no partial matching to avoid conflicts with commands
      match = adjacent_rooms.find { |r| r[:name_lower] == input_lower }

      match ? "walk #{match[:name]}" : nil
    rescue StandardError => e
      warn "[RoomNameFallbackService] Error in fallback: #{e.message}"
      nil
    end
  end
end
