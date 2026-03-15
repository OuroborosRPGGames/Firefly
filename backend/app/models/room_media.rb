# frozen_string_literal: true

class RoomMedia < Sequel::Model(:room_media)
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room
  many_to_one :started_by, class: :CharacterInstance, key: :started_by_id

  def validate
    super
    validates_presence [:room_id, :url]
    validates_includes %w[video audio], :media_type if media_type
  end

  # Check if this media is a YouTube video
  def youtube?
    YouTubeMetadataService.youtube_url?(url)
  end

  def expired?
    ends_at && Time.now > ends_at
  end

  def playing?
    !expired?
  end

  def time_remaining
    return 0 if expired? || ends_at.nil?

    [(ends_at - Time.now).to_i, 0].max
  end

  def stop!
    update(ends_at: Time.now)
  end

  # Extract YouTube video ID from URL
  def youtube_video_id
    YouTubeMetadataService.extract_video_id(url)
  end

  # Get embed URL for YouTube videos
  def embed_url
    return nil unless youtube?

    video_id = youtube_video_id
    return nil unless video_id

    params = []
    params << 'autoplay=1' if autoplay
    param_string = params.any? ? "?#{params.join('&')}" : ''

    "https://www.youtube.com/embed/#{video_id}#{param_string}"
  end

  # Get currently playing media in a room
  def self.playing_in(room_id)
    where(room_id: room_id)
      .where { ends_at > Time.now }
      .order(Sequel.desc(:started_at))
      .first
  end

  # Stop all media playing in a room
  def self.stop_all_in(room_id)
    where(room_id: room_id)
      .where { ends_at > Time.now }
      .update(ends_at: Time.now)
  end
end
