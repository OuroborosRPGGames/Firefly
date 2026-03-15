# frozen_string_literal: true

module Commands
  module System
    class Quit < ::Commands::Base::Command
      command_name 'quit'
      aliases 'logout', 'sleep', 'log out'
      category :system
      help_text 'Leave the game and go to sleep'
      usage 'quit'
      examples 'quit', 'logout', 'sleep'

      requires :not_in_combat, message: "You can't quit while in combat! Finish the fight first."

      protected

      def perform_command(_parsed_input)
        # Build departure message
        departure_message = build_departure_message

        # Broadcast departure to room (personalized per viewer)
        broadcast_to_room(departure_message, exclude_character: character_instance, type: :departure)

        # Clear active states
        clear_active_states

        # Record playtime before logging out
        character_instance.record_session_playtime!

        # Set character offline
        character_instance.update(online: false, session_start_at: nil)

        # Log the logout for IC logging system
        RpLoggingService.on_logout(character_instance)

        success_result(
          "You go to sleep. Goodbye!",
          type: :quit,
          data: {
            action: 'quit',
            close_play_window: true
          }
        )
      end

      private

      def build_departure_message
        if character_instance.at_place?
          place_name = character_instance.current_place.name
          "#{character.full_name} goes to sleep at #{place_name}."
        else
          "#{character.full_name} goes to sleep."
        end
      end

      def clear_active_states
        # Stop observing
        character_instance.stop_observing! if character_instance.observing?

        # Stop following
        if character_instance.following_id
          MovementService.stop_following(character_instance)
        end

        # Clear any status flags
        character_instance.clear_afk! if character_instance.afk?
        character_instance.update(semiafk: false) if character_instance.semiafk?

        # Clear pending attempts
        if character_instance.attempt_target_id
          target = character_instance.attempt_target
          target&.clear_pending_attempt!
          character_instance.clear_attempt!
        end

        # Clear reading mind
        character_instance.stop_reading_mind! if character_instance.reading_mind?
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Quit)
