# frozen_string_literal: true

module Commands
  module Staff
    class CancelScene < ::Commands::Base::Command
      command_name 'cancelscene'
      aliases 'cancel scene', 'deletescene'
      category :staff
      help_text 'Cancel a pending arranged scene (staff only)'
      usage 'cancelscene <scene_id>'
      examples 'cancelscene 5', 'cancel scene 12'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'Usage: cancelscene <scene_id>')
        return error if error

        scene_id = text.strip.to_i
        if scene_id <= 0
          return error_result('Please provide a valid scene ID number.')
        end

        # Find the scene
        scene = ArrangedScene[scene_id]
        unless scene
          return error_result("Could not find scene with ID #{scene_id}.")
        end

        unless scene.pending?
          return error_result(
            "Scene is #{scene.status}. Only pending scenes can be cancelled.\n" \
            "Use 'endscene' if you need to end an active scene."
          )
        end

        # Cancel the scene
        result = ArrangedSceneService.cancel_scene(scene)

        if result[:success]
          success_result(
            "Cancelled scene '#{scene.display_name}'.\n" \
            "NPC: #{scene.npc_character&.full_name}\n" \
            "PC: #{scene.pc_character&.full_name}",
            type: :status,
            data: {
              action: 'scene_cancelled',
              scene_id: scene.id
            }
          )
        else
          error_result(result[:message])
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::CancelScene)
