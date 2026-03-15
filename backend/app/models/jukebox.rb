# frozen_string_literal: true

# Jukebox represents a music player installed in a room.
# Each room can have at most one jukebox with a playlist of tracks.
class Jukebox < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room
  many_to_one :created_by, class: :Character
  one_to_many :tracks, class: :JukeboxTrack, order: :position

  def validate
    super
    validates_presence [:room_id, :name]
    validates_max_length 100, :name
    validates_unique :room_id, message: 'already has a jukebox'
  end

  # === PLAYBACK CONTROL ===

  def play!
    # Start at the first track (position 0)
    first_track = tracks_dataset.order(:position).first
    start_pos = first_track&.position || 0
    update(currently_playing: start_pos, next_play: Time.now)
  end

  def stop!
    update(currently_playing: nil, next_play: nil)
  end

  def playing?
    !currently_playing.nil?
  end

  # Check if jukebox is ready to advance to next track
  # @return [Boolean]
  def ready_for_next?
    playing? && next_play && next_play <= Time.now
  end

  def toggle_shuffle!
    update(shuffle_play: !shuffle_play)
  end

  def toggle_loop!
    update(loop_play: !loop_play)
  end

  # === TRACK MANAGEMENT ===

  def current_track
    return nil unless currently_playing

    tracks_dataset.where(position: currently_playing).first
  end

  def next_track!
    return unless playing?

    next_pos = if shuffle_play
                 tracks_dataset.exclude(position: currently_playing).order(Sequel.lit('RANDOM()')).first&.position
               else
                 currently_playing + 1
               end

    # Check if we've reached the end
    if next_pos.nil? || tracks_dataset.where(position: next_pos).empty?
      if loop_play
        next_pos = tracks_dataset.order(:position).first&.position || 0
      else
        stop!
        return
      end
    end

    update(currently_playing: next_pos)
  end

  def add_track!(url:, title: nil, duration_seconds: nil)
    max_pos = tracks_dataset.max(:position) || -1
    JukeboxTrack.create(
      jukebox_id: id,
      url: url,
      title: title,
      duration_seconds: duration_seconds,
      position: max_pos + 1
    )
  end

  def remove_track!(position)
    tracks_dataset.where(position: position).delete
    # Reorder remaining tracks
    tracks_dataset.where { position > position }.update(position: Sequel[:position] - 1)
  end

  def clear_tracks!
    tracks_dataset.delete
  end

  def track_count
    tracks_dataset.count
  end

  # === DISPLAY ===

  def status_text
    if playing?
      track = current_track
      mode = []
      mode << 'shuffle' if shuffle_play
      mode << 'loop' if loop_play
      mode_str = mode.any? ? " (#{mode.join(', ')})" : ''
      "Playing: #{track&.title || 'Unknown'}#{mode_str}"
    else
      'Stopped'
    end
  end
end
