# frozen_string_literal: true

# JukeboxTrack represents a single track in a jukebox playlist.
class JukeboxTrack < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, create: :created_at, update: false

  many_to_one :jukebox

  def validate
    super
    validates_presence [:jukebox_id, :url, :position]
  end

  # Check if this track is a YouTube video
  def youtube?
    YouTubeMetadataService.youtube_url?(url)
  end

  # Extract YouTube video ID from URL
  def youtube_video_id
    YouTubeMetadataService.extract_video_id(url)
  end

  def embed_url
    return url unless youtube?

    vid = youtube_video_id
    return url unless vid

    "https://www.youtube.com/embed/#{vid}"
  end

  def display_title
    (title && !title.empty?) ? title : "Track #{position + 1}"
  end
end
