# frozen_string_literal: true

# Calculates the "power" rating of an ability for balance comparison.
# 100 power = 15 average damage to a single target.
#
# Power components:
# - Base damage (scaled by power_per_damage weight)
# - AoE multiplier (more targets = more power)
# - Chain/bounce damage
# - Status effect values (from ability_power_weights.csv)
# - Special mechanics (execute, lifesteal, knockdown, etc.)
# - Cost penalties (cooldowns, willpower, to-hit penalties)
#
# All weights are loaded from config/ability_power_weights.csv and can be
# auto-tuned using the ability balance simulator.
#
# @example
#   calc = AbilityPowerCalculator.new(ability)
#   calc.total_power  # => 145
#   calc.breakdown    # => { base_damage: 100, aoe_bonus: 50, status_effects: 40, ... }
#
class AbilityPowerCalculator
  # Pre-calculated P(2d8 exploding >= X) for threshold checks
  # Used to reduce effect power when threshold makes effect unreliable
  THRESHOLD_PROBABILITIES = {
    2 => 1.00, 3 => 0.98, 4 => 0.95, 5 => 0.91, 6 => 0.84,
    7 => 0.77, 8 => 0.67, 9 => 0.56, 10 => 0.47, 11 => 0.38,
    12 => 0.30, 13 => 0.23, 14 => 0.17, 15 => 0.13, 16 => 0.09,
    17 => 0.06, 18 => 0.05, 19 => 0.03, 20 => 0.02
  }.freeze

  attr_reader :ability, :for_pc

  # @param ability [Ability] the ability to calculate power for
  # @param for_pc [Boolean] if true, uses PC unified roll (10.3) for main actions
  def initialize(ability, for_pc: false)
    @ability = ability
    @for_pc = for_pc || ability_is_pc?
  end

  private

  # Check if ability indicates it's for PC use
  # Synthetic abilities may have is_pc_ability attribute
  def ability_is_pc?
    return ability.is_pc_ability if ability.respond_to?(:is_pc_ability)
    return ability.pc_ability? if ability.respond_to?(:pc_ability?)
    return ability.user_type.to_s == 'pc' if ability.respond_to?(:user_type)

    false
  end

  public

  # Get total power rating rounded to integer
  # @return [Integer] total power
  def total_power
    breakdown.values.sum.round
  end

  # Get detailed breakdown of power components
  # @return [Hash] power by component
  def breakdown
    @breakdown ||= calculate_breakdown
  end

  private

  # Weight accessors with fallbacks
  def weights
    AbilityPowerWeights
  end

  def power_per_damage
    weights.global('power_per_damage') || GameConfig::AbilityPower::DEFAULT_POWER_PER_DAMAGE
  end

  def dot_penalty
    weights.global('dot_penalty') || GameConfig::AbilityPower::DEFAULT_DOT_PENALTY
  end

  def healing_multiplier
    weights.global('healing_multiplier') || GameConfig::AbilityPower::DEFAULT_HEALING_MULTIPLIER
  end

  def stat_bonus_assumed
    weights.global('stat_bonus_assumed') || GameConfig::AbilityPower::DEFAULT_STAT_BONUS
  end

  def status_power(effect_name)
    weights.status(effect_name, default: 15)
  end

  # Calculate probability of meeting a threshold roll
  # @param threshold [Integer] minimum roll needed
  # @return [Float] probability between 0 and 1
  def calculate_threshold_probability(threshold)
    return 1.0 if threshold.nil? || threshold <= 2
    return 0.01 if threshold > 20

    THRESHOLD_PROBABILITIES[threshold.clamp(2, 20)] || 0.01
  end

  # Build a specific weight key for variable status effects
  # Examples:
  #   armored + damage_reduction:4 => "armored_4red"
  #   shielded + shield_hp:10 => "shielded_10hp"
  #   empowered + damage_bonus:5 => "empowered_5dmg"
  #   protected + damage_reduction:5 => "protected_5red"
  #   vulnerable + damage_mult:2.0 => "vulnerable_2x"
  def build_status_weight_key(name, effect)
    name = name.to_s.downcase

    case name
    when 'armored'
      reduction = effect['damage_reduction']&.to_i || effect['reduction']&.to_i
      reduction ? "armored_#{reduction}red" : name
    when 'shielded'
      shield_hp = effect['shield_hp']&.to_i || effect['amount']&.to_i
      shield_hp ? "shielded_#{shield_hp}hp" : name
    when 'empowered'
      bonus = effect['damage_bonus']&.to_i || effect['bonus']&.to_i
      bonus ? "empowered_#{bonus}dmg" : name
    when 'protected'
      reduction = effect['damage_reduction']&.to_i || effect['reduction']&.to_i
      reduction ? "protected_#{reduction}red" : name
    when 'vulnerable'
      mult = effect['damage_mult']&.to_f || effect['multiplier']&.to_f
      if mult && mult.positive?
        formatted_mult = if (mult % 1.0).zero?
                           mult.to_i.to_s
                         else
                           format('%.2f', mult).sub(/0+$/, '').sub(/\.$/, '').tr('.', '_')
                         end
        "vulnerable_#{formatted_mult}x"
      else
        name
      end
    else
      name
    end
  end

  def calculate_breakdown
    components = {}

    components[:base_damage] = calculate_base_damage_power
    components[:aoe_bonus] = calculate_aoe_bonus
    components[:chain_bonus] = calculate_chain_bonus
    components[:status_effects] = calculate_status_power
    components[:special_mechanics] = calculate_special_mechanics_power

    power_before = components.values.sum
    components[:cost_penalties] = calculate_cost_penalties(power_before)

    components
  end

  # Normalize status-effect chance to 0.0..1.0.
  # Accepts both fractional storage (0.75) and legacy percent-style values (75).
  def normalize_effect_chance(value)
    chance = value.nil? ? 1.0 : value.to_f
    chance /= 100.0 if chance > 1.0
    chance.clamp(0.0, 1.0)
  end

  # ============================================
  # Base Damage Power
  # ============================================

  def calculate_base_damage_power
    # For PC main action abilities, use unified roll expected value (10.3)
    # Otherwise, use base_damage_dice average
    if for_pc && ability.main_action?
      avg = GameConfig::Mechanics::UNIFIED_ROLL[:expected_value]
      # Add dice modifier average if present
      avg += ability.average_modifier_dice if ability.respond_to?(:average_modifier_dice)
      # Add flat damage modifier
      avg += ability.damage_modifier.to_i
    elsif ability.base_damage_dice
      # Use ability's average_damage which now includes modifier calculations
      avg = ability.average_damage.to_f
    else
      return 0
    end

    power = avg * power_per_damage

    # Add stat scaling bonus (assume average modifier)
    if ability.damage_stat && !ability.damage_stat.to_s.empty?
      power += stat_bonus_assumed * power_per_damage
    end

    # Apply damage multiplier if present
    if ability.damage_multiplier && ability.damage_multiplier != 1.0
      power *= ability.damage_multiplier.to_f
    end

    # Healing is worth less than damage
    power *= healing_multiplier if ability.is_healing

    power
  end

  # ============================================
  # AoE Bonus (multi-target damage)
  # ============================================

  def calculate_aoe_bonus
    targets = target_count_estimate
    return 0 if targets <= 1.0

    base = calculate_base_damage_power
    target_multiplier = targets - 1.0  # -1 because base already counts 1 target

    # Action economy multiplier: AoE has non-linear combat advantage because
    # eliminating multiple enemies reduces their total actions faster.
    # This is tunable via aoe_action_economy weight (default 1.5).
    action_economy = weights.get('aoe', 'action_economy_multiplier', default: 1.5)
    if ability.respond_to?(:aoe_hits_allies) && ability.aoe_hits_allies
      ff_penalty = weights.get('aoe', 'friendly_fire_penalty', default: 0.7)
      action_economy *= ff_penalty
    end

    base * target_multiplier * action_economy
  end

  def target_count_estimate
    case ability.aoe_shape
    when 'circle'
      weights.aoe_circle_targets(ability.aoe_radius.to_i.nonzero? || 1)
    when 'cone'
      cone_target_estimate(
        ability.aoe_length.to_i.nonzero? || 2,
        ability.aoe_angle.to_i.nonzero? || 60
      )
    when 'line'
      line_divisor = weights.get('aoe_line', 'divisor', default: 2.0)
      [(ability.aoe_length.to_i.nonzero? || 3) / line_divisor, 1].max
    else
      1.0
    end
  end

  def cone_target_estimate(length, angle)
    divisor = weights.get('aoe_cone', 'base_divisor', default: 2.0)
    minimum = weights.get('aoe_cone', 'minimum', default: 1.5)

    base = length * (angle / 60.0) / divisor
    [base, minimum].max
  end

  # ============================================
  # Chain/Bounce Bonus
  # ============================================

  def calculate_chain_bonus
    return 0 unless ability.has_chain?

    config = ability.parsed_chain_config
    default_targets = weights.get('chain', 'default_max_targets', default: 3)
    default_falloff = weights.get('chain', 'default_falloff', default: 0.5)

    max_targets = config['max_targets']&.to_i || default_targets
    falloff = config['damage_falloff']&.to_f || default_falloff
    efficiency = weights.get('chain', 'target_efficiency', default: 1.0)

    # Calculate total damage multiplier across bounces
    chain_total = (1...max_targets).sum { |i| falloff**i }

    base = calculate_base_damage_power
    base * chain_total * efficiency
  end

  # ============================================
  # Status Effect Power
  # ============================================

  def calculate_status_power
    effects = ability.parsed_status_effects || []
    return 0 if effects.empty?

    total = effects.sum do |effect|
      name = effect['effect'] || effect['effect_name'] || effect['name']
      name = name.to_s

      chance = normalize_effect_chance(effect['chance'])
      duration = effect['duration_rounds'] || effect['duration'] || 1
      duration = duration.to_i

      # Calculate threshold probability for effects with effect_threshold
      # This reduces power for effects that only apply on high rolls
      threshold = effect['effect_threshold']&.to_i
      threshold_probability = calculate_threshold_probability(threshold)

      # Build specific key for variable status effects
      weight_key = build_status_weight_key(name, effect)
      base_power = status_power(weight_key)

      # Different duration scaling based on effect type
      duration_factor = if dot_effect?(name) || hot_effect?(name)
                          # DOTs/HOTs use geometric decay: later ticks worth less
                          # (you might cleanse it, or die before it finishes)
                          decay = weights.get('duration', 'dot_decay', default: 0.7)
                          (0...duration).sum { |i| decay**i }
                        else
                          # CC/buffs/debuffs use geometric decay like simulator tuning.
                          base = weights.get('duration', 'base_factor', default: 1.0)
                          subsequent = weights.get('duration', 'subsequent_factor', default: 0.5)
                          max = weights.get('duration', 'max_factor', default: 2.5)
                          if duration <= 1
                            base
                          else
                            factor = base
                            (2..duration).each do |round|
                              factor += subsequent**(round - 1)
                            end
                            [factor, max].min
                          end
                        end

      # Combine base power with chance, threshold probability, and duration
      effect_power = (base_power * chance * threshold_probability * duration_factor).round

      # Apply healing multiplier to HOTs (like DOT formula * healing_multiplier)
      effect_power = (effect_power * healing_multiplier).round if hot_effect?(name)

      effect_power
    end

    # Also add power for applies_prone (knockdown)
    total += status_power('prone') if ability.applies_prone

    total
  end

  # Check if effect is a damage-over-time effect
  def dot_effect?(name)
    %w[burning poisoned bleeding freezing].include?(name.to_s.downcase)
  end

  # Check if effect is a heal-over-time effect
  def hot_effect?(name)
    %w[regenerating healing_amplified].include?(name.to_s.downcase)
  end

  # ============================================
  # Special Mechanics Power
  # ============================================

  def calculate_special_mechanics_power
    power = 0

    power += calculate_execute_power
    power += calculate_forced_movement_power
    power += calculate_lifesteal_power
    power += calculate_conditional_damage_power
    power += calculate_combo_power

    if ability.bypasses_resistances
      power += weights.get('special', 'resistance_bypass', default: 15)
    end

    power
  end

  def calculate_execute_power
    return 0 unless ability.has_execute?

    execute = ability.parsed_execute_effect || {}

    if execute['instant_kill']
      weights.get('special', 'execute_instant_kill', default: 50)
    else
      multiplier = execute['damage_multiplier']&.to_f || 2.0
      base = weights.get('special', 'execute_multiplier_base', default: 20)
      (base * (multiplier - 1)).round
    end
  end

  def calculate_forced_movement_power
    return 0 unless ability.has_forced_movement?

    movement = ability.parsed_forced_movement
    distance = movement['distance']&.to_i || 1
    per_hex = weights.get('special', 'forced_movement_per_hex', default: 5)

    distance * per_hex
  end

  def calculate_lifesteal_power
    return 0 unless ability.has_lifesteal?

    base_damage_avg = calculate_base_damage_power / power_per_damage
    lifesteal_cap = ability.lifesteal_max.to_f
    return 0 if lifesteal_cap <= 0

    # Lifesteal is capped healing per hit, not percent-based.
    expected_lifesteal = [base_damage_avg, lifesteal_cap].min
    efficiency = weights.get('special', 'lifesteal_fraction', default: 1.0)
    (expected_lifesteal * power_per_damage * healing_multiplier * efficiency).round
  end

  def calculate_conditional_damage_power
    return 0 unless ability.has_conditional_damage?

    conditions = ability.parsed_conditional_damage
    return 0 if conditions.empty?

    trigger_rate = weights.get('special', 'conditional_trigger_rate', default: 0.5)

    conditions.sum do |cond|
      bonus_dice = cond['bonus_dice'].to_s
      next 0 if bonus_dice.empty?

      begin
        bonus_avg = DiceNotationService.new(bonus_dice).average
      rescue StandardError => e
        warn "[AbilityPowerCalculator] Invalid conditional dice '#{bonus_dice}': #{e.message}"
        next 0
      end
      (bonus_avg * power_per_damage * trigger_rate).round
    end
  end

  def calculate_combo_power
    return 0 unless ability.has_combo?

    combo = ability.parsed_combo_condition
    bonus_dice = combo['bonus_dice'].to_s
    return 0 if bonus_dice.empty?

    trigger_rate = weights.get('special', 'combo_trigger_rate', default: 0.3)
    begin
      bonus_avg = DiceNotationService.new(bonus_dice).average
    rescue StandardError => e
      warn "[AbilityPowerCalculator] Invalid combo dice '#{bonus_dice}': #{e.message}"
      return 0
    end
    (bonus_avg * power_per_damage * trigger_rate).round
  end

  # ============================================
  # Cost Penalties (reduce power)
  # ============================================

  def calculate_cost_penalties(power_before_costs = nil)
    power_before_costs ||= calculate_base_damage_power + calculate_aoe_bonus +
                           calculate_chain_bonus + calculate_status_power +
                           calculate_special_mechanics_power

    penalties = 0
    costs = ability.parsed_costs || {}

    # Cooldown penalty
    if ability.cooldown_seconds.to_i > 0
      max_penalty = weights.get('cost', 'cooldown_max_penalty_pct', default: 0.2)
      divisor = weights.get('cost', 'cooldown_seconds_divisor', default: 300)
      cd_penalty_pct = [ability.cooldown_seconds / divisor.to_f, max_penalty].min
      penalties -= (power_before_costs * cd_penalty_pct).round
    end

    # Ability penalty (to-hit reduction - amount is negative, e.g. -2)
    if costs['ability_penalty']
      penalty_amount = costs.dig('ability_penalty', 'amount')&.to_i || 0
      per_point = weights.get('cost', 'ability_penalty_per_point', default: 5)
      penalties += penalty_amount * per_point
    end

    # All-roll penalty (roll penalty - amount is negative, e.g. -1)
    if costs['all_roll_penalty']
      penalty_amount = costs.dig('all_roll_penalty', 'amount')&.to_i || 0
      per_point = weights.get('cost', 'all_roll_penalty_per_point', default: 3)
      penalties += penalty_amount * per_point
    end

    # Specific cooldown (rounds)
    specific_cd = costs.dig('specific_cooldown', 'rounds')&.to_i || 0
    if specific_cd > 0
      per_round = weights.get('cost', 'specific_cooldown_per_round', default: 0.05)
      max_pct = weights.get('cost', 'specific_cooldown_max_pct', default: 0.25)
      cd_penalty_pct = [specific_cd * per_round, max_pct].min
      penalties -= (power_before_costs * cd_penalty_pct).round
    end

    penalties
  end
end
