# frozen_string_literal: true

# Service for building public profile page data
# Provides character profile with pictures, sections, videos, and settings
class ProfileDisplayService
  attr_reader :character, :viewer

  def initialize(character, viewer: nil)
    @character = character
    @viewer = viewer
  end

  # Build complete public profile data
  # @return [Hash, nil] Profile data or nil if not publicly visible
  def build_profile
    return nil unless @character.publicly_visible?

    {
      id: @character.id,
      name: @character.full_name,
      nickname: @character.nickname,
      account_handle: @character.user&.username,
      background_url: profile_setting&.background_url,
      pictures: ordered_pictures,
      sections: ordered_sections,
      videos: ordered_videos,
      is_owner: viewer_is_owner?
    }
  end

  private

  def profile_setting
    @character.profile_setting
  end

  def ordered_pictures
    @character.profile_pictures_dataset.order(:position).all.map do |pic|
      {
        id: pic.id,
        url: pic.url,
        position: pic.position
      }
    end
  end

  def ordered_sections
    @character.profile_sections_dataset.order(:position).all.map do |section|
      {
        id: section.id,
        title: section.title,
        content: section.content,
        position: section.position
      }
    end
  end

  def ordered_videos
    @character.profile_videos_dataset.order(:position).all.map do |video|
      {
        id: video.id,
        youtube_id: video.youtube_id,
        title: video.title,
        position: video.position
      }
    end
  end

  def viewer_is_owner?
    return false unless @viewer
    @viewer.id == @character.id
  end
end
