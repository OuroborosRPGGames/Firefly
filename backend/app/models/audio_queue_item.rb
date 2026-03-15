# frozen_string_literal: true

# Represents a queued audio item for TTS playback.
# Used when accessibility mode is enabled to provide sequential narration.
class AudioQueueItem < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character_instance

  # Valid content types for narration
  CONTENT_TYPES = %w[narrator speech system combat room action].freeze

  # Default expiration time for queued items (10 minutes)
  QUEUE_EXPIRY_MINUTES = 10

  def validate
    super
    validates_presence [:character_instance_id, :audio_url, :content_type, :sequence_number]
    validates_includes CONTENT_TYPES, :content_type
  end

  def before_create
    super
    self.queued_at ||= Time.now
    self.expires_at ||= Time.now + (QUEUE_EXPIRY_MINUTES * 60)
  end

  # Mark this item as played
  def mark_played!
    update(played: true, played_at: Time.now)
  end

  # Check if item has expired
  # @return [Boolean]
  def expired?
    expires_at && Time.now > expires_at
  end

  class << self
    # Get the next sequence number for a character instance
    # @param character_instance_id [Integer]
    # @return [Integer]
    def next_sequence_for(character_instance_id)
      max = where(character_instance_id: character_instance_id).max(:sequence_number) || 0
      max + 1
    end

    # Clean up expired queue items
    # @return [Integer] number of deleted items
    def cleanup_expired!
      where { expires_at < Time.now }.delete
    end

    # Get pending items for a character instance
    # @param character_instance_id [Integer]
    # @param from_position [Integer, nil] starting sequence number
    # @param limit [Integer] max items to return
    # @return [Array<AudioQueueItem>]
    def pending_for(character_instance_id, from_position: 0, limit: 20)
      where(character_instance_id: character_instance_id, played: false)
        .where { sequence_number > from_position }
        .order(:sequence_number)
        .limit(limit)
        .all
    end
  end

  # Convert to hash for API response
  # @return [Hash]
  def to_api_hash
    {
      id: id,
      sequence: sequence_number,
      audio_url: audio_url,
      content_type: content_type,
      text: original_text,
      voice: voice_type,
      duration: duration_seconds,
      queued_at: queued_at&.iso8601,
      played: played
    }
  end
end
