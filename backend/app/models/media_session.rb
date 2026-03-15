# frozen_string_literal: true

# MediaSession represents a synchronized media playback session (Watch2Gether-style).
# Supports YouTube sync and screen/tab sharing via PeerJS WebRTC.
#
# Session types:
# - youtube: Synchronized YouTube video playback
# - screen_share: WebRTC screen sharing
# - tab_share: WebRTC browser tab sharing (with audio in Chrome)
#
class MediaSession < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room
  many_to_one :host, class: :CharacterInstance, key: :host_id
  many_to_one :playlist, class: :MediaPlaylist
  one_to_many :viewers, class: :MediaSessionViewer

  TYPES = %w[youtube screen_share tab_share].freeze
  status_enum :status, %w[active paused ended]
  SHARE_TYPES = %w[screen window tab].freeze

  def validate
    super
    validates_presence [:room_id, :host_id, :session_type]
    validates_includes TYPES, :session_type
    validate_status_enum
    validates_includes SHARE_TYPES, :share_type if share_type
    validates_presence :youtube_video_id if session_type == 'youtube'
    validates_presence :peer_id if %w[screen_share tab_share].include?(session_type)
  end

  # === Class Methods ===

  # Find active session in a room
  def self.active_in_room(room_id)
    where(room_id: room_id)
      .where(status: %w[active paused])
      .first
  end

  # Cleanup stale sessions (no heartbeat for 2+ minutes)
  def self.cleanup_stale_sessions!
    where(status: %w[active paused])
      .where { last_heartbeat < Time.now - GameConfig::Timeouts::HEARTBEAT_TIMEOUT_SECONDS }
      .update(status: 'ended', ended_at: Time.now)
  end

  # === Type Checks ===

  def youtube?
    session_type == 'youtube'
  end

  def screen_share?
    session_type == 'screen_share'
  end

  def tab_share?
    session_type == 'tab_share'
  end

  def webrtc_share?
    screen_share? || tab_share?
  end

  def host?(character_instance)
    return false unless character_instance

    host_id == character_instance.id
  end

  # === Playback Position (with drift correction) ===

  # Calculate current playback position accounting for time drift
  # When playing, position = saved_position + (now - started_at) * rate
  def current_position
    return playback_position || 0.0 unless is_playing && playback_started_at

    elapsed = Time.now - playback_started_at
    (playback_position || 0.0) + (elapsed * (playback_rate || 1.0))
  end

  # === Host Playback Controls ===

  def play!(position: nil)
    updates = {
      is_playing: true,
      is_buffering: false,
      playback_started_at: Time.now,
      status: 'active'
    }
    updates[:playback_position] = position if position
    update(updates)
  end

  def pause!
    # Save current position before pausing
    update(
      is_playing: false,
      is_buffering: false,
      playback_position: current_position,
      playback_started_at: nil,
      status: 'paused'
    )
  end

  def seek!(position)
    updates = { playback_position: position.to_f }
    updates[:playback_started_at] = Time.now if is_playing
    update(updates)
  end

  def end_session!
    update(status: 'ended', ended_at: Time.now, is_playing: false)
    viewers_dataset.update(connection_status: 'disconnected')
  end

  def heartbeat!
    update(last_heartbeat: Time.now)
  end

  # === Viewer Management ===

  def connected_viewers
    viewers_dataset.where(connection_status: 'connected')
  end

  def viewer_count
    connected_viewers.count
  end

  # === API Response ===

  def to_sync_hash
    {
      id: id,
      type: session_type,
      room_id: room_id,
      host_id: host_id,
      host_peer_id: peer_id,
      host_name: host&.character&.full_name,
      status: status,
      is_playing: is_playing,
      is_buffering: is_buffering || false,
      position: current_position,
      playback_rate: playback_rate || 1.0,
      playback_started_at: playback_started_at&.iso8601,
      youtube_video_id: youtube_video_id,
      youtube_title: youtube_title,
      youtube_duration: youtube_duration_seconds,
      share_type: share_type,
      has_audio: has_audio,
      viewer_count: viewer_count,
      started_at: started_at&.iso8601,
      playlist_id: playlist_id,
      playlist_position: playlist_position
    }
  end

  # === Buffering State ===

  def buffering!
    update(is_buffering: true)
  end

  def unbuffer!
    update(is_buffering: false)
  end
end
