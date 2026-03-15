# frozen_string_literal: true

require_relative 'combat_ai_service'

# AI service for autobattle mode.
# Extends CombatAIService with style-aware decisions (aggressive, defensive, supportive).
#
# Key differences from CombatAIService:
# - Uses tactical stances (aggressive/defensive/guard)
# - Allocates willpower dice intelligently
# - Applies style-based profile adjustments
#
# @example
#   ai = AutobattleAIService.new(participant)
#   decisions = ai.decide!  # Returns style-aware decisions
#
class AutobattleAIService < CombatAIService
  # Maximum willpower dice that can be spent per round
  MAX_WILLPOWER_SPEND = 2

  def initialize(participant)
    super
    @style = participant.autobattle_style
    @style_config = GameConfig::Autobattle
  end

  # Override to apply style-specific profile adjustments
  # @return [Hash] profile configuration with style overrides
  def determine_profile
    base = super
    return base unless @style

    case @style
    when 'aggressive'
      base.merge(attack_weight: 0.9, defend_weight: 0.1, target_strategy: :weakest)
    when 'defensive'
      base.merge(attack_weight: 0.4, defend_weight: 0.6, target_strategy: :threat, flee_threshold: 0.3)
    when 'supportive'
      base.merge(attack_weight: 0.3, defend_weight: 0.4, target_strategy: :threat)
    else
      base
    end
  end

  # Override to include tactic and willpower decisions
  # @return [Hash] decisions hash with all combat choices
  def decide_standard_combat!
    decisions = super

    # Apply style-specific tactic
    decisions[:tactic_choice] = determine_tactic
    decisions[:tactic_target_participant_id] = determine_tactic_target(decisions[:tactic_choice])

    # Apply willpower allocation (base class sets 0 for all)
    allocate_willpower!(decisions)

    decisions
  end

  private

  # Determine which tactic to use based on style
  # @return [String, nil] tactic choice
  def determine_tactic
    case @style
    when 'aggressive'
      'aggressive'
    when 'defensive'
      'defensive'
    when 'supportive'
      ally_needs_protection? ? 'guard' : nil
    end
  end

  # Determine which ally to protect (for guard/back_to_back tactics)
  # @param tactic [String, nil] the tactic being used
  # @return [Integer, nil] participant ID of ally to protect
  def determine_tactic_target(tactic)
    return nil unless %w[guard back_to_back].include?(tactic)

    allies = available_allies
    return nil if allies.empty?

    # Find most wounded ally being targeted
    targeted_allies = allies.select { |a| ally_being_targeted?(a) }
    priority_allies = targeted_allies.any? ? targeted_allies : allies

    # Pick the most wounded from priority list
    most_wounded = priority_allies.min_by { |a| a.current_hp.to_f / [a.max_hp.to_f, 1].max }
    most_wounded&.id
  end

  # Check if any ally needs protection (low HP or being targeted)
  # @return [Boolean]
  def ally_needs_protection?
    allies = available_allies
    return false if allies.empty?

    allies.any? do |ally|
      hp_percent = ally.current_hp.to_f / [ally.max_hp.to_f, 1].max
      hp_percent < 0.5 || ally_being_targeted?(ally)
    end
  end

  # Check if an ally is being targeted by enemies
  # @param ally [FightParticipant]
  # @return [Boolean]
  def ally_being_targeted?(ally)
    available_enemies.any? { |e| e.target_participant_id == ally.id }
  end

  # Allocate willpower dice based on style and action
  # @param decisions [Hash] the decisions hash to modify
  def allocate_willpower!(decisions)
    available = participant.available_willpower_dice
    return if available == 0

    ability = decisions[:ability_id] ? Ability[decisions[:ability_id]] : nil

    if ability
      # Using an ability - check if it's one of the top 2
      top_abilities = participant.top_powerful_abilities(2)
      is_top = top_abilities.map(&:id).include?(ability.id)

      if participant.willpower_dice >= 3.0 && is_top
        # At max willpower with a top ability - spend all available (up to max)
        decisions[:willpower_ability] = [available, MAX_WILLPOWER_SPEND].min
      else
        # Normal ability - spend 1 die
        decisions[:willpower_ability] = [available, 1].min
      end
    elsif @style == 'aggressive' && decisions[:main_action] == 'attack'
      # Aggressive style attacking - boost damage
      decisions[:willpower_attack] = [available, 1].min
    elsif @style == 'defensive'
      # Defensive style - boost defense roll
      decisions[:willpower_defense] = [available, 1].min
    end
    # Supportive style without ability doesn't spend willpower on basic attacks
  end
end
