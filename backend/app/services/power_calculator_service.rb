# frozen_string_literal: true

# Calculates power ratings for PCs and NPCs to estimate initial encounter balance.
# These formulas provide a starting point for the simulation-based balancing.
#
# The power rating is a rough estimate of combat effectiveness.
# After initial estimation, CombatSimulatorService runs simulations to fine-tune.
#
# @example
#   # Calculate NPC power
#   archetype = NpcArchetype.find(id: 1)
#   power = PowerCalculatorService.calculate_archetype_power(archetype)
#
#   # Estimate initial composition
#   composition = PowerCalculatorService.estimate_balanced_composition(
#     pc_power: 500,
#     mandatory_archetypes: [boss],
#     optional_archetypes: [minion1, minion2]
#   )
#
class PowerCalculatorService
  # Delegate to centralized GameConfig
  WEIGHTS = GameConfig::Power::WEIGHTS
  BALANCED_POWER_RATIO = GameConfig::Power::BALANCE[:npc_to_pc_ratio]

  # Calculate power rating for an NPC archetype
  # @param archetype [NpcArchetype] The archetype to evaluate
  # @return [Float] Power rating
  def self.calculate_archetype_power(archetype)
    stats = archetype.combat_stats

    hp_factor = (stats[:max_hp] || 6) * WEIGHTS[:hp]
    damage_factor = (stats[:damage_bonus] || 0) * WEIGHTS[:damage_bonus]
    defense_factor = (stats[:defense_bonus] || 0) * WEIGHTS[:defense_bonus]
    speed_factor = (stats[:speed_modifier] || 0) * WEIGHTS[:speed]

    # Calculate expected dice damage relative to base
    dice_count = stats[:damage_dice_count] || 2
    dice_sides = stats[:damage_dice_sides] || 6
    expected_dice = dice_count * ((dice_sides + 1) / 2.0)
    dice_factor = (expected_dice - (WEIGHTS[:dice_base] / 2.0)) * GameConfig::Power::BALANCE[:dice_factor_mult]

    # AI profile modifier (aggressive NPCs are more dangerous)
    ai_modifier = GameConfig::Power::AI_MODIFIERS[archetype.ai_profile] || 1.0

    # Factor in ability power if archetype has combat abilities
    ability_power = 0.0
    if archetype.has_combat_abilities?
      ability_power = calculate_ability_power(archetype.combat_abilities)
    end

    base_power = hp_factor + damage_factor + defense_factor + speed_factor + dice_factor + ability_power
    (base_power * ai_modifier).round(1)
  end

  # Calculate total ability power for a list of abilities
  # @param abilities [Array<Ability>] abilities to evaluate
  # @return [Float] scaled ability power contribution
  def self.calculate_ability_power(abilities)
    return 0.0 if abilities.nil? || abilities.empty?

    # Sum raw ability power
    raw_power = abilities.sum { |a| a.power.to_f }

    # Apply diminishing returns for multiple abilities
    # First ability counts full, subsequent have decreasing marginal value
    ability_count = abilities.count
    scaling = ability_count > 1 ? 1.0 + (Math.log(ability_count) * 0.3) : 1.0

    # Scale contribution - abilities meaningful but don't overwhelm base stats
    # 0.5 factor balances against HP/stat contributions
    (raw_power * 0.5 * scaling).round(1)
  end

  # Calculate power rating for a PC from their character
  # @param character [Character] The character to evaluate
  # @return [Float] Power rating
  def self.calculate_pc_power(character)
    defaults = GameConfig::Power::DEFAULTS
    balance = GameConfig::Power::BALANCE

    # Try to get stat block from user's universe or default
    stat_block = nil
    if character.respond_to?(:universe) && character.universe
      stat_block = character.universe.default_stat_block
    end

    # Estimate HP from stat block or use default
    hp = stat_block ? (stat_block.total_points.to_i / defaults[:hp_divisor] + defaults[:hp_base]) : 6
    hp = [hp, defaults[:hp_floor]].max

    # Try to get combat stats (may not exist on all characters)
    str = defaults[:stat_default]
    dex = defaults[:stat_default]
    if character.respond_to?(:get_stat_value)
      str = character.get_stat_value('STR') ||
            character.get_stat_value('Strength') || defaults[:stat_default]
      dex = character.get_stat_value('DEX') ||
            character.get_stat_value('Dexterity') || defaults[:stat_default]
    end

    hp_factor = hp * WEIGHTS[:hp]
    stat_factor = ((str + dex - defaults[:stat_baseline]) / 2.0) * WEIGHTS[:damage_bonus]

    # PCs use 2d8 exploding (avg ~10.5 with explosions)
    # This is slightly above the 2d6 base
    dice_factor = balance[:pc_dice_factor] * balance[:dice_factor_mult]

    # Factor in ability power from character's primary instance
    ability_power = 0.0
    if character.respond_to?(:primary_instance) && character.primary_instance
      abilities = character.primary_instance.character_abilities.map(&:ability).compact
      ability_power = calculate_ability_power(abilities)
    end

    hp_factor + stat_factor + dice_factor + ability_power
  end

  # Calculate combined power for a group of PCs
  # @param character_ids [Array<Integer>] Character IDs to include
  # @return [Float] Combined power rating
  def self.calculate_pc_group_power(character_ids)
    characters = Character.where(id: character_ids).all
    characters.sum { |c| calculate_pc_power(c) }
  end

  # Estimate an initial balanced NPC composition
  # @param pc_power [Float] Combined PC power rating
  # @param mandatory_archetypes [Array<NpcArchetype>] Required NPCs
  # @param optional_archetypes [Array<NpcArchetype>] Available optional NPCs
  # @return [Hash] Composition { archetype_id => count }
  def self.estimate_balanced_composition(pc_power:, mandatory_archetypes:, optional_archetypes:)
    target_power = pc_power * BALANCED_POWER_RATIO

    # Cache power calculations to avoid redundant computation
    power_cache = {}
    (mandatory_archetypes + optional_archetypes).each do |a|
      power_cache[a.id] = calculate_archetype_power(a)
    end

    # Calculate mandatory power
    mandatory_power = mandatory_archetypes.sum { |a| power_cache[a.id] }

    # Start with mandatory NPCs
    composition = mandatory_archetypes.each_with_object({}) do |archetype, hash|
      hash[archetype.id] = { count: 1, power: power_cache[archetype.id] }
    end

    # Fill remaining power budget with optional NPCs
    remaining = target_power - mandatory_power

    if remaining > 0 && optional_archetypes.any?
      # Sort by power (strongest first for better distribution)
      sorted_optional = optional_archetypes.sort_by { |a| -power_cache[a.id] }

      sorted_optional.each do |archetype|
        break if remaining <= 0

        power = power_cache[archetype.id]
        next if power <= 0 # Skip archetypes with zero or negative power

        # Calculate how many of this type we can add
        count = [remaining / power, 0].max.floor

        if count > 0
          composition[archetype.id] = { count: count, power: power }
          remaining -= count * power
        end
      end
    end

    composition
  end

  # Apply stat modifiers to an archetype for difficulty scaling
  # @param archetype [NpcArchetype] Base archetype
  # @param modifier [Float] Difficulty modifier (-0.5 to 0.5)
  # @return [Hash] Modified combat stats
  def self.apply_difficulty_modifier(archetype, modifier)
    stats = archetype.combat_stats.dup

    # Apply modifier to all combat stats
    if modifier > 0
      # Making harder: increase damage, HP, speed
      stats[:damage_bonus] = ((stats[:damage_bonus] || 0) + (modifier * 3)).round
      stats[:max_hp] = ((stats[:max_hp] || 6) * (1 + modifier)).round
      stats[:speed_modifier] = ((stats[:speed_modifier] || 0) + (modifier * 2)).round
    else
      # Making easier: reduce damage, defense, speed
      reduction = modifier.abs
      stats[:damage_bonus] = [(stats[:damage_bonus] || 0) - (reduction * 3).round, 0].max
      stats[:defense_bonus] = [(stats[:defense_bonus] || 0) - (reduction * 2).round, 0].max
      stats[:speed_modifier] = [(stats[:speed_modifier] || 0) - (reduction * 2).round, -2].max
    end

    stats
  end

  # Convert a composition to SimParticipant array for simulation
  # @param composition [Hash] { archetype_id => { count:, power:, stat_modifiers: {} } }
  # @param stat_modifiers [Hash] Optional stat modifiers per archetype { archetype_id => modifier }
  # @return [Array<CombatSimulatorService::SimParticipant>]
  def self.composition_to_participants(composition, stat_modifiers: {})
    participants = []
    id_counter = 1000

    composition.each do |archetype_id, config|
      archetype_id_int = archetype_id.to_i
      archetype = NpcArchetype[archetype_id_int]
      next unless archetype

      count = config[:count] || config['count'] || 1
      modifier = stat_modifiers[archetype_id] ||
                 stat_modifiers[archetype_id_int] ||
                 stat_modifiers[archetype_id.to_s] || 0.0

      count.times do |i|
        stats = if modifier != 0.0
                  apply_difficulty_modifier(archetype, modifier)
                else
                  archetype.combat_stats
                end

        # Include combat abilities so simulations use them
        abilities = archetype.has_combat_abilities? ? archetype.combat_abilities : []
        ability_chance = stats[:ability_chance] || 30

        participants << CombatSimulatorService::SimParticipant.new(
          id: id_counter,
          name: "#{archetype.name} #{i + 1}",
          is_pc: false,
          team: 'npc',
          current_hp: stats[:max_hp] || 6,
          max_hp: stats[:max_hp] || 6,
          hex_x: 0,
          hex_y: 0,
          damage_bonus: stats[:damage_bonus] || 0,
          defense_bonus: stats[:defense_bonus] || 0,
          speed_modifier: stats[:speed_modifier] || 0,
          damage_dice_count: stats[:damage_dice_count] || 2,
          damage_dice_sides: stats[:damage_dice_sides] || 6,
          stat_modifier: 10,
          ai_profile: archetype.ai_profile || 'balanced',
          abilities: abilities,
          ability_chance: ability_chance
        )

        id_counter += 1
      end
    end

    participants
  end

  # Convert PC character IDs to SimParticipant array
  # @param character_ids [Array<Integer>] Character IDs
  # @return [Array<CombatSimulatorService::SimParticipant>]
  def self.pcs_to_participants(character_ids)
    characters = Character.where(id: character_ids).all

    characters.map.with_index do |char, i|
      # Try to get stat block from character's universe
      stat_block = nil
      if char.respond_to?(:universe) && char.universe
        stat_block = char.universe.default_stat_block
      end

      defaults = GameConfig::Power::DEFAULTS
      hp = stat_block ? (stat_block.total_points.to_i / defaults[:hp_divisor] + defaults[:hp_base]) : 6
      hp = [hp, defaults[:hp_floor]].max

      str = defaults[:stat_default]
      if char.respond_to?(:get_stat_value)
        str = char.get_stat_value('STR') ||
              char.get_stat_value('Strength') || defaults[:stat_default]
      end

      CombatSimulatorService::SimParticipant.new(
        id: char.id,
        name: char.full_name,
        is_pc: true,
        team: 'pc',
        current_hp: hp,
        max_hp: hp,
        hex_x: 0,
        hex_y: 0,
        damage_bonus: 0,
        defense_bonus: 0,
        speed_modifier: 0,
        damage_dice_count: 2,
        damage_dice_sides: 8,
        stat_modifier: str,
        ai_profile: 'balanced'
      )
    end
  end

  # Format power analysis for display
  # @param pc_power [Float]
  # @param composition [Hash]
  # @return [String]
  def self.format_analysis(pc_power:, composition:)
    npc_power = composition.sum { |_, c| (c[:count] || 1) * (c[:power] || 0) }

    lines = [
      "=== Power Analysis ===",
      "PC Power: #{pc_power.round(1)}",
      "NPC Power: #{npc_power.round(1)}",
      "Ratio: #{(npc_power / pc_power * 100).round(1)}% (target: #{(BALANCED_POWER_RATIO * 100).round}%)",
      "",
      "NPC Composition:"
    ]

    composition.each do |archetype_id, config|
      archetype = NpcArchetype[archetype_id]
      name = archetype&.name || "Archetype ##{archetype_id}"
      count = config[:count] || 1
      power = config[:power] || 0
      lines << "  #{count}x #{name} (power: #{power.round(1)} each)"
    end

    lines.join("\n")
  end
end
