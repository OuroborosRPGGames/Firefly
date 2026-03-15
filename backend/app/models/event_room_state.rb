# frozen_string_literal: true

# EventRoomState stores a snapshot of room state when an event starts.
# Allows event-specific room customizations without affecting the permanent room.
class EventRoomState < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :event
  many_to_one :room

  def validate
    super
    validates_presence [:event_id, :room_id]
  end

  # Snapshot the current room state for this event
  def self.snapshot!(event, room)
    find_or_create(event_id: event.id, room_id: room.id) do |state|
      state.original_description = room.description
      state.original_background_url = room.default_background_url
      if state.respond_to?(:original_night_background_url=) && room.respond_to?(:default_background_url)
        state.original_night_background_url = room.default_background_url
      end
    end
  end

  # Get effective description (event override or original)
  def effective_description
    event_description.to_s.empty? ? original_description : event_description
  end

  # Get effective background URL (event override or original)
  def effective_background_url
    event_background_url.to_s.empty? ? original_background_url : event_background_url
  end

  # Get effective night background URL (event override or original)
  def effective_night_background_url
    if respond_to?(:event_night_background_url) && respond_to?(:original_night_background_url)
      event_night_background_url.to_s.empty? ? original_night_background_url : event_night_background_url
    else
      effective_background_url
    end
  end

  # Check if any event overrides are set
  def has_overrides?
    has_night_override = respond_to?(:event_night_background_url) && !event_night_background_url.to_s.empty?

    !event_description.to_s.empty? ||
      !event_background_url.to_s.empty? ||
      has_night_override
  end
  alias overrides? has_overrides?

  # Apply description override for the event
  def set_event_description(desc)
    update(event_description: desc)
  end

  # Apply background override for the event
  def set_event_background(url, night_url: nil)
    updates = { event_background_url: url }
    if night_url && respond_to?(:event_night_background_url=)
      updates[:event_night_background_url] = night_url
    end
    update(updates)
  end

  # Clear all event overrides
  def clear_overrides!
    updates = {
      event_description: nil,
      event_background_url: nil
    }
    updates[:event_night_background_url] = nil if respond_to?(:event_night_background_url=)
    update(updates)
  end
end
