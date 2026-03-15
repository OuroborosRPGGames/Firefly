# frozen_string_literal: true

# Shared helper for generating a simple room look summary used in scene transitions.
#
# Used by Scene and Endscene commands.
#
# Expects the including class to provide:
#   - character_instance - the acting character instance
module SceneHelper
  def generate_look_output(room)
    return '' unless room

    lines = []
    lines << room.name
    lines << room.short_description if room.short_description

    # List characters in the room
    chars_in_room = CharacterInstance
      .where(current_room_id: room.id, online: true)
      .exclude(id: character_instance.id)
      .all

    unless chars_in_room.empty?
      lines << ''
      lines << 'Also here:'
      chars_in_room.each do |ci|
        lines << "  #{ci.full_name}"
      end
    end

    lines.join("\n")
  end
end
