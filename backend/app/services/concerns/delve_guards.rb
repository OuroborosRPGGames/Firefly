# frozen_string_literal: true

# Shared participant validation guards for delve services.
# Services must `extend ResultHandler` for `error()` to be available.
module DelveGuards
  # Guard for action methods (fight, recover, focus, study).
  # Returns an error Result if participant state is invalid, nil if valid.
  def validate_for_action(participant)
    return error("You're not in a delve.") unless participant.current_room
    return error("You've already extracted.") if participant.extracted?
    return error("You're dead.") if participant.respond_to?(:dead?) && participant.dead?
    return error("Time has run out!") if participant.time_expired?
    return error("You can no longer continue this delve.") if participant.respond_to?(:active?) && !participant.active?

    nil
  end

  # Guard for non-combat actions (recover, focus) that shouldn't work mid-fight.
  # Returns an error Result if in combat, nil if valid.
  def validate_not_in_combat(participant)
    if participant.character_instance&.in_combat?
      return error("You can't do that while in combat!")
    end

    nil
  end

  # Guard for movement (move).
  # Returns an error Result if participant state is invalid, nil if valid.
  def validate_for_movement(participant)
    return error("You're not in a delve.") unless participant.current_room
    return error("You've already extracted.") if participant.extracted?
    return error("You're dead.") if participant.dead?
    return error("You can no longer move in this delve.") if participant.respond_to?(:active?) && !participant.active?
    if participant.character_instance&.respond_to?(:in_combat?) && participant.character_instance.in_combat?
      return error("You can't move while in combat!")
    end

    nil
  end
end
