# frozen_string_literal: true

# Shared helper for checking lead/follow permission between characters.
#
# Used by Follow and Lead commands.
#
# Expects the including class to provide:
#   - character - the acting character
#   - error_result(message) - from Commands::Base::Command
module LeadFollowHelper
  # Check lead/follow permission
  # @param target_instance [CharacterInstance]
  # @return [Hash, nil] Error result if blocked, nil if allowed
  def check_lead_follow_permission(target_instance)
    actor_user = character.user
    target_user = target_instance.character&.user
    return nil unless target_user # No user = allowed

    unless UserPermission.lead_follow_allowed?(actor_user, target_user)
      return error_result("#{target_instance.character.full_name} has blocked lead/follow from you.")
    end

    nil
  end
end
