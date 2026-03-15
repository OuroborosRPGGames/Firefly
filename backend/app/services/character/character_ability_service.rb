# frozen_string_literal: true

# Service for managing ability assignment to characters
# Handles assigning, removing, and querying abilities for a CharacterInstance
class CharacterAbilityService
  attr_reader :character

  def initialize(character_instance)
    @character = character_instance
  end

  # Assign an ability to the character
  # @param ability [Ability, Integer] The ability or ability ID
  # @param proficiency_level [Integer] Starting proficiency (default 1)
  # @return [CharacterAbility] The created or existing record
  def assign(ability, proficiency_level: 1)
    ability_id = resolve_ability_id(ability)
    return nil unless ability_id

    existing = find_character_ability(ability_id)
    return existing if existing

    CharacterAbility.create(
      character_instance_id: character.id,
      ability_id: ability_id,
      proficiency_level: proficiency_level,
      learned_at: Time.now
    )
  end

  # Remove an ability from the character
  # @param ability [Ability, Integer] The ability or ability ID
  # @return [Boolean] True if removed, false if not found
  def unassign(ability)
    ability_id = resolve_ability_id(ability)
    return false unless ability_id

    existing = find_character_ability(ability_id)
    return false unless existing

    existing.destroy
    true
  end

  # Check if character has a specific ability
  # @param ability [Ability, Integer] The ability or ability ID
  # @return [Boolean]
  def has_ability?(ability)
    ability_id = resolve_ability_id(ability)
    return false unless ability_id

    !find_character_ability(ability_id).nil?
  end

  # Get all abilities for the character
  # @return [Array<Ability>] Array of Ability records
  def abilities
    character_abilities.map(&:ability).compact
  end

  # Get all CharacterAbility records (includes proficiency, cooldowns)
  # Eager-loads the associated Ability to avoid N+1 queries
  # @return [Array<CharacterAbility>]
  def character_abilities
    CharacterAbility.where(character_instance_id: character.id).eager(:ability).all
  end

  # Get a specific CharacterAbility record
  # @param ability [Ability, Integer] The ability or ability ID
  # @return [CharacterAbility, nil]
  def get(ability)
    ability_id = resolve_ability_id(ability)
    return nil unless ability_id

    find_character_ability(ability_id)
  end

  # Assign multiple abilities at once
  # @param abilities [Array<Ability, Integer>] Array of abilities or IDs
  # @param proficiency_level [Integer] Starting proficiency for all
  # @return [Array<CharacterAbility>] Array of created/existing records
  def assign_all(abilities, proficiency_level: 1)
    abilities.map { |a| assign(a, proficiency_level: proficiency_level) }.compact
  end

  # Remove all abilities from the character
  # @return [Integer] Number of abilities removed
  def clear_all
    dataset = CharacterAbility.where(character_instance_id: character.id)
    count = dataset.count
    dataset.delete
    count
  end

  # Get abilities filtered by type
  # @param ability_type [String] combat, utility, passive, social, crafting
  # @return [Array<Ability>]
  def abilities_by_type(ability_type)
    abilities.select { |a| a.ability_type == ability_type }
  end

  # Get abilities that are currently usable (not on cooldown)
  # @return [Array<CharacterAbility>]
  def usable_abilities
    character_abilities.select(&:can_use?)
  end

  private

  def resolve_ability_id(ability)
    case ability
    when Ability
      ability.id
    when Integer
      ability
    else
      nil
    end
  end

  def find_character_ability(ability_id)
    CharacterAbility.first(
      character_instance_id: character.id,
      ability_id: ability_id
    )
  end
end
