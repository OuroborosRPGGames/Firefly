# frozen_string_literal: true

module Commands
  module Staff
    class SceneInstructions < ::Commands::Base::Command
      command_name 'sceneinstructions'
      aliases 'scene instructions', 'sceneinstruct'
      category :staff
      help_text 'Set NPC instructions for an arranged scene (staff only)'
      usage 'sceneinstructions <scene_id> <instructions>'
      examples 'sceneinstructions 5 mention the weather and offer a discount'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]
        error = require_input(text, 'Usage: sceneinstructions <scene_id> <instructions>')
        return error if error

        # Parse: first token is scene_id, rest is instructions
        if text.include?('=')
          # Backward compat
          parts = text.split('=', 2)
          scene_id = parts[0]&.strip
          instructions = parts[1]&.strip
        else
          parts = text.strip.split(/\s+/, 2)
          scene_id = parts[0]
          instructions = parts[1]&.strip
        end

        error = require_input(scene_id, 'Please specify a scene ID.')
        return error if error

        error = require_input(instructions, 'Please specify instructions.')
        return error if error

        # Find the scene
        scene = ArrangedScene[scene_id.to_i]
        unless scene
          return error_result("Could not find scene with ID #{scene_id}.")
        end

        unless scene.pending? || scene.active?
          return error_result("Scene is #{scene.status}. Can only set instructions for pending or active scenes.")
        end

        # Update instructions
        scene.update(npc_instructions: instructions)

        # If scene is active, seed the NPC now
        if scene.active?
          npc_instance = scene.npc_instance
          if npc_instance
            npc_instance.seed_instruction!(instructions)
            success_result(
              "Instructions updated for scene '#{scene.display_name}':\n" \
              "\"#{instructions}\"\n\n" \
              "The NPC has been seeded with these instructions immediately.",
              type: :status,
              data: { action: 'instructions_set', scene_id: scene.id }
            )
          else
            success_result(
              "Instructions updated for scene '#{scene.display_name}':\n" \
              "\"#{instructions}\"\n\n" \
              "Note: NPC is not currently online, instructions will apply when scene triggers.",
              type: :status,
              data: { action: 'instructions_set', scene_id: scene.id }
            )
          end
        else
          success_result(
            "Instructions set for scene '#{scene.display_name}':\n" \
            "\"#{instructions}\"\n\n" \
            "The NPC will receive these instructions when the scene triggers.",
            type: :status,
            data: { action: 'instructions_set', scene_id: scene.id }
          )
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::SceneInstructions)
