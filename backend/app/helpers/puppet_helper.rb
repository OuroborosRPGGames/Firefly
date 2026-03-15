# frozen_string_literal: true

# Shared helper for finding a puppet NPC by name among a list of puppets.
#
# Used by Pemote and Unpuppet commands.
module PuppetHelper
  def find_puppet_by_name(puppets_list, name)
    name_lower = name.downcase

    # Exact match
    match = puppets_list.find { |ci| ci.full_name.downcase == name_lower }
    return match if match

    # Forename match
    match = puppets_list.find { |ci| ci.character.forename.downcase == name_lower }
    return match if match

    # Prefix match
    match = puppets_list.find { |ci| ci.full_name.downcase.start_with?(name_lower) }
    return match if match

    # Partial match
    puppets_list.find { |ci| ci.full_name.downcase.include?(name_lower) }
  end
end
