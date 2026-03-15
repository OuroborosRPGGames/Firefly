# frozen_string_literal: true

# CityJourney tracks in-progress street-level vehicle travel.
# Used for both taxis (vehicle_id nil) and owned vehicles.
class CityJourney < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :vehicle
  many_to_one :driver, class: :CharacterInstance, key: :driver_id
  many_to_one :destination_room, class: :Room, key: :destination_room_id

  status_enum :status, %w[traveling paused arrived cancelled]

  def validate
    super
    validates_presence [:driver_id, :destination_room_id]
    validate_status_enum
  end

  def before_create
    super
    self.started_at ||= Time.now
    self.status ||= 'traveling'
  end

  # Is this a taxi journey (no owned vehicle)?
  def taxi?
    vehicle_id.nil?
  end

  # Get the current room in the route
  def current_room
    return nil if route.nil? || route.empty?

    room_id = route[current_index]
    Room[room_id] if room_id
  end

  # Get passengers as CharacterInstances
  def passengers
    return [] if passenger_ids.nil? || passenger_ids.empty?

    CharacterInstance.where(id: passenger_ids).all
  end

  # Add a passenger
  def add_passenger(character_instance)
    ids = (passenger_ids || []) + [character_instance.id]
    update(passenger_ids: ids.uniq)
  end

  # Remove a passenger
  def remove_passenger(character_instance)
    ids = (passenger_ids || []) - [character_instance.id]
    update(passenger_ids: ids)
  end

  # Check if journey has more rooms to traverse
  def more_rooms?
    return false if route.nil? || route.empty?

    current_index < route.length - 1
  end

  # Advance to next room in route
  def advance!
    return false unless more_rooms?

    update(current_index: current_index + 1)
    true
  end

  # Complete the journey
  def complete!
    update(status: 'arrived')
  end

  # Cancel the journey
  def cancel!
    update(status: 'cancelled')
  end
end
