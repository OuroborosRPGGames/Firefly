# frozen_string_literal: true

module Commands
  module Staff
    module Concerns
      # Shared lookup logic for finding a puppeted NPC by name among a list of puppets.
      #
      # Used by PEmote and Unpuppet commands.
      module PuppetLookupConcern
        # Find a puppet CharacterInstance by name (exact, forename, prefix, or partial).
        #
        # @param puppets_list [Array<CharacterInstance>] the puppets controlled by this staff member
        # @param name [String] the name fragment to match against
        # @return [CharacterInstance, nil]
        def find_puppet_by_name(puppets_list, name)
          name_lower = name.downcase

          # Exact full-name match
          match = puppets_list.find { |ci| ci.full_name.downcase == name_lower }
          return match if match

          # Forename-only match
          match = puppets_list.find { |ci| ci.character.forename.downcase == name_lower }
          return match if match

          # Prefix match
          match = puppets_list.find { |ci| ci.full_name.downcase.start_with?(name_lower) }
          return match if match

          # Partial match
          puppets_list.find { |ci| ci.full_name.downcase.include?(name_lower) }
        end
      end
    end
  end
end
