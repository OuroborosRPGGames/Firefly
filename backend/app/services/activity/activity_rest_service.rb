# frozen_string_literal: true

# Handles rest round resolution for the Activity System.
#
# Rest rounds are recovery points where:
# - No automatic progression - wait until >50% elect to continue
# - Healing available:
#   - Every 2 HP lost = 1 permanent (can't heal back)
#   - Example: Lost 1 HP → heal to full
#   - Example: Lost 2 HP → heal to max-1
#   - Example: Lost 4 HP → heal to max-2
# - Players use 'activity rest' to heal, 'activity continue' to vote proceed
class ActivityRestService
  class RestError < StandardError; end

  # Result structure for rest round
  RestResult = Struct.new(
    :ready_to_continue,
    :continue_votes,
    :total_participants,
    :healing_results,     # Array of { participant_id:, healed_amount:, permanent_damage: }
    :emit_text,
    :result_text,
    keyword_init: true
  )

  # Healing result for a single participant
  HealingResult = Struct.new(
    :participant_id,
    :character_name,
    :previous_hp,
    :new_hp,
    :max_hp,
    :permanent_damage,
    :healed_amount,
    keyword_init: true
  )

  class << self
    # Resolve a rest round (check if ready to continue)
    # @param instance [ActivityInstance] The running activity instance
    # @param round [ActivityRound] The rest round
    # @return [RestResult]
    def resolve(instance, round)
      raise RestError, 'Not a rest round' unless round.rest?
      raise RestError, 'No active participants' if instance.active_participants.empty?

      participants = instance.active_participants.all
      continue_votes = instance.continue_votes
      total = participants.count

      ready = instance.majority_wants_continue?

      RestResult.new(
        ready_to_continue: ready,
        continue_votes: continue_votes,
        total_participants: total,
        healing_results: [],
        emit_text: round.emit_text,
        result_text: ready ? 'The group is ready to continue.' : 'Resting... waiting for majority to continue.'
      )
    end

    # Heal a participant at rest
    # @param participant [ActivityParticipant]
    # @return [HealingResult]
    def heal_at_rest(participant)
      character_instance = participant.character_instance
      raise RestError, 'No character instance found' unless character_instance

      previous_hp = character_instance.current_hp || 0
      max_hp = character_instance.max_hp || 6

      # Calculate permanent damage from a stable baseline so repeated heal calls
      # in the same rest round cannot reduce permanent damage.
      damage_taken = max_hp - previous_hp
      baseline_damage = rest_damage_baseline(participant, damage_taken: damage_taken, max_hp: max_hp)
      permanent_damage = baseline_damage / 2 # Integer division

      # Calculate healable maximum
      healable_to = max_hp - permanent_damage

      # Already at or above healable max
      if previous_hp >= healable_to
        return HealingResult.new(
          participant_id: participant.id,
          character_name: participant.character&.full_name || 'Unknown',
          previous_hp: previous_hp,
          new_hp: previous_hp,
          max_hp: max_hp,
          permanent_damage: permanent_damage,
          healed_amount: 0
        )
      end

      # Heal to max healable
      character_instance.update(health: healable_to)
      healed_amount = healable_to - previous_hp

      HealingResult.new(
        participant_id: participant.id,
        character_name: participant.character&.full_name || 'Unknown',
        previous_hp: previous_hp,
        new_hp: healable_to,
        max_hp: max_hp,
        permanent_damage: permanent_damage,
        healed_amount: healed_amount
      )
    end

    # Submit continue vote
    # @param participant [ActivityParticipant]
    # @return [Boolean]
    def vote_to_continue(participant)
      participant.vote_to_continue!
      true
    end

    # Check if ready to continue
    # @param instance [ActivityInstance]
    # @return [Boolean]
    def ready_to_continue?(instance)
      instance.majority_wants_continue?
    end

    # Get rest status for display
    # @param instance [ActivityInstance]
    # @return [Hash]
    def rest_status(instance)
      participants = instance.active_participants.all
      total = participants.count
      continue_votes = instance.continue_votes

      {
        total_participants: total,
        continue_votes: continue_votes,
        votes_needed: (total / 2) + 1,
        ready: instance.majority_wants_continue?,
        participants_status: participants.map do |p|
          ci = p.character_instance
          {
            name: p.character&.full_name,
            current_hp: ci&.current_hp || 0,
            max_hp: ci&.max_hp || 0,
            voted_continue: p.voted_continue?
          }
        end
      }
    end

    # Cache the initial damage at rest-round start so repeated heal calls
    # cannot reduce permanent damage. Uses roll_result (unused during rest
    # rounds and reset to nil each round by reset_participant_choices!).
    def rest_damage_baseline(participant, damage_taken:, max_hp:)
      cached = participant.roll_result
      cached = cached.to_i if cached

      # Ignore stale/non-sensical cached values and refresh if current damage is worse.
      if cached.nil? || cached.negative? || cached > max_hp
        baseline = damage_taken
      else
        baseline = [cached, damage_taken].max
      end

      if cached != baseline
        participant.update(roll_result: baseline)
      end

      baseline
    rescue StandardError => e
      warn "[ActivityRestService] Failed to persist rest damage baseline: #{e.message}"
      damage_taken
    end
  end
end
