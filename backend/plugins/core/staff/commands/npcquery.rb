# frozen_string_literal: true

module Commands
  module Staff
    class NpcQuery < ::Commands::Base::Command
      command_name 'npcquery'
      aliases 'asknpc', 'querynpc'
      category :staff
      help_text 'Ask any question of an NPC and receive their response (staff only)'
      usage 'npcquery <npc name> <question>'
      examples 'npcquery Bob What do you think of the mayor?', 'asknpc Guard What are you guarding?'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'Usage: npcquery <npc name> <question>')
        return error if error

        # Try "=" separator first (backward compat, unambiguous)
        if text.include?('=')
          parts = text.split('=', 2)
          npc_name = parts[0].strip
          question = parts[1]&.strip
        else
          # Fall back to normalizer for natural language: "npcquery Bob What's up?"
          normalized = parsed_input[:normalized]
          if normalized[:target] && normalized[:message]
            npc_name = normalized[:target]
            question = normalized[:message]
          else
            return error_result('Usage: npcquery <npc name> <question>')
          end
        end

        error = require_input(npc_name, 'Who do you want to query?')
        return error if error

        error = require_input(question, 'What question do you want to ask?')
        return error if error

        # Find NPC globally (staff can query any NPC)
        npc_instance = find_npc(npc_name)

        unless npc_instance
          return error_result("Could not find an NPC named '#{npc_name}'.")
        end

        npc_full_name = npc_instance.character.full_name

        # Query the NPC (sync call)
        result = NpcLeadershipService.query_npc(
          npc_instance: npc_instance,
          question: question
        )

        if result[:success]
          room = npc_instance.current_room
          room_name = room ? room.name : 'unknown location'

          response_text = <<~TEXT
            <h3>NPC Query: #{npc_full_name}</h3>
            Location: #{room_name}
            Question: #{question}

            Response:
            #{result[:response]}
          TEXT

          success_result(response_text.strip, type: :system)
        else
          error_result("Query failed: #{result[:error]}")
        end
      end

      private

      def find_npc(name)
        find_online_npc(name)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::NpcQuery)
