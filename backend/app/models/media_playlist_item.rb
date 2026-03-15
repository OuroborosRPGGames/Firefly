# frozen_string_literal: true

# MediaPlaylistItem represents a single video entry in a media playlist.
class MediaPlaylistItem < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, create: :created_at, update: false

  many_to_one :media_playlist

  def validate
    super
    validates_presence [:media_playlist_id, :youtube_video_id, :position]
    validates_max_length 20, :youtube_video_id
  end

  def display_title
    (!title.nil? && !title.empty?) ? title : "Video #{position + 1}"
  end

  def to_hash
    {
      id: id,
      youtube_video_id: youtube_video_id,
      title: title,
      thumbnail_url: thumbnail_url,
      duration_seconds: duration_seconds,
      is_embeddable: is_embeddable,
      position: position
    }
  end
end
