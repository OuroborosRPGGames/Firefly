# frozen_string_literal: true

# Tracks active status effects on fight participants.
# Links participants to status effects with duration and stacking info.
class ParticipantStatusEffect < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :fight_participant
  many_to_one :status_effect
  many_to_one :applied_by_participant, class: :FightParticipant, key: :applied_by_participant_id

  def validate
    super
    validates_presence [:fight_participant_id, :status_effect_id, :expires_at_round]
    validates_integer :stack_count, minimum: 1 if stack_count
  end

  # Check if this effect has expired
  def expired?
    return true unless fight_participant&.fight

    expires_at_round <= fight_participant.fight.round_number
  end

  # Check if this effect is still active
  def active?
    !expired?
  end

  # Get rounds remaining until expiration
  # @return [Integer] rounds remaining (0 if expired)
  def rounds_remaining
    return 0 unless fight_participant&.fight

    [expires_at_round - fight_participant.fight.round_number, 0].max
  end

  # Get the effective modifier value (accounting for stacks)
  # @return [Integer] total modifier value
  def effective_modifier
    base_value = effect_value || status_effect&.modifier_value || 0
    base_value * (stack_count || 1)
  end

  # Get display info for UI
  def display_info
    {
      name: status_effect&.name,
      description: status_effect&.description,
      is_buff: status_effect&.buff?,
      icon: status_effect&.icon_name,
      stacks: stack_count,
      rounds_remaining: rounds_remaining,
      effect_value: effective_modifier
    }
  end

  # Refresh the duration (for refresh stacking behavior)
  def refresh!(new_duration, new_value: nil)
    update_data = { expires_at_round: fight_participant.fight.round_number + new_duration }
    update_data[:effect_value] = new_value if new_value
    update(update_data)
  end

  # Add a stack (for stack stacking behavior)
  def add_stack!(new_duration: nil)
    return false unless status_effect&.stackable?
    return false if stack_count >= (status_effect.max_stacks || 1)

    new_count = (stack_count || 1) + 1
    update_data = { stack_count: new_count }

    # Optionally refresh duration when adding stacks
    if new_duration
      update_data[:expires_at_round] = fight_participant.fight.round_number + new_duration
    end

    update(update_data)
    true
  end

  # Extend the duration by adding rounds (for duration stacking behavior)
  def extend_duration!(additional_rounds)
    update(expires_at_round: expires_at_round + additional_rounds)
  end
end
