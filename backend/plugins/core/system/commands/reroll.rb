# frozen_string_literal: true

module Commands
  module System
    class Reroll < ::Commands::Base::Command
      command_name 'reroll'
      aliases 'newchar', 'new character'
      category :system
      help_text 'Create a new character (only available when dead)'
      usage 'reroll'
      examples 'reroll', 'newchar'

      protected

      def perform_command(_parsed_input)
        # Must be dead to reroll
        unless character_instance.status == 'dead'
          return error_result("You can only reroll when you are dead. Type QUIT to log out normally.")
        end

        # Get the character and user
        user = character.user

        # Store the character ID for deletion
        old_character_id = character.id
        old_character_name = character.full_name

        # Log the character out
        character_instance.update(online: false)

        # Delete the character (this will cascade delete the character_instance due to FK)
        # Note: This is a hard delete - the character is gone forever
        character.destroy

        # Return success with redirect to character creation
        success_result(
          "#{old_character_name} fades from existence. You may now create a new character.",
          type: :reroll,
          data: {
            action: 'reroll',
            redirect_to_character_creation: true,
            old_character_name: old_character_name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Reroll)
