# frozen_string_literal: true

# Provides display name helpers to reduce duplication of name resolution logic.
#
# Consolidates the repeated pattern:
#   obj.respond_to?(:full_name) ? obj.full_name : obj.name
#
# Found in many services, especially auto_gm services.
#
# Usage:
#   # As instance method (when included):
#   class MyService
#     include DisplayHelper
#
#     def format_character(char)
#       "Player: #{display_name(char)}"
#     end
#   end
#
#   # As module method (for class-level or standalone use):
#   DisplayHelper.display_name(character)  # => "John Smith"
#   DisplayHelper.character_display_name(ci)  # => "John Smith"
#
module DisplayHelper
  module_function
  # Get the display name for any object that has name/full_name methods
  #
  # @param obj [Object] An object with #name or #full_name method
  # @return [String, nil] The full_name if available, otherwise name
  #
  # @example
  #   display_name(character)      # => "John Smith" (uses full_name)
  #   display_name(item)           # => "Sword" (uses name)
  #   display_name(nil)            # => nil
  def display_name(obj)
    return nil unless obj

    obj.respond_to?(:full_name) ? obj.full_name : obj.name
  end

  # Get the display name for a character through its instance
  #
  # @param character_instance [CharacterInstance] A character instance
  # @return [String, nil] The character's display name
  #
  # @example
  #   character_display_name(ci)   # => "John Smith"
  def character_display_name(character_instance)
    return nil unless character_instance

    display_name(character_instance.character)
  end

  # Get the display name from a fight participant
  #
  # @param participant [FightParticipant] A fight participant
  # @return [String, nil] The participant's character display name
  def participant_display_name(participant)
    return nil unless participant

    character_display_name(participant.character_instance)
  end
end
