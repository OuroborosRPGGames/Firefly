# frozen_string_literal: true

# Service to format emotes with speech coloring and name substitution
# - Speech (quoted text) is wrapped in the speaker's signature color
# - Action text has character names replaced with what the viewer knows them as
class EmoteFormatterService
  class << self
    # Resolve @mentions in emote text to character full names
    # @param text [String] emote text potentially containing @mentions
    # @param sender_instance [CharacterInstance] who is emoting
    # @param room_characters [Array<CharacterInstance>] characters in the room
    # @return [String] text with @mentions replaced by full names
    def resolve_at_mentions(text, sender_instance, room_characters)
      resolve_at_mentions_with_targets(text, sender_instance, room_characters)[:text]
    end

    # Resolve @mentions and also return the resolved target instances.
    # @param text [String] emote text potentially containing @mentions
    # @param sender_instance [CharacterInstance] who is emoting
    # @param room_characters [Array<CharacterInstance>] characters in the room
    # @return [Hash] { text: String, targets: Array<CharacterInstance> }
    def resolve_at_mentions_with_targets(text, sender_instance, room_characters)
      targets = []
      return { text: text, targets: targets } if text.nil? || !text.include?('@')

      resolved_text = text.gsub(/@"([^"]+)"|(?<!\w)@(\w+)/) do |match|
        query = $1 || $2 # $1 = quoted, $2 = single word

        target = TargetResolverService.resolve_character(
          query: query,
          candidates: room_characters,
          viewer: sender_instance
        )

        if target
          # Collect the CharacterInstance (not Character)
          target_instance = target.respond_to?(:character) ? target : nil
          targets << target_instance if target_instance
          char = target.respond_to?(:character) ? target.character : target
          char.full_name
        else
          match # Leave unresolved @mentions as-is
        end
      end

      { text: resolved_text, targets: targets }
    end

    # Format an emote for a specific viewer
    # @param emote_text [String] the raw emote text
    # @param emoting_character [Character] the character performing the emote
    # @param viewer_instance [CharacterInstance] the character viewing the emote
    # @param room_characters [Array<CharacterInstance>] all characters in the room
    # @return [String] the formatted emote text
    def format_for_viewer(emote_text, emoting_character, viewer_instance, room_characters)
      return emote_text if emote_text.nil? || emote_text.empty?

      segments = EmoteParserService.parse(emote_text)
      speech_color = emoting_character.speech_color

      # Format each segment appropriately
      formatted_parts = segments.map do |segment|
        case segment[:type]
        when :speech
          # Wrap in speech color, keep original names
          format_speech(segment[:text], speech_color)
        when :action
          # Substitute names for what viewer knows
          format_action(segment[:text], viewer_instance, room_characters)
        end
      end

      # Rejoin segments, adding quotes back around speech
      result = []
      formatted_parts.each_with_index do |part, index|
        if segments[index][:type] == :speech
          q = segments[index][:quote_char] || '"'
          if part.include?('<span')
            # Insert quotes inside the color span so they are colored too
            result << part.sub('>', ">#{q}").sub('</span>', "#{q}</span>")
          else
            result << q << part << q
          end
        else
          result << part
        end
      end

      result.join
    end

    private

    # Format speech text with the speaker's color
    # @param text [String] the speech text (without quotes)
    # @param color [String] the hex color to use (e.g., '#FF5733')
    # @return [String] the colored speech text
    def format_speech(text, color)
      MessageFormattingHelper.apply_speech_color_to_text(text.to_s, color)
    end

    # Format action text with name substitution based on viewer knowledge
    # @param text [String] the action text
    # @param viewer_instance [CharacterInstance] the viewer
    # @param room_characters [Array<CharacterInstance>] all characters in the room
    # @return [String] the text with names substituted
    def format_action(text, viewer_instance, room_characters)
      return text if room_characters.nil? || room_characters.empty?

      substituted = text

      # Sort characters by their longest name variant first
      sorted_chars = room_characters.sort_by do |ci|
        -(ci.character.name_variants.first&.length || 0)
      end

      sorted_chars.each do |char_instance|
        character = char_instance.character
        display_name = character.display_name_for(viewer_instance, room_characters: room_characters)
        is_viewer = (char_instance.id == viewer_instance.id)

        # Try each variant (longest first from name_variants), break on first match
        character.name_variants.each do |variant|
          next if variant.nil? || variant.empty?

          matched = false
          substituted = substituted.gsub(/(?<=\A|\s)(#{Regexp.escape(variant)})(?=\W|\z)/i) do
            matched = true
            pre_match = $~.pre_match
            name = if pre_match.empty? || pre_match.match?(/[.!?]\s*\z/)
                     capitalize_first(display_name)
                   else
                     display_name
                   end
            if is_viewer
              pov = viewer_instance.character.point_of_view
              if pov == 'Second'
                (pre_match.empty? || pre_match.match?(/[.!?]\s*\z/)) ? 'You' : 'you'
              else
                "<strong>#{name}</strong>"
              end
            else
              name
            end
          end
          break if matched # Stop trying shorter variants for this character
        end
      end

      substituted
    end

    # Capitalize the first letter of a string, leaving the rest unchanged
    def capitalize_first(str)
      return str if str.nil? || str.empty?

      str[0].upcase + str[1..]
    end
  end
end
