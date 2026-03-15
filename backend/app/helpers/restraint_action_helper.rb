# frozen_string_literal: true

# Helper for standardized restraint/prisoner actions (gag, blindfold, tie, etc.)
# Reduces duplication across prisoner commands
module RestraintActionHelper
  # Apply a restraint to a target character with standard messaging
  # @param target_name [String] Name of target to resolve
  # @param restraint_type [String] Type of restraint (gag, blindfold, hands, feet)
  # @param action_verb [String] Verb for messages (e.g., "gag", "blindfold", "bind")
  # @param self_msg_template [String] Message template for actor (use %{target} and %{type})
  # @param other_msg_template [String] Message template for observers (use %{actor}, %{target}, %{type})
  # @param target_msg_template [String] Message template for target (use %{actor}, %{type})
  # @param empty_error [String] Error when no target specified
  # @param self_error [String] Error when targeting self
  # @param check_timeline [Boolean] Whether to check timeline restrictions
  # @return [Hash] Result hash
  def apply_restraint_action(target_name:, restraint_type:, action_verb:,
                              self_msg_template: nil, other_msg_template: nil, target_msg_template: nil,
                              empty_error: nil, self_error: nil, check_timeline: false)
    # Timeline check if required
    if check_timeline && !character_instance.can_be_prisoner?
      return error_result('Prisoner mechanics are disabled in past timelines.')
    end

    # Require target
    return error_result(empty_error || "#{action_verb.capitalize} whom?") if blank?(target_name)

    # Resolve target with disambiguation
    resolution = resolve_character_with_menu(target_name)
    return disambiguation_result(resolution[:result]) if resolution[:disambiguation]
    return error_result(resolution[:error]) if resolution[:error]

    target = resolution[:match]

    # Can't target yourself
    if target.id == character_instance.id
      return error_result(self_error || "You can't #{action_verb} yourself.")
    end

    # Apply restraint via PrisonerService
    result = PrisonerService.apply_restraint!(target, restraint_type, actor: character_instance)
    return error_result(result[:error]) unless result[:success]

    # Build messages with templates or defaults
    # For target_msg, use personalized actor name (target may not know actor's real name)
    actor_display = character.display_name_for(target)
    msg_data = { actor: character.full_name, target: target.full_name, type: restraint_type }
    target_msg_data = { actor: actor_display, target: target.full_name, type: restraint_type }

    other_msg = other_msg_template ? (other_msg_template % msg_data) : "#{character.full_name} #{action_verb}s #{target.full_name}."
    target_msg = target_msg_template ? (target_msg_template % target_msg_data) : "#{actor_display} #{action_verb}s you."
    self_msg = self_msg_template ? (self_msg_template % msg_data) : "You #{action_verb} #{target.full_name}."

    broadcast_to_room(other_msg, exclude_character: character_instance)
    send_to_character(target, target_msg)

    success_result(
      self_msg,
      type: :action,
      data: { action: action_verb, target: target.full_name, restraint_type: restraint_type }
    )
  end

  # Remove restraints from a target character
  # @param target_name [String] Name of target to resolve
  # @param restraint_type [String] Type to remove (hands, feet, gag, blindfold, all)
  # @param empty_error [String] Error when no target specified
  # @return [Hash] Result hash
  def remove_restraint_action(target_name:, restraint_type: 'all', empty_error: nil)
    return error_result(empty_error || 'Untie whom?') if blank?(target_name)

    # Resolve target with disambiguation
    resolution = resolve_character_with_menu(target_name)
    return disambiguation_result(resolution[:result]) if resolution[:disambiguation]
    return error_result(resolution[:error]) if resolution[:error]

    target = resolution[:match]

    # Remove restraint via PrisonerService
    result = PrisonerService.remove_restraint!(target, restraint_type, actor: character_instance)
    return error_result(result[:error]) unless result[:success]

    removed_text = result[:removed].join(', ')

    broadcast_to_room(
      "#{character.full_name} removes #{target.full_name}'s #{removed_text}.",
      exclude_character: character_instance
    )

    actor_display = character.display_name_for(target)
    send_to_character(target, "#{actor_display} removes your #{removed_text}.")

    success_result(
      "You remove #{target.full_name}'s #{removed_text}.",
      type: :action,
      data: { action: 'untie', target: target.full_name, removed: result[:removed] }
    )
  end

  # Start dragging or carrying a target
  # @param target_name [String] Name of target to resolve
  # @param action_type [Symbol] :drag or :carry
  # @param empty_error [String] Error when no target specified
  # @param check_timeline [Boolean] Whether to check timeline restrictions
  # @return [Hash] Result hash
  def transport_action(target_name:, action_type:, empty_error: nil, check_timeline: false)
    # Timeline check if required
    if check_timeline && !character_instance.can_be_prisoner?
      return error_result('Prisoner mechanics are disabled in past timelines.')
    end

    verb = action_type.to_s
    return error_result(empty_error || "#{verb.capitalize} whom?") if blank?(target_name)

    # Resolve target with disambiguation
    resolution = resolve_character_with_menu(target_name)
    return disambiguation_result(resolution[:result]) if resolution[:disambiguation]
    return error_result(resolution[:error]) if resolution[:error]

    target = resolution[:match]

    # Can't target yourself
    if target.id == character_instance.id
      return error_result("You can't #{verb} yourself.")
    end

    # Start drag or carry
    result = if action_type == :drag
               PrisonerService.start_drag!(character_instance, target)
             else
               PrisonerService.pick_up!(character_instance, target)
             end

    return error_result(result[:error]) unless result[:success]

    # Messages based on action type
    # For target_msg, use personalized actor name (target may not know actor's real name)
    actor_display = character.display_name_for(target)
    if action_type == :drag
      other_msg = "#{character.full_name} grabs hold of #{target.full_name} and prepares to drag them."
      target_msg = "#{actor_display} grabs hold of you and prepares to drag you."
      self_msg = "You grab hold of #{target.full_name}. They will be dragged along when you move."
    else
      other_msg = "#{character.full_name} picks up #{target.full_name} and carries them."
      target_msg = "#{actor_display} picks you up and carries you."
      self_msg = "You pick up #{target.full_name}. They will be carried along when you move."
    end

    broadcast_to_room(other_msg, exclude_character: character_instance)
    send_to_character(target, target_msg)

    success_result(
      self_msg,
      type: :action,
      data: { action: verb, target: target.full_name }
    )
  end
end
