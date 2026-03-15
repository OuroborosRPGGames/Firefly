# frozen_string_literal: true

module Commands
  module Prisoner
    class Wake < Commands::Base::Command
      command_name 'wake'
      aliases 'rouse', 'awaken'
      category :combat
      help_text 'Wake an unconscious character'
      usage 'wake <character>'
      examples 'wake Bob', 'rouse Jane'

      requires_alive

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args]

        return error_result('Wake whom?') if args.empty?

        target_name = args.join(' ')

        # Resolve target in same room
        resolution = resolve_character_with_menu(target_name)
        return disambiguation_result(resolution[:result]) if resolution[:disambiguation]
        return error_result(resolution[:error]) if resolution[:error]

        target = resolution[:match]

        # Can't wake yourself
        if target.id == character_instance.id
          return error_result("You can't wake yourself.")
        end

        # Attempt to wake
        result = PrisonerService.wake!(target, waker: character_instance)

        return error_result(result[:error]) unless result[:success]

        # Notify everyone
        broadcast_to_room(
          "#{character.full_name} shakes #{target.full_name}, rousing them from unconsciousness.",
          exclude_character: character_instance
        )

        send_to_character(
          target,
          "#{character.full_name} shakes you awake. You slowly regain consciousness."
        )

        success_result(
          "You shake #{target.full_name} until they regain consciousness.",
          type: :action,
          data: { action: 'wake', target: target.full_name }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Prisoner::Wake)
