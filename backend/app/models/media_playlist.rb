# frozen_string_literal: true

# MediaPlaylist represents a saved playlist of YouTube videos for a character.
# Each character can have multiple named playlists.
class MediaPlaylist < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  one_to_many :items, class: :MediaPlaylistItem, order: :position

  def validate
    super
    validates_presence [:character_id, :name]
    validates_max_length 100, :name
    validates_unique [:character_id, :name], message: 'already exists'
  end

  # === Item Management ===

  def add_item!(attrs)
    max_pos = items_dataset.max(:position) || -1
    MediaPlaylistItem.create(
      media_playlist_id: id,
      youtube_video_id: attrs[:youtube_video_id],
      title: attrs[:title],
      thumbnail_url: attrs[:thumbnail_url],
      duration_seconds: attrs[:duration_seconds],
      is_embeddable: attrs.fetch(:is_embeddable, true),
      position: max_pos + 1
    )
  end

  def remove_item!(pos)
    items_dataset.where(position: pos).delete
    # Reorder remaining items
    items_dataset.where(Sequel[:position] > pos).update(position: Sequel[:position] - 1)
  end

  def clear_items!
    items_dataset.delete
  end

  def item_count
    items_dataset.count
  end

  # === Display ===

  def to_hash
    {
      id: id,
      name: name,
      character_id: character_id,
      item_count: item_count,
      items: items.map(&:to_hash),
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end
end
