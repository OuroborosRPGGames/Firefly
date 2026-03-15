# frozen_string_literal: true

module Commands
  module Staff
    class ListScenes < ::Commands::Base::Command
      command_name 'listscenes'
      aliases 'scenes', 'list scenes', 'arranged scenes'
      category :staff
      help_text 'List all arranged scenes (staff only)'
      usage 'listscenes [all|pending|active|completed]'
      examples 'listscenes', 'listscenes pending', 'listscenes all'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]&.strip&.downcase
        filter = text.nil? || text.empty? ? 'pending' : text

        scenes = case filter
                 when 'all'
                   ArrangedScene.order(Sequel.desc(:created_at)).limit(50).all
                 when 'active'
                   ArrangedScene.where(status: 'active').order(Sequel.desc(:started_at)).all
                 when 'completed'
                   ArrangedScene.where(status: 'completed').order(Sequel.desc(:ended_at)).limit(20).all
                 when 'cancelled'
                   ArrangedScene.where(status: 'cancelled').order(Sequel.desc(:updated_at)).limit(20).all
                 else # pending
                   ArrangedScene.where(status: 'pending').order(Sequel.desc(:created_at)).all
                 end

        if scenes.empty?
          return success_result(
            "No #{filter} scenes found.",
            type: :status,
            data: { action: 'list', count: 0, filter: filter }
          )
        end

        lines = ["Arranged Scenes (#{filter}): #{scenes.length} found"]
        lines << ''

        scene_data = scenes.map do |scene|
          npc_name = scene.npc_character&.full_name || 'Unknown NPC'
          pc_name = scene.pc_character&.full_name || 'Unknown PC'
          meeting_room = scene.meeting_room&.name || 'Unknown'
          rp_room = scene.rp_room&.name || 'Unknown'

          lines << "  [#{scene.id}] #{scene.display_name}"
          lines << "      NPC: #{npc_name} | PC: #{pc_name}"
          lines << "      Meeting: #{meeting_room} | RP: #{rp_room}"
          lines << "      Status: #{scene.status}"

          if scene.pending? && scene.available?
            lines << "      (Ready to trigger)"
          elsif scene.pending? && scene.available_from && Time.now < scene.available_from
            lines << "      (Available from: #{scene.available_from.strftime('%Y-%m-%d %H:%M')})"
          elsif scene.pending? && scene.expires_at && Time.now >= scene.expires_at
            lines << "      (EXPIRED)"
          end

          if scene.active?
            lines << "      Started: #{scene.started_at&.strftime('%Y-%m-%d %H:%M')}"
          end

          if scene.completed? && scene.world_memory
            summary = scene.world_memory.summary
            truncated = summary.length > 100 ? "#{summary[0..100]}..." : summary
            lines << "      Summary: #{truncated}"
          end

          lines << ''

          {
            id: scene.id,
            name: scene.display_name,
            npc: npc_name,
            pc: pc_name,
            status: scene.status
          }
        end

        lines << 'Commands:'
        lines << '  sceneinstructions <id> = <text> - Set NPC instructions'
        lines << '  cancelscene <id>                - Cancel a pending scene'

        success_result(
          lines.join("\n"),
          type: :status,
          data: {
            action: 'list',
            count: scenes.length,
            filter: filter,
            scenes: scene_data
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::ListScenes)
