# frozen_string_literal: true

module Commands
  module Communication
    class GiveNumber < Commands::Base::Command
      command_name 'give number'
      aliases 'givenumber', 'share number'
      category :communication
      help_text 'Give your phone number to someone'
      usage 'give number [to] <person>'
      examples 'give number Bob', 'give number to Alice'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args]

        # Parse target name (handle "to" prefix)
        target_name = if args.first&.downcase == 'to'
                        args[1..].join(' ')
                      else
                        args.join(' ')
                      end

        if blank?(target_name)
          return error_result('Give your number to whom? Usage: give number [to] <person>')
        end

        # Find target in the same room
        target = find_character_in_room(target_name)
        unless target
          return error_result("You don't see anyone like that here.")
        end

        # Can't give number to yourself
        if target.id == character_instance.id
          return error_result("You can't give your number to yourself.")
        end

        # Get target's character
        target_character = target.character

        # Check if they already have your number
        if HasNumber.has_number?(target_character, character)
          return error_result("#{target.full_name} already has your number.")
        end

        # Give the number
        HasNumber.give_number!(character, target_character)

        # Broadcast to room (exclude self using inherited method)
        action_message = "#{character.full_name} gives #{target.full_name} #{character.pronoun_possessive} number."
        broadcast_to_room(action_message, exclude_character: character_instance, type: :action)

        success_result(
          "You give #{target.full_name} your number.",
          type: :action,
          data: {
            action: 'give_number',
            target_id: target.id,
            target_name: target.full_name
          }
        )
      end

      # Uses inherited find_character_in_room and broadcast_to_room from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::GiveNumber)
