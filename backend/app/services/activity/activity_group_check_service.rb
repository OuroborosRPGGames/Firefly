# frozen_string_literal: true

# Handles group check round resolution for the Activity System.
#
# Group check rounds are collaborative challenges where:
# - Everyone MUST roll (no help/recover options)
# - Each participant rolls 2d8 + stat + optional willpower + optional risk
# - Uses MEDIAN of all rolls (not highest) + avg(risk_rolls)
# - Success/failure applies to entire group
class ActivityGroupCheckService

  class GroupCheckError < StandardError; end

  # Result structure for group check round
  GroupCheckResult = Struct.new(
    :success,
    :median_roll,
    :avg_risk,
    :final_total,
    :dc,
    :participant_results,
    :emit_text,
    :result_text,
    keyword_init: true
  )

  # Individual participant result
  ParticipantResult = Struct.new(
    :participant_id,
    :character_name,
    :dice_results,
    :stat_bonus,
    :willpower_spent,
    :risk_result,
    :total,
    keyword_init: true
  )

  class << self
    # Resolve a group check round
    # @param instance [ActivityInstance] The running activity instance
    # @param round [ActivityRound] The group check round to resolve
    # @return [GroupCheckResult]
    def resolve(instance, round)
      raise GroupCheckError, 'Not a group check round' unless round.group_check?
      raise GroupCheckError, 'No active participants' if instance.active_participants.empty?

      participants = instance.active_participants.all
      dc = round.difficulty_class || instance.current_difficulty || 12

      participant_results = []
      roll_totals = []
      risk_results = []

      participants.each do |p|
        result = roll_group_check(p, round, instance)
        participant_results << result
        roll_totals << result.total
        risk_results << result.risk_result if result.risk_result
      end

      # Calculate median roll
      sorted = roll_totals.sort
      median_roll = if sorted.length.odd?
                      sorted[sorted.length / 2]
                    else
                      (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2.0
                    end

      # Calculate average risk
      avg_risk = risk_results.empty? ? 0 : risk_results.sum.to_f / risk_results.size

      # Final total
      final_total = median_roll + avg_risk
      success = final_total >= dc

      # Apply failure consequences
      apply_failure_consequence(instance, round) unless success

      GroupCheckResult.new(
        success: success,
        median_roll: median_roll.round(1),
        avg_risk: avg_risk.round(2),
        final_total: final_total.round(2),
        dc: dc,
        participant_results: participant_results,
        emit_text: round.emit_text,
        result_text: success ? (round.success_text || 'The group succeeds together!') : (round.failure_text || 'The group fails as one.')
      )
    end

    private

    # Roll for a single participant in group check
    def roll_group_check(participant, round, instance)
      action = participant.chosen_action

      # Get observer effects for this participant
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      applied_effects = []

      # Roll base 2d8 via DiceRollService (no help in group checks, but respects observer effects)
      explode = !effects[:block_explosions]
      applied_effects << :block_explosions if effects[:block_explosions]
      base_result = ActivityResolutionService.roll_base_dice(0, explode: explode)

      # Mandatory group-check rounds can roll from round stat sets even when
      # no action was explicitly selected.
      stat_bonus = resolve_stat_bonus(participant, round, action)

      # Add willpower dice (up to 2) based on willpower_to_spend
      willpower_spent = 0
      if effects[:block_willpower]
        applied_effects << :block_willpower
      elsif participant.willpower_to_spend.to_i > 0
        wp_count = [participant.willpower_to_spend.to_i, 2].min
        wp_count = [wp_count, participant.available_willpower.to_i].min

        if wp_count > 0
          wp_result = DiceRollService.roll(wp_count, 8, explode_on: explode ? 8 : nil)
          base_result = ActivityResolutionService.append_willpower(base_result, wp_result)
          willpower_spent = wp_count
          wp_count.times { participant.use_willpower!(1) }
        end
      end

      # Apply reroll_ones effect if active
      all_dice = base_result.dice
      explosion_indices = base_result.explosions
      if effects[:reroll_ones]
        all_dice, explosion_indices = ActivityResolutionService.reroll_ones(all_dice, explosion_indices, explode: explode)
        applied_effects << :reroll_ones
      end

      # Apply damage_on_ones effect
      character_instance = participant.character_instance
      if effects[:damage_on_ones] && all_dice.any? { |d| d == 1 }
        applied_effects << :damage_on_ones
        character_instance&.take_damage(1)
      end

      # Roll risk dice if chosen
      risk_result = nil
      if participant.has_risk?
        risk_result = ActivityResolutionService::RISK_VALUES.sample
      end

      # Calculate total
      dice_total = all_dice.sum
      total = dice_total + stat_bonus

      # Update participant roll result
      participant.update(
        roll_result: total,
        expect_roll: round.difficulty_class || instance.current_difficulty || 12
      )

      ParticipantResult.new(
        participant_id: participant.id,
        character_name: participant.character&.full_name || 'Unknown',
        dice_results: all_dice,
        stat_bonus: stat_bonus,
        willpower_spent: willpower_spent,
        risk_result: risk_result,
        total: total
      )
    end

    def resolve_stat_bonus(participant, round, action)
      character_instance = participant.character_instance

      if action
        return action.stat_bonus_for(character_instance) || 0
      end

      return 0 unless round.stat_set_a
      stat_ids = round.stat_set_a.to_a.map(&:to_i).select(&:positive?).uniq
      return 0 if stat_ids.empty? || character_instance.nil?

      values = stat_ids.map do |stat_id|
        stat = Stat[stat_id]
        next 0 unless stat

        value = StatAllocationService.get_stat_value(character_instance, stat.abbreviation)
        value.to_i
      end

      values.max || 0
    rescue StandardError => e
      warn "[ActivityGroupCheckService] Failed to resolve stat bonus: #{e.message}"
      0
    end

    # Apply failure consequences
    def apply_failure_consequence(instance, round)
      case round.fail_consequence_type
      when 'difficulty'
        instance.add_difficulty_modifier!(1)
      when 'injury'
        # Damage all participants
        instance.active_participants.each do |p|
          p.character_instance&.take_damage(1)
        end
      when 'harder_finale'
        instance.add_finale_modifier!(1)
      end
    end

  end
end
