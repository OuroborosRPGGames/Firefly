# frozen_string_literal: true

module Commands
  module Info
    class Finger < Commands::Base::Command
      command_name 'finger'
      aliases 'info'
      category :info
      output_category :info
      help_text 'Get detailed information about a character'
      usage 'finger <character>'
      examples 'finger Alice', 'finger Bob'

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]&.strip

        if blank?(target_name)
          return error_result("Finger whom? Use: finger <character>")
        end

        # Find target - first in room, then globally (uses CharacterLookupHelper)
        target = find_character_room_then_global(
          target_name,
          room: location,
          reality_id: character_instance.reality_id,
          exclude_instance_id: character_instance.id
        )
        unless target
          return error_result("No character named '#{target_name}' found.")
        end

        display_finger(target)
      end

      private

      def display_finger(target_instance)
        target_char = target_instance.character
        viewer_char = character

        lines = ["<h3>#{target_char.full_name}</h3>"]
        lines << ""

        # Basic info
        lines << "Full Name: #{target_char.full_name}"

        if target_char.race || target_char.character_class
          race_class = [target_char.race, target_char.character_class].compact.join(' | ')
          lines << race_class unless race_class.empty?
        end

        lines << "Level: #{target_instance.level}"

        lines << ""

        # Online status
        if target_instance.online
          lines << "Status: Online"
          room_name = target_instance.current_room&.name || 'Unknown'
          stance_info = format_stance(target_instance)
          lines << "Location: #{room_name}#{stance_info}"

          if target_instance.last_activity
            ago = time_ago(target_instance.last_activity)
            lines << "Last Activity: #{ago}"
          end
        else
          lines << "Status: Offline"
          if target_instance.last_activity
            lines << "Last Seen: #{time_ago(target_instance.last_activity)}"
          end
        end

        lines << ""

        # Character knowledge
        knowledge = CharacterKnowledge.first(
          knower_character_id: viewer_char.id,
          known_character_id: target_char.id
        )

        if knowledge&.is_known
          if knowledge.known_name && knowledge.known_name != target_char.full_name
            lines << "Known to you: Yes (as \"#{knowledge.known_name}\")"
          else
            lines << "Known to you: Yes"
          end
        else
          lines << "Known to you: No"
        end

        # Schedule overlap section
        overlap_lines = schedule_overlap_section(target_char, viewer_char)
        if overlap_lines&.any?
          lines << ""
          lines << "<h4>Schedule Overlap</h4>"
          lines.concat(overlap_lines)
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'finger',
            target_id: target_instance.id,
            target_name: target_char.full_name,
            online: target_instance.online
          }
        )
      end

      def format_stance(ci)
        parts = []

        stance = ci.current_stance
        unless stance == 'standing'
          parts << stance
        end

        if ci.current_place
          prep = ci.current_place.default_sit_action || 'at'
          parts << "#{prep} #{ci.current_place.name}"
        end

        return "" if parts.empty?

        " (#{parts.join(' ')})"
      end

      # time_ago is now provided by StringHelper (included via base command)

      def schedule_overlap_section(target_char, viewer_char)
        return [] if target_char.id == viewer_char.id

        result = ActivityTrackingService.calculate_overlap(viewer_char, target_char)

        return [] if result[:error]
        return [] if result[:insufficient_data]

        lines = []

        # Main overlap percentage
        lines << "Schedule overlap: #{result[:percentage]}%"

        # Best days info
        if result[:best_days]&.any?
          best = result[:best_days].first
          if best[:overlap_hours].length >= 2
            day_name = ActivityTrackingService.full_day_name(best[:day])
            hours_str = ActivityTrackingService.format_hour_range(best[:overlap_hours])

            # Check if this day is notably better
            avg_hours = result[:best_days].sum { |d| d[:overlap_hours].length } / result[:best_days].length.to_f
            if best[:overlap_hours].length > avg_hours * 1.3
              lines << "Better overlap on #{day_name}s"
            end

            lines << "Common times: #{hours_str}"
          end
        end

        lines
      rescue StandardError => e
        # Don't break finger if activity tracking fails
        warn "[Finger] Activity tracking error: #{e.message}"
        []
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Info::Finger)
