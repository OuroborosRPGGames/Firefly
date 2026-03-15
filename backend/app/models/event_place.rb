# frozen_string_literal: true

# EventPlace represents temporary furniture/seating during events.
# These are visible only to event participants and are cleaned up when the event ends.
# Mirrors the structure of the permanent Place model.
class EventPlace < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :event
  many_to_one :room
  many_to_one :created_by, class: :Character

  PLACE_TYPES = %w[furniture seating stage bar table booth lounge other].freeze

  def validate
    super
    validates_presence [:event_id, :room_id, :name]
    validates_max_length 200, :name
    validates_includes PLACE_TYPES, :place_type if place_type
  end

  def before_save
    super
    self.place_type ||= 'furniture'
    self.capacity ||= 1
  end

  # Get places for a specific event and room
  def self.for_event_room(event, room)
    where(event_id: event.id, room_id: room.id)
      .exclude(invisible: true)
      .order(:display_order, :id)
  end

  # Get all places for an event
  def self.for_event(event)
    where(event_id: event.id).order(:room_id, :display_order, :id)
  end

  # Create a place for an event
  def self.add_to_event(event:, room:, name:, **options)
    max_order = where(event_id: event.id, room_id: room.id).max(:display_order) || -1
    order = max_order + 1

    place_id = nil
    if columns.include?(:place_id)
      linked_place = Place.create(
        room_id: room.id,
        name: name,
        description: options[:description],
        place_type: options[:place_type] || 'furniture',
        capacity: options[:capacity] || 1,
        default_sit_action: options[:default_sit_action],
        image_url: options[:image_url],
        is_furniture: options.fetch(:is_furniture, true),
        # Keep linked place hidden from non-event rendering/commands.
        invisible: true,
        display_order: order
      )
      place_id = linked_place.id
    end

    attrs = {
      event_id: event.id,
      room_id: room.id,
      name: name,
      description: options[:description],
      place_type: options[:place_type] || 'furniture',
      capacity: options[:capacity] || 1,
      default_sit_action: options[:default_sit_action],
      image_url: options[:image_url],
      is_furniture: options.fetch(:is_furniture, true),
      invisible: options.fetch(:invisible, false),
      created_by_id: options[:created_by]&.id,
      display_order: order
    }
    attrs[:place_id] = place_id if columns.include?(:place_id)

    create(attrs)
  end

  # Remove all places for an event
  def self.cleanup_event!(event)
    if columns.include?(:place_id)
      rows = where(event_id: event.id).all
      place_ids = rows.filter_map { |row| row.respond_to?(:place_id) ? row.place_id : nil }
      where(event_id: event.id).delete
      Place.where(id: place_ids).delete unless place_ids.empty?
    else
      where(event_id: event.id).delete
    end
  end

  # Check if this place is at capacity
  def at_capacity?
    if self.class.columns.include?(:place_id) && respond_to?(:place_id) && place_id
      linked_place = Place[place_id]
      return linked_place.full? if linked_place
    end
    return false if capacity.nil? || capacity <= 0

    # This would need integration with character sitting system
    # For now, just return false
    false
  end

  def full?
    at_capacity?
  end

  # Get the sit action phrase
  def sit_action
    default_sit_action.to_s.empty? ? 'sits at' : default_sit_action
  end

  # Display string for the place
  def display_text
    text = name
    text += " (#{capacity} seats)" if capacity && capacity > 1
    text
  end
end
