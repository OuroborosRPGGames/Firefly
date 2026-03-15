# frozen_string_literal: true

module Commands
  module Clothing
    # Shared concern for aesthete commands (tattoo, style, makeup, pierce)
    # that need to resolve targets and check permissions for character modification.
    module AestheteConcern
      SELF_REFERENCES = %w[me self myself].freeze

      # Resolve a target name to a Character object
      # Handles self-references and delegates to TargetResolverService via base command
      # @param name [String] Target name or self-reference
      # @return [Character, Hash] Character object or error result hash
      def resolve_aesthete_target(name)
        return character if SELF_REFERENCES.include?(name.downcase)

        # Use the base command's find_character_in_room which returns CharacterInstance
        target_instance = find_character_in_room(name, exclude_self: true)
        return error_result("No one named '#{name}' is here.") unless target_instance

        target_instance.character
      end

      # Check if performer has permission to modify target's appearance
      # @param target_char [Character] The target character
      # @return [Boolean] Whether permission is granted
      def has_aesthete_permission?(target_char)
        # Always have permission to modify self
        return true if target_char.id == character.id

        performer_user = character&.user
        target_user = target_char&.user

        return false unless performer_user && target_user

        UserPermission.dress_style_allowed?(performer_user, target_user)
      end
    end
  end
end
