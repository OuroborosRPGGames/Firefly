# frozen_string_literal: true

require_relative '../../../../app/helpers/lead_follow_helper'

module Commands
  module Navigation
    class Lead < Commands::Base::Command
      include LeadFollowHelper
      command_name 'lead'
      aliases 'allow', 'permit', 'carry'
      category :navigation
      help_text 'Allow or revoke permission for someone to follow you, or ask an NPC to follow'
      usage 'lead <character>, lead stop <character>'
      examples 'lead John', 'lead allow Jane', 'lead stop John', 'lead Merchant'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args]
        text = parsed_input[:text]

        if text.nil? || text.empty?
          return show_current_followers
        end

        # Check for "lead stop <name>" or "lead revoke <name>"
        if args.first&.downcase == 'stop' || args.first&.downcase == 'revoke'
          target_name = args[1..-1].join(' ')
          return revoke_permission(target_name)
        end

        # Find target first to determine if NPC or PC
        result = resolve_character_with_menu(text)

        # If disambiguation needed, return the quickmenu
        return disambiguation_result(result[:result], 'Who do you want to lead?') if result[:disambiguation]

        # If error (no match found)
        return error_result(result[:error] || "You don't see '#{text}' here.") if result[:error]

        target = result[:match]

        # Branch based on NPC vs PC
        if target.character.npc?
          handle_npc_lead(target)
        else
          handle_pc_lead(target)
        end
      end

      private

      # Handle asking an NPC to follow
      def handle_npc_lead(npc_instance)
        npc = npc_instance.character
        npc_name = npc.full_name

        # Check if NPC can be led
        unless NpcLeadershipService.can_be_led?(npc)
          return error_result("#{npc_name} cannot be led.")
        end

        # Check if already following this PC
        if npc_instance.following_id == character_instance.id
          return error_result("#{npc_name} is already following you.")
        end

        # Check cooldown
        if NpcLeadershipService.on_lead_cooldown?(npc: npc, pc: character)
          remaining = NpcLeadershipService.lead_cooldown_remaining(npc: npc, pc: character)
          minutes = (remaining / 60.0).ceil
          return error_result("#{npc_name} recently declined your request. Try again in #{minutes} minute#{'s' if minutes != 1}.")
        end

        # Check if NPC is already following someone else
        if npc_instance.following_id && npc_instance.following_id != character_instance.id
          leader = CharacterInstance[npc_instance.following_id]
          leader_name = leader&.character&.full_name || 'someone'
          return error_result("#{npc_name} is already following #{leader_name}.")
        end

        # Submit the lead request (async LLM decision)
        NpcLeadershipService.request_lead(
          npc_instance: npc_instance,
          pc_instance: character_instance
        )

        success_result("You ask #{npc_name} to follow you...", type: :narrative)
      end

      # Handle granting follow permission to a PC
      def handle_pc_lead(target)
        # Check lead/follow permission
        error = check_lead_follow_permission(target)
        return error if error

        movement_result = MovementService.grant_follow_permission(character_instance, target)

        if movement_result.success
          success_result(movement_result.message)
        else
          error_result(movement_result.message)
        end
      end

      def show_current_followers
        followers = CharacterInstance.where(following_id: character_instance.id, online: true).eager(:character).all

        if followers.empty?
          return success_result('No one is currently following you.')
        end

        names = followers.map { |f| f.character.full_name }.join(', ')
        success_result("Currently following you: #{names}")
      end

      def revoke_permission(target_name)
        if target_name.nil? || target_name.empty?
          return error_result('Who do you want to stop leading?')
        end

        # For revoke, search all characters (uses CharacterLookupHelper)
        candidates = find_all_online_characters

        result = TargetResolverService.resolve_character_with_disambiguation(
          query: target_name,
          candidates: candidates,
          character_instance: character_instance,
          context: { action: 'lead_revoke' }
        )

        if result[:quickmenu]
          return disambiguation_result(result[:quickmenu], "Who do you want to stop leading?")
        end

        return error_result(result[:error] || "Don't know who '#{target_name}' is.") if result[:error]

        target = result[:match]
        movement_result = MovementService.revoke_follow_permission(character_instance, target)

        if movement_result.success
          success_result(movement_result.message)
        else
          error_result(movement_result.message)
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Lead)
