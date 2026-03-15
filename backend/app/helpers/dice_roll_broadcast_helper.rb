# frozen_string_literal: true

# Shared helper for broadcasting dice roll results to a room.
#
# Used by Roll and Diceroll commands.
#
# Expects the including class to provide:
#   - character_instance - the acting character instance
#   - character - the acting character
module DiceRollBroadcastHelper
  def broadcast_dice_roll(animation_data, description, roll_result, modifier)
    room = character_instance.current_room
    return unless room

    # Send personalized dice roll to each viewer in the room
    all_room_chars = CharacterInstance
      .where(current_room_id: room.id, online: true)
      .eager(:character)
      .all

    all_room_chars.each do |viewer|
      viewer_name = character.display_name_for(viewer)

      BroadcastService.to_character(
        viewer,
        {
          type: 'dice_roll',
          character_id: character.id,
          character_name: viewer_name,
          animation_data: animation_data,
          roll_modifier: modifier,
          roll_total: roll_result.total,
          description: description,
          timestamp: Time.now.iso8601
        },
        type: :dice_roll
      )
    end

    # Also persist as a message for history
    Message.create(
      character_instance_id: character_instance.id,
      reality_id: character_instance.reality_id,
      room_id: room.id,
      content: description,
      message_type: 'roll'
    )
  rescue StandardError => e
    warn "[DiceRoll] Failed to broadcast dice roll: #{e.message}"
  end
end
