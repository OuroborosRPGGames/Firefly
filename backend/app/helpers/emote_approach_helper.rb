# frozen_string_literal: true

# Shared helper for emote/semote commands that resolves @mentions
# and silently moves the emoting character closer to the first target.
module EmoteApproachHelper
  # Resolve @mentions in text and approach the first mentioned target.
  # @param text [String] emote text containing @mentions
  # @return [String] text with @mentions resolved to full names
  def resolve_mentions_and_approach(text)
    room_chars = CharacterInstance
                   .where(current_room_id: location.id, online: true)
                   .eager(:character).all

    result = EmoteFormatterService.resolve_at_mentions_with_targets(
      text, character_instance, room_chars
    )

    # Silently approach the first resolved target
    first_target = result[:targets].first
    approach_emote_target(first_target) if first_target

    result[:text]
  end

  private

  # Silently move the emoting character closer to the target.
  # Guards: skip if either party at furniture, in combat, already moving, or within 5ft.
  def approach_emote_target(target_instance)
    return if target_instance.id == character_instance.id
    return if character_instance.at_place?
    return if target_instance.at_place?
    return if character_instance.in_combat?
    return if character_instance.movement_state == 'moving'

    char_pos = character_instance.position
    target_pos = target_instance.position

    dist = DistanceService.calculate_distance(
      char_pos[0], char_pos[1], char_pos[2],
      target_pos[0], target_pos[1], target_pos[2]
    )

    return if dist <= 5.0

    # Calculate position 2-4ft from target along the line from character to target
    stop_dist = 2.0 + rand * 2.0 # 2-4ft offset
    dx = target_pos[0] - char_pos[0]
    dy = target_pos[1] - char_pos[1]
    line_dist = Math.sqrt(dx * dx + dy * dy)
    return if line_dist < 0.01 # avoid division by zero

    # Position along the line, stopping short of the target
    ratio = [1.0 - (stop_dist / line_dist), 0.0].max
    new_x = char_pos[0] + dx * ratio
    new_y = char_pos[1] + dy * ratio

    character_instance.move_to_valid_position(new_x, new_y, char_pos[2], snap_to_valid: true)
  end
end
