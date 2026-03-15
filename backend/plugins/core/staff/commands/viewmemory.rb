# frozen_string_literal: true

module Commands
  module Staff
    class ViewMemory < Commands::Base::Command
      command_name 'viewmemory'
      aliases 'memview', 'showmemory'
      category :staff
      help_text 'View full details of a world memory including raw log'
      usage 'viewmemory <memory_id>'
      examples 'viewmemory 142', 'memview 98'

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        args = parsed_input[:text] || ''
        id = args.strip.to_i
        return error_result('Usage: viewmemory <memory_id>') if id <= 0

        return error_result('WorldMemory not available.') unless defined?(WorldMemory)

        memory = WorldMemory[id]
        return error_result("World memory ##{id} not found.") unless memory

        lines = build_output(memory)
        success_result(lines.join("\n"), type: :status, data: {
                         action: 'viewmemory',
                         memory_id: memory.id
                       })
      end

      private

      def build_output(memory)
        lines = ["<h3>World Memory ##{memory.id}</h3>", '']

        lines << "Summary: #{memory.summary}"
        lines << ''
        lines << "Importance: #{memory.importance || 5}/10"
        lines << "Publicity: #{memory.publicity_level}"
        lines << "Started: #{memory.started_at&.strftime('%Y-%m-%d %H:%M') || 'unknown'}"
        lines << "Ended: #{memory.ended_at&.strftime('%Y-%m-%d %H:%M') || 'unknown'}"
        lines << "Message Count: #{memory.message_count || 0}"
        lines << ''

        # Characters
        lines << 'Characters Involved:'
        chars = memory.world_memory_characters
        if chars.empty?
          lines << '  None linked.'
        else
          chars.each do |wmc|
            char = wmc.character
            next unless char

            lines << "  - #{char.full_name} (#{wmc.role}, #{wmc.message_count} messages)"
          end
        end
        lines << ''

        # Locations
        lines << 'Locations:'
        locs = memory.world_memory_locations
        if locs.empty?
          lines << '  None linked.'
        else
          locs.each do |wml|
            room = wml.room
            next unless room

            primary = wml.is_primary ? ' (primary)' : ''
            lines << "  - #{room.name}#{primary}"
          end
        end
        lines << ''

        # Raw log
        lines << '<h4>Raw Log</h4>'
        if memory.raw_log && !memory.raw_log.strip.empty?
          lines << memory.raw_log
        elsif memory.raw_log_expired?
          lines << '[Raw log has expired and been purged]'
        else
          lines << '[No raw log available]'
        end

        lines
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::ViewMemory)
