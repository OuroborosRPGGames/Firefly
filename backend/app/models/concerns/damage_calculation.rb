# frozen_string_literal: true

# Shared damage calculation logic for the threshold-based damage system.
# Used by FightParticipant (Sequel model) and SimParticipant (simulation struct).
#
# The damage threshold system converts raw damage totals into HP loss:
#   0-9 damage   = 0 HP (miss)
#   10-17 damage = 1 HP
#   18-29 damage = 2 HP
#   30-99 damage = 3 HP
#   100+ damage  = 4+ HP (100-damage bands)
#
# Wound penalty (HP lost) shifts all thresholds down, making wounded
# characters take more HP loss from the same raw damage.
#
# @example Including in a Sequel model
#   class FightParticipant < Sequel::Model
#     include DamageCalculation
#   end
#
# @example Extending a Struct (call module methods directly)
#   hp_loss = DamageCalculation.calculate_hp_from_raw_damage(damage, wound_penalty)
#
module DamageCalculation
  # Calculate adjusted damage thresholds based on wound penalty
  # @param wound_penalty [Integer] HP already lost (shifts thresholds down)
  # @return [Hash] threshold values for miss, 1hp, 2hp, 3hp boundaries
  def self.calculate_damage_thresholds(wound_penalty)
    thresholds = GameConfig::Mechanics::DAMAGE_THRESHOLDS
    {
      miss: thresholds[:miss] - wound_penalty,
      one_hp: thresholds[:one_hp] - wound_penalty,
      two_hp: thresholds[:two_hp] - wound_penalty,
      three_hp: thresholds[:three_hp] - wound_penalty
    }
  end

  # Calculate HP loss from raw damage using threshold system
  # @param damage [Integer] total raw damage
  # @param wound_penalty [Integer] HP already lost
  # @return [Integer] HP lost from this damage
  def self.calculate_hp_from_raw_damage(damage, wound_penalty)
    t = calculate_damage_thresholds(wound_penalty)
    return 0 if damage <= t[:miss]
    return 1 if damage <= t[:one_hp]
    return 2 if damage <= t[:two_hp]
    return 3 if damage <= t[:three_hp]

    # High damage scaling: 4 + floor((damage - base) / band_size)
    high_damage_start = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:three_hp] + 1
    base_high_threshold = high_damage_start - wound_penalty
    if damage >= base_high_threshold
      GameConfig::Mechanics::HIGH_DAMAGE_BASE_HP +
        ((damage - base_high_threshold) / GameConfig::Mechanics::HIGH_DAMAGE_BAND_SIZE).to_i
    else
      # Edge case: wound penalty pushed thresholds so low that damage is in the gap
      3
    end
  end

  # Instance method versions for including in classes
  def self.included(base)
    base.class_eval do
      # Calculate wound penalty - override in including class if special logic needed
      # Default: max_hp - current_hp
      def wound_penalty_for_damage
        respond_to?(:wound_penalty) ? wound_penalty : (max_hp - current_hp)
      end

      # Get adjusted damage thresholds
      def damage_thresholds
        DamageCalculation.calculate_damage_thresholds(wound_penalty_for_damage)
      end

      # Calculate HP loss from damage (alias for compatibility)
      def calculate_hp_from_damage(damage)
        DamageCalculation.calculate_hp_from_raw_damage(damage, wound_penalty_for_damage)
      end
    end
  end
end
