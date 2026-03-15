# frozen_string_literal: true

module Commands
  module Entertainment
    class Play < Commands::Base::Command
      command_name 'play'
      aliases 'youtube', 'video'
      category :entertainment
      help_text 'Play a YouTube video as a synchronized watch party in the current room.'
      usage 'play <youtube url>'
      examples 'play https://www.youtube.com/watch?v=dQw4w9WgXcQ',
               'play https://youtu.be/dQw4w9WgXcQ',
               'video https://youtube.com/watch?v=xyz'

      YOUTUBE_REGEX = /^https?:\/\/(www\.)?(youtube\.com\/watch\?v=|youtu\.be\/)/i.freeze
      DEFAULT_DURATION = 300  # 5 minutes default

      protected

      def perform_command(parsed_input)
        url = parsed_input[:text]&.strip || ''

        if blank?(url)
          return error_result("Play what? Provide a YouTube URL. Use: play <youtube url>")
        end

        # Validate YouTube URL
        unless valid_youtube_url?(url)
          return error_result("Invalid URL. Please provide a valid YouTube link.")
        end

        video_id = extract_youtube_id(url)
        duration = DEFAULT_DURATION  # Could fetch from YouTube API

        start_sync_session(url, video_id, duration)
      end

      private

      # Start a synchronized watch party session
      def start_sync_session(url, video_id, duration)
        # Check if there's already a media session
        existing = MediaSession.active_in_room(location.id)
        if existing && !existing.host?(character_instance)
          host_name = existing.host&.character&.full_name || 'Someone'
          return error_result("#{host_name} is already running a watch party. Use 'share stop' first.")
        end

        # Create synchronized session
        session = MediaSyncService.start_youtube(
          room_id: location.id,
          host: character_instance,
          video_id: video_id,
          title: 'YouTube Video',
          duration: duration
        )

        broadcast_to_room(
          "#{character.full_name} started a watch party!",
          exclude_character: nil
        )

        success_result(
          "Watch party started! Others in the room will sync to your playback. Use 'media play' to start.",
          type: :media_action,
          target_panel: Firefly::Panels::RIGHT_MAIN_FEED,
          data: {
            action: 'start_youtube_sync',
            session_id: session.id,
            video_id: video_id,
            is_host: true,
            session: session.to_sync_hash
          }
        )
      end

      def valid_youtube_url?(url)
        url.match?(YOUTUBE_REGEX)
      end

      def extract_youtube_id(url)
        if url.include?('youtu.be/')
          url.split('youtu.be/').last.split(/[?&#]/).first
        elsif url.include?('v=')
          url.split('v=').last.split(/[?&#]/).first
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Entertainment::Play)
