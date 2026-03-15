# frozen_string_literal: true

# Shared concern for broadcasting personalized messages to rooms.
#
# Messages containing character full_names are automatically personalized
# per viewer via MessagePersonalizationService, so each player sees names
# based on their own knowledge of other characters.
#
# Usage:
#   class MyService
#     include PersonalizedBroadcastConcern  # for instance methods
#     # or in class << self block:
#     # include PersonalizedBroadcastConcern  # for class methods
#   end
#
#   broadcast_personalized_to_room(
#     room.id,
#     "#{character.full_name} waves at #{target.full_name}.",
#     exclude: [character.id, target.id],
#     extra_characters: [character, target]
#   )
#
module PersonalizedBroadcastConcern
  # Broadcast a personalized message to all online characters in a room.
  #
  # Each viewer receives the message with character names substituted based
  # on their knowledge (via MessagePersonalizationService).
  #
  # @param room_id [Integer] The room to broadcast to
  # @param message [String] The message containing character full_names
  # @param exclude [Array<Integer, #id>] Character instances to exclude from receiving the message
  # @param extra_characters [Array<CharacterInstance>] Additional characters to include in
  #   personalization context (e.g., characters who just left the room)
  def broadcast_personalized_to_room(room_id, message, exclude: [], extra_characters: [])
    return unless room_id

    exclude_ids = Array(exclude).map { |e| e.is_a?(Integer) ? e : e.id }

    room_chars = CharacterInstance.where(
      current_room_id: room_id,
      online: true
    ).exclude(id: exclude_ids).eager(:character).all

    all_chars = room_chars + extra_characters.reject { |ci| room_chars.any? { |rc| rc.id == ci.id } }

    room_chars.each do |viewer|
      personalized = MessagePersonalizationService.personalize(
        message: message,
        viewer: viewer,
        room_characters: all_chars
      )
      BroadcastService.to_character(viewer, personalized)
    end
  end

  # Personalize a message for a specific viewer.
  #
  # Convenience wrapper around MessagePersonalizationService.personalize
  # for cases where you need the personalized text without broadcasting.
  #
  # @param message [String] The message containing character full_names
  # @param viewer [CharacterInstance] The viewer to personalize for
  # @param room_characters [Array<CharacterInstance>] Characters in the room for context
  # @return [String] The personalized message
  def personalize_for(message, viewer:, room_characters: [])
    MessagePersonalizationService.personalize(
      message: message,
      viewer: viewer,
      room_characters: room_characters
    )
  end
end
