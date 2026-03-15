# frozen_string_literal: true

# OfflineMentionConcern - shared helpers for emote-style commands.
#
# Provides:
#   - extract_emote_text   - strips the command word (and shorthand : / . prefixes)
#                            from parsed input and returns the raw emote body
#   - notify_offline_mentions - sends Discord notifications to offline characters
#                               whose names appear in the emote text
#
# Expects the including class to provide:
#   - location             - the current room/location
#   - character_instance   - the acting CharacterInstance
#   - character            - the acting Character
#   - blank?(value)        - from Commands::Base::Command
#
# Used by: Emote, SEmote, Subtle
module OfflineMentionConcern
  # Extract the emote body from parsed input.
  # Handles shorthand prefixes (: and .) as well as the normal "cmd text" form.
  #
  # @param parsed_input [Hash] the parsed command input hash
  # @return [String, nil] the emote body, or nil if blank
  def extract_emote_text(parsed_input)
    input = parsed_input[:full_input].to_s
    stripped_input = input.strip
    return nil if blank?(stripped_input)

    # Handle shorthand prefixes like : or .
    if stripped_input.start_with?(':') || stripped_input.start_with?('.')
      stripped_input[1..-1]&.strip
    else
      # Remove command word and return the rest
      parts = stripped_input.split(/\s+/, 2)
      parts[1]&.strip
    end
  end

  # Send Discord notifications to offline characters mentioned in the emote text.
  # Online characters see the emote in-game; this covers those who are absent.
  #
  # @param emote_text [String] the fully formatted emote message
  def notify_offline_mentions(emote_text)
    return unless location

    room_instances = CharacterInstance.where(current_room_id: location.id)
                                      .eager(:character)
                                      .all

    room_instances.each do |ci|
      next if ci.id == character_instance.id
      next if ci.online
      next unless mentions_character?(emote_text, ci.character)

      NotificationService.notify_mention(ci, emote_text, character)
    end
  end

  # Check whether a character's name appears in the text.
  #
  # @param text [String] the emote text to search
  # @param target_character [Character] the character to look for
  # @return [Boolean]
  def mentions_character?(text, target_character)
    return false unless text && target_character

    text_lower = text.downcase
    text_lower.include?(target_character.forename.downcase) ||
      text_lower.include?(target_character.full_name.downcase)
  end
end
