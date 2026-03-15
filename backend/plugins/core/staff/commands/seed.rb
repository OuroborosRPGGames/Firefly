# frozen_string_literal: true

module Commands
  module Staff
    class Seed < ::Commands::Base::Command
      command_name 'seed'
      aliases 'instruct', 'npc seed'
      category :staff
      help_text 'Seed an instruction into an NPC for their next action (staff only)'
      usage 'seed <npc name> <instruction>'
      examples 'seed Bob mention the weather', 'seed merchant offer a discount on potions'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'What instruction should the NPC follow? Usage: seed <npc name> <instruction>')
        return error if error

        # Try "=" separator first (backward compat, unambiguous)
        if text.include?('=')
          parts = text.split('=', 2)
          npc_name = parts[0]&.strip
          instruction = parts[1]&.strip
        else
          # Fall back to normalizer for natural language: "seed Bob mention the weather"
          normalized = parsed_input[:normalized]
          if normalized[:target] && normalized[:message]
            npc_name = normalized[:target]
            instruction = normalized[:message]
          else
            return error_result('Usage: seed <npc name> <instruction>')
          end
        end

        error = require_input(npc_name, 'Please specify an NPC name. Usage: seed <npc name> <instruction>')
        return error if error

        error = require_input(instruction, 'Please specify an instruction. Usage: seed <npc name> <instruction>')
        return error if error

        # Find the NPC
        npc_instance = find_npc(npc_name)

        unless npc_instance
          return error_result("Could not find an NPC named '#{npc_name}'.")
        end

        # Check if NPC is being fully puppeted by someone else
        if npc_instance.puppet_mode? && npc_instance.puppeted_by_instance_id != character_instance.id
          puppeteer_name = npc_instance.puppeteer&.full_name || 'someone'
          return error_result("#{npc_instance.full_name} is being puppeted by #{puppeteer_name}. Cannot seed instructions while puppeted.")
        end

        # Seed the instruction
        result = npc_instance.seed_instruction!(instruction)

        if result[:success]
          room_info = npc_instance.current_room&.name || 'unknown location'

          success_result(
            "Seeded instruction for #{npc_instance.full_name} (in #{room_info}):\n\"#{instruction}\"\n" \
            "This will influence their next LLM-generated action.",
            type: :status,
            data: {
              action: 'seed_instruction',
              npc_id: npc_instance.id,
              npc_name: npc_instance.full_name,
              instruction: instruction,
              room_name: room_info
            }
          )
        else
          error_result(result[:message])
        end
      end

      private

      def find_npc(name)
        find_online_npc(name, room_first: true)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::Seed)
