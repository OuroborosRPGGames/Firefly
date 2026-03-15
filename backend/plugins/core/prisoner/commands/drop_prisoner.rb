# frozen_string_literal: true

module Commands
  module Prisoner
    class DropPrisoner < Commands::Base::Command
      command_name 'release'
      aliases 'letgo', 'putdown'
      category :combat
      help_text 'Release a character you are dragging or carrying'
      usage 'release'
      examples 'release', 'putdown', 'letgo'

      requires_alive

      protected

      def perform_command(_parsed_input)
        # Check if carrying someone
        if character_instance.carrying_someone?
          result = PrisonerService.put_down!(character_instance)

          return error_result(result[:error]) unless result[:success]

          prisoner = result[:released]

          broadcast_to_room(
            "#{character.full_name} puts #{prisoner.full_name} down.",
            exclude_character: character_instance
          )

          send_to_character(prisoner, "#{character.full_name} puts you down.")

          return success_result(
            "You put #{prisoner.full_name} down.",
            type: :action,
            data: { action: 'release', target: prisoner.full_name, was_carrying: true }
          )
        end

        # Check if dragging someone
        if character_instance.dragging_someone?
          result = PrisonerService.stop_drag!(character_instance)

          return error_result(result[:error]) unless result[:success]

          prisoner = result[:released]

          broadcast_to_room(
            "#{character.full_name} releases their grip on #{prisoner.full_name}.",
            exclude_character: character_instance
          )

          send_to_character(prisoner, "#{character.full_name} releases their grip on you.")

          return success_result(
            "You release #{prisoner.full_name}.",
            type: :action,
            data: { action: 'release', target: prisoner.full_name, was_dragging: true }
          )
        end

        error_result('You are not dragging or carrying anyone.')
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::DropPrisoner)
