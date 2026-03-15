#!/usr/bin/env ruby
# frozen_string_literal: true

# Load model concerns first (required for JsonbParsing etc)
Dir[File.join(__dir__, '../app/models/concerns/*.rb')].each { |f| require f }
require_relative '../config/application'
require 'yaml'

# ============================================
# Formula-Based Ability Balance Simulator
# ============================================
#
# Dynamically generates test abilities from STATUS_EFFECTS and targeting options,
# using mathematical formulas with tunable coefficients for power calculation.
#
# Two modes:
#   --fresh  : Start from math-derived initial coefficients
#   --refine : Use previously tuned coefficients from YAML (default)
#
# @example Auto-tune all abilities
#   ruby scripts/ability_balance_simulator.rb --synthetic-tune
#
# @example Fresh start (reset to math-derived values)
#   ruby scripts/ability_balance_simulator.rb --synthetic-tune --fresh
#
# @example Test a specific synthetic ability
#   ruby scripts/ability_balance_simulator.rb --synthetic=stun_1r
#

# ============================================
# Coefficient System (uses AbilityPowerWeights)
# ============================================

# This module wraps AbilityPowerWeights for coefficient access during simulation.
# After tuning, it exports coefficients to derived status weights.
module BalanceCoefficients
  # Math-derived initial values based on game assumptions
  INITIAL_COEFFICIENTS = {
    # CC effects (individual coefficients per ability)
    cc_stun_1r: 1.0,
    cc_stun_2r: 1.0,
    cc_daze_1r: 1.0,
    cc_daze_2r: 1.0,
    cc_daze_3r: 1.0,
    cc_prone_1r: 1.0,

    # Vulnerability (individual coefficients per ability)
    vuln_2x_2r: 1.0,
    vuln_3x_1r: 1.0,
    vuln_1_5x_3r: 1.0,

    # DoT (individual coefficients per ability)
    dot_burning_2r: 1.0,
    dot_burning_3r: 1.0,
    dot_poisoned_2r: 1.0,
    dot_poisoned_3r: 1.0,
    dot_bleeding_2r: 1.0,
    dot_bleeding_3r: 1.0,
    dot_freezing_2r: 1.0,
    dot_freezing_3r: 1.0,

    # Debuff (individual coefficients per ability)
    debuff_frightened_2r: 1.0,
    debuff_taunted_2r: 1.0,

    # Buff (individual coefficients per ability)
    buff_5dmg_2r: 1.0,
    buff_10dmg_1r: 1.0,
    buff_3dmg_3r: 1.0,

    # Mitigation per-hit (individual coefficients per ability)
    armor_3red_3r: 1.0,
    armor_4red_2r: 1.0,
    armor_6red_1r: 1.0,

    # Mitigation pool (individual coefficients per ability)
    protect_3red_3r: 1.0,
    protect_5red_2r: 1.0,
    protect_8red_1r: 1.0,

    # Shield (individual coefficients per ability)
    shield_10hp_3r: 1.0,
    shield_15hp_2r: 1.0,
    shield_20hp_2r: 1.0,

    # Healing
    heal_mult: 1.2,

    # AoE targets
    aoe_circle_r1: 1.5,
    aoe_circle_r2: 2.5,
    aoe_circle_r3: 4.0,
    aoe_circle_r4: 6.0,
    aoe_action_economy: 1.5,
    aoe_ff_penalty: 0.7,

    # Chain
    chain_target_efficiency: 0.8,

    # Special
    forced_movement_per_hex: 6.0,
    execute_threshold_mult: 0.5,
    lifesteal_efficiency: 0.3,

    # Duration
    duration_base: 1.0,
    duration_decay: 0.5,
    duration_max_factor: 2.5,
    dot_tick_decay: 0.7
  }.freeze

  BASELINE = {
    damage: 11,          # 2d10 average
    hp: 6,               # Standard combatant HP
    hits_per_round: 1,   # Average hits received per round
    rounds_per_fight: 4  # Average fight length
  }.freeze

  class << self
    def load!(mode: :refine)
      @mode = mode
      AbilityPowerWeights.reload!

      if mode == :fresh
        # Start with initial coefficients
        @coefficients = INITIAL_COEFFICIENTS.dup
      else
        # Load from AbilityPowerWeights
        @coefficients = load_from_weights
      end
      @baseline = BASELINE.dup
    end

    def get(key)
      @coefficients ||= load_from_weights
      @coefficients[key.to_sym] || INITIAL_COEFFICIENTS[key.to_sym]
    end

    def set(key, value)
      @coefficients ||= INITIAL_COEFFICIENTS.dup
      @coefficients[key.to_sym] = value
    end

    def baseline(key)
      @baseline ||= BASELINE.dup
      @baseline[key.to_sym]
    end

    def all
      @coefficients ||= INITIAL_COEFFICIENTS.dup
      @coefficients.dup
    end

    def save!
      # Save coefficients to AbilityPowerWeights
      @coefficients.each do |key, value|
        AbilityPowerWeights.set_coefficient(key.to_s, value)
      end

      # Also compute and save derived status weights
      export_derived_weights!

      AbilityPowerWeights.save!
    end

    def loaded?
      !@coefficients.nil?
    end

    # Export tuned coefficients to derived status power weights
    # This allows AbilityPowerCalculator to use pre-computed values
    def export_derived_weights!
      baseline_damage = baseline(:damage)
      hits = baseline(:hits_per_round)

      # === CC Effects (each has its own coefficient) ===
      # stunned: use 1r coefficient as default
      AbilityPowerWeights.set('status', 'stunned', baseline_damage * (get(:cc_stun_1r) || 1.0))

      # dazed: use 1r coefficient as default
      daze_penalty = 0.5
      AbilityPowerWeights.set('status', 'dazed', baseline_damage * daze_penalty * (get(:cc_daze_1r) || 1.0))

      # prone: single round
      prone_penalty = 0.8
      AbilityPowerWeights.set('status', 'prone', baseline_damage * prone_penalty * (get(:cc_prone_1r) || 1.0))

      # === DoTs (each has its own coefficient) ===
      dot_configs = {
        'burning' => { damage: 4, coef_2r: :dot_burning_2r, coef_3r: :dot_burning_3r },
        'poisoned' => { damage: 3, coef_2r: :dot_poisoned_2r, coef_3r: :dot_poisoned_3r },
        'bleeding' => { damage: 3, coef_2r: :dot_bleeding_2r, coef_3r: :dot_bleeding_3r },
        'freezing' => { damage: 4, coef_2r: :dot_freezing_2r, coef_3r: :dot_freezing_3r }
      }
      # Use the 2r coefficient as the default status weight (most common duration)
      dot_configs.each do |name, config|
        coef_value = get(config[:coef_2r]) || 1.0
        AbilityPowerWeights.set('status', name, config[:damage] * coef_value)
      end

      # === Vulnerability (each has its own coefficient) ===
      # Use vuln_2x_2r as the default status weight
      AbilityPowerWeights.set('status', 'vulnerable', baseline_damage * 1.0 * (get(:vuln_2x_2r) || 1.0))
      AbilityPowerWeights.set('status', 'vulnerable_2x', baseline_damage * 1.0 * (get(:vuln_2x_2r) || 1.0))
      AbilityPowerWeights.set('status', 'vulnerable_3x', baseline_damage * 2.0 * (get(:vuln_3x_1r) || 1.0))
      AbilityPowerWeights.set('status', 'vulnerable_1_5x', baseline_damage * 0.5 * (get(:vuln_1_5x_3r) || 1.0))

      # === Debuffs (each has its own coefficient) ===
      AbilityPowerWeights.set('status', 'frightened', baseline_damage * 0.25 * (get(:debuff_frightened_2r) || 1.0))
      AbilityPowerWeights.set('status', 'taunted', baseline_damage * 0.15 * (get(:debuff_taunted_2r) || 1.0))

      # === Buffs ===
      # Each buff ability has its own coefficient tuned individually
      buff_configs = {
        3 => { coef: :buff_3dmg_3r, duration: 3 },
        5 => { coef: :buff_5dmg_2r, duration: 2 },
        10 => { coef: :buff_10dmg_1r, duration: 1 }
      }
      buff_configs.each do |bonus, config|
        coef_value = get(config[:coef]) || 1.0
        AbilityPowerWeights.set('status', "empowered_#{bonus}dmg", bonus * coef_value)
      end

      # === Mitigation (each has its own coefficient) ===
      armor_configs = {
        3 => { coef: :armor_3red_3r, duration: 3 },
        4 => { coef: :armor_4red_2r, duration: 2 },
        6 => { coef: :armor_6red_1r, duration: 1 }
      }
      armor_configs.each do |reduction, config|
        coef_value = get(config[:coef]) || 1.0
        power = reduction * hits * coef_value
        AbilityPowerWeights.set('status', "armored_#{reduction}red", power)
      end

      protect_configs = {
        3 => { coef: :protect_3red_3r, duration: 3 },
        5 => { coef: :protect_5red_2r, duration: 2 },
        8 => { coef: :protect_8red_1r, duration: 1 }
      }
      protect_configs.each do |reduction, config|
        coef_value = get(config[:coef]) || 1.0
        power = reduction * coef_value
        AbilityPowerWeights.set('status', "protected_#{reduction}red", power)
      end

      # Default protected status (use 5red coefficient)
      AbilityPowerWeights.set('status', 'protected', 5 * (get(:protect_5red_2r) || 1.0))

      # === Shields (each has its own coefficient) ===
      shield_configs = {
        10 => { coef: :shield_10hp_3r, duration: 3 },
        15 => { coef: :shield_15hp_2r, duration: 2 },
        20 => { coef: :shield_20hp_2r, duration: 2 }
      }
      shield_configs.each do |hp, config|
        coef_value = get(config[:coef]) || 1.0
        AbilityPowerWeights.set('status', "shielded_#{hp}hp", hp * coef_value)
      end

      # === Healing ===
      AbilityPowerWeights.set('status', 'regenerating', 1 * get(:heal_mult))

      # === AoE targets ===
      (1..4).each do |r|
        AbilityPowerWeights.set('aoe_circle', "radius_#{r}", get(:"aoe_circle_r#{r}"))
      end
      AbilityPowerWeights.set('aoe', 'action_economy_multiplier', get(:aoe_action_economy))
      AbilityPowerWeights.set('aoe', 'friendly_fire_penalty', get(:aoe_ff_penalty))

      # === Duration scaling ===
      AbilityPowerWeights.set('duration', 'base_factor', get(:duration_base))
      AbilityPowerWeights.set('duration', 'subsequent_factor', get(:duration_decay))
      AbilityPowerWeights.set('duration', 'max_factor', get(:duration_max_factor))
      AbilityPowerWeights.set('duration', 'dot_decay', get(:dot_tick_decay))

      # === Special mechanics ===
      AbilityPowerWeights.set('special', 'forced_movement_per_hex', get(:forced_movement_per_hex))
      AbilityPowerWeights.set('special', 'lifesteal_fraction', get(:lifesteal_efficiency))

      # === Chain ===
      AbilityPowerWeights.set('chain', 'target_efficiency', get(:chain_target_efficiency))
    end

    private

    def load_from_weights
      weights_coefs = AbilityPowerWeights.all_coefficients
      return INITIAL_COEFFICIENTS.dup if weights_coefs.empty?

      # Convert string keys to symbols and merge with defaults
      INITIAL_COEFFICIENTS.merge(weights_coefs.transform_keys(&:to_sym))
    end

    def duration_factor(duration)
      return get(:duration_base) if duration <= 1

      base = get(:duration_base)
      decay = get(:duration_decay)
      max_factor = get(:duration_max_factor)

      factor = base
      (2..duration).each do |round|
        factor += decay**(round - 1)
      end

      [factor, max_factor].min
    end

    def dot_duration_factor(duration)
      decay = get(:dot_tick_decay)
      factor = 0.0
      duration.times { |tick| factor += decay**tick }
      factor
    end
  end
end

# ============================================
# Dynamic Ability Generator
# ============================================

module AbilityGenerator
  # Import STATUS_EFFECTS from CombatSimulatorService
  STATUS_EFFECTS = CombatSimulatorService::STATUS_EFFECTS

  # Effect categories for formula-based calculation
  EFFECT_CATEGORIES = {
    cc_skip: %i[stunned],
    cc_penalty: %i[dazed prone],
    dot: %i[burning poisoned bleeding freezing],
    vulnerability: %i[vulnerable vulnerable_fire vulnerable_ice vulnerable_lightning vulnerable_physical],
    debuff: %i[frightened taunted],
    buff: %i[empowered],
    mitigation_per_hit: %i[armored],
    mitigation_pool: %i[protected],
    shield: %i[shielded],
    hot: %i[regenerating]
  }.freeze

  # Effects to skip (movement impairment has no effect in unlimited-range sim)
  SKIP_EFFECTS = %i[immobilized snared slowed grappled cleansed].freeze

  class << self
    def generate_all
      abilities = []

      # Phase 1: Isolated mechanics (one effect each)
      abilities += generate_cc_abilities
      abilities += generate_dot_abilities
      abilities += generate_vulnerability_abilities
      abilities += generate_debuff_abilities
      abilities += generate_buff_abilities
      abilities += generate_mitigation_abilities
      abilities += generate_shield_abilities

      # Phase 2: AoE variants (representative samples)
      abilities += generate_aoe_abilities

      abilities
    end

    # CC abilities - test stun and daze with different durations
    def generate_cc_abilities
      [
        # Stun: full action denial (individual coefficients)
        { name: 'stun_1r', effect: 'stunned', duration: 1, category: :cc_skip, coef_key: :cc_stun_1r },
        { name: 'stun_2r', effect: 'stunned', duration: 2, category: :cc_skip, coef_key: :cc_stun_2r },

        # Daze: 50% attack penalty (individual coefficients)
        { name: 'daze_1r', effect: 'dazed', duration: 1, category: :cc_penalty, coef_key: :cc_daze_1r },
        { name: 'daze_2r', effect: 'dazed', duration: 2, category: :cc_penalty, coef_key: :cc_daze_2r },
        { name: 'daze_3r', effect: 'dazed', duration: 3, category: :cc_penalty, coef_key: :cc_daze_3r },

        # Prone: defense penalty (only 1 round makes sense)
        { name: 'prone_1r', effect: 'prone', duration: 1, category: :cc_penalty, coef_key: :cc_prone_1r }
      ].map { |config| build_status_ability(config) }
    end

    # DoT abilities - test each dot type with 2-3 round durations
    def generate_dot_abilities
      dots = %w[burning poisoned bleeding freezing]
      abilities = []

      dots.each do |dot|
        effect_data = STATUS_EFFECTS[dot.to_sym]
        dot_damage = effect_data[:dot_damage] || 3

        [2, 3].each do |duration|
          # Each DoT ability gets its own coefficient
          coef_key = :"dot_#{dot}_#{duration}r"
          abilities << build_status_ability(
            name: "#{dot}_#{duration}r",
            effect: dot,
            duration: duration,
            category: :dot,
            coef_key: coef_key,
            dot_damage: dot_damage
          )
        end
      end

      abilities
    end

    # Vulnerability abilities - test different multipliers and durations
    def generate_vulnerability_abilities
      [
        { name: 'vuln_2x_2r', effect: 'vulnerable', duration: 2, damage_mult: 2.0, category: :vulnerability, coef_key: :vuln_2x_2r },
        { name: 'vuln_3x_1r', effect: 'vulnerable', duration: 1, damage_mult: 3.0, category: :vulnerability, coef_key: :vuln_3x_1r },
        { name: 'vuln_1.5x_3r', effect: 'vulnerable', duration: 3, damage_mult: 1.5, category: :vulnerability, coef_key: :vuln_1_5x_3r }
      ].map { |config| build_status_ability(config) }
    end

    # Debuff abilities - frightened and taunted
    def generate_debuff_abilities
      [
        { name: 'frightened_2r', effect: 'frightened', duration: 2, category: :debuff, coef_key: :debuff_frightened_2r },
        { name: 'taunted_2r', effect: 'taunted', duration: 2, category: :debuff, coef_key: :debuff_taunted_2r }
      ].map { |config| build_status_ability(config) }
    end

    # Buff abilities - empowered with different bonuses
    def generate_buff_abilities
      [
        { name: 'empower_5dmg_2r', effect: 'empowered', duration: 2, damage_bonus: 5, category: :buff, coef_key: :buff_5dmg_2r },
        { name: 'empower_10dmg_1r', effect: 'empowered', duration: 1, damage_bonus: 10, category: :buff, coef_key: :buff_10dmg_1r },
        { name: 'empower_3dmg_3r', effect: 'empowered', duration: 3, damage_bonus: 3, category: :buff, coef_key: :buff_3dmg_3r }
      ].map { |config| build_status_ability(config) }
    end

    # Mitigation abilities - armored (per-hit) and protected (pool)
    def generate_mitigation_abilities
      abilities = []

      # Armored: per-hit damage reduction (individual coefficients)
      [
        { name: 'armor_3red_3r', effect: 'armored', duration: 3, damage_reduction: 3, category: :mitigation_per_hit, coef_key: :armor_3red_3r },
        { name: 'armor_4red_2r', effect: 'armored', duration: 2, damage_reduction: 4, category: :mitigation_per_hit, coef_key: :armor_4red_2r },
        { name: 'armor_6red_1r', effect: 'armored', duration: 1, damage_reduction: 6, category: :mitigation_per_hit, coef_key: :armor_6red_1r }
      ].each { |config| abilities << build_status_ability(config) }

      # Protected: total damage reduction pool (individual coefficients)
      [
        { name: 'protect_3red_3r', effect: 'protected', duration: 3, damage_reduction: 3, category: :mitigation_pool, coef_key: :protect_3red_3r },
        { name: 'protect_5red_2r', effect: 'protected', duration: 2, damage_reduction: 5, category: :mitigation_pool, coef_key: :protect_5red_2r },
        { name: 'protect_8red_1r', effect: 'protected', duration: 1, damage_reduction: 8, category: :mitigation_pool, coef_key: :protect_8red_1r }
      ].each { |config| abilities << build_status_ability(config) }

      abilities
    end

    # Shield abilities - HP absorption pools
    def generate_shield_abilities
      [
        { name: 'shield_10hp_3r', effect: 'shielded', duration: 3, shield_hp: 10, category: :shield, coef_key: :shield_10hp_3r },
        { name: 'shield_15hp_2r', effect: 'shielded', duration: 2, shield_hp: 15, category: :shield, coef_key: :shield_15hp_2r },
        { name: 'shield_20hp_2r', effect: 'shielded', duration: 2, shield_hp: 20, category: :shield, coef_key: :shield_20hp_2r }
      ].map { |config| build_status_ability(config) }
    end

    # AoE abilities - representative samples
    def generate_aoe_abilities
      [
        # Circle AoE with different radii
        { name: 'aoe_circle_r2', damage_dice: '1d10', aoe_shape: 'circle', aoe_radius: 2, coef_key: :aoe_circle_r2 },
        { name: 'aoe_circle_r3', damage_dice: '1d8', aoe_shape: 'circle', aoe_radius: 3, coef_key: :aoe_circle_r3 },

        # AoE with status effect (combination test)
        { name: 'aoe_burning_r2', damage_dice: '1d6', aoe_shape: 'circle', aoe_radius: 2,
          status_effects: [{ 'effect' => 'burning', 'duration' => 2 }], coef_key: :aoe_circle_r2 }
      ].map { |config| build_aoe_ability(config) }
    end

    def find(name)
      generate_all.find { |a| a[:ability].name == name }&.then { |a| a[:ability] }
    end

    private

    def build_status_ability(config)
      name = config[:name]
      effect = config[:effect]
      duration = config[:duration]

      status_effect = { 'effect' => effect, 'duration' => duration }
      status_effect['damage_mult'] = config[:damage_mult] if config[:damage_mult]
      status_effect['damage_bonus'] = config[:damage_bonus] if config[:damage_bonus]
      status_effect['damage_reduction'] = config[:damage_reduction] if config[:damage_reduction]
      status_effect['shield_hp'] = config[:shield_hp] if config[:shield_hp]

      # Defensive/buff abilities have no damage - they're ally-targeted
      is_defensive = %i[shield mitigation_pool buff].include?(config[:category])
      damage_dice = is_defensive ? nil : '1d6'

      ability = SyntheticAbility.new(
        name: name,
        damage_dice: damage_dice,
        status_effects: [status_effect]
      )

      {
        ability: ability,
        category: config[:category],
        coef_key: config[:coef_key],
        effect: effect,
        duration: duration,
        dot_damage: config[:dot_damage],
        damage_mult: config[:damage_mult],
        damage_bonus: config[:damage_bonus],
        damage_reduction: config[:damage_reduction],
        shield_hp: config[:shield_hp]
      }
    end

    def build_aoe_ability(config)
      name = config[:name]
      status_effects = config[:status_effects] || []

      ability = SyntheticAbility.new(
        name: name,
        damage_dice: config[:damage_dice],
        aoe_shape: config[:aoe_shape],
        aoe_radius: config[:aoe_radius],
        status_effects: status_effects
      )

      {
        ability: ability,
        category: :aoe,
        coef_key: config[:coef_key],
        aoe_shape: config[:aoe_shape],
        aoe_radius: config[:aoe_radius]
      }
    end
  end
end

# ============================================
# Formula-Based Power Calculator
# ============================================

class FormulaPowerCalculator
  def initialize(ability_config)
    @config = ability_config
    @ability = ability_config[:ability]
  end

  def calculate_power
    power = base_damage_power
    power += effect_power
    power *= aoe_multiplier
    power
  end

  private

  def base_damage_power
    # For PC main action abilities, use unified roll expected value (10.3)
    if @ability.respond_to?(:is_pc_ability) && @ability.is_pc_ability && @ability.main_action?
      avg = GameConfig::Mechanics::UNIFIED_ROLL[:expected_value]
      # Add dice modifier average if present
      avg += @ability.average_modifier_dice if @ability.respond_to?(:average_modifier_dice)
      # Add flat damage modifier
      avg += @ability.damage_modifier.to_i
      return avg
    end

    return 0 unless @ability.base_damage_dice

    DiceNotationService.new(@ability.base_damage_dice).average
  end

  def effect_power
    return 0 unless @config[:category]

    duration = @config[:duration] || 1
    duration_factor = calculate_duration_factor(duration)
    baseline_damage = BalanceCoefficients.baseline(:damage)

    case @config[:category]
    when :cc_skip
      # Full action denial = lost attack - each CC has its own coefficient
      coef_key = @config[:coef_key] || :cc_stun_1r
      baseline_damage * BalanceCoefficients.get(coef_key) * duration_factor

    when :cc_penalty
      # Partial action denial (daze=50%, prone=80% defense penalty) - each has its own coefficient
      penalty = CombatSimulatorService::STATUS_EFFECTS[@config[:effect].to_sym][:attack_penalty] || 0.5
      coef_key = @config[:coef_key] || :cc_daze_1r
      baseline_damage * penalty * BalanceCoefficients.get(coef_key) * duration_factor

    when :dot
      # Damage over time with decay - each DoT has its own coefficient
      dot_damage = @config[:dot_damage] || 3
      dot_duration_factor = calculate_dot_duration_factor(duration)
      coef_key = @config[:coef_key] || :dot_burning_2r
      dot_damage * BalanceCoefficients.get(coef_key) * dot_duration_factor

    when :vulnerability
      # Extra damage from vulnerability multiplier - each has its own coefficient
      mult = @config[:damage_mult] || 2.0
      coef_key = @config[:coef_key] || :vuln_2x_2r
      baseline_damage * (mult - 1) * BalanceCoefficients.get(coef_key) * duration_factor

    when :debuff
      # Partial penalties (frightened=25%) - each debuff has its own coefficient
      effect_data = CombatSimulatorService::STATUS_EFFECTS[@config[:effect].to_sym]
      penalty = effect_data[:attack_penalty] ? (1.0 - effect_data[:attack_penalty]) : 0.25
      coef_key = @config[:coef_key] || :debuff_frightened_2r
      baseline_damage * penalty * BalanceCoefficients.get(coef_key) * duration_factor

    when :buff
      # Extra damage dealt - each buff ability has its own coefficient
      bonus = @config[:damage_bonus] || 5
      coef_key = @config[:coef_key] || :buff_5dmg_2r
      bonus * BalanceCoefficients.get(coef_key) * duration_factor

    when :mitigation_per_hit
      # Damage reduction per hit received - each armor ability has its own coefficient
      reduction = @config[:damage_reduction] || 2
      hits = BalanceCoefficients.baseline(:hits_per_round)
      coef_key = @config[:coef_key] || :armor_3red_3r
      reduction * hits * BalanceCoefficients.get(coef_key) * duration_factor

    when :mitigation_pool
      # Total damage reduction pool per round - each protect ability has its own coefficient
      reduction = @config[:damage_reduction] || 5
      coef_key = @config[:coef_key] || :protect_3red_3r
      reduction * BalanceCoefficients.get(coef_key) * duration_factor

    when :shield
      # HP absorption - duration matters because shield can be depleted or expire
      shield_hp = @config[:shield_hp] || 10
      coef_key = @config[:coef_key] || :shield_10hp_3r
      shield_hp * BalanceCoefficients.get(coef_key) * duration_factor

    when :hot
      # Heal over time
      heal = CombatSimulatorService::STATUS_EFFECTS[@config[:effect].to_sym][:hot_healing] || 1
      heal * BalanceCoefficients.get(:heal_mult) * duration_factor

    else
      0
    end
  end

  def aoe_multiplier
    return 1.0 unless @ability.has_aoe?

    case @ability.aoe_shape
    when 'circle'
      radius = @ability.aoe_radius || 1
      BalanceCoefficients.get(:"aoe_circle_r#{radius}") || 1.0
    else
      1.0
    end
  end

  def calculate_duration_factor(duration)
    # First round full value, subsequent rounds decay
    return BalanceCoefficients.get(:duration_base) if duration <= 1

    base = BalanceCoefficients.get(:duration_base)
    decay = BalanceCoefficients.get(:duration_decay)
    max_factor = BalanceCoefficients.get(:duration_max_factor)

    # Sum of geometric series: base + decay + decay^2 + ...
    factor = base
    (2..duration).each do |round|
      factor += decay**(round - 1)
    end

    [factor, max_factor].min
  end

  def calculate_dot_duration_factor(duration)
    # DoT uses different decay (damage accumulates)
    decay = BalanceCoefficients.get(:dot_tick_decay)
    factor = 0.0
    duration.times do |tick|
      factor += decay**tick
    end
    factor
  end
end

# ============================================
# Synthetic Ability (duck-types Ability model)
# ============================================

class SyntheticAbility
  attr_accessor :name, :base_damage_dice, :damage_modifier, :damage_modifier_dice,
                :damage_type, :aoe_shape, :aoe_radius, :aoe_length, :aoe_angle,
                :aoe_hits_allies, :applied_status_effects, :chain_config,
                :forced_movement, :lifesteal_max, :execute_threshold, :execute_effect,
                :combo_condition, :is_healing, :activation_segment,
                :costs, :conditional_damage, :damage_stat, :damage_multiplier,
                :applies_prone, :cooldown_seconds, :bypasses_resistances,
                :is_pc_ability, :action_type

  def initialize(name:, **attrs)
    @name = name
    @base_damage_dice = attrs[:damage_dice]
    @damage_modifier = attrs[:damage_modifier] || 0
    @damage_modifier_dice = attrs[:damage_modifier_dice]
    @damage_type = attrs[:damage_type] || 'physical'
    @damage_stat = attrs[:damage_stat]
    @damage_multiplier = attrs[:damage_multiplier] || 1.0
    @aoe_shape = attrs[:aoe_shape] || 'single'
    @aoe_radius = attrs[:aoe_radius]
    @aoe_length = attrs[:aoe_length]
    @aoe_angle = attrs[:aoe_angle]
    @aoe_hits_allies = attrs[:aoe_hits_allies] || false
    @applied_status_effects = attrs[:status_effects] || []
    @chain_config = attrs[:chain_config]
    @forced_movement = attrs[:forced_movement]
    @lifesteal_max = attrs[:lifesteal_max]
    @execute_threshold = attrs[:execute_threshold]
    @execute_effect = attrs[:execute_effect]
    @combo_condition = attrs[:combo_condition]
    @conditional_damage = attrs[:conditional_damage]
    @is_healing = attrs[:is_healing] || false
    @activation_segment = attrs[:activation_segment] || 50
    @costs = attrs[:costs] || {}
    @applies_prone = attrs[:applies_prone] || false
    @cooldown_seconds = attrs[:cooldown_seconds] || 0
    @bypasses_resistances = attrs[:bypasses_resistances] || false
    @is_pc_ability = attrs[:is_pc_ability] || false
    @action_type = attrs[:action_type] || 'main'
  end

  def main_action?
    @action_type == 'main'
  end

  # Get average damage, using PC unified roll for PC main actions
  # @param for_pc [Boolean] override PC ability detection
  # @return [Float] expected average damage
  def average_damage(for_pc: nil)
    use_pc = for_pc.nil? ? @is_pc_ability : for_pc

    base_avg = if use_pc && main_action?
                 GameConfig::Mechanics::UNIFIED_ROLL[:expected_value]
               elsif @base_damage_dice
                 DiceNotationService.new(@base_damage_dice).average
               else
                 0.0
               end

    base_avg + average_modifier_dice + (@damage_modifier || 0)
  end

  # Roll dice-based damage modifier (e.g., "+1d6", "-1d4")
  # @return [Integer] the rolled modifier (can be negative)
  def calculate_modifier_dice
    return 0 unless @damage_modifier_dice

    notation = @damage_modifier_dice.to_s.strip
    return 0 if notation.empty?

    if notation.start_with?('-')
      -DiceNotationService.roll(notation[1..])
    else
      DiceNotationService.roll(notation.delete_prefix('+'))
    end
  end

  # Get average value of dice modifier
  # @return [Float] expected value of dice modifier
  def average_modifier_dice
    return 0.0 unless @damage_modifier_dice

    notation = @damage_modifier_dice.to_s.strip
    return 0.0 if notation.empty?

    if notation.start_with?('-')
      -DiceNotationService.new(notation[1..]).average
    else
      DiceNotationService.new(notation.delete_prefix('+')).average
    end
  end

  def parsed_status_effects
    @applied_status_effects
  end

  def parsed_chain_config
    @chain_config
  end

  def parsed_forced_movement
    @forced_movement
  end

  def parsed_execute_effect
    @execute_effect
  end

  def parsed_combo_condition
    @combo_condition
  end

  def parsed_conditional_damage
    @conditional_damage || []
  end

  def parsed_costs
    @costs
  end

  def has_aoe?
    @aoe_shape && @aoe_shape != 'single'
  end

  def single_target?
    !has_aoe?
  end

  def has_chain?
    @chain_config && !@chain_config.empty?
  end

  def has_lifesteal?
    @lifesteal_max.to_i > 0
  end

  def has_execute?
    @execute_threshold.to_i > 0
  end

  def has_forced_movement?
    @forced_movement && !@forced_movement.empty?
  end

  def has_combo?
    @combo_condition && !@combo_condition.empty?
  end

  def has_conditional_damage?
    parsed_conditional_damage.any?
  end

  def healing_ability?
    @is_healing
  end

  def power
    # Use legacy calculator for now, will be replaced by FormulaPowerCalculator
    AbilityPowerCalculator.new(self).total_power
  end

  def power_scaled?
    false
  end
end

# ============================================
# Pure Damage Control Ability
# ============================================

class PureDamageControlAbility
  # Fixed base dice for control ability
  # Using 2d10+4 = 15 avg damage to match a standard ability's base damage
  BASE_DICE = '2d10+4'
  BASE_POWER = 15.0  # Average damage of 2d10+4

  attr_reader :target_power

  def initialize(target_power)
    @target_power = target_power
  end

  def name
    mult = power_multiplier.round(2)
    "Pure Damage (#{BASE_DICE} × #{mult})"
  end

  def base_damage_dice
    BASE_DICE
  end

  # The multiplier applied to ability damage only
  # Combat simulator checks power_scaled? && power_multiplier
  def power_multiplier
    @target_power / BASE_POWER
  end

  def damage_modifier
    0
  end

  def damage_type
    'physical'
  end

  def activation_segment
    50
  end

  def parsed_status_effects
    []
  end

  def applies_prone
    false
  end

  def has_aoe?
    false
  end

  def aoe_shape
    nil
  end

  def power_scaled?
    true
  end

  def power
    @target_power
  end

  def has_chain?
    false
  end

  def has_lifesteal?
    false
  end

  def has_forced_movement?
    false
  end

  def has_execute?
    false
  end

  def parsed_conditional_damage
    []
  end

  def parsed_chain_config
    nil
  end

  def parsed_forced_movement
    nil
  end

  def lifesteal_max
    0
  end
end

# ============================================
# Balance Simulator (locked parameters)
# ============================================

class BalanceSimulator
  # Simulation parameters - vary team size 2-5 for robustness
  TEAM_SIZES = (2..5).to_a
  BASE_HP = 6
  ABILITY_CHANCE = 33
  ARENA_SIZE = 20

  attr_reader :ability_config, :results

  def initialize(ability_config)
    @ability_config = ability_config
    @ability = ability_config[:ability]
    @results = { test_wins: 0, control_wins: 0, draws: 0 }
  end

  def run(iterations: 100, seed: nil, verbose: false)
    @verbose = verbose
    base_seed = seed || Random.new_seed
    team_rng = Random.new(base_seed)
    power = FormulaPowerCalculator.new(@ability_config).calculate_power

    iterations.times do |i|
      battle_seed = base_seed + i
      team_size = TEAM_SIZES[team_rng.rand(TEAM_SIZES.length)]

      test_team = build_team(@ability, team_size)
      control_team = build_team(PureDamageControlAbility.new(power), team_size)

      sim = CombatSimulatorService.new(
        pcs: test_team,
        npcs: control_team,
        arena_width: ARENA_SIZE,
        arena_height: ARENA_SIZE,
        seed: battle_seed,
        randomize_positions: true
      )
      result = sim.simulate!

      draw = result.npc_ko_count == 0 && result.pc_ko_count == 0

      if draw
        @results[:draws] += 1
        puts "Battle #{i + 1}: Draw (#{result.rounds_taken} rounds, #{team_size}v#{team_size})" if @verbose
      elsif result.pc_victory
        @results[:test_wins] += 1
        puts "Battle #{i + 1}: Test team wins (#{result.rounds_taken} rounds, #{team_size}v#{team_size})" if @verbose
      else
        @results[:control_wins] += 1
        puts "Battle #{i + 1}: Control team wins (#{result.rounds_taken} rounds, #{team_size}v#{team_size})" if @verbose
      end
    end

    @results
  end

  def win_rate
    total = @results.values.sum
    return 50.0 if total == 0

    ((@results[:test_wins] + (@results[:draws] * 0.5)).to_f / total * 100)
  end

  def balanced?(threshold: 2.0)
    (win_rate - 50).abs <= threshold
  end

  def report
    total = @results.values.sum
    test_rate = win_rate.round(1)
    control_rate = (@results[:control_wins].to_f / total * 100).round(1)
    power = FormulaPowerCalculator.new(@ability_config).calculate_power

    puts '=' * 60
    puts "Ability Balance Report: #{@ability.name}"
    puts '=' * 60
    puts "Formula Power: #{power.round(1)}"
    puts "Category: #{@ability_config[:category]}"
    puts "Coefficient: #{@ability_config[:coef_key]} = #{BalanceCoefficients.get(@ability_config[:coef_key])}"
    puts
    puts "Results (#{total} battles):"
    puts "  Test Team:    #{@results[:test_wins]} wins (#{test_rate}%)"
    puts "  Control Team: #{@results[:control_wins]} wins (#{control_rate}%)"
    puts "  Draws:        #{@results[:draws]}"
    puts

    deviation = (test_rate - 50).abs
    if deviation < 2
      puts "\e[32m✓ BALANCED\e[0m - Within 2% of 50/50"
    elsif deviation < 5
      puts "\e[33m~ CLOSE\e[0m - Within 5% of 50/50"
    else
      puts "\e[31m✗ UNBALANCED\e[0m - #{deviation.round(1)}% deviation"
    end
    puts '=' * 60
  end

  private

  def build_team(ability, team_size)
    # Use different ID ranges: test team 0-99, control team 100+
    id_offset = ability.is_a?(SyntheticAbility) ? 0 : 100
    team_size.times.map do |i|
      CombatSimulatorService::SimParticipant.new(
        id: id_offset + i,
        name: "Fighter-#{i + 1}",
        is_pc: ability.is_a?(SyntheticAbility),
        team: ability.is_a?(SyntheticAbility) ? 'test' : 'control',
        current_hp: BASE_HP,
        max_hp: BASE_HP,
        hex_x: 0,
        hex_y: 0,
        damage_bonus: 0,
        defense_bonus: 0,
        speed_modifier: 0,
        damage_dice_count: 2,
        damage_dice_sides: 10,
        stat_modifier: 0,
        ai_profile: 'aggressive',
        abilities: [ability],
        ability_chance: ABILITY_CHANCE,
        damage_multiplier: 1.0  # Both teams have same basic attacks - only abilities differ
      )
    end
  end
end

# ============================================
# Formula Auto-Tuner
# ============================================

class FormulaAutoTuner
  FINAL_VALIDATION_ITERATIONS = 200
  FINAL_THRESHOLD = 5.0

  attr_reader :results

  def initialize(mode: :refine)
    @mode = mode
    @results = { tuned: [], validated: [], failed: [] }
  end

  def run(verbose: false)
    @verbose = verbose
    BalanceCoefficients.load!(mode: @mode)

    puts '=' * 70
    puts 'FORMULA-BASED ABILITY AUTO-TUNING'
    puts '=' * 70
    puts "Mode: #{@mode == :fresh ? 'FRESH (math-derived start)' : 'REFINE (use saved coefficients)'}"
    puts "Tuning: Grid search (#{GRID_SEARCH_POINTS.size} points) + local refinement"
    puts "  Grid search: #{GRID_SEARCH_POINTS.map { |p| p.to_s }.join(', ')}"
    puts "  Refinement: 7 points around best, 30 iterations each"
    puts "Final validation: #{FINAL_VALIDATION_ITERATIONS} iterations, ±#{FINAL_THRESHOLD}%"
    puts "Team sizes: #{BalanceSimulator::TEAM_SIZES.join(', ')} (varies each run)"
    puts '=' * 70
    puts

    # Phase 1: Tune isolated mechanics
    puts '=== PHASE 1: ISOLATED MECHANICS ==='
    puts
    tune_isolated_mechanics

    # Phase 2: Validate combinations
    puts
    puts '=== PHASE 2: COMBINATION VALIDATION ==='
    puts
    validate_combinations

    BalanceCoefficients.save!
    puts
    puts "Coefficients and weights saved to: #{AbilityPowerWeights.yaml_path}"

    print_summary
  end

  private

  def tune_isolated_mechanics
    AbilityGenerator.generate_all.each do |config|
      next unless config[:coef_key]

      tune_coefficient(config)
    end
  end

  # Grid search points for finding balance (handles non-monotonic curves from damage thresholds)
  GRID_SEARCH_POINTS = [0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 1.0, 1.5, 2.0, 3.0].freeze

  def tune_coefficient(config)
    ability = config[:ability]
    coef_key = config[:coef_key]

    print "[TUNE] #{ability.name} "

    original = BalanceCoefficients.get(coef_key)

    # Phase 1: Grid search to find approximate balance point
    # (handles non-monotonic curves from damage thresholds)
    print "G:"
    grid_results = []
    GRID_SEARCH_POINTS.each do |coef|
      clamped = clamp_coefficient(coef_key, coef)
      BalanceCoefficients.set(coef_key, clamped)

      sim = BalanceSimulator.new(config)
      sim.run(iterations: 200)
      rate = sim.win_rate
      grid_results << { coef: clamped, rate: rate, deviation: (rate - 50).abs }
      print '.'
    end

    # Find the coefficient closest to 50%
    best = grid_results.min_by { |r| r[:deviation] }
    current = best[:coef]
    print "\e[32m✓\e[0m "

    # Phase 2: Local refinement around the best point
    print "R:"
    refinement_range = [current * 0.5, current * 0.7, current * 0.85, current, current * 1.15, current * 1.3, current * 1.5]
    refinement_results = []

    refinement_range.each do |coef|
      clamped = clamp_coefficient(coef_key, coef)
      BalanceCoefficients.set(coef_key, clamped)

      sim = BalanceSimulator.new(config)
      sim.run(iterations: 200)
      rate = sim.win_rate
      refinement_results << { coef: clamped, rate: rate, deviation: (rate - 50).abs }
      print '.'
    end

    best_refined = refinement_results.min_by { |r| r[:deviation] }
    current = best_refined[:coef]
    print "\e[32m✓\e[0m "

    # Final validation with more iterations
    BalanceCoefficients.set(coef_key, current)
    sim = BalanceSimulator.new(config)
    sim.run(iterations: FINAL_VALIDATION_ITERATIONS)
    final_rate = sim.win_rate

    if (final_rate - 50).abs <= FINAL_THRESHOLD
      puts
      puts "  \e[32m✓\e[0m Balanced at #{final_rate.round(1)}% (#{coef_key}: #{format_value(original)} → #{format_value(current)})"
      @results[:tuned] << { name: ability.name, coef: coef_key, original: original, final: current, win_rate: final_rate }
    else
      puts
      puts "  \e[33m~\e[0m Close at #{final_rate.round(1)}% (#{coef_key}: #{format_value(original)} → #{format_value(current)})"
      @results[:tuned] << { name: ability.name, coef: coef_key, original: original, final: current, win_rate: final_rate, close: true }
    end
  end

  def validate_combinations
    # Test a few combination abilities to validate the tuned coefficients
    combinations = [
      { name: 'damage_stun', damage_dice: '2d10', status_effects: [{ 'effect' => 'stunned', 'duration' => 1 }] },
      { name: 'damage_burn', damage_dice: '2d10', status_effects: [{ 'effect' => 'burning', 'duration' => 2 }] }
    ]

    combinations.each do |combo|
      ability = SyntheticAbility.new(**combo)
      config = { ability: ability, category: :combination, coef_key: nil }

      sim = BalanceSimulator.new(config)
      sim.run(iterations: FINAL_VALIDATION_ITERATIONS)
      rate = sim.win_rate
      deviation = (rate - 50).abs

      status = if deviation <= FINAL_THRESHOLD
                 "\e[32m✓\e[0m"
               elsif deviation <= 10.0
                 "\e[33m~\e[0m"
               else
                 "\e[31m✗\e[0m"
               end

      puts "[VALID] #{ability.name}: #{rate.round(1)}% #{status}"
      @results[:validated] << { name: ability.name, win_rate: rate, deviation: deviation }
    end
  end

  def clamp_coefficient(key, value)
    # Allow much higher caps - the tuner needs room to find balance
    key_str = key.to_s
    case key
    when :heal_mult
      value.clamp(0.1, 10.0)
    else
      # Pattern match for individual coefficients by prefix
      case key_str
      when /^cc_/       # CC coefficients (cc_stun_1r, cc_daze_2r, etc.)
        value.clamp(0.1, 20.0)
      when /^dot_/      # DoT coefficients (dot_burning_2r, etc.)
        value.clamp(0.01, 15.0)
      when /^vuln_/     # Vulnerability coefficients (vuln_2x_2r, etc.)
        value.clamp(0.1, 15.0)
      when /^debuff_/   # Debuff coefficients (debuff_frightened_2r, etc.)
        value.clamp(0.1, 15.0)
      when /^buff_/     # Buff coefficients (buff_5dmg_2r, etc.)
        value.clamp(0.1, 15.0)
      when /^armor_/    # Armor coefficients (armor_3red_3r, etc.)
        value.clamp(0.1, 20.0)
      when /^protect_/  # Protection coefficients (protect_3red_3r, etc.)
        value.clamp(0.1, 20.0)
      when /^shield_/   # Shield coefficients (shield_10hp_3r, etc.)
        value.clamp(0.1, 20.0)
      when /^aoe_circle_r/
        value.clamp(0.5, 15.0)
      else
        value.clamp(0.1, 20.0)
      end
    end
  end

  def format_value(value)
    if value.is_a?(Float)
      format('%.2f', value)
    else
      value.to_s
    end
  end

  def print_summary
    puts
    puts '=' * 70
    puts 'SUMMARY'
    puts '=' * 70

    balanced = @results[:tuned].reject { |r| r[:close] }
    close = @results[:tuned].select { |r| r[:close] }

    puts "\n\e[32mBalanced (±#{FINAL_THRESHOLD}%): #{balanced.count}\e[0m"
    balanced.each do |r|
      change = r[:final] - r[:original]
      sign = change >= 0 ? '+' : ''
      mult = r[:original] > 0 ? (r[:final] / r[:original]).round(2) : 'N/A'
      puts "  #{r[:name]}: #{r[:coef]} #{format_value(r[:original])} → #{format_value(r[:final])} (#{mult}x) @ #{r[:win_rate].round(1)}%"
    end

    if close.any?
      puts "\n\e[33mClose (>±#{FINAL_THRESHOLD}%): #{close.count}\e[0m"
      close.each do |r|
        change = r[:final] - r[:original]
        sign = change >= 0 ? '+' : ''
        mult = r[:original] > 0 ? (r[:final] / r[:original]).round(2) : 'N/A'
        puts "  #{r[:name]}: #{r[:coef]} #{format_value(r[:original])} → #{format_value(r[:final])} (#{mult}x) @ #{r[:win_rate].round(1)}%"
      end
    end

    puts "\nValidated: #{@results[:validated].count}"
    @results[:validated].each do |r|
      status = r[:deviation] <= FINAL_THRESHOLD ? '✓' : (r[:deviation] <= 10 ? '~' : '✗')
      puts "  #{r[:name]}: #{r[:win_rate].round(1)}% (#{status})"
    end

    if @results[:failed].any?
      puts "\n\e[31mFailed: #{@results[:failed].count}\e[0m"
      @results[:failed].each do |r|
        puts "  #{r[:name]}: could not balance #{r[:coef]}"
      end
    end

    # Show final coefficient values
    puts "\n" + '=' * 70
    puts 'FINAL COEFFICIENTS'
    puts '=' * 70
    BalanceCoefficients.all.each do |key, value|
      puts "  #{key}: #{format_value(value)}"
    end
  end
end

# ============================================
# Command Line Interface
# ============================================

def print_usage
  puts 'Formula-Based Ability Balance Simulator'
  puts '=' * 50
  puts
  puts 'Usage: ruby ability_balance_simulator.rb [options]'
  puts
  puts 'Options:'
  puts '  --synthetic-tune      Auto-tune using formula-based approach'
  puts '  --fresh               Start from math-derived initial values (with --synthetic-tune)'
  puts '  --synthetic=NAME      Test a specific synthetic ability'
  puts '  --list-synthetic      List all available synthetic test abilities'
  puts '  --iterations=N        Number of battles per test (default: 500)'
  puts '  --verbose             Show detailed progress'
  puts '  --help                Show this help'
  puts
  puts 'Examples:'
  puts '  ruby ability_balance_simulator.rb --synthetic-tune'
  puts '  ruby ability_balance_simulator.rb --synthetic-tune --fresh --verbose'
  puts '  ruby ability_balance_simulator.rb --synthetic=stun_1r'
  puts '  ruby ability_balance_simulator.rb --list-synthetic'
end

def list_synthetic_abilities
  BalanceCoefficients.load!(mode: :refine)

  puts 'Synthetic Test Abilities'
  puts '=' * 80
  puts
  puts format('%-25s %10s %20s %s', 'Name', 'Power', 'Coefficient', 'Category')
  puts '-' * 80

  AbilityGenerator.generate_all.each do |config|
    ability = config[:ability]
    power = FormulaPowerCalculator.new(config).calculate_power
    coef = config[:coef_key] || 'validate'
    category = config[:category] || 'combo'
    puts format('%-25s %10.1f %20s %s', ability.name[0..24], power, coef.to_s[0..19], category)
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    iterations: 500,
    verbose: false,
    synthetic_tune: false,
    fresh: false,
    synthetic_ability: nil
  }

  args = ARGV.dup
  args.reject! do |arg|
    case arg
    when '--help', '-h'
      print_usage
      exit 0
    when '--list-synthetic'
      list_synthetic_abilities
      exit 0
    when '--verbose', '-v'
      options[:verbose] = true
      true
    when '--synthetic-tune'
      options[:synthetic_tune] = true
      true
    when '--fresh'
      options[:fresh] = true
      true
    when /^--synthetic=(.+)$/
      options[:synthetic_ability] = ::Regexp.last_match(1)
      true
    when /^--iterations=(\d+)$/
      options[:iterations] = ::Regexp.last_match(1).to_i
      true
    else
      false
    end
  end

  # Synthetic auto-tune mode
  if options[:synthetic_tune]
    mode = options[:fresh] ? :fresh : :refine
    tuner = FormulaAutoTuner.new(mode: mode)
    tuner.run(verbose: options[:verbose])
    exit 0
  end

  # Test a specific synthetic ability
  if options[:synthetic_ability]
    BalanceCoefficients.load!(mode: :refine)

    config = AbilityGenerator.generate_all.find { |c| c[:ability].name == options[:synthetic_ability] }
    unless config
      puts "Error: Synthetic ability '#{options[:synthetic_ability]}' not found"
      puts
      puts 'Available synthetic abilities:'
      AbilityGenerator.generate_all.each { |c| puts "  #{c[:ability].name}" }
      exit 1
    end

    ability = config[:ability]
    power = FormulaPowerCalculator.new(config).calculate_power

    puts "Testing synthetic ability: #{ability.name}"
    puts "Formula Power: #{power.round(1)}"
    puts "Category: #{config[:category]}"
    puts "Coefficient: #{config[:coef_key]}"
    puts
    puts "Running #{options[:iterations]} battle simulations..."
    puts

    sim = BalanceSimulator.new(config)
    sim.run(iterations: options[:iterations], verbose: options[:verbose])
    sim.report
    exit 0
  end

  # Default: show usage
  print_usage
end
