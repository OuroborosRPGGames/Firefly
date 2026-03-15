# frozen_string_literal: true

# Helper for checking IC/OOC messaging permissions between users
# Consolidates permission logic for whisper, say_to, private_message, etc.
module CommunicationPermissionHelper
  # Check if IC (in-character) messaging is allowed from sender to target
  # Uses UserPermission.ic_allowed? for simple yes/no check
  # @param target_instance [CharacterInstance] The message recipient
  # @return [Hash, nil] Error result if blocked, nil if allowed
  def check_ic_permission(target_instance)
    sender_user = character.user
    target_char = target_instance.character
    target_user = target_char&.user
    return nil unless target_user # No user = NPC, always allowed

    target_name = target_char.display_name_for(character_instance)

    # Check Relationship blocks (dm covers IC direct messages)
    if Relationship.blocked_for_between?(character, target_char, 'dm')
      return error_result("#{target_name} has blocked IC messages from you.")
    end

    unless UserPermission.ic_allowed?(sender_user, target_user)
      return error_result("#{target_name} has blocked IC messages from you.")
    end

    nil
  end

  # Check if OOC (out-of-character) messaging is allowed from sender to target
  # Uses UserPermission.ooc_permission which returns 'yes', 'no', or 'ask'
  # Handles OocRequest flow for 'ask' cases
  # @param target_instance [CharacterInstance] The message recipient
  # @return [Hash, nil] Error result if blocked, nil if allowed
  def check_ooc_permission(target_instance)
    sender_user = character.user
    target_char = target_instance.character
    target_user = target_char&.user
    return nil unless target_user # No user = NPC, always allowed

    target_name = target_char.display_name_for(character_instance)

    # Check Relationship blocks for OOC
    if Relationship.blocked_for_between?(character, target_char, 'ooc')
      return error_result("#{target_name} has blocked OOC messages from you.")
    end

    permission = UserPermission.ooc_permission(sender_user, target_user)

    case permission
    when 'no'
      error_result("#{target_name} has blocked OOC messages from you.")
    when 'ask'
      # Check if they have an accepted OOC request
      if OocRequest.has_accepted_request?(sender_user, target_user)
        nil # Allowed - they accepted the request
      else
        error_result(
          "#{target_name} requires an OOC request first.\n" \
          "Use: oocrequest #{target_name} <your message>"
        )
      end
    else # 'yes' or generic defaults to 'yes'
      nil # Allowed
    end
  end
end
