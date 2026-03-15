# frozen_string_literal: true

require_relative '../concerns/scene_look_concern'

module Commands
  module Communication
    class EndScene < ::Commands::Base::Command
      include SceneLookConcern
      command_name 'endscene'
      aliases 'end scene', 'leave scene', 'leavescene', 'exitscene'
      category :roleplaying
      help_text 'End your current arranged scene and return to the meeting location'
      usage 'endscene'
      examples 'endscene', 'leave scene'

      protected

      def perform_command(_parsed_input)
        # Find active scene for this character
        scene = ArrangedScene.active_for(character_instance)

        unless scene
          return error_result(
            "You are not currently in an arranged scene.\n" \
            "This command is for ending scenes that were triggered with 'scene' or 'meet'."
          )
        end

        result = ArrangedSceneService.end_scene(scene, character_instance)

        if result[:success]
          meeting_room = result[:meeting_room]

          # Generate the return room description
          look_result = generate_look_output(meeting_room)

          success_result(
            "Your meeting has concluded. You return to #{meeting_room.name}.\n\n#{look_result}",
            type: :action,
            data: {
              action: 'scene_ended',
              scene_id: scene.id,
              scene_name: scene.display_name,
              return_room: meeting_room.name
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

Commands::Base::Registry.register(Commands::Communication::EndScene)
