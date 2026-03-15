# frozen_string_literal: true

# PetAnimationQueue - Tracks pending and completed pet animation requests
#
# Simplified version of NpcAnimationQueue for pet items.
# Manages queue status and provides rate limiting queries.
#
# Status flow: pending → processing → complete/failed
#
# Trigger types:
#   - broadcast_reaction: Pet reacting to room activity
#   - idle_animation: Periodic idle behavior
#
class PetAnimationQueue < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :item
  many_to_one :room
  many_to_one :owner_instance, class: :CharacterInstance

  TRIGGER_TYPES = %w[broadcast_reaction idle_animation].freeze
  status_enum :status, %w[pending processing complete failed]

  def validate
    super
    validates_presence %i[item_id room_id trigger_type status]
    validates_includes TRIGGER_TYPES, :trigger_type
    validate_status_enum
  end

  def before_create
    super
    self.scheduled_at ||= Time.now
  end

  # State transitions
  def start_processing!
    update(status: 'processing')
  end

  def complete!(response_text)
    update(status: 'complete', processed_at: Time.now, llm_response: response_text)
  end

  def fail!(error_msg)
    update(status: 'failed', processed_at: Time.now, error_message: error_msg)
  end

  # Queue management class methods
  class << self
    # Get pending entries ready to process
    # @param limit [Integer] max entries to return
    # @return [Array<PetAnimationQueue>]
    def pending_ready(limit: 10)
      where(status: 'pending')
        .where { scheduled_at <= Time.now }
        .order(:scheduled_at)
        .limit(limit)
        .all
    end

    # Count recent completions for a room (for rate limiting)
    # @param room_id [Integer]
    # @param window_seconds [Integer] time window (default 60s)
    # @return [Integer]
    def recent_count_for_room(room_id, window_seconds: 60)
      where(room_id: room_id, status: 'complete')
        .where { processed_at > Time.now - window_seconds }
        .count
    end

    # Count recent completions for a specific pet (for cooldown)
    # @param item_id [Integer]
    # @param window_seconds [Integer] time window (default 120s)
    # @return [Integer]
    def recent_count_for_pet(item_id, window_seconds: 120)
      where(item_id: item_id, status: 'complete')
        .where { processed_at > Time.now - window_seconds }
        .count
    end

    # Clean up old completed/failed entries
    # @param older_than [Integer] seconds (default 1 hour)
    # @return [Integer] number of entries deleted
    def cleanup_old_entries(older_than: 3600)
      where(status: %w[complete failed])
        .where { processed_at < Time.now - older_than }
        .delete
    end

    # Queue a new animation
    # @param pet [Item] the pet item
    # @param room_id [Integer]
    # @param trigger_type [String] broadcast_reaction or idle_animation
    # @param trigger_content [String, nil] the triggering content
    # @param owner_instance [CharacterInstance, nil]
    # @return [PetAnimationQueue]
    def queue_animation(pet:, room_id:, trigger_type:, trigger_content: nil, owner_instance: nil)
      entry = new
      entry.item = pet
      entry.room = Room[room_id]
      entry.owner_instance = owner_instance
      entry.trigger_type = trigger_type
      entry.trigger_content = trigger_content
      entry.status = 'pending'
      entry.scheduled_at = Time.now
      entry.save
      entry
    end
  end
end
