# frozen_string_literal: true

# Shared helpers for emote-style commands that need to notify offline characters
# who are mentioned in emote text, and parse emote input.
#
# Used by Emote, Semote, and Subtle commands.
#
# Expects the including class to provide:
#   - location          - the room/location context
#   - character_instance - the acting character instance
#   - character         - the acting character
#   - blank?(value)     - from Commands::Base::Command
module EmoteNotificationHelper
  # Send Discord notifications to offline characters mentioned in the emote
  def notify_offline_mentions(emote_text)
    return unless location

    # Get all character instances in the room (including offline)
    room_instances = CharacterInstance.where(current_room_id: location.id)
                                      .eager(:character)
                                      .all

    room_instances.each do |ci|
      # Skip the emoting character
      next if ci.id == character_instance.id

      # Skip online characters (they see the emote in-game)
      next if ci.online

      # Check if this character is mentioned in the emote
      next unless mentions_character?(emote_text, ci.character)

      # Send Discord notification
      NotificationService.notify_mention(ci, emote_text, character)
    end
  end

  # Check if a character's name appears in the text
  def mentions_character?(text, target_character)
    return false unless text && target_character

    text_lower = text.downcase
    # Check for forename mention
    text_lower.include?(target_character.forename.downcase) ||
      # Check for full name mention
      text_lower.include?(target_character.full_name.downcase)
  end

  # Extract the emote text from parsed input (strips the command word)
  def extract_emote_text(parsed_input)
    input = parsed_input[:full_input].to_s
    stripped_input = input.strip
    return nil if blank?(stripped_input)

    # Remove command word and return the rest
    parts = stripped_input.split(/\s+/, 2)
    parts[1]&.strip
  end
end
