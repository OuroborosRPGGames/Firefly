# frozen_string_literal: true

# EmoteBroadcastConcern - shared helpers for Emote and Semote commands.
#
# Extracted from Commands::Communication::Emote and Commands::Communication::Semote
# to eliminate duplication in wrapper styling, self-message formatting, and
# emote message construction. Emote-specific emit_mode behaviour is handled
# via keyword arguments that default to false.
module EmoteBroadcastConcern
  # Apply spotlight or emit wrapper styling to an emote message.
  # @param message [String] the formatted message
  # @param is_spotlighted [Boolean] whether the sender has an active spotlight
  # @param emit_mode [Boolean] whether this is a GM emit (no attribution)
  # @return [String] the wrapped message
  def apply_wrapper_styling(message, is_spotlighted, emit_mode: false)
    if emit_mode
      "<fieldset>#{message}</fieldset>"
    elsif is_spotlighted
      "<div class=\"spotlight-emote\">#{message}</div>"
    else
      message
    end
  end

  # Format the emote message as the sender sees it (self-view).
  # @param message [String] the base emote message
  # @param is_spotlighted [Boolean] whether the sender has an active spotlight
  # @param room_characters [Array<CharacterInstance>] all room characters for name lookup
  # @param emit_mode [Boolean] whether this is a GM emit
  # @return [String] the styled self-view message
  def format_self_message(message, is_spotlighted, room_characters, emit_mode: false)
    formatted = EmoteFormatterService.format_for_viewer(
      message,
      character,
      character_instance,
      room_characters
    )
    apply_wrapper_styling(formatted, is_spotlighted, emit_mode: emit_mode)
  end

  # Check whether emote text references the acting character by any name variant.
  # @param text [String] the emote text
  # @return [Boolean]
  def mentions_self?(text)
    text_lower = text.downcase
    character.name_variants.any? { |variant| text_lower.include?(variant.downcase) }
  end

  # Build the emote string with optional adverb placement.
  # Randomly places adverb before or after the character name for variety.
  # @param character_name [String] the acting character's name
  # @param text [String] the emote body (lowercase start)
  # @param adverb [String, nil] optional adverb extracted from the emote text
  # @return [String] the constructed emote message
  def build_emote_message(character_name, text, adverb)
    if present?(adverb)
      if rand(2) == 1
        "#{character_name} #{adverb.downcase} #{text}"
      else
        "#{adverb.capitalize} #{character_name} #{text}"
      end
    else
      "#{character_name} #{text}"
    end
  end
end
