# frozen_string_literal: true

# Service for auto-capitalizing text after sentence endings
# Used to ensure proper grammar in character descriptions
class DescriptionGrammarService
  # Only match horizontal whitespace (space, tab) after sentence endings, not newlines
  SENTENCE_ENDINGS = /([.!?])[ \t]+([a-z])/

  # Auto-capitalize text after sentence endings
  # @param text [String] the text to process
  # @return [String] text with proper capitalization
  def self.auto_capitalize(text)
    return text if text.nil? || text.empty?

    result = text.dup

    # Capitalize after periods, exclamation marks, question marks (on same line)
    result.gsub!(SENTENCE_ENDINGS) { "#{$1} #{$2.upcase}" }

    # Capitalize after newlines (preserving any leading whitespace)
    result.gsub!(/\n(\s*)([a-z])/) { "\n#{$1}#{$2.upcase}" }

    # Capitalize first letter if lowercase
    result = result[0].upcase + result[1..] if result.length > 0 && result[0] =~ /[a-z]/

    result
  end
end
