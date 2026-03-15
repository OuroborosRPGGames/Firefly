# frozen_string_literal: true

# Shared display formatting methods for character descriptions.
# Used by both CharacterDefaultDescription (persistent) and CharacterDescription (session).
#
# Requirements:
#   - Model must have `suffix` column (string)
#   - Model must have `prefix` column (string)
#
module DescriptionFormatting
  SUFFIX_TYPES = %w[period comma space newline double_newline].freeze
  PREFIX_TYPES = %w[pronoun_has pronoun_is and none].freeze

  # Get the suffix character/string for display formatting
  # @return [String] the suffix to use after this description
  def suffix_text
    case suffix
    when 'period' then '. '
    when 'comma' then ', '
    when 'space' then ' '
    when 'newline' then ".\n"
    when 'double_newline' then ".\n\n"
    else '. '
    end
  end

  # Get the prefix text for display formatting
  # Requires character for pronoun lookup
  # @param character [Character] the character to get pronouns from
  # @return [String] the prefix to use before this description
  def prefix_text(character = nil)
    char = character || (respond_to?(:character) ? self.character : nil)
    return '' unless char

    case prefix
    when 'pronoun_has'
      pronoun = char.pronoun_subject.capitalize
      verb = char.gender&.downcase == 'neutral' || !%w[male female].include?(char.gender&.downcase) ? 'have' : 'has'
      "#{pronoun} #{verb} "
    when 'pronoun_is'
      pronoun = char.pronoun_subject.capitalize
      verb = char.gender&.downcase == 'neutral' || !%w[male female].include?(char.gender&.downcase) ? 'are' : 'is'
      "#{pronoun} #{verb} "
    when 'and'
      'and '
    else
      ''
    end
  end
end
