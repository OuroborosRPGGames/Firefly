# frozen_string_literal: true

# EventDecoration represents temporary decorations during events.
# These are visible only to event participants and are cleaned up when the event ends.
class EventDecoration < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :event
  many_to_one :room
  many_to_one :created_by, class: :Character

  def validate
    super
    validates_presence [:event_id, :room_id, :name]
    validates_max_length 200, :name
  end

  # Get decorations for a specific event and room
  def self.for_event_room(event, room)
    where(event_id: event.id, room_id: room.id).order(:display_order, :id)
  end

  # Get all decorations for an event
  def self.for_event(event)
    where(event_id: event.id).order(:room_id, :display_order, :id)
  end

  # Create a decoration for an event
  def self.add_to_event(event:, room:, name:, description: nil, image_url: nil, created_by: nil)
    max_order = where(event_id: event.id, room_id: room.id).max(:display_order) || -1

    create(
      event_id: event.id,
      room_id: room.id,
      name: name,
      description: description,
      image_url: image_url,
      created_by_id: created_by&.id,
      display_order: max_order + 1
    )
  end

  # Remove all decorations for an event
  def self.cleanup_event!(event)
    where(event_id: event.id).delete
  end

  # Display string for the decoration
  def display_text
    if description.to_s.empty?
      name
    else
      "#{name} - #{description}"
    end
  end
end
