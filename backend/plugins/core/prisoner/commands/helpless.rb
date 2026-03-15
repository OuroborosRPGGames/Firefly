# frozen_string_literal: true

module Commands
  module Prisoner
    class Helpless < Commands::Base::Command
      command_name 'helpless'
      aliases 'surrender'
      category :combat
      help_text 'Toggle voluntary helpless state for roleplay'
      usage 'helpless [on/off]'
      examples 'helpless', 'helpless on', 'helpless off'

      requires_alive

      protected

      def perform_command(parsed_input)
        # Timeline restriction - prisoner mechanics disabled in past timelines
        unless character_instance.can_be_prisoner?
          return error_result('Prisoner mechanics are disabled in past timelines.')
        end

        args = parsed_input[:args]

        # Parse on/off argument
        enable = nil
        if args.any?
          case args.first.downcase
          when 'on', 'yes', 'true'
            enable = true
          when 'off', 'no', 'false'
            enable = false
          else
            return error_result("Usage: helpless [on/off]")
          end
        end

        result = PrisonerService.toggle_helpless!(character_instance, enable: enable)

        return error_result(result[:error]) unless result[:success]

        if result[:enabled]
          broadcast_to_room(
            "#{character.full_name} becomes helpless and vulnerable.",
            exclude_character: character_instance
          )
          success_result(
            'You make yourself helpless and vulnerable. Others can now restrain you, search you, or move you.',
            type: :action,
            data: { action: 'helpless', enabled: true }
          )
        else
          broadcast_to_room(
            "#{character.full_name} is no longer helpless.",
            exclude_character: character_instance
          )
          success_result(
            'You are no longer helpless.',
            type: :action,
            data: { action: 'helpless', enabled: false }
          )
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Helpless)
