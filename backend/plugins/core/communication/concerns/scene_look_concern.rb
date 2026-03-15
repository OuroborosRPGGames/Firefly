# frozen_string_literal: true

# SceneLookConcern - generates a brief room description used during scene transitions.
#
# Provides:
#   - generate_look_output - returns a plain-text room summary (name, description,
#                            and list of other present characters) for a given room
#
# Expects the including class to provide:
#   - character_instance - the acting CharacterInstance
#
# Used by: Scene, EndScene
module SceneLookConcern
  # Generate a plain-text room summary for use in scene transition messages.
  #
  # @param room [Room] the room to describe
  # @return [String] multi-line room summary, or empty string if room is nil
  def generate_look_output(room)
    return '' unless room

    lines = []
    lines << room.name
    lines << room.short_description if room.short_description

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
