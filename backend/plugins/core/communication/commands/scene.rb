# frozen_string_literal: true

require_relative '../concerns/scene_look_concern'

module Commands
  module Communication
    class Scene < ::Commands::Base::Command
      include SceneLookConcern
      command_name 'scene'
      aliases 'meet', 'startscene', 'begin scene'
      category :roleplaying
      help_text 'Trigger an arranged scene meeting with an NPC'
      usage 'scene'
      examples 'scene', 'meet'

      protected

      def perform_command(_parsed_input)
        # Find available scenes for this character in this room
        available_scenes = ArrangedScene.available_for(character_instance)

        if available_scenes.empty?
          return error_result(
            "There are no arranged scenes waiting for you here.\n" \
            "If you've been invited to a meeting, go to the designated meeting location first."
          )
        end

        # If only one scene, trigger it directly
        if available_scenes.length == 1
          trigger_scene(available_scenes.first)
        else
          # Multiple scenes - show a quickmenu
          present_scene_selection(available_scenes)
        end
      end

      private

      def trigger_scene(scene)
        result = ArrangedSceneService.trigger_scene(scene, character_instance)

        if result[:success]
          rp_room = result[:rp_room]
          npc = scene.npc_character

          # Generate the room description
          look_result = generate_look_output(rp_room)

          success_result(
            "You begin your arranged meeting with #{npc.full_name}.\n\n#{look_result}",
            type: :action,
            data: {
              action: 'scene_started',
              scene_id: scene.id,
              scene_name: scene.display_name,
              npc_name: npc.full_name,
              rp_room: rp_room.name
            }
          )
        else
          error_result(result[:message])
        end
      end

      def present_scene_selection(scenes)
        options = scenes.map do |scene|
          {
            key: scene.id.to_s,
            label: scene.display_name,
            description: "Meet with #{scene.npc_character&.full_name || 'an NPC'}"
          }
        end

        create_quickmenu(
          character_instance,
          'You have multiple arranged meetings available. Which would you like to attend?',
          options,
          context: {
            command: 'scene_select',
            scene_ids: scenes.map(&:id)
          }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Scene)
