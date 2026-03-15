# frozen_string_literal: true

# RoomConsentCache stores cached consent calculations for rooms.
# Tracks when room occupancy changed (for 10-minute timer) and caches
# the intersection of all present characters' content consents.
class RoomConsentCache < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room

  def validate
    super
    validates_presence [:room_id]
    validates_unique :room_id
  end

  # Check if cache is stale and needs recalculation
  def stale?(current_char_count)
    return true if character_count != current_char_count
    return true if updated_at.nil?

    # Recalculate if cache is older than 1 minute
    (Time.now - updated_at) > 60
  end

  # Check if 10-minute timer has elapsed
  def display_ready?
    return false unless occupancy_changed_at

    # 10 minutes = 600 seconds
    (Time.now - occupancy_changed_at) >= 600
  end

  # Get seconds remaining until display ready
  def time_until_display
    return 0 if display_ready?
    return 600 unless occupancy_changed_at

    elapsed = (Time.now - occupancy_changed_at).to_i
    [600 - elapsed, 0].max
  end

  # Parse allowed codes from JSONB
  def allowed_content_codes
    return [] if allowed_codes.nil?

    if allowed_codes.is_a?(Array)
      allowed_codes
    else
      JSON.parse(allowed_codes.to_s)
    end
  rescue JSON::ParserError
    []
  end

  class << self
    # Find or create cache for a room
    def for_room(room)
      first(room_id: room.id) || create(
        room_id: room.id,
        occupancy_changed_at: Time.now,
        character_count: 0
      )
    end
  end
end
