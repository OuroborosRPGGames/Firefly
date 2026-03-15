# frozen_string_literal: true

# Shared helper for formatting the "Nearby Areas:" text line shown in room descriptions.
#
# Used by Look and Observe commands.
#
# Expects: none (pure formatter).
module RoomDisplayHelper
  # Build Ravencroft-style "Nearby Areas:" text with distance tags
  # @param exits [Array<Hash>] exit data from RoomDisplayService
  # @return [String, nil] formatted nearby areas text or nil if no exits
  def build_nearby_areas_text(exits)
    return nil if exits.nil? || exits.empty?

    areas = exits.map do |e|
      name = e[:to_room_name] || e[:display_name]
      tag = e[:distance_tag]
      tag ? "#{name} (#{tag})" : name
    end.compact

    return nil if areas.empty?

    "Nearby Areas: #{areas.join(', ')}"
  end
end
