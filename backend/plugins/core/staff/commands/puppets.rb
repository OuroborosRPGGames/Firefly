# frozen_string_literal: true

module Commands
  module Staff
    class Puppets < ::Commands::Base::Command
      command_name 'puppets'
      aliases 'puppet list', 'my puppets', 'puppetlist'
      category :staff
      help_text 'List all NPCs you are currently puppeting (staff only)'
      usage 'puppets'
      examples 'puppets'

      protected

      def perform_command(_parsed_input)
        error = require_staff
        return error if error

        puppets_list = character_instance.puppets

        if puppets_list.empty?
          return success_result(
            "You are not currently puppeting any NPCs.\n" \
            "Use 'puppet <npc name>' to start puppeting an NPC.",
            type: :status,
            data: { action: 'list', count: 0, puppets: [] }
          )
        end

        # Build the list
        lines = ["You are currently puppeting #{puppets_list.length} NPC(s):"]
        lines << ""

        puppet_data = puppets_list.map do |npc|
          room_name = npc.current_room&.name || 'unknown location'
          started_at = npc.puppet_started_at

          # Calculate duration
          duration = if started_at
                       seconds = (Time.now - started_at).to_i
                       format_duration(seconds)
                     else
                       'just now'
                     end

          # Check for pending suggestion
          suggestion_status = if npc.pending_puppet_suggestion
                                "Pending suggestion: #{npc.pending_puppet_suggestion[0..50]}..."
                              else
                                'No pending suggestion'
                              end

          lines << "  #{npc.full_name}"
          lines << "    Location: #{room_name}"
          lines << "    Puppeting for: #{duration}"
          lines << "    #{suggestion_status}"
          lines << ""

          {
            id: npc.id,
            name: npc.full_name,
            room: room_name,
            duration: duration,
            has_suggestion: !npc.pending_puppet_suggestion.nil?
          }
        end

        lines << "Commands:"
        lines << "  pemote <text>       - Make the NPC emote (if only one puppet)"
        lines << "  pemote <npc> = <text> - Make a specific NPC emote"
        lines << "  unpuppet [npc]      - Stop puppeting (no arg = all)"
        lines << "  seed <npc> = <instruction> - Seed an instruction for next action"

        success_result(
          lines.join("\n"),
          type: :status,
          data: {
            action: 'list',
            count: puppets_list.length,
            puppets: puppet_data
          }
        )
      end

      private

      def format_duration(seconds)
        if seconds < 60
          "#{seconds} seconds"
        elsif seconds < 3600
          minutes = seconds / 60
          "#{minutes} minute#{'s' if minutes != 1}"
        elsif seconds < 86400
          hours = seconds / 3600
          "#{hours} hour#{'s' if hours != 1}"
        else
          days = seconds / 86400
          "#{days} day#{'s' if days != 1}"
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::Puppets)
