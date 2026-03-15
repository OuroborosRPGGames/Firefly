# frozen_string_literal: true

# Service to handle automatic name learning from emotes and speech
# When characters mention names in speech or action, others learn those names
class NameLearningService
  class << self
    # Process an emote for name learning opportunities
    # @param emoting_character [Character] the character performing the emote
    # @param text [String] the emote text
    # @param room_characters [Array<CharacterInstance>] all characters in the room
    def process_emote(emoting_character, text, room_characters)
      return if text.nil? || room_characters.nil? || room_characters.empty?

      segments = EmoteParserService.parse(text)

      segments.each do |segment|
        case segment[:type]
        when :speech
          process_self_introduction(emoting_character, segment[:text], room_characters)
          process_mentioned_characters(segment[:text], emoting_character, room_characters)
        when :action
          # Only check self-intro in action if the name wasn't auto-prepended.
          # Auto-prepended emotes start with full_name; explicit ones (capital-letter
          # emotes) start with a partial name like just "Robert" or "Bob".
          unless segment[:text].strip.start_with?(emoting_character.full_name)
            process_self_introduction(emoting_character, segment[:text], room_characters)
          end
          process_mentioned_characters(segment[:text], emoting_character, room_characters)
        end
      end
    end

    # Process direct speech (say command) for name learning
    # @param speaking_character [Character] the character speaking
    # @param speech_text [String] the speech content (without formatting)
    # @param room_characters [Array<CharacterInstance>] all characters in the room
    def process_speech(speaking_character, speech_text, room_characters)
      return if speech_text.nil? || room_characters.nil? || room_characters.empty?

      process_self_introduction(speaking_character, speech_text, room_characters)
      process_mentioned_characters(speech_text, speaking_character, room_characters)
    end

    private

    # Check if the speaker mentions any of their own names, and teach
    # exactly the name they used (not their full name)
    def process_self_introduction(character, text, room_characters)
      matched_name = find_best_self_name_match(character, text)
      return unless matched_name

      teach_name_to_room(character, matched_name, room_characters)
    end

    # Find the best (longest) matching name variant the character used
    # @return [String, nil] the matched name, or nil if no match
    def find_best_self_name_match(character, text)
      variants = character.respond_to?(:name_variants) ? character.name_variants : [character.full_name]

      # Check all variants and return the longest match
      # so "Robert Testerman" beats "Robert" if both appear in the text
      matches = variants.select { |name| EmoteParserService.name_mentioned?(text, name) }
      matches.max_by(&:length)
    end

    # Teach the character's name to everyone in the room
    # Uses the exact name mentioned, not the full name
    # @param character [Character] the character whose name is being learned
    # @param mentioned_name [String] the name as it was mentioned
    # @param room_characters [Array<CharacterInstance>] all characters in the room
    def teach_name_to_room(character, mentioned_name, room_characters)
      room_characters.each do |ci|
        next if ci.character_id == character.id

        character.introduce_to(ci.character, mentioned_name)
      end
    end

    # Process mentions of other characters in the text
    # When a character is mentioned by name, everyone learns that name
    # @param text [String] the text to check for mentions
    # @param speaking_character [Character] the character speaking (excluded from learning)
    # @param room_characters [Array<CharacterInstance>] all characters in the room
    def process_mentioned_characters(text, speaking_character, room_characters)
      mentioned = EmoteParserService.extract_mentioned_names(text, room_characters)

      mentioned.each do |mentioned_ci|
        mentioned_character = mentioned_ci.character
        next if mentioned_character.id == speaking_character.id

        # Find the best name match for this character in the text
        matched_name = find_best_self_name_match(mentioned_character, text)
        next unless matched_name

        room_characters.each do |viewer_ci|
          next if viewer_ci.character_id == mentioned_character.id

          mentioned_character.introduce_to(viewer_ci.character, matched_name)
        end
      end
    end
  end
end
