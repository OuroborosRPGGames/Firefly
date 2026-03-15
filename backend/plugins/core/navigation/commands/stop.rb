# frozen_string_literal: true

module Commands
  module Navigation
    class Stop < Commands::Base::Command
      command_name 'stop'
      aliases 'halt'
      category :navigation
      help_text 'Stop moving, following, observing, or cancel a journey'
      usage 'stop [following|observing|journey]'
      examples 'stop', 'stop following', 'stop observing', 'stop journey', 'halt'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.downcase&.strip

        case text
        when 'following', 'follow'
          return stop_following
        when 'observing', 'observe', 'watching', 'watch'
          return stop_observing
        when 'journey', 'traveling', 'travel', 'voyage'
          return stop_journey
        end

        # Check if moving
        if MovementService.moving?(character_instance)
          return stop_movement
        end

        # Check if following
        if character_instance.following_id
          return stop_following
        end

        # Check if observing
        if character_instance.observing?
          return stop_observing
        end

        # Check if on a world journey
        if character_instance.traveling?
          return stop_journey
        end

        error_result("You're not moving, following, observing, or traveling.")
      end

      private

      def stop_movement
        result = MovementService.stop_movement(character_instance)

        if result.success
          extra = {}
          # Include moved_to so the webclient refreshes the room display
          if result.data&.dig(:was_directional)
            extra[:moved_to] = result.data[:room_id]
          end
          success_result(result.message, **extra)
        else
          error_result(result.message)
        end
      end

      def stop_following
        result = MovementService.stop_following(character_instance)

        if result.success
          success_result(result.message)
        else
          error_result(result.message)
        end
      end

      def stop_observing
        unless character_instance.observing?
          return error_result("You're not observing anything.")
        end

        # Get the name of what was being observed before stopping
        observed_name = if character_instance.observing_character?
                          character_instance.observing&.character&.full_name || 'that character'
                        elsif character_instance.observing_place?
                          character_instance.observed_place&.name || 'that place'
                        elsif character_instance.observing_room?
                          'the room'
                        else
                          'that'
                        end

        character_instance.stop_observing!

        success_result("You stop observing #{observed_name}.")
      end

      def stop_journey
        unless character_instance.traveling?
          return error_result("You're not on a journey.")
        end

        result = WorldTravelService.cancel_journey(character_instance, reason: 'stopped by passenger')

        if result[:success]
          # Notify other passengers that were on the journey
          room = result[:room]

          success_result(
            result[:message],
            type: :world_travel,
            data: {
              action: 'journey_cancelled',
              room_id: room&.id,
              room_name: room&.name
            }
          )
        else
          error_result(result[:error])
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Stop)
