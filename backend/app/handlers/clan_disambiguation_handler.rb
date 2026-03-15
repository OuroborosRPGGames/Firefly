# frozen_string_literal: true

# ClanDisambiguationHandler processes responses to clan selection quickmenus.
#
# When a command needs to know which clan to operate on and the user
# is in multiple clans, a quickmenu is shown. When the user selects
# an option, this handler completes the original action.
#
# The context stored in the quickmenu includes:
# - action: the clan action (e.g., 'invite', 'kick', 'leave', 'memo')
# - clan_ids: array of candidate clan IDs
# - command-specific context (e.g., target_id for invite/kick, message for memo)
#
class ClanDisambiguationHandler
  class << self
    include HandlerResponseHelper

    def process_response(char_instance, interaction_data, selected_key)
      context = interaction_data[:context] || interaction_data['context'] || {}
      action = context[:action] || context['action']
      clan_ids = context[:clan_ids] || context['clan_ids'] || []

      # Get the selected clan ID (1-indexed key)
      selected_index = selected_key.to_i - 1
      selected_clan_id = clan_ids[selected_index]

      return error_response("Invalid selection") unless selected_clan_id

      with_record(Group, selected_clan_id, error_message: "Clan not found") do |clan|
        character = char_instance.character

        # Dispatch to the appropriate handler based on action
        case action
        when 'invite'
          complete_invite(clan, character, context)
        when 'kick'
          complete_kick(clan, character, context)
        when 'leave'
          complete_leave(clan, character)
        when 'memo'
          complete_memo(clan, character, context)
        when 'handle'
          complete_handle(clan, character, context)
        when 'grant'
          complete_grant(clan, character, char_instance, context)
        when 'revoke'
          complete_revoke(clan, character, char_instance, context)
        else
          error_response("Unknown clan action: #{action}")
        end
      end
    end

    private

    def complete_invite(clan, inviter, context)
      target_id = context[:target_id] || context['target_id']
      handle = context[:handle] || context['handle']

      with_record(Character, target_id, error_message: "Character not found") do |target|
        result = ClanService.invite_member(clan, inviter, target, handle: handle)
        result_to_response(result)
      end
    end

    def complete_kick(clan, kicker, context)
      target_id = context[:target_id] || context['target_id']

      with_record(Character, target_id, error_message: "Character not found") do |target|
        result = ClanService.kick_member(clan, kicker, target)
        result_to_response(result)
      end
    end

    def complete_leave(clan, character)
      result = ClanService.leave_clan(clan, character)
      result_to_response(result)
    end

    def complete_memo(clan, sender, context)
      subject = context[:subject] || context['subject']
      body = context[:body] || context['body']

      result = ClanService.send_clan_memo(clan, sender, subject: subject, body: body)
      result_to_response(result)
    end

    def complete_handle(clan, character, context)
      new_handle = context[:new_handle] || context['new_handle']

      result = ClanService.set_handle(clan, character, new_handle)
      result_to_response(result)
    end

    def complete_grant(clan, character, _char_instance, context)
      room_id = context[:room_id] || context['room_id']

      with_record(Room, room_id, error_message: "Room not found") do |room|
        membership = clan.membership_for(character)
        return error_response('Only officers can grant room access.') unless membership&.officer?

        clan.grant_room_access!(room, permanent: true)
        success_response("#{clan.display_name} members can now enter this room.")
      end
    end

    def complete_revoke(clan, character, _char_instance, context)
      room_id = context[:room_id] || context['room_id']

      with_record(Room, room_id, error_message: "Room not found") do |room|
        membership = clan.membership_for(character)
        return error_response('Only officers can revoke room access.') unless membership&.officer?

        clan.revoke_room_access!(room)
        success_response("#{clan.display_name} members can no longer enter this room.")
      end
    end
  end
end
