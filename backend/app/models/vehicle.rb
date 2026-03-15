# frozen_string_literal: true

# Vehicle represents a specific vehicle instance owned by a character.
# Used for travel, can carry passengers.
#
# Schema columns:
#   owner_id        - Character who owns this vehicle
#   current_room_id - Room where the vehicle is currently located
#   vehicle_type_id - FK to VehicleType
#   status          - String: 'parked', 'moving', etc.
#   roof_open       - Boolean for convertibles
#   convertible     - Boolean if roof can open
#
class Vehicle < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  # === RELATIONSHIPS ===
  many_to_one :owner, class: :Character, key: :owner_id
  many_to_one :current_room, class: :Room, key: :current_room_id
  many_to_one :vehicle_type, class: :VehicleType, key: :vehicle_type_id
  one_to_many :passengers, class: :CharacterInstance, key: :current_vehicle_id

  # === TEMPORARY ROOM POOL RELATIONSHIPS ===
  many_to_one :interior_room, class: :Room, key: :interior_room_id
  many_to_one :preferred_template, class: :RoomTemplate, key: :preferred_template_id

  # === LEGACY ALIASES ===
  # For backward compatibility with old code

  def char_id
    owner_id
  end

  def char_id=(val)
    self.owner_id = val
  end

  def room_id
    current_room_id
  end

  def room_id=(val)
    self.current_room_id = val
  end

  def opentop
    roof_open
  end

  def opentop=(val)
    self.roof_open = val
  end

  def condition
    health
  end

  def condition=(val)
    self.health = val
  end

  # vtype alias - maps to vehicle_type name for backward compatibility
  def vtype
    vehicle_type&.name
  end

  def vtype=(val)
    if val.is_a?(String)
      vt = VehicleType.where(Sequel.ilike(:name, val)).first
      self.vehicle_type_id = vt&.id
    else
      self.vehicle_type_id = val
    end
  end

  # max_passengers delegation for backward compatibility
  def max_passengers
    vehicle_type&.max_passengers || 4
  end

  # Setter for backward compatibility (value comes from vehicle_type, so this is a no-op)
  # Some tests/legacy code may try to set this directly
  def max_passengers=(_val)
    # No-op - max_passengers is determined by vehicle_type
    # To change max_passengers, update the vehicle_type
  end

  # === VALIDATION ===

  def validate
    super
    validates_presence [:name]
    validates_max_length 100, :name
  end

  def before_save
    super
    self.status ||= 'parked' if new?
  end

  # === STATUS METHODS ===

  def parked?
    status == 'parked'
  end

  # Setter for parked status (for backward compatibility)
  def parked=(value)
    self.status = value ? 'parked' : 'moving'
  end

  def moving?
    status == 'moving'
  end

  def damaged?
    (health || 100) < 50
  end

  def operational?
    (health || 100) > 0
  end

  # === CAPACITY METHODS ===

  def available_seats
    capacity = max_passengers || 4
    capacity - passengers.count
  end

  def full?
    available_seats <= 0
  end

  # === BOARDING (no driver_id in production - all via current_vehicle_id) ===

  def board!(character_instance, as_driver: false)
    return false if full?
    return false unless operational?

    character_instance.update(current_vehicle_id: id)
    true
  end

  def disembark!(character_instance)
    character_instance.update(current_vehicle_id: nil)
    update(status: 'parked') if passengers.empty?
    true
  end

  def park!(room)
    update(current_room_id: room.id, status: 'parked')
  end

  def start!
    return false if passengers.empty?
    update(status: 'moving')
    true
  end

  # === CONVERTIBLE ROOF METHODS ===

  def convertible?
    convertible == true
  end

  def roof_open?
    roof_open == true
  end

  def roof_closed?
    !roof_open?
  end

  def open_roof!
    return false unless convertible?
    return false if roof_open?

    update(roof_open: true)
    true
  end

  def close_roof!
    return false unless convertible?
    return false if roof_closed?

    update(roof_open: false)
    true
  end

  # Check if vehicle occupants are visible to observers.
  # True for always-open vehicles (motorcycles, horses) or convertibles with roof open.
  # @return [Boolean]
  def occupants_visible?
    # Check if vehicle type is always open
    return true if vehicle_type&.always_open?

    # Check if convertible with roof open
    convertible? && roof_open?
  end

  # Get all occupants (passengers in vehicle via current_vehicle_id)
  # Note: No separate driver tracking in production schema
  def occupants
    passengers.to_a
  end

  # === INTERIOR ROOM POOL METHODS ===

  # Check if vehicle has an active interior room
  # @return [Boolean]
  def has_interior?
    interior_room_id && interior_room&.in_use?
  end
  alias interior? has_interior?

  # Get characters currently inside the vehicle's interior room
  # @return [Array<CharacterInstance>]
  def characters_inside
    return [] unless interior_room

    if interior_room.respond_to?(:characters_here)
      interior_room.characters_here.to_a
    else
      []
    end
  end

  # Check if vehicle interior is empty
  # @return [Boolean]
  def interior_empty?
    characters_inside.empty?
  end

  # Enter the vehicle using the interior room pool
  # @param character_instance [CharacterInstance]
  # @return [ResultHandler::Result]
  def enter!(character_instance)
    VehicleInteriorService.enter_vehicle(character_instance, self)
  end

  # Exit the vehicle
  # @param character_instance [CharacterInstance]
  # @return [ResultHandler::Result]
  def exit!(character_instance)
    VehicleInteriorService.exit_vehicle(character_instance)
  end

  # Save current interior customizations for persistence
  # @return [ResultHandler::Result]
  def save_interior!
    VehicleInteriorService.save_interior_customizations(self)
  end

  # Get vehicle type name (from the associated VehicleType)
  # @return [String, nil]
  def vehicle_type_name
    vehicle_type&.name
  end

  # === QUERY HELPERS ===

  def self.for_owner(character)
    where(owner_id: character.id)
  end

  def self.in_room(room)
    where(current_room_id: room.id)
  end
end
