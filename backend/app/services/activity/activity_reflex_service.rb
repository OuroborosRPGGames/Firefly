# frozen_string_literal: true

# Handles reflex round resolution for the Activity System.
#
# Reflex rounds are fast-paced danger checks where:
# - Everyone rolls the same stat against the same DC
# - No action choices, help, or willpower spending allowed
# - 2-minute timeout (faster than standard 8 min)
# - Failure consequence: Take 1 HP damage to character_instance
# - Always progresses to next round (no repeat on failure)
class ActivityReflexService

  class ReflexError < StandardError; end

  # Result structure for reflex round
  ReflexResult = Struct.new(
    :success,           # Overall round success (did party pass?)
    :participant_results, # Array of individual results
    :emit_text,
    :result_text,
    keyword_init: true
  )

  # Individual participant result
  ParticipantResult = Struct.new(
    :participant_id,
    :character_name,
    :roll_total,
    :dc,
    :success,
    :damage_taken,
    keyword_init: true
  )

  class << self
    # Resolve a reflex round
    # @param instance [ActivityInstance] The running activity instance
    # @param round [ActivityRound] The reflex round to resolve
    # @return [ReflexResult]
    def resolve(instance, round)
      raise ReflexError, 'Not a reflex round' unless round.reflex?
      raise ReflexError, 'No active participants' if instance.active_participants.empty?

      participants = instance.active_participants.all
      dc = round.difficulty_class || instance.current_difficulty || 12

      participant_results = []
      success_count = 0

      participants.each do |p|
        result = roll_reflex_check(p, round, dc, instance)
        participant_results << result
        success_count += 1 if result.success
      end

      # Round success if majority passed
      overall_success = success_count > (participants.count / 2.0)

      # Apply failure consequences to the round (not individual - that's handled per participant)
      apply_round_failure_consequence(instance, round) unless overall_success

      ReflexResult.new(
        success: overall_success,
        participant_results: participant_results,
        emit_text: round.emit_text,
        result_text: overall_success ? (round.success_text || 'You react in time!') : (round.failure_text || 'Too slow!')
      )
    end

    private

    # Roll reflex check for a single participant
    def roll_reflex_check(participant, round, dc, instance)
      character = participant.character
      character_instance = participant.character_instance

      # Get observer effects for this participant
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      applied_effects = []

      # Get stat bonus for reflex stat
      stat_bonus = stat_bonus(character_instance, round.reflex_stat_id)

      # Roll 2d8 via DiceRollService (respecting observer effects)
      explode = !effects[:block_explosions]
      applied_effects << :block_explosions if effects[:block_explosions]
      base_result = ActivityResolutionService.roll_base_dice(0, explode: explode)

      # Add willpower dice if spending
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
      if effects[:damage_on_ones] && all_dice.any? { |d| d == 1 }
        applied_effects << :damage_on_ones
        character_instance&.take_damage(1)
      end

      roll_total = all_dice.sum + stat_bonus
      success = roll_total >= dc

      # Take damage on failure
      damage_taken = 0
      unless success
        if character_instance
          character_instance.take_damage(1)
          damage_taken = 1
        end
      end

      # Update participant roll result
      participant.update(
        roll_result: roll_total,
        expect_roll: dc
      )

      ParticipantResult.new(
        participant_id: participant.id,
        character_name: character&.full_name || 'Unknown',
        roll_total: roll_total,
        dc: dc,
        success: success,
        damage_taken: damage_taken
      )
    end

    # Get stat bonus for the reflex stat
    def stat_bonus(character_instance, stat_id)
      return 0 unless character_instance && stat_id

      stat = Stat[stat_id]
      return 0 unless stat

      StatAllocationService.get_stat_value(character_instance, stat.abbreviation) || 0
    end

    # Apply round failure consequences
    def apply_round_failure_consequence(instance, round)
      case round.fail_consequence_type
      when 'difficulty'
        instance.add_difficulty_modifier!(1)
      when 'harder_finale'
        instance.add_finale_modifier!(1)
      end
      # Note: 'injury' is already applied per participant above
      # 'branch' is handled by the main activity service
    end

  end
end
