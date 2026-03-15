# frozen_string_literal: true

# Service to parse emotes into speech and action segments
# Splits text on quotation marks to distinguish dialogue from action.
# Supports both double quotes ("speech") and single quotes ('speech').
# Double quotes are checked first; single quotes are used as fallback
# only when no double-quoted speech is found.
class EmoteParserService
  class << self
    # Parse emote text into segments
    # @param text [String] the emote text to parse
    # @return [Array<Hash>] array of segments with :type (:action or :speech) and :text
    #   Each segment also includes :quote_char indicating which quote type was used
    #
    # @example Double quotes
    #   EmoteParserService.parse('Alice smiles and says, "Hello everyone!" warmly.')
    #   # => [
    #   #   { type: :action, text: 'Alice smiles and says, ', quote_char: '"' },
    #   #   { type: :speech, text: 'Hello everyone!', quote_char: '"' },
    #   #   { type: :action, text: ' warmly.', quote_char: '"' }
    #   # ]
    #
    # @example Single quotes (when no double quotes present)
    #   EmoteParserService.parse("Alice says, 'Hello!' warmly.")
    #   # => [
    #   #   { type: :action, text: 'Alice says, ', quote_char: "'" },
    #   #   { type: :speech, text: 'Hello!', quote_char: "'" },
    #   #   { type: :action, text: ' warmly.', quote_char: "'" }
    #   # ]
    def parse(text)
      return [] if text.nil? || text.empty?

      # Try double quotes first
      if text.include?('"')
        return parse_with_delimiter(text, '"')
      end

      # Fall back to single quotes using regex to find paired quotes
      # This avoids treating apostrophes (don't, can't) as speech delimiters
      parse_single_quotes(text)
    end

    # Extract the speech-only portions of an emote
    # @param text [String] the emote text
    # @return [String] concatenated speech portions
    def extract_speech(text)
      parse(text)
        .select { |seg| seg[:type] == :speech }
        .map { |seg| seg[:text] }
        .join(' ')
    end

    # Extract the action-only portions of an emote
    # @param text [String] the emote text
    # @return [String] concatenated action portions
    def extract_action(text)
      parse(text)
        .select { |seg| seg[:type] == :action }
        .map { |seg| seg[:text] }
        .join
    end

    # Find all character instances whose names are mentioned in the text
    # @param text [String] the text to search
    # @param room_characters [Array<CharacterInstance>] characters to check for
    # @return [Array<CharacterInstance>] mentioned characters
    def extract_mentioned_names(text, room_characters)
      return [] if text.nil? || room_characters.nil?

      room_characters.select do |ci|
        char = ci.respond_to?(:character) ? ci.character : ci
        name = DisplayHelper.display_name(char) || char.to_s
        name_mentioned?(text, name)
      end
    end

    # Check if a name is mentioned in text using word boundary matching
    # @param text [String] the text to search
    # @param name [String] the name to look for
    # @return [Boolean] true if name is mentioned as a complete word
    def name_mentioned?(text, name)
      return false if text.nil? || name.nil? || name.length < 2

      # Case-insensitive word boundary match
      # Matches: "Alice", "alice", "ALICE"
      # But not: "malice", "alicejones"
      text.match?(/(?:\A|\s)(#{Regexp.escape(name)})(?:\W|\z)/i)
    end

    private

    # Parse text by splitting on a specific quote delimiter
    # @param text [String] the text to parse
    # @param delimiter [String] the quote character to split on
    # @return [Array<Hash>] segments
    def parse_with_delimiter(text, delimiter)
      segments = []
      parts = text.split(delimiter)

      parts.each_with_index do |part, index|
        next if part.empty?

        if index.odd?
          segments << { type: :speech, text: part, quote_char: delimiter }
        else
          segments << { type: :action, text: part, quote_char: delimiter }
        end
      end

      segments
    end

    # Parse single-quoted speech using regex to find paired quotes.
    # Matches 'text' where the opening quote is preceded by a comma/colon + space,
    # or appears at the very start of the string. This avoids treating
    # apostrophes in contractions (don't, can't, it's) as speech delimiters.
    # @param text [String] the text to parse
    # @return [Array<Hash>] segments
    def parse_single_quotes(text)
      # Match single-quoted strings that look like speech:
      # - Opening quote preceded by ", " or ": " or at start of string
      # - Contains at least 2 characters (to skip possessives like 's)
      # - Closing quote followed by whitespace, punctuation, or end of string
      pattern = /(?:(?<=,\s)|(?<=:\s)|(?:\A))'([^']{2,})'/

      matches = []
      text.scan(pattern) do
        match = Regexp.last_match
        matches << { start: match.begin(0), finish: match.end(0), text: match[1] }
      end

      # If no speech found, return the whole thing as action
      if matches.empty?
        return [{ type: :action, text: text, quote_char: "'" }]
      end

      segments = []
      pos = 0

      matches.each do |m|
        # Add action text before this speech segment
        if pos < m[:start]
          action_text = text[pos...m[:start]]
          segments << { type: :action, text: action_text, quote_char: "'" } unless action_text.empty?
        end

        # Add speech segment
        segments << { type: :speech, text: m[:text], quote_char: "'" }
        pos = m[:finish]
      end

      # Add remaining action text
      if pos < text.length
        remaining = text[pos..]
        segments << { type: :action, text: remaining, quote_char: "'" } unless remaining.empty?
      end

      segments
    end
  end
end
