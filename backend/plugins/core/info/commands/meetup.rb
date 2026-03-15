# frozen_string_literal: true

module Commands
  module Info
    class Meetup < Commands::Base::Command
      command_name 'meetup'
      aliases 'schedule', 'findtime'
      category :info
      help_text 'Find the best times when multiple characters are likely online'
      usage 'meetup <character1> <character2> [character3] ...'
      examples 'meetup Alice Bob', 'meetup Alice Bob Carol', 'meetup me'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip

        if blank?(args)
          return error_result("Who should be included? Use: meetup <character1> <character2> ...")
        end

        # Handle "meetup me" to show own schedule
        if args.downcase == 'me'
          return display_own_schedule
        end

        # Parse character names
        names = args.split(/\s+/)

        if names.length < 2
          return error_result("Need at least 2 characters. Use: meetup <character1> <character2> ...")
        end

        # Find all characters
        characters = []
        not_found = []

        names.each do |name|
          char = find_character_by_name(name)
          if char
            characters << char
          else
            not_found << name
          end
        end

        unless not_found.empty?
          return error_result("Could not find: #{not_found.join(', ')}")
        end

        # Calculate meeting times
        display_meeting_times(characters)
      end

      private

      # Uses inherited find_character_globally with surname fallback
      def find_character_by_name(name)
        result = find_character_globally(name)
        return result if result

        # Fallback: surname search (find_character_globally doesn't match surname-only queries)
        Character.where(Sequel.ilike(:surname, name.strip)).first
      end

      def display_own_schedule
        profile = ActivityProfile.for_character(character)

        unless profile.has_sufficient_data?
          return info_result(
            "Not enough activity data yet.\n" \
            "Keep playing and your schedule will be tracked automatically.\n" \
            "(Need at least 20 samples, you have #{profile.total_samples || 0})"
          )
        end

        lines = ["<h3>Your Activity Schedule</h3>", ""]

        # Show peak times
        peak_times = profile.peak_times(limit: 5, threshold: 20)
        if peak_times.any?
          lines << "Peak Activity Times:"
          peak_times.each do |pt|
            day_name = ActivityTrackingService.full_day_name(pt[:day])
            hour_str = ActivityTrackingService.format_hour(pt[:hour])
            lines << "  #{day_name} at #{hour_str} (#{pt[:score].to_i}%)"
          end
          lines << ""
        end

        # Show weekly pattern
        schedule = profile.weekly_schedule(threshold: 20)
        active_days = schedule.select { |_, hours| hours.any? }

        if active_days.any?
          lines << "Typical Weekly Pattern:"
          active_days.each do |day, hours|
            day_name = ActivityTrackingService.full_day_name(day)
            hours_str = ActivityTrackingService.format_hour_range(hours)
            lines << "  #{day_name}: #{hours_str}"
          end
        end

        # Privacy status
        lines << ""
        if profile.share_schedule
          lines << "Schedule sharing: ON (others can see your overlap)"
        else
          lines << "Schedule sharing: OFF (overlap hidden from others)"
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'meetup', mode: 'self' }
        )
      end

      def display_meeting_times(characters)
        result = ActivityTrackingService.find_meeting_times(characters)

        if result[:error]
          return error_result(result[:error])
        end

        char_names = characters.map(&:full_name)
        lines = ["<h3>Best Meeting Times</h3>", ""]
        lines << "Characters: #{char_names.join(', ')}"
        lines << ""

        if result[:times].empty?
          lines << "No common availability found."
          lines << "Try checking individual schedules with 'meetup me'."
        else
          result[:times].each_with_index do |slot, idx|
            day_name = ActivityTrackingService.full_day_name(slot[:day])
            hour_str = ActivityTrackingService.format_hour(slot[:hour])
            attendee_names = slot[:attendees].map(&:full_name).join(', ')
            count = slot[:attendee_count]
            total = characters.length

            lines << "#{idx + 1}. #{day_name} at #{hour_str}"
            lines << "   Available: #{attendee_names} (#{count}/#{total})"
            lines << ""
          end

          # Summary
          lines << result[:summary] if result[:summary]
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'meetup',
            mode: 'group',
            characters: char_names,
            times: result[:times]&.map { |t| { day: t[:day], hour: t[:hour] } }
          }
        )
      end

      def info_result(message)
        success_result(message, type: :message)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Info::Meetup)
