# frozen_string_literal: true

module Commands
  module Environment
    class Time < Commands::Base::Command
      command_name 'time'
      aliases 'clock', 'date'
      category :info
      output_category :info
      help_text 'Check the current time and date'
      usage 'time'
      examples 'time', 'clock', 'date'

      protected

      def perform_command(_parsed_input)
        room_location = location&.location

        game_time = GameTimeService.current_time(room_location)
        time_of_day = GameTimeService.time_of_day(room_location)
        moon_phase = MoonPhaseService.current_phase
        weather = room_location ? ::Weather.for_location(room_location) : nil

        lines = []
        lines << format_time_header(game_time, time_of_day)
        lines << ''
        lines << format_celestial_info(moon_phase, weather, time_of_day)

        success_result(
          lines.join("\n"),
          type: :message,
          data: build_time_data(game_time, time_of_day, moon_phase)
        )
      end

      private

      def format_time_header(game_time, time_of_day)
        formatted_date = game_time.strftime('%A, %B %d, %Y')
        time_str = game_time.strftime('%l:%M %p').strip
        period = time_of_day.to_s.capitalize

        "It is #{time_str} on #{formatted_date} (#{period})"
      end

      def format_celestial_info(moon_phase, weather, time_of_day)
        lines = []

        if %i[night dusk dawn].include?(time_of_day)
          if weather&.stars_visible?
            lines << "The #{moon_phase.name} #{moon_phase.emoji} illuminates the sky."
          else
            lines << "The #{moon_phase.name} #{moon_phase.emoji} hides behind the clouds."
          end
        else
          cloud_cover = weather&.cloud_cover || 0
          if cloud_cover < 50
            lines << "The sun shines through the #{cloud_cover}% cloud cover."
          else
            lines << "The sky is overcast with #{cloud_cover}% cloud cover."
          end
          # Include moon phase info even during day for planning
          lines << "Tonight's moon: #{moon_phase.name} #{moon_phase.emoji}"
        end

        lines.join("\n")
      end

      def build_time_data(game_time, time_of_day, moon_phase)
        {
          action: 'time',
          hour: game_time.hour,
          minute: game_time.min,
          day: game_time.day,
          weekday: game_time.strftime('%A').downcase,
          formatted_time: game_time.strftime('%l:%M %p').strip,
          formatted_date: game_time.strftime('%B %d, %Y'),
          time_of_day: time_of_day,
          moon_phase: moon_phase.name,
          moon_emoji: moon_phase.emoji,
          moon_illumination: moon_phase.illumination
        }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Environment::Time)
