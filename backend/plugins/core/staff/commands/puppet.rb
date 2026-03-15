# frozen_string_literal: true

module Commands
  module Staff
    class Puppet < ::Commands::Base::Command
      command_name 'puppet'
      aliases 'puppeteer', 'control'
      category :staff
      help_text 'Take control of an NPC to manually control their actions (staff only)'
      usage 'puppet <npc name>'
      examples 'puppet Bob', 'puppet the merchant'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'Who do you want to puppet? Usage: puppet <npc name>')
        return error if error

        npc_name = text.strip

        # Find NPC - first check current room, then search globally
        npc_instance = find_npc(npc_name)

        unless npc_instance
          return error_result("Could not find an NPC named '#{npc_name}'.")
        end

        # Start puppeting
        result = character_instance.start_puppeting!(npc_instance)

        if result[:success]
          room_info = npc_instance.current_room
          room_name = room_info ? room_info.name : 'unknown location'

          success_result(
            "You are now puppeting #{npc_instance.full_name} (in #{room_name}).\n" \
            "Use 'pemote <text>' to make them emote, or 'unpuppet' to release control.",
            type: :status,
            data: {
              action: 'puppet_start',
              npc_id: npc_instance.id,
              npc_name: npc_instance.full_name,
              room_name: room_name
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

Commands::Base::Registry.register(Commands::Staff::Puppet)
