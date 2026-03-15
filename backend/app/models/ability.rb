# frozen_string_literal: true

# Ability represents a combat or non-combat power that characters can use.
# Can require main action, tactical action, or be passive.
# Supports configurable targeting, timing, AoE shapes, damage, and costs.
class Ability < Sequel::Model
  include JsonbParsing

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  one_to_many :character_abilities
  one_to_many :fight_participants, key: :ability_id

  ABILITY_TYPES = %w[combat utility passive social crafting].freeze
  ACTION_TYPES = %w[main tactical free passive reaction].freeze
  TARGET_TYPES = %w[self ally enemy].freeze
  AOE_SHAPES = %w[single circle cone line].freeze
  DAMAGE_TYPES = %w[fire ice lightning physical holy shadow poison healing].freeze
  USER_TYPES = %w[pc npc].freeze  # Separate pools - PC uses unified roll, NPC uses specified dice

  def validate
    super
    validates_presence [:name, :ability_type]
    validates_max_length 100, :name
    validates_unique [:universe_id, :name]
    validates_includes ABILITY_TYPES, :ability_type
    validates_includes ACTION_TYPES, :action_type if self[:action_type]
    validates_includes TARGET_TYPES, :target_type if self[:target_type]
    validates_includes AOE_SHAPES, :aoe_shape if self[:aoe_shape]
    validates_includes USER_TYPES, :user_type if self[:user_type]
    validates_numeric :activation_segment if self[:activation_segment]
    validates_numeric :aoe_radius if self[:aoe_radius]
    validates_numeric :aoe_length if self[:aoe_length]
    validates_numeric :aoe_angle if self[:aoe_angle]

    if self[:activation_segment] && !(0..100).cover?(activation_segment.to_i)
      errors.add(:activation_segment, 'must be between 0 and 100')
    end
    if self[:aoe_radius] && aoe_radius.to_i < 0
      errors.add(:aoe_radius, 'must be greater than or equal to 0')
    end
    if self[:aoe_length] && aoe_length.to_i < 0
      errors.add(:aoe_length, 'must be greater than or equal to 0')
    end
    if self[:aoe_angle] && !(0..360).cover?(aoe_angle.to_i)
      errors.add(:aoe_angle, 'must be between 0 and 360')
    end

    validate_dice_notation(:base_damage_dice)
    validate_dice_notation(:damage_modifier_dice, allow_signed: true)
  end

  def before_save
    super
    self[:action_type] ||= 'main'
    self[:target_type] ||= 'enemy'
    self[:aoe_shape] ||= 'single'
    self[:user_type] ||= 'npc'
    self[:activation_segment] ||= GameConfig::AbilityDefaults::ACTIVATION_SEGMENT
    self[:cooldown_seconds] ||= GameConfig::AbilityDefaults::COOLDOWN_SECONDS
  end

  def after_save
    super
    clear_memoized_jsonb!
  end

  # === Type Checks ===

  def combat?
    ability_type == 'combat'
  end

  def passive?
    action_type == 'passive'
  end

  def main_action?
    action_type == 'main'
  end

  def tactical_action?
    action_type == 'tactical'
  end

  def pc_ability?
    user_type == 'pc'
  end

  def npc_ability?
    user_type == 'npc'
  end

  def has_cooldown?
    cooldown_seconds.to_i > 0
  end
  alias cooldown? has_cooldown?

  # === AoE Helpers ===

  def single_target?
    aoe_shape.nil? || aoe_shape == 'single'
  end

  def has_aoe?
    !single_target?
  end
  alias aoe? has_aoe?

  def self_targeted?
    target_type == 'self'
  end

  def healing_ability?
    is_healing == true || damage_type == 'healing'
  end

  # Returns the range of this ability in hexes
  # Used by combat targeting to determine valid targets
  def range_in_hexes
    # Self-targeted abilities are always in range
    return 0 if self_targeted?

    # For line/cone abilities, use aoe_length if set
    if %w[line cone].include?(aoe_shape) && aoe_length.to_i > 0
      return aoe_length
    end

    # For circle AoE, use aoe_radius if set
    if aoe_shape == 'circle' && aoe_radius.to_i > 0
      return aoe_radius
    end

    # Default range from config for most abilities
    GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES
  end

  # === Cost Parsing ===

  # Parse costs from JSONB field (memoized)
  # @return [Hash] parsed cost configuration
  def parsed_costs
    @parsed_costs ||= parse_jsonb_hash(costs)
  end

  # Get ability penalty configuration
  # @return [Hash] { "amount" => -6, "decay_per_round" => 2 } or {}
  def ability_penalty_config
    parsed_costs['ability_penalty'] || {}
  end

  # Get all-roll penalty configuration
  # @return [Hash] { "amount" => -4, "decay_per_round" => 1 } or {}
  def all_roll_penalty_config
    parsed_costs['all_roll_penalty'] || {}
  end

  # Get specific cooldown (rounds this ability is unavailable after use)
  # @return [Integer] rounds of cooldown
  def specific_cooldown_rounds
    parsed_costs.dig('specific_cooldown', 'rounds').to_i
  end

  # Get global cooldown (rounds ALL abilities are unavailable after use)
  # @return [Integer] rounds of global cooldown
  def global_cooldown_rounds
    parsed_costs.dig('global_cooldown', 'rounds').to_i
  end

  # Check if ability has any cost
  def has_cost?
    ability_penalty_config.any? ||
      all_roll_penalty_config.any? ||
      specific_cooldown_rounds > 0 ||
      global_cooldown_rounds > 0
  end
  alias cost? has_cost?

  # === Status Effect Parsing ===

  # Parse applied status effects from JSONB field (memoized)
  # @return [Array<Hash>] list of status effect configurations
  def parsed_status_effects
    @parsed_status_effects ||= parse_jsonb_array(applied_status_effects)
  end

  # Check if ability applies any status effects
  def applies_status_effects?
    parsed_status_effects.any?
  end

  # === Damage Calculation ===

  # Roll damage for this ability
  # @param stat_modifier [Integer] stat bonus to add
  # @param bonus [Integer] additional bonus (willpower, etc.)
  # @return [Integer] total damage rolled
  def roll_damage(stat_modifier: 0, bonus: 0)
    return 0 unless base_damage_dice

    DiceNotationService.roll(base_damage_dice) + stat_modifier + bonus
  end

  # Get minimum possible damage
  # @return [Integer] minimum damage
  def min_damage
    return 0 unless base_damage_dice

    DiceNotationService.new(base_damage_dice).minimum
  end

  # Get maximum possible damage
  # @return [Integer] maximum damage
  def max_damage
    return 0 unless base_damage_dice

    DiceNotationService.new(base_damage_dice).maximum
  end

  # Get average damage
  # @param for_pc [Boolean] if true, uses PC unified roll expected value (10.3)
  # @return [Float] average damage
  def average_damage(for_pc: false)
    base_avg = if for_pc && main_action?
                 GameConfig::Mechanics::UNIFIED_ROLL[:expected_value]
               elsif base_damage_dice
                 DiceNotationService.new(base_damage_dice).average
               else
                 0.0
               end

    base_avg + average_modifier_dice + damage_modifier.to_i
  end

  # Roll dice-based damage modifier (e.g., "+1d6", "-1d4")
  # @return [Integer] the rolled modifier (can be negative)
  def calculate_modifier_dice
    return 0 unless damage_modifier_dice

    notation = damage_modifier_dice.to_s.strip
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
    return 0.0 unless damage_modifier_dice

    notation = damage_modifier_dice.to_s.strip
    return 0.0 if notation.empty?

    if notation.start_with?('-')
      -DiceNotationService.new(notation[1..]).average
    else
      DiceNotationService.new(notation.delete_prefix('+')).average
    end
  end

  # === Segment Timing ===

  # Calculate the actual activation segment with variance
  # @return [Integer] segment number (1-100)
  def calculate_activation_segment
    base = activation_segment || 50
    variance = segment_variance || 2
    (base + rand(-variance..variance)).clamp(1, 100)
  end

  # === Timing Coefficient ===

  # Get the effective timing coefficient for this ability.
  # Used for power balancing - earlier abilities have timing advantage.
  # @return [Float] coefficient between 0.0 and 1.0 (or 1.0 if disabled)
  def effective_timing_coefficient
    return 1.0 unless apply_timing_coefficient

    # Use stored coefficient, or calculate from activation segment
    timing_coefficient || ((activation_segment || 50) / 100.0)
  end

  # Get the base timing coefficient (before any manual adjustments).
  # Always calculated from activation_segment.
  # @return [Float] base coefficient between 0.01 and 1.0
  def base_timing_coefficient
    ((activation_segment || 50) / 100.0).clamp(0.01, 1.0)
  end

  # Check if timing coefficient is manually set (differs from calculated)
  # @return [Boolean] true if manually overridden
  def timing_coefficient_manually_set?
    return false unless timing_coefficient

    (timing_coefficient - base_timing_coefficient).abs > 0.001
  end

  # === Narrative Helpers ===

  # Get a random cast verb
  # @return [String] cast description
  def random_cast_verb
    verbs = parsed_cast_verbs
    return "uses #{name}" if verbs.empty?

    verbs.sample
  end

  # Get a random hit verb
  # @return [String] hit description
  def random_hit_verb
    verbs = parsed_hit_verbs
    return 'hits' if verbs.empty?

    verbs.sample
  end

  # Get a random AoE description
  # @return [String] AoE spread description
  def random_aoe_description
    descs = parsed_aoe_descriptions
    return 'also hits' if descs.empty?

    descs.sample
  end

  # Parse cast verbs from JSONB (memoized)
  def parsed_cast_verbs
    @parsed_cast_verbs ||= parse_jsonb_array(cast_verbs)
  end

  # Parse hit verbs from JSONB (memoized)
  def parsed_hit_verbs
    @parsed_hit_verbs ||= parse_jsonb_array(hit_verbs)
  end

  # Parse AoE descriptions from JSONB (memoized)
  def parsed_aoe_descriptions
    @parsed_aoe_descriptions ||= parse_jsonb_array(aoe_descriptions)
  end

  private def validate_dice_notation(field, allow_signed: false)
    raw_value = self[field]
    return if raw_value.nil? || raw_value.to_s.strip.empty?

    notation = raw_value.to_s.strip
    if allow_signed && (notation.start_with?('+') || notation.start_with?('-'))
      notation = notation[1..]
    end

    parsed = DiceNotationService.parse(notation)
    valid = parsed[:valid] && (parsed[:count] > 0 || parsed[:sides] > 0)
    return if valid

    errors.add(field, "must be valid dice notation (for example: '2d6', 'd8', or '2d6+3')")
  rescue StandardError => e
    warn "[Ability] Failed to validate #{field}: #{e.message}"
    errors.add(field, 'is invalid')
  end

  # Uses parse_jsonb_array from JsonbParsing concern

  # === Display Helpers ===

  # Get a summary of the ability for menus
  # @return [String] short description
  def menu_description
    parts = []
    parts << "#{base_damage_dice} #{damage_type}" if base_damage_dice
    parts << "heals" if healing_ability?
    parts << "AoE #{aoe_radius}hex" if has_aoe? && aoe_radius.to_i > 0
    parts << "segment #{activation_segment}" if activation_segment
    parts << "#{specific_cooldown_rounds}rd CD" if specific_cooldown_rounds > 0
    parts.join(', ')
  end

  # === Advanced Combat Mechanics ===

  # Parse conditional damage bonuses from JSONB (memoized)
  # @return [Array<Hash>] list of conditional damage configs
  # e.g., [{ "condition" => "target_has_status", "status" => "burning", "bonus_dice" => "1d6" }]
  def parsed_conditional_damage
    @parsed_conditional_damage ||= parse_jsonb_array(conditional_damage)
  end

  # Parse split damage types from JSONB (memoized)
  # @return [Array<Hash>] list of damage type splits
  # e.g., [{ "type" => "fire", "value" => "50%" }, { "type" => "physical", "value" => "50%" }]
  def parsed_damage_types
    @parsed_damage_types ||= parse_jsonb_array(damage_types)
  end

  # Parse chain ability config from JSONB (memoized)
  # @return [Hash, nil] chain configuration or nil
  # e.g., { "max_targets" => 3, "range_per_jump" => 2, "damage_falloff" => "1d4", "friendly_fire" => false }
  def parsed_chain_config
    @parsed_chain_config ||= parse_jsonb_hash(chain_config)
  end

  # Parse forced movement config from JSONB (memoized)
  # @return [Hash, nil] forced movement configuration or nil
  # e.g., { "direction" => "away", "distance" => 2 } or { "direction" => "toward", "distance" => 3 }
  def parsed_forced_movement
    @parsed_forced_movement ||= parse_jsonb_hash(forced_movement)
  end

  # Parse execute effect from JSONB (memoized)
  # @return [Hash, nil] execute effect configuration or nil
  # e.g., { "instant_kill" => true } or { "damage_multiplier" => 2.0 }
  def parsed_execute_effect
    @parsed_execute_effect ||= parse_jsonb_hash(execute_effect)
  end

  # Parse combo condition from JSONB (memoized)
  # @return [Hash, nil] combo condition configuration or nil
  # e.g., { "requires_status" => "burning", "bonus_dice" => "2d6", "consumes_status" => true }
  def parsed_combo_condition
    @parsed_combo_condition ||= parse_jsonb_hash(combo_condition)
  end

  # Check if ability has split damage types
  def has_split_damage?
    parsed_damage_types.any?
  end
  alias split_damage? has_split_damage?

  # Check if ability is a chain ability
  def has_chain?
    parsed_chain_config && !parsed_chain_config.empty?
  end
  alias chain? has_chain?

  # Check if ability has forced movement
  def has_forced_movement?
    parsed_forced_movement && !parsed_forced_movement.empty?
  end
  alias forced_movement? has_forced_movement?

  # Check if ability has execute mechanics
  def has_execute?
    execute_threshold.to_i > 0
  end
  alias execute? has_execute?

  # Check if ability has combo mechanics
  def has_combo?
    parsed_combo_condition && !parsed_combo_condition.empty?
  end
  alias combo? has_combo?

  # Check if ability has any conditional damage bonuses
  def has_conditional_damage?
    parsed_conditional_damage.any?
  end
  alias conditional_damage? has_conditional_damage?

  # Check if ability has lifesteal
  def has_lifesteal?
    lifesteal_max.to_i > 0
  end
  alias lifesteal? has_lifesteal?

  # === Power Rating ===

  # Get the power rating for this ability
  # 100 power = 15 average damage to a single target
  # @return [Integer] total power rating
  def power
    AbilityPowerCalculator.new(self).total_power
  end

  # Get detailed breakdown of power components
  # @return [Hash] power by component (base_damage, aoe_bonus, status_effects, etc.)
  def power_breakdown
    AbilityPowerCalculator.new(self).breakdown
  end

  # Uses parse_jsonb_hash from JsonbParsing concern

  private

  # Clear all memoized JSONB parsed values after save so stale data isn't served
  def clear_memoized_jsonb!
    @parsed_costs = nil
    @parsed_status_effects = nil
    @parsed_cast_verbs = nil
    @parsed_hit_verbs = nil
    @parsed_aoe_descriptions = nil
    @parsed_conditional_damage = nil
    @parsed_damage_types = nil
    @parsed_chain_config = nil
    @parsed_forced_movement = nil
    @parsed_execute_effect = nil
    @parsed_combo_condition = nil
  end
end
