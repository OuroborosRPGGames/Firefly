# frozen_string_literal: true

module Commands
  module Entertainment
    class MediaControl < Commands::Base::Command
      command_name 'media'
      aliases 'mc', 'watchparty', 'share', 'player', 'jukebox', 'playlist'
      category :entertainment
      help_text 'Control media playback, sharing, and playlists'
      usage 'media [play|pause|stop|seek <time>|share|playlist|status]'
      examples 'media', 'media play', 'media pause', 'media seek 1:30', 'media share screen', 'media playlist'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        text = parsed_input[:text]&.strip || ''
        full_input = parsed_input[:full_input]&.strip || ''

        # Detect alias used - check the full input to detect which alias was used
        called_as_share = full_input.match?(/^share(\s|$)/i)
        called_as_player = full_input.match?(/^(player|jukebox)(\s|$)/i)
        called_as_playlist = full_input.match?(/^playlist(\s|$)/i)

        # Strip command prefix from text for further processing
        text = full_input.sub(/^(media|mc|watchparty|share|player|jukebox|playlist)\s*/i, '').strip

        # If called as share, delegate to share handling
        if called_as_share
          return handle_share_command(text)
        end

        # If called as player/jukebox, delegate to player handling
        if called_as_player
          return handle_player_command(text)
        end

        # If called as playlist, delegate to playlist handling
        if called_as_playlist
          return handle_playlist_command(text)
        end

        # No args - show media menu
        if args.empty? && text.empty?
          return show_media_menu
        end

        action = args.first&.to_s&.downcase || text.split.first&.downcase

        case action
        when 'play', 'resume'
          handle_play_action
        when 'pause'
          handle_pause_action
        when 'stop'
          handle_stop_action
        when 'seek', 'skip', 'goto'
          time_str = args[1] || text.split[1]
          handle_seek_action(time_str)
        when 'status'
          show_media_status
        when 'share', 'screen', 'tab'
          handle_share_command(text.sub(/^share\s*/i, ''))
        when 'player', 'jukebox'
          handle_player_command(text.sub(/^(player|jukebox)\s*/i, ''))
        when 'playlist'
          handle_playlist_command(text.sub(/^playlist\s*/i, ''))
        else
          error_result("Unknown action '#{action}'. Use: media play, media pause, media stop, media share, media playlist")
        end
      end

      private

      def show_media_menu
        success_result(
          "Opening media panel...",
          type: :open_gui,
          data: { gui: 'media' }
        )
      end

      def show_media_status
        session = MediaSession.active_in_room(location.id)

        unless session
          return success_result(
            "No active media session in this room.",
            type: :media_status,
            data: { session: nil }
          )
        end

        is_host = session.host?(character_instance)
        host_name = session.host&.character&.full_name || 'Someone'

        if session.youtube?
          position = session.current_position.to_i
          duration = session.youtube_duration_seconds || 0
          status = session.is_playing ? 'Playing' : 'Paused'

          lines = []
          lines << "Watch Party - #{session.youtube_title || 'YouTube Video'}"
          lines << "Status: #{status} at #{format_duration_seconds(position)}#{duration > 0 ? " / #{format_duration_seconds(duration)}" : ''}"
          lines << "Host: #{host_name}"
          lines << "Viewers: #{session.viewer_count}"
          lines << ""
          lines << is_host ? "Controls: media play | media pause | media seek <time>" : "Only the host can control playback."

          success_result(
            lines.join("\n"),
            type: :media_status,
            data: {
              is_host: is_host,
              session: session.to_sync_hash
            }
          )
        else
          share_desc = session.share_type == 'tab' ? 'browser tab' : 'screen'
          audio_status = session.has_audio ? ' with audio' : ''

          lines = []
          lines << "Screen Share - #{share_desc}#{audio_status}"
          lines << "Host: #{host_name}"
          lines << "Viewers: #{session.viewer_count}"

          success_result(
            lines.join("\n"),
            type: :media_status,
            data: {
              is_host: is_host,
              session: session.to_sync_hash
            }
          )
        end
      end

      # ========== Playback Controls ==========

      def handle_play_action
        session = MediaSession.active_in_room(location.id)
        unless session
          return error_result("No active media session. Use 'play <youtube url>' to start.")
        end

        if session.youtube? && !session.host?(character_instance)
          host_name = session.host&.character&.full_name || 'the host'
          return error_result("Only #{host_name} can control playback.")
        end

        if session.is_playing
          return success_result("Already playing.", data: { session: session.to_sync_hash })
        end

        result = MediaSyncService.play(session)

        if result[:success]
          broadcast_to_room("#{character.full_name} resumed playback.", exclude_character: nil)
          success_result("Resumed playback.", type: :media_action, data: { action: 'media_play', session: result[:session] })
        else
          error_result(result[:error])
        end
      end

      def handle_pause_action
        session = MediaSession.active_in_room(location.id)
        unless session
          return error_result("No active media session.")
        end

        if session.youtube? && !session.host?(character_instance)
          host_name = session.host&.character&.full_name || 'the host'
          return error_result("Only #{host_name} can control playback.")
        end

        unless session.is_playing
          return success_result("Already paused.", data: { session: session.to_sync_hash })
        end

        result = MediaSyncService.pause(session)

        if result[:success]
          position = session.current_position.to_i
          broadcast_to_room("#{character.full_name} paused at #{format_duration_seconds(position)}.", exclude_character: nil)
          success_result("Paused playback.", type: :media_action, data: { action: 'media_pause', session: result[:session] })
        else
          error_result(result[:error])
        end
      end

      def handle_stop_action
        # Check for media session first
        session = MediaSession.active_in_room(location.id)
        if session
          unless session.host?(character_instance)
            host_name = session.host&.character&.full_name || 'the host'
            return error_result("Only #{host_name} can stop this session.")
          end

          MediaSyncService.end_room_session(location.id)
          broadcast_to_room("#{character.full_name} stopped the media session.", exclude_character: nil)
          return success_result("Media session ended.", type: :media_action, data: { action: 'stop_media' })
        end

        # Check for room media
        current_media = RoomMedia.playing_in(location.id)
        if current_media
          current_media.stop!
          broadcast_to_room("#{character.full_name} stops the video.", exclude_character: nil)
          return success_result("You stop the video.", type: :message, data: { action: 'stop_media', media_id: current_media.id })
        end

        error_result("Nothing is currently playing.")
      end

      def handle_seek_action(time_str)
        session = MediaSession.active_in_room(location.id)
        unless session
          return error_result("No active media session.")
        end

        if session.youtube? && !session.host?(character_instance)
          host_name = session.host&.character&.full_name || 'the host'
          return error_result("Only #{host_name} can control playback.")
        end

        return error_result("Specify a time: media seek 1:30") unless time_str

        seconds = parse_time_string(time_str)
        return error_result("Invalid time format. Use MM:SS or seconds.") unless seconds

        if session.youtube_duration_seconds && seconds > session.youtube_duration_seconds
          seconds = session.youtube_duration_seconds
        end

        result = MediaSyncService.seek(session, seconds)

        if result[:success]
          broadcast_to_room("#{character.full_name} skipped to #{format_duration_seconds(seconds)}.", exclude_character: nil)
          success_result("Seeked to #{format_duration_seconds(seconds)}.", type: :media_action, data: { action: 'media_seek', position: seconds, session: result[:session] })
        else
          error_result(result[:error])
        end
      end

      # ========== Share Commands ==========

      def handle_share_command(args_text)
        args = args_text.split
        action = args.first&.downcase

        if action.nil? || action == 'status'
          return show_share_status
        end

        case action
        when 'screen', 'window'
          start_screen_share('screen')
        when 'tab', 'browser'
          start_tab_share
        when 'stop', 'end'
          stop_sharing
        else
          error_result("Unknown share type. Use: media share screen, media share tab, or media share stop")
        end
      end

      def show_share_status
        session = MediaSession.active_in_room(location.id)

        if session
          if session.host?(character_instance)
            viewer_count = session.viewer_count
            share_desc = session.youtube? ? 'YouTube video' : (session.share_type || 'content')
            msg = "You are currently sharing #{share_desc}. #{viewer_count} viewer#{viewer_count == 1 ? '' : 's'} connected."
            success_result(msg, type: :media_status, data: { is_host: true, session: session.to_sync_hash })
          else
            host_name = session.host&.character&.full_name || 'Someone'
            share_desc = session.youtube? ? 'a YouTube video' : "their #{session.share_type || 'screen'}"
            success_result("#{host_name} is sharing #{share_desc}.", type: :media_status, data: { is_host: false, session: session.to_sync_hash })
          end
        else
          success_result("No active share in this room. Use 'media share screen' or 'media share tab' to start.", type: :media_status, data: { session: nil })
        end
      end

      def start_screen_share(share_type)
        existing = MediaSession.active_in_room(location.id)
        if existing && !existing.host?(character_instance)
          host_name = existing.host&.character&.full_name || 'Someone'
          return error_result("#{host_name} is already sharing. They must stop first.")
        end

        broadcast_to_room("#{character.full_name} is starting to share their screen...", exclude_character: character_instance)

        success_result(
          "Starting screen share... Select what to share in the browser prompt.",
          type: :media_action,
          target_panel: Firefly::Panels::LEFT_MAIN_FEED,
          data: { action: 'start_screen_share', share_type: share_type, room_id: location.id }
        )
      end

      def start_tab_share
        existing = MediaSession.active_in_room(location.id)
        if existing && !existing.host?(character_instance)
          host_name = existing.host&.character&.full_name || 'Someone'
          return error_result("#{host_name} is already sharing. They must stop first.")
        end

        broadcast_to_room("#{character.full_name} is starting to share a browser tab...", exclude_character: character_instance)

        success_result(
          "Starting tab share... Select a browser tab to share (Chrome only for audio).",
          type: :media_action,
          target_panel: Firefly::Panels::LEFT_MAIN_FEED,
          data: { action: 'start_tab_share', share_type: 'tab', room_id: location.id, request_audio: true }
        )
      end

      def stop_sharing
        session = MediaSession.active_in_room(location.id)

        unless session
          return error_result("No active share to stop.")
        end

        unless session.host?(character_instance)
          host_name = session.host&.character&.full_name || 'the host'
          return error_result("Only #{host_name} can stop this share.")
        end

        MediaSyncService.end_room_session(location.id)
        broadcast_to_room("#{character.full_name} stopped sharing.", exclude_character: nil)
        success_result("Share ended.", type: :media_action, data: { action: 'stop_share' })
      end

      # ========== Player/Jukebox Commands ==========

      def handle_player_command(args_text)
        jukebox = location.respond_to?(:jukebox) ? location.jukebox : nil
        unless jukebox
          return error_result('There is no player here.')
        end

        args = args_text.split
        action = args.first&.downcase

        if action.nil?
          return show_player_status(jukebox)
        end

        case action
        when 'play', 'start'
          player_play(jukebox)
        when 'stop'
          player_stop(jukebox)
        when 'shuffle'
          player_shuffle(jukebox)
        when 'loop'
          player_loop(jukebox)
        else
          error_result('Syntax: media player play|stop|shuffle|loop')
        end
      end

      def show_player_status(jukebox)
        status = jukebox.playing? ? 'Playing' : 'Stopped'
        modes = []
        modes << 'shuffle' if jukebox.shuffle_play
        modes << 'loop' if jukebox.loop_play
        mode_str = modes.any? ? " [#{modes.join(', ')}]" : ''

        lines = ["#{jukebox.name} - #{status}#{mode_str}", "Tracks: #{jukebox.track_count}", "", "Controls: media player play|stop|shuffle|loop"]
        success_result(lines.join("\n"), type: :message, data: { jukebox_id: jukebox.id, playing: jukebox.playing? })
      end

      def player_play(jukebox)
        if jukebox.track_count.zero?
          return error_result('The playlist is empty. Use "media playlist add <url>" to add tracks.')
        end

        if jukebox.playing?
          return error_result("#{jukebox.name} is already playing.")
        end

        jukebox.play!
        JukeboxPlaybackService.play_track_now(jukebox)
        action_message = "#{character.full_name} starts #{jukebox.name}."
        broadcast_to_room(action_message, type: :action)
        success_result(action_message, type: :action, data: { action: 'player_play', jukebox_id: jukebox.id })
      end

      def player_stop(jukebox)
        unless jukebox.playing?
          return error_result("#{jukebox.name} is not playing.")
        end

        jukebox.stop!
        action_message = "#{character.full_name} stops #{jukebox.name}."
        broadcast_to_room(action_message, type: :action)
        success_result(action_message, type: :action, data: { action: 'player_stop', jukebox_id: jukebox.id })
      end

      def player_shuffle(jukebox)
        jukebox.toggle_shuffle!
        mode = jukebox.shuffle_play ? 'shuffle' : 'sequential'
        action_message = "#{character.full_name} sets #{jukebox.name} to #{mode}."
        broadcast_to_room(action_message, type: :action)
        success_result(action_message, type: :action, data: { action: 'player_shuffle', jukebox_id: jukebox.id, shuffle: jukebox.shuffle_play })
      end

      def player_loop(jukebox)
        jukebox.toggle_loop!
        mode = jukebox.loop_play ? 'loop' : 'stop looping'
        action_message = "#{character.full_name} sets #{jukebox.name} to #{mode}."
        broadcast_to_room(action_message, type: :action)
        success_result(action_message, type: :action, data: { action: 'player_loop', jukebox_id: jukebox.id, loop: jukebox.loop_play })
      end

      # ========== Playlist Commands ==========

      def handle_playlist_command(args_text)
        jukebox = location.respond_to?(:jukebox) ? location.jukebox : nil
        unless jukebox
          return error_result('There is no player here. Use "make music player <name>" to create one.')
        end

        args = args_text.split(/\s+/, 2)
        action = args.first&.downcase

        if action.nil? || action == 'list'
          return show_playlist(jukebox)
        end

        # Check permission
        unless can_edit_playlist?
          return error_result("You don't have permission to edit this playlist.")
        end

        case action
        when 'add'
          playlist_add(jukebox, args[1])
        when 'remove', 'delete'
          playlist_remove(jukebox, args[1]&.to_i || 0)
        when 'clear'
          playlist_clear(jukebox)
        else
          if args_text.include?('http')
            playlist_add(jukebox, args_text)
          else
            error_result('Syntax: media playlist [add <url>|remove <number>|clear|list]')
          end
        end
      end

      def can_edit_playlist?
        outer_room = location
        outer_room = outer_room.inside_room while outer_room.respond_to?(:inside_room) && outer_room.inside_room
        outer_room.owned_by?(character) || character.staff?
      end

      def show_playlist(jukebox)
        tracks = jukebox.tracks

        if tracks.empty?
          return success_result(
            "#{jukebox.name} playlist is empty.\nUse 'media playlist add <url>' to add tracks.",
            type: :message,
            data: { action: 'playlist_list', jukebox_id: jukebox.id, tracks: [] }
          )
        end

        lines = ["<h3>#{jukebox.name} Playlist</h3>"]
        tracks.each do |track|
          duration = track.duration_seconds ? " (#{format_duration_seconds(track.duration_seconds)})" : ''
          lines << "[#{track.position + 1}] #{track.display_title}#{duration}"
        end

        status = []
        status << 'shuffle' if jukebox.shuffle_play
        status << 'loop' if jukebox.loop_play
        status_str = status.any? ? " [#{status.join(', ')}]" : ''
        lines << "\nStatus: #{jukebox.playing? ? 'Playing' : 'Stopped'}#{status_str}"

        tracks_data = tracks.map { |t| { position: t.position, title: t.display_title, url: t.url, duration: t.duration_seconds } }

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'playlist_list', jukebox_id: jukebox.id, jukebox_name: jukebox.name, track_count: tracks.size, tracks: tracks_data }
        )
      end

      def playlist_add(jukebox, url)
        if blank?(url)
          return error_result('Please provide a URL. Usage: media playlist add <url>')
        end

        unless url.start_with?('http://') || url.start_with?('https://')
          return error_result('Please provide a valid URL starting with http:// or https://')
        end

        title = "Track #{jukebox.track_count + 1}"
        track = jukebox.add_track!(url: url, title: title)

        success_result(
          "Added '#{title}' to #{jukebox.name} playlist.",
          type: :action,
          data: { action: 'playlist_add', jukebox_id: jukebox.id, track_id: track.id, title: title, url: url }
        )
      end

      def playlist_remove(jukebox, position)
        if position < 1
          return error_result('Please specify a valid track number. Usage: media playlist remove <number>')
        end

        track_position = position - 1
        track = jukebox.tracks_dataset.where(position: track_position).first

        unless track
          return error_result("Track ##{position} not found.")
        end

        title = track.display_title
        jukebox.remove_track!(track_position)

        success_result(
          "Removed '#{title}' from #{jukebox.name} playlist.",
          type: :action,
          data: { action: 'playlist_remove', jukebox_id: jukebox.id, position: position, title: title }
        )
      end

      def playlist_clear(jukebox)
        count = jukebox.track_count
        jukebox.clear_tracks!
        jukebox.stop! if jukebox.playing?

        success_result(
          "Cleared #{count} tracks from #{jukebox.name} playlist.",
          type: :action,
          data: { action: 'playlist_clear', jukebox_id: jukebox.id, removed_count: count }
        )
      end

      # ========== Helpers ==========

      def parse_time_string(str)
        str = str.to_s.strip
        return nil if str.empty?

        if str.include?(':')
          raw_parts = str.split(':')
          return nil if raw_parts.length > 3 || raw_parts.length < 2
          return nil unless raw_parts.all? { |p| p.match?(/^\d+$/) }

          parts = raw_parts.map(&:to_i)
          return nil if parts.any?(&:negative?)

          if parts.length == 3
            return nil if parts[1] > 59 || parts[2] > 59
          elsif parts.length == 2
            return nil if parts[1] > 59
          end

          seconds = parts.reverse.each_with_index.sum { |n, i| n * (60**i) }
          return nil if seconds > 86_400

          seconds
        else
          return nil unless str.match?(/^\d+$/)

          val = str.to_i
          return nil if val.negative? || val > 86_400

          val
        end
      end

      def format_duration_seconds(seconds)
        seconds = seconds.to_i
        mins = seconds / 60
        secs = seconds % 60
        "#{mins}:#{secs.to_s.rjust(2, '0')}"
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Entertainment::MediaControl)
