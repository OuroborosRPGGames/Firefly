# frozen_string_literal: true

# MediaSyncService coordinates Watch2Gether-style media sharing.
# Uses Redis for real-time state synchronization since AnyCable isn't integrated yet.
#
# Flow:
# 1. Host starts share -> creates MediaSession, stores peer_id
# 2. Viewers poll -> get session info including host peer_id
# 3. Viewers connect to host via PeerJS cloud signaling
# 4. Host sends controls -> updates Redis -> viewers get via poll
#
module MediaSyncService
  class SessionConflictError < StandardError; end

  class << self
    REDIS_PREFIX = 'media_sync'
    SYNC_TTL = GameConfig::Cache::SYNC_TTL
    HEARTBEAT_TIMEOUT = GameConfig::Timeouts::HEARTBEAT_TIMEOUT_SECONDS

    # === Session Management ===

    # Start a YouTube sync session
    # @param room_id [Integer] Room to create session in
    # @param host [CharacterInstance] Host character
    # @param video_id [String] YouTube video ID
    # @param title [String] Video title
    # @param duration [Integer] Duration in seconds
    # @return [MediaSession]
    def start_youtube(room_id:, host:, video_id:, title: nil, duration: nil, playlist_id: nil, playlist_position: nil, force: false)
      existing = MediaSession.active_in_room(room_id)
      if existing
        if !force && existing.host_id != host.id
          raise SessionConflictError, 'Another host is already running media in this room'
        end
        end_room_session(room_id)
      end

      session = MediaSession.create(
        room_id: room_id,
        host_id: host.id,
        session_type: 'youtube',
        youtube_video_id: video_id,
        youtube_title: title || 'YouTube Video',
        youtube_duration_seconds: duration,
        status: 'active',
        is_playing: true,
        playback_position: 0.0,
        playback_started_at: Time.now,
        last_heartbeat: Time.now,
        playlist_id: playlist_id,
        playlist_position: playlist_position
      )

      # Cache in Redis for fast polling
      cache_session_state(session)

      # Notify room (via Redis for polling)
      broadcast_to_room(room_id, {
        type: 'media_session_started',
        session: session.to_sync_hash
      })

      session
    end

    # Start a screen/tab share session
    # @param room_id [Integer] Room to create session in
    # @param host [CharacterInstance] Host character
    # @param peer_id [String] Host's PeerJS peer ID
    # @param share_type [String] 'screen', 'window', or 'tab'
    # @param has_audio [Boolean] Whether audio is being captured
    # @return [MediaSession]
    def start_screen_share(room_id:, host:, peer_id:, share_type:, has_audio: false, force: false)
      existing = MediaSession.active_in_room(room_id)
      if existing
        if !force && existing.host_id != host.id
          raise SessionConflictError, 'Another host is already running media in this room'
        end
        end_room_session(room_id)
      end

      session_type = share_type == 'tab' ? 'tab_share' : 'screen_share'

      session = MediaSession.create(
        room_id: room_id,
        host_id: host.id,
        session_type: session_type,
        peer_id: peer_id,
        share_type: share_type,
        has_audio: has_audio,
        status: 'active',
        is_playing: true,  # Screen shares are always "playing"
        last_heartbeat: Time.now
      )

      cache_session_state(session)

      broadcast_to_room(room_id, {
        type: 'media_session_started',
        session: session.to_sync_hash
      })

      session
    end

    # End session in a room
    # @param room_id [Integer]
    def end_room_session(room_id)
      session = MediaSession.active_in_room(room_id)
      return unless session

      session.end_session!
      clear_session_cache(session.id)

      broadcast_to_room(room_id, {
        type: 'media_session_ended',
        session_id: session.id
      })
    end

    # === Playback Controls (Host Only) ===

    # Resume playback
    # @param session [MediaSession]
    # @param position [Float, nil] Optional position to seek to
    # @return [Hash] { success: Boolean, session: Hash, error: String }
    def play(session, position: nil)
      unless session.active? || session.paused?
        return { success: false, error: 'Session not active' }
      end

      session.play!(position: position)
      cache_session_state(session)

      broadcast_to_room(session.room_id, {
        type: 'media_playback_update',
        action: 'play',
        session: session.to_sync_hash
      })

      { success: true, session: session.to_sync_hash }
    end

    # Pause playback
    # @param session [MediaSession]
    # @return [Hash]
    def pause(session)
      return { success: false, error: 'Not playing' } unless session.is_playing

      session.pause!
      cache_session_state(session)

      broadcast_to_room(session.room_id, {
        type: 'media_playback_update',
        action: 'pause',
        session: session.to_sync_hash
      })

      { success: true, session: session.to_sync_hash }
    end

    # Seek to position
    # @param session [MediaSession]
    # @param position [Float] Position in seconds
    # @return [Hash]
    def seek(session, position)
      session.seek!(position)
      cache_session_state(session)

      broadcast_to_room(session.room_id, {
        type: 'media_playback_update',
        action: 'seek',
        position: position,
        session: session.to_sync_hash
      })

      { success: true, session: session.to_sync_hash }
    end

    # Set buffering state (host is buffering, viewers should pause)
    # @param session [MediaSession]
    # @param position [Float, nil] Current position when buffering started
    # @return [Hash]
    def buffering(session, position: nil)
      session.update(
        is_buffering: true,
        playback_position: position || session.current_position
      )
      cache_session_state(session)

      broadcast_to_room(session.room_id, {
        type: 'media_playback_update',
        action: 'buffering',
        session: session.to_sync_hash
      })

      { success: true, session: session.to_sync_hash }
    end

    # Change playback rate
    # @param session [MediaSession]
    # @param rate [Float] Playback rate (0.5, 1.0, 1.5, 2.0, etc.)
    # @return [Hash]
    def set_rate(session, rate)
      # Validate rate is reasonable
      rate = [[0.25, rate].max, 2.0].min

      session.update(playback_rate: rate)
      cache_session_state(session)

      broadcast_to_room(session.room_id, {
        type: 'media_playback_update',
        action: 'rate',
        playback_rate: rate,
        session: session.to_sync_hash
      })

      { success: true, session: session.to_sync_hash }
    end

    # Broadcast a general session update (for state changes not covered by specific methods)
    # @param session [MediaSession]
    # @return [Hash]
    def broadcast_update(session)
      session.refresh
      cache_session_state(session)

      broadcast_to_room(session.room_id, {
        type: 'media_playback_update',
        action: 'update',
        session: session.to_sync_hash
      })

      { success: true, session: session.to_sync_hash }
    end

    # === Viewer Management ===

    # Register a viewer joining a session
    # @param session [MediaSession]
    # @param character_instance [CharacterInstance]
    # @param peer_id [String] Viewer's PeerJS peer ID
    # @return [Hash] Current session state for sync
    def viewer_join(session, character_instance, peer_id)
      viewer = MediaSessionViewer.find_or_create(
        media_session_id: session.id,
        character_instance_id: character_instance.id
      ) do |v|
        v.peer_id = peer_id
        v.connection_status = 'pending'
      end

      viewer.update(
        peer_id: peer_id,
        connection_status: 'pending',
        joined_at: Time.now
      )

      # Return current session state for immediate sync
      session.to_sync_hash
    end

    # Mark viewer as connected (WebRTC established)
    # @param session [MediaSession]
    # @param character_instance [CharacterInstance]
    def viewer_connected(session, character_instance)
      viewer = session.viewers_dataset.where(character_instance_id: character_instance.id).first
      viewer&.mark_connected!
    end

    # Mark viewer as disconnected
    # @param session [MediaSession]
    # @param character_instance [CharacterInstance]
    def viewer_disconnected(session, character_instance)
      viewer = session.viewers_dataset.where(character_instance_id: character_instance.id).first
      viewer&.mark_disconnected!
    end

    # === Polling Support ===

    # Get current session state for a room (called by polling endpoint)
    # @param room_id [Integer]
    # @return [Hash, nil] Session state or nil if none
    def fetch_room_session(room_id)
      # Try Redis cache first
      cached = cached_session_by_room(room_id)
      return cached if cached

      # Fall back to database
      session = MediaSession.active_in_room(room_id)
      return nil unless session

      cache_session_state(session)
      session.to_sync_hash
    end

    # Get pending events for a room since timestamp
    # @param room_id [Integer]
    # @param since_timestamp [String, nil] ISO8601 timestamp
    # @return [Array<Hash>]
    def room_events(room_id, since_timestamp: nil)
      REDIS_POOL.with do |redis|
        events = redis.lrange("#{REDIS_PREFIX}:events:#{room_id}", 0, -1)
        parsed = events.map { |e| JSON.parse(e, symbolize_names: true) }

        if since_timestamp && !since_timestamp.empty?
          cutoff = Time.parse(since_timestamp)
          parsed.select { |e| Time.parse(e[:timestamp]) > cutoff }
        else
          parsed
        end
      end
    rescue Redis::BaseError, JSON::ParserError => e
      warn "[MediaSyncService] Error getting events: #{e.message}"
      []
    end

    # Host heartbeat to keep session alive
    # @param session [MediaSession]
    def heartbeat(session)
      session.heartbeat!
      refresh_session_cache(session)
    end

    # Cleanup stale sessions (call from scheduler)
    def cleanup_stale_sessions!
      MediaSession.cleanup_stale_sessions!
    end

    private

    # === Redis Caching ===

    def cache_session_state(session)
      REDIS_POOL.with do |redis|
        # Store by session ID
        redis.setex(
          "#{REDIS_PREFIX}:session:#{session.id}",
          SYNC_TTL,
          session.to_sync_hash.to_json
        )
        # Index by room for fast lookup
        redis.setex(
          "#{REDIS_PREFIX}:room:#{session.room_id}",
          SYNC_TTL,
          session.id.to_s
        )
      end
    rescue Redis::BaseError => e
      warn "[MediaSyncService] Redis cache error: #{e.message}"
    end

    def cached_session_by_room(room_id)
      REDIS_POOL.with do |redis|
        session_id = redis.get("#{REDIS_PREFIX}:room:#{room_id}")
        return nil unless session_id

        cached = redis.get("#{REDIS_PREFIX}:session:#{session_id}")
        return nil unless cached

        JSON.parse(cached, symbolize_names: true)
      end
    rescue Redis::BaseError, JSON::ParserError
      nil
    end

    def clear_session_cache(session_id)
      REDIS_POOL.with do |redis|
        session_data = redis.get("#{REDIS_PREFIX}:session:#{session_id}")
        if session_data
          data = JSON.parse(session_data)
          redis.del("#{REDIS_PREFIX}:room:#{data['room_id']}")
        end
        redis.del("#{REDIS_PREFIX}:session:#{session_id}")
      end
    rescue Redis::BaseError
      nil
    end

    def refresh_session_cache(session)
      REDIS_POOL.with do |redis|
        redis.expire("#{REDIS_PREFIX}:session:#{session.id}", SYNC_TTL)
        redis.expire("#{REDIS_PREFIX}:room:#{session.room_id}", SYNC_TTL)
      end
    rescue Redis::BaseError
      nil
    end

    # === Broadcasting via Redis ===

    def broadcast_to_room(room_id, message)
      message_with_meta = message.merge(
        timestamp: Time.now.iso8601,
        room_id: room_id
      )

      REDIS_POOL.with do |redis|
        # Push to room's media event queue
        redis.rpush("#{REDIS_PREFIX}:events:#{room_id}", message_with_meta.to_json)
        redis.expire("#{REDIS_PREFIX}:events:#{room_id}", SYNC_TTL)

        # Keep only last 50 events
        redis.ltrim("#{REDIS_PREFIX}:events:#{room_id}", -50, -1)
      end
    rescue Redis::BaseError => e
      warn "[MediaSyncService] Broadcast error: #{e.message}"
    end
  end
end
