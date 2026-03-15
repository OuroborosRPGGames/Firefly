# frozen_string_literal: true

require_relative '../concerns/puppet_lookup_concern'

module Commands
  module Staff
    class Unpuppet < ::Commands::Base::Command
      include Commands::Staff::Concerns::PuppetLookupConcern
      command_name 'unpuppet'
      aliases 'release', 'uncontrol'
      category :staff
      help_text 'Release control of a puppeted NPC (staff only)'
      usage 'unpuppet [npc name]'
      examples 'unpuppet', 'unpuppet Bob', 'unpuppet all'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]&.strip

        # If no argument or 'all', release all puppets
        if text.nil? || text.empty? || text.downcase == 'all'
          result = character_instance.stop_puppeting_all!

          if result[:count] == 0
            return error_result('You are not puppeting any NPCs.')
          end

          return success_result(
            result[:message],
            type: :status,
            data: {
              action: 'unpuppet_all',
              count: result[:count]
            }
          )
        end

        # Find specific NPC among our puppets
        puppets_list = character_instance.puppets
        if puppets_list.empty?
          return error_result('You are not puppeting any NPCs.')
        end

        npc_instance = find_puppet_by_name(puppets_list, text)

        unless npc_instance
          puppet_names = puppets_list.map(&:full_name).join(', ')
          return error_result(
            "Could not find '#{text}' among your puppets.\n" \
            "Currently puppeting: #{puppet_names}"
          )
        end

        result = character_instance.stop_puppeting!(npc_instance)

        if result[:success]
          success_result(
            result[:message],
            type: :status,
            data: {
              action: 'unpuppet',
              npc_id: npc_instance.id,
              npc_name: npc_instance.full_name
            }
          )
        else
          error_result(result[:message])
        end
      end

      private

    end
  end
end

Commands::Base::Registry.register(Commands::Staff::Unpuppet)
