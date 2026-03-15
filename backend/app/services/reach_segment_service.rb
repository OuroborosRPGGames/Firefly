# frozen_string_literal: true

# Calculates attack segment compression based on weapon reach advantage.
# Longer weapons attack first at range, shorter weapons attack first in close.
#
# @example
#   # Spear (reach 4) vs Dagger (reach 1), not adjacent
#   ReachSegmentService.calculate_segment_range(
#     attacker_reach: 4, defender_reach: 1, is_adjacent: false
#   ) # => { start: 1, end: 66 }  # Spear attacks first
#
#   # Same matchup but starting adjacent
#   ReachSegmentService.calculate_segment_range(
#     attacker_reach: 4, defender_reach: 1, is_adjacent: true
#   ) # => { start: 34, end: 100 }  # Spear attacks last
#
class ReachSegmentService
  class << self
    # Calculate segment range for attacker based on reach comparison
    # @param attacker_reach [Integer] attacker's melee reach (1-5)
    # @param defender_reach [Integer] defender's melee reach (1-5)
    # @param is_adjacent [Boolean] true if starting distance <= 1 hex
    # @return [Hash] { start: Integer, end: Integer } segment range
    def calculate_segment_range(attacker_reach:, defender_reach:, is_adjacent:)
      config = GameConfig::Mechanics::REACH

      # Equal reach = no compression, full range
      return { start: 1, end: 100 } if attacker_reach == defender_reach

      has_reach_advantage = attacker_reach > defender_reach

      if is_adjacent
        # Close quarters: shorter weapon attacks first
        if has_reach_advantage
          # Long weapon is at disadvantage when adjacent
          { start: config[:short_weapon_start], end: config[:short_weapon_end] }
        else
          # Short weapon advantage when adjacent
          { start: config[:long_weapon_start], end: config[:long_weapon_end] }
        end
      else
        # Non-adjacent: longer weapon attacks first
        if has_reach_advantage
          { start: config[:long_weapon_start], end: config[:long_weapon_end] }
        else
          { start: config[:short_weapon_start], end: config[:short_weapon_end] }
        end
      end
    end

    # Compress attack segments into a given range
    # @param base_segments [Array<Integer>] original evenly-distributed segments
    # @param segment_range [Hash] { start: Integer, end: Integer }
    # @return [Array<Integer>] compressed segments
    def compress_segments(base_segments, segment_range)
      return base_segments if segment_range[:start] == 1 && segment_range[:end] == 100
      return [] if base_segments.empty?

      range_size = segment_range[:end] - segment_range[:start]

      base_segments.map do |seg|
        # Scale segment proportionally into the compressed range
        # Original segments are 1-100, normalize to 0.0-1.0
        normalized = (seg - 1) / 99.0
        compressed = segment_range[:start] + (normalized * range_size)
        compressed.round.clamp(segment_range[:start], segment_range[:end])
      end.sort
    end

    # Get effective reach for a participant's current weapon/attack
    # @param weapon_type [Symbol] :melee, :ranged, :unarmed, :natural_melee, :natural_ranged
    # @param weapon [Item, nil] the weapon item (if any)
    # @param natural_attack [NpcAttack, nil] the natural attack (if any)
    # @return [Integer, nil] reach value (1-5), nil for ranged
    def effective_reach(weapon_type, weapon, natural_attack)
      case weapon_type
      when :ranged, :natural_ranged
        nil # Ranged attacks don't have reach
      when :unarmed
        GameConfig::Mechanics::REACH[:unarmed_reach]
      when :natural_melee
        natural_attack&.melee_reach_value || GameConfig::Mechanics::REACH[:unarmed_reach]
      when :melee
        weapon&.pattern&.melee_reach_value || GameConfig::Mechanics::REACH[:unarmed_reach]
      else
        GameConfig::Mechanics::REACH[:unarmed_reach]
      end
    end

    # Get defender's effective melee reach from their primary melee weapon or natural attack
    # @param participant [FightParticipant] the target
    # @return [Integer] reach value (defaults to unarmed if no melee weapon)
    def defender_reach(participant)
      # Check for melee weapon first
      melee_weapon = participant.melee_weapon
      if melee_weapon&.pattern
        return melee_weapon.pattern.melee_reach_value || GameConfig::Mechanics::REACH[:unarmed_reach]
      end

      # Check for natural melee attacks
      if participant.using_natural_attacks?
        archetype = participant.npc_archetype
        if archetype
          # Get primary melee attack
          melee_attack = archetype.parsed_npc_attacks.find(&:melee?)
          return melee_attack.melee_reach_value if melee_attack&.melee_reach_value
        end
      end

      # Default to unarmed
      GameConfig::Mechanics::REACH[:unarmed_reach]
    end
  end
end
