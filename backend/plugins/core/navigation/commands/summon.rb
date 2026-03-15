# frozen_string_literal: true

module Commands
  module Navigation
    class Summon < Commands::Base::Command
      command_name 'summon'
      aliases 'call', 'beckon'
      category :navigation
      help_text 'Send a message summoning an NPC to your location'
      usage 'summon <npc name> <message>'
      examples 'summon Merchant I need to buy supplies', 'call Guard There is trouble here!'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        if text.nil? || text.empty?
          return error_result('Usage: summon <npc name> <message>')
        end

        # Try "=" separator first (backward compat, unambiguous)
        if text.include?('=')
          parts = text.split('=', 2)
          npc_name = parts[0].strip
          message = parts[1]&.strip
        else
          # Fall back to normalizer for natural language: "summon Guard Help!"
          normalized = parsed_input[:normalized]
          if normalized[:target] && normalized[:message]
            npc_name = normalized[:target]
            message = normalized[:message]
          else
            return error_result("Please include a message: summon <npc name> <your message>")
          end
        end

        if npc_name.empty?
          return error_result('Who do you want to summon?')
        end

        if message.nil? || message.empty?
          return error_result('What message do you want to send?')
        end

        # Find NPC within summon range
        npc_instance = NpcLeadershipService.find_npc_in_summon_range(
          pc_instance: character_instance,
          name: npc_name
        )

        unless npc_instance
          return error_result("You don't know how to reach anyone named '#{npc_name}'.")
        end

        npc = npc_instance.character
        npc_full_name = npc.full_name

        # Check if NPC can be summoned
        unless NpcLeadershipService.can_be_summoned?(npc)
          return error_result("#{npc_full_name} cannot be summoned.")
        end

        # Check if NPC is already in the same room
        if npc_instance.current_room_id == character_instance.current_room_id
          return error_result("#{npc_full_name} is already here.")
        end

        # Check cooldown
        if NpcLeadershipService.on_summon_cooldown?(npc: npc, pc: character)
          remaining = NpcLeadershipService.summon_cooldown_remaining(npc: npc, pc: character)
          minutes = (remaining / 60.0).ceil
          return error_result("#{npc_full_name} recently declined your summons. Try again in #{minutes} minute#{'s' if minutes != 1}.")
        end

        # Submit the summon request (async LLM decision)
        NpcLeadershipService.request_summon(
          npc_instance: npc_instance,
          pc_instance: character_instance,
          message: message
        )

        success_result("You send word to #{npc_full_name}: \"#{message}\"", type: :narrative)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Summon)
