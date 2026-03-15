# frozen_string_literal: true

# Shared behavior for services that display character information
#
# Provides common patterns for:
# - Display name resolution based on viewer context
# - Pronoun handling
#
# Usage:
#   class MyDisplayService
#     include CharacterDisplayConcern
#
#     def initialize(target_instance, viewer_instance: nil)
#       @target = target_instance
#       @character = target_instance.character
#       @viewer = viewer_instance
#     end
#   end
#
module CharacterDisplayConcern
  # Get the appropriate display name based on viewer context
  # Uses the character's knowledge system if a viewer is present
  #
  # @return [String] the display name
  def display_name
    if @viewer
      @character.display_name_for(@viewer)
    else
      @character.full_name
    end
  end

  # Get subject pronoun for character (He/She/They)
  # Capitalizes for sentence start - delegates to Character#pronoun_subject
  #
  # @return [String]
  def pronoun_subject
    @character.pronoun_subject.capitalize
  end

  # Get possessive pronoun for character (His/Her/Their)
  # Capitalizes for sentence start - delegates to Character#pronoun_possessive
  #
  # @return [String]
  def pronoun_possessive
    @character.pronoun_possessive.capitalize
  end

  # Get object pronoun for character (him/her/them)
  # Delegates to Character#pronoun_object
  #
  # @return [String]
  def pronoun_object
    @character.pronoun_object
  end

  # Get reflexive pronoun for character (himself/herself/themselves)
  # Delegates to Character#pronoun_reflexive
  #
  # @return [String]
  def pronoun_reflexive
    @character.pronoun_reflexive
  end
end
