# frozen_string_literal: true

module Commands
  module Building
    class SetSeasonal < Commands::Base::Command
      command_name 'set seasonal'
      aliases 'setseasonal', 'seasonal'
      category :building
      help_text 'Set seasonal descriptions or backgrounds for a room you own'
      usage 'set seasonal <desc|bg> <time> <season> <text|url>'
      examples(
        'set seasonal desc morning spring The spring morning light filters through the windows...',
        'set seasonal desc night - The room is dark and quiet...',
        'set seasonal desc - winter Snow blankets the view outside...',
        'set seasonal desc default A cozy room with wooden floors...',
        'set seasonal bg morning summer https://example.com/summer_morning.jpg',
        'set seasonal bg - - https://example.com/default.jpg',
        'set seasonal list'
      )

      # Valid time periods (user-facing names)
      TIME_OPTIONS = %w[morning afternoon evening night dawn day dusk -].freeze
      SEASON_OPTIONS = %w[spring summer fall winter -].freeze

      protected

      def perform_command(parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room.")
        end

        # Parse the input
        text = (parsed_input[:text] || '').strip
        text = text.sub(/^seasonal\s*/i, '') if parsed_input[:command_word] == 'set'

        parts = text.split(/\s+/, 4)
        action = parts[0]&.downcase

        case action
        when 'desc', 'description'
          handle_description(room, parts[1..])
        when 'bg', 'background'
          handle_background(room, parts[1..])
        when 'list'
          handle_list(room)
        when 'clear'
          handle_clear(room, parts[1..])
        else
          show_usage
        end
      end

      private

      def handle_description(room, parts)
        return error_result('Usage: set seasonal desc <time> <season> <description>') if parts.length < 3

        time_input = parts[0]
        season_input = parts[1]
        desc_text = parts[2..].join(' ')

        unless valid_time?(time_input)
          return error_result("Invalid time. Use: #{TIME_OPTIONS.join(', ')}")
        end

        unless valid_season?(season_input)
          return error_result("Invalid season. Use: #{SEASON_OPTIONS.join(', ')}")
        end

        if desc_text.empty?
          return error_result('Please provide a description.')
        end

        # Normalize time/season to nil if '-'
        time = time_input == '-' ? nil : time_input
        season = season_input == '-' ? nil : season_input

        room.set_seasonal_description!(time, season, desc_text)

        key = build_display_key(time, season)
        success_result(
          "Seasonal description set for #{key}.",
          type: :message,
          data: {
            action: 'set_seasonal_description',
            room_id: room.id,
            key: key,
            description: desc_text
          }
        )
      end

      def handle_background(room, parts)
        return error_result('Usage: set seasonal bg <time> <season> <url>') if parts.length < 3

        time_input = parts[0]
        season_input = parts[1]
        url = parts[2..].join(' ').strip

        unless valid_time?(time_input)
          return error_result("Invalid time. Use: #{TIME_OPTIONS.join(', ')}")
        end

        unless valid_season?(season_input)
          return error_result("Invalid season. Use: #{SEASON_OPTIONS.join(', ')}")
        end

        if url.empty?
          return error_result('Please provide a URL.')
        end

        unless url.match?(%r{^https?://})
          return error_result('Please provide a valid URL starting with http:// or https://')
        end

        if url.length > 2048
          return error_result('URL too long (max 2048 characters).')
        end

        time = time_input == '-' ? nil : time_input
        season = season_input == '-' ? nil : season_input

        room.set_seasonal_background!(time, season, url)

        key = build_display_key(time, season)
        success_result(
          "Seasonal background set for #{key}.",
          type: :message,
          data: {
            action: 'set_seasonal_background',
            room_id: room.id,
            key: key,
            url: url
          }
        )
      end

      def handle_list(room)
        descs = room.list_seasonal_descriptions
        bgs = room.list_seasonal_backgrounds

        output_lines = ["Seasonal settings for #{room.name}:"]

        if descs.empty? && bgs.empty?
          output_lines << '  (none set)'
        else
          unless descs.empty?
            output_lines << ''
            output_lines << 'Descriptions:'
            descs.each do |key, value|
              preview = value.length > 50 ? "#{value[0..47]}..." : value
              output_lines << "  #{key}: #{preview}"
            end
          end

          unless bgs.empty?
            output_lines << ''
            output_lines << 'Backgrounds:'
            bgs.each do |key, url|
              output_lines << "  #{key}: #{url}"
            end
          end
        end

        success_result(
          output_lines.join("\n"),
          type: :message,
          data: {
            action: 'list_seasonal',
            room_id: room.id,
            descriptions: descs,
            backgrounds: bgs
          }
        )
      end

      def handle_clear(room, parts)
        return error_result('Usage: set seasonal clear <desc|bg> <time> <season>') if parts.length < 3

        type = parts[0]&.downcase
        time_input = parts[1]
        season_input = parts[2]

        unless valid_time?(time_input)
          return error_result("Invalid time. Use: #{TIME_OPTIONS.join(', ')}")
        end

        unless valid_season?(season_input)
          return error_result("Invalid season. Use: #{SEASON_OPTIONS.join(', ')}")
        end

        time = time_input == '-' ? nil : time_input
        season = season_input == '-' ? nil : season_input
        key = build_display_key(time, season)

        case type
        when 'desc', 'description'
          room.clear_seasonal_description!(time, season)
          success_result("Cleared seasonal description for #{key}.", type: :message)
        when 'bg', 'background'
          room.clear_seasonal_background!(time, season)
          success_result("Cleared seasonal background for #{key}.", type: :message)
        else
          error_result('Specify desc or bg to clear.')
        end
      end

      def show_usage
        lines = [
          'Usage: set seasonal <action> [options]',
          '',
          'Actions:',
          '  desc <time> <season> <text>  - Set a seasonal description',
          '  bg <time> <season> <url>     - Set a seasonal background',
          '  list                         - Show all seasonal settings',
          '  clear <desc|bg> <time> <season> - Remove a setting',
          '',
          'Time options: morning, afternoon, evening, night (or - for any)',
          'Season options: spring, summer, fall, winter (or - for any)',
          '',
          'Examples:',
          '  set seasonal desc morning spring The spring sun rises...',
          '  set seasonal desc - winter Snow falls softly...',
          '  set seasonal bg night - https://example.com/night.jpg',
          '  set seasonal desc default A regular room description...'
        ]

        success_result(lines.join("\n"), type: :message)
      end

      def valid_time?(input)
        TIME_OPTIONS.include?(input.downcase)
      end

      def valid_season?(input)
        SEASON_OPTIONS.include?(input.downcase)
      end

      def build_display_key(time, season)
        if time && season
          "#{time}_#{season}"
        elsif time
          "#{time} (any season)"
        elsif season
          "#{season} (any time)"
        else
          'default'
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::SetSeasonal)
