# frozen_string_literal: true

# WorldJourney tracks long-distance travel between locations on the world hex grid.
# Characters on a journey are placed in a shared "traveling room" where they can interact.
# The scheduler advances journeys hex by hex until arrival.
class WorldJourney < Sequel::Model
  include StatusEnum

  plugin :timestamps
  plugin :validation_helpers

  TRAVEL_MODES = %w[land water air rail].freeze
  status_enum :status, %w[traveling paused arrived cancelled]

  # Era-based vehicle types
  VEHICLE_TYPES = {
    medieval: { land: %w[horse cart wagon], water: %w[ferry rowboat sailing_ship] },
    gaslight: { land: %w[carriage bicycle horse], water: %w[steamship ferry sailing_ship], rail: %w[steam_train] },
    modern: { land: %w[car bus motorcycle], water: %w[ferry motorboat], rail: %w[train], air: %w[airplane] },
    near_future: { land: %w[car maglev hoverbike], water: %w[hydrofoil ferry], rail: %w[maglev], air: %w[aircraft vtol] },
    scifi: { land: %w[hovercar hoverbike], water: %w[submarine hovercraft], air: %w[shuttle spacecraft] }
  }.freeze

  # Base time per hex (from centralized config)
  BASE_TIME_PER_HEX = GameConfig::Navigation::WORLD_TRAVEL[:base_time_per_hex]

  # Vehicle speed multipliers (higher = faster)
  VEHICLE_SPEEDS = {
    # Land vehicles
    'horse' => 1.5, 'cart' => 0.8, 'wagon' => 0.7, 'carriage' => 1.2,
    'bicycle' => 1.0, 'car' => 3.0, 'bus' => 2.5, 'motorcycle' => 3.5,
    'maglev' => 5.0, 'hovercar' => 4.0, 'hoverbike' => 4.5,
    # Water vehicles
    'ferry' => 1.5, 'rowboat' => 0.5, 'sailing_ship' => 1.0, 'steamship' => 2.0,
    'motorboat' => 2.5, 'hydrofoil' => 3.5, 'submarine' => 2.0, 'hovercraft' => 3.0,
    # Rail vehicles
    'steam_train' => 2.5, 'train' => 4.0,
    # Air vehicles
    'airplane' => 6.0, 'aircraft' => 7.0, 'vtol' => 5.0, 'shuttle' => 10.0, 'spacecraft' => 15.0
  }.freeze

  many_to_one :world
  many_to_one :origin_location, class: :Location
  many_to_one :destination_location, class: :Location
  one_to_many :journey_passengers, class: :WorldJourneyPassenger

  # Interior room from the temporary room pool
  many_to_one :interior_room, class: :Room, key: :interior_room_id

  def validate
    super
    validates_presence %i[world_id current_globe_hex_id travel_mode vehicle_type started_at]
    validates_includes TRAVEL_MODES, :travel_mode
    validate_status_enum
  end

  # Get all character instances currently on this journey
  def passengers
    journey_passengers_dataset.eager(:character_instance).all.map(&:character_instance)
  end

  # Get the driver (first passenger marked as driver)
  def driver
    passenger = journey_passengers_dataset.where(is_driver: true).first
    passenger&.character_instance
  end

  # Get the current WorldHex for terrain info
  def current_hex
    WorldHex.find_by_globe_hex(world_id, current_globe_hex_id)
  end

  # Check if ready to advance to next hex
  def ready_to_advance?
    traveling? && next_hex_at && next_hex_at <= Time.now
  end

  # Advance to the next hex in the path
  # path_remaining contains globe_hex_ids (integers), not [x, y] coordinate arrays
  def advance_to_next_hex!
    return false if path_remaining.nil? || path_remaining.empty?

    next_hex_id = path_remaining.first
    remaining = path_remaining[1..]

    update(
      current_globe_hex_id: next_hex_id,
      path_remaining: remaining,
      next_hex_at: remaining.empty? ? nil : calculate_next_hex_time
    )

    true
  end

  # Complete the journey - move passengers to destination
  def complete_arrival!
    update(status: 'arrived')

    # Use return_to_room_id if set (e.g. flashback return journeys),
    # falling back to find_arrival_room if nil or room deleted
    destination_room = if return_to_room_id
                         Room[return_to_room_id] || find_arrival_room
                       else
                         find_arrival_room
                       end

    passengers.each do |char_instance|
      # Remove from journey
      char_instance.update(current_world_journey_id: nil)

      # Move to destination room with proper positioning
      char_instance.teleport_to_room!(destination_room) if destination_room
    end

    # Release the interior room back to the pool
    release_interior_room!
  end

  # Cancel the journey
  def cancel!(reason: nil)
    update(status: 'cancelled')

    # Create a waypoint at current hex and move passengers there
    waypoint_room = find_or_create_waypoint_room

    passengers.each do |char_instance|
      char_instance.update(current_world_journey_id: nil)
      char_instance.teleport_to_room!(waypoint_room) if waypoint_room
    end

    # Release the interior room back to the pool
    release_interior_room!
  end

  # Calculate time to next hex based on terrain, vehicle, era
  def calculate_next_hex_time
    Time.now + time_per_hex_seconds
  end

  # Get time per hex in seconds
  def time_per_hex_seconds
    era_mod = era_speed_modifier
    vehicle_mod = VEHICLE_SPEEDS[vehicle_type] || 1.0
    terrain_mod = terrain_speed_modifier
    road_mod = road_or_rail_modifier

    # Apply modifiers - higher modifiers = faster = less time
    total_modifier = era_mod * vehicle_mod * terrain_mod * road_mod * (speed_modifier || 1.0)
    total_modifier = 0.1 if total_modifier < 0.1 # Prevent division by zero

    (BASE_TIME_PER_HEX / total_modifier).round
  end

  # Format remaining travel time for display
  def time_remaining_display
    return 'Arrived' if arrived?
    return 'Unknown' unless estimated_arrival_at

    remaining_seconds = [(estimated_arrival_at - Time.now).to_i, 0].max

    if remaining_seconds < 60
      "#{remaining_seconds} seconds"
    elsif remaining_seconds < 3600
      "#{(remaining_seconds / 60.0).ceil} minutes"
    else
      hours = remaining_seconds / 3600
      minutes = (remaining_seconds % 3600) / 60
      "#{hours}h #{minutes}m"
    end
  end

  # Get a description of the current terrain for the traveling room
  def terrain_description
    hex = current_hex
    return 'featureless terrain' unless hex

    terrain_descriptions = {
      'ocean' => 'vast open ocean',
      'lake' => 'calm lake waters',
      'rocky_coast' => 'rocky coastline',
      'sandy_coast' => 'sandy beach',
      'grassy_plains' => 'rolling grasslands',
      'rocky_plains' => 'rocky flatlands',
      'light_forest' => 'scattered woodland',
      'dense_forest' => 'dense forest',
      'jungle' => 'tropical jungle',
      'swamp' => 'murky swampland',
      'mountain' => 'steep mountain terrain',
      'grassy_hills' => 'grassy hills',
      'rocky_hills' => 'rocky hills',
      'tundra' => 'frozen tundra',
      'desert' => 'arid desert',
      'volcanic' => 'volcanic wasteland',
      'urban' => 'developed urban area',
      'light_urban' => 'suburban area'
    }

    terrain_descriptions[hex.terrain_type] || hex.terrain_type
  end

  # Get a description of the vehicle interior
  def vehicle_description
    vehicle_interiors = {
      # Land
      'horse' => 'You ride on horseback, the wind in your face.',
      'cart' => 'You sit in the back of a simple wooden cart, bumping along.',
      'wagon' => 'You travel in a covered wagon, sheltered from the elements.',
      'carriage' => 'You sit in a comfortable carriage, watching the world pass by.',
      'car' => 'You travel in a comfortable vehicle, watching the landscape.',
      'bus' => 'You sit among other travelers on a public transport vehicle.',
      # Water
      'ferry' => 'You stand on the deck of a ferry, watching the water.',
      'rowboat' => 'You sit in a small boat, oars splashing in the water.',
      'sailing_ship' => 'You travel aboard a sailing vessel, wind filling the sails.',
      'steamship' => 'You travel aboard a steam-powered vessel, engines humming.',
      # Rail
      'steam_train' => 'You sit in a railway carriage, the train chugging along.',
      'train' => 'You travel in a comfortable train compartment.',
      'maglev' => 'You glide silently in a magnetic levitation train.',
      # Air
      'airplane' => 'You look out the window of an aircraft.',
      'shuttle' => 'You travel in a spacecraft, stars visible outside.'
    }

    vehicle_interiors[vehicle_type] || "You travel by #{vehicle_type}."
  end

  # === INTERIOR ROOM POOL METHODS ===

  # Ensure this journey has an interior room, acquiring one from the pool if needed
  # @return [Room, nil] the interior room or nil if acquisition failed
  def ensure_interior_room!
    return interior_room if interior_room_id

    result = TemporaryRoomPoolService.acquire_for_journey(self)
    return nil unless result.success?

    reload
    interior_room
  end

  # Alias for ensure_interior_room! for semantic clarity
  # @return [Room, nil]
  def traveling_room
    ensure_interior_room!
  end

  # Check if journey has an active interior room
  # @return [Boolean]
  def has_interior?
    interior_room_id && interior_room&.in_use?
  end
  alias interior? has_interior?

  # Get characters currently in the traveling room
  # @return [Array<CharacterInstance>]
  def characters_in_compartment
    return [] unless interior_room

    if interior_room.respond_to?(:characters_here)
      interior_room.characters_here.to_a
    else
      []
    end
  end

  # Release the interior room back to the pool
  # Called when journey arrives or is cancelled
  def release_interior_room!
    return unless interior_room_id

    room = interior_room
    update(interior_room_id: nil)

    if room&.is_temporary && room&.in_use?
      TemporaryRoomPoolService.release_room(room)
    end
  end

  private

  # Get era speed modifier from EraService
  def era_speed_modifier
    return 1.0 unless defined?(EraService)

    era_mods = { medieval: 0.5, gaslight: 1.0, modern: 2.0, near_future: 2.5, scifi: 3.0 }
    current_era = EraService.current_era rescue :modern
    era_mods[current_era] || 1.0
  end

  # Get terrain-based speed modifier based on travel mode
  # Water mode uses era-scaled bonuses for water terrain
  # Land/rail mode uses inverse of movement_cost
  def terrain_speed_modifier
    hex = current_hex
    return 1.0 unless hex

    case travel_mode
    when 'water'
      water_terrain_modifier(hex)
    else
      land_terrain_modifier(hex)
    end
  end

  # Water mode: water terrain is fast (era-scaled), land is very slow
  def water_terrain_modifier(hex)
    case hex.terrain_type
    when 'ocean', 'lake', 'rocky_coast', 'sandy_coast'
      era = current_era
      GameConfig::WorldTravel::WATER_ERA_BONUSES[era] || 1.0
    else
      # Land terrain is very slow for boats
      1.0 / GameConfig::WorldTravel::WATER_MODE_LAND_PENALTY
    end
  end

  # Land/rail mode: use inverse of movement cost
  # Water terrain is very slow for land travel
  def land_terrain_modifier(hex)
    case hex.terrain_type
    when 'ocean', 'lake'
      # Water terrain is very slow for land vehicles
      1.0 / GameConfig::WorldTravel::LAND_MODE_WATER_PENALTY
    else
      # Invert movement_cost so lower cost = higher speed
      cost = hex.movement_cost || 1
      cost = 1 if cost < 1
      1.0 / cost
    end
  end

  # Get current era for era-scaled bonuses
  # Returns :modern as fallback if EraService is not defined or errors
  def current_era
    return :modern unless defined?(EraService)

    EraService.current_era
  rescue StandardError => e
    warn "[WorldJourney] Error getting era: #{e.message}"
    :modern
  end

  # Get road/rail modifier based on travel mode
  # Rail mode gets RAILWAY_SPEED_BONUS when on railway
  # Land mode gets 2.0 bonus when on road
  def road_or_rail_modifier
    case travel_mode
    when 'rail'
      has_railway_feature? ? GameConfig::WorldTravel::RAILWAY_SPEED_BONUS : 1.0
    when 'land'
      has_road_feature? ? 2.0 : 1.0
    else
      1.0
    end
  end

  # Check if current hex has a road feature
  def has_road_feature?
    hex = current_hex
    return false unless hex

    hex.respond_to?(:has_road?) && hex.has_road?
  end
  alias road_feature? has_road_feature?

  # Check if current hex has a railway feature
  def has_railway_feature?
    hex = current_hex
    return false unless hex

    hex.respond_to?(:has_railway?) && hex.has_railway?
  end
  alias railway_feature? has_railway_feature?

  # Find an appropriate room at the destination for arrival
  def find_arrival_room
    return nil unless destination_location

    # Look for a street or public room
    street_types = %w[street avenue intersection plaza square]
    destination_location.rooms_dataset.where(room_type: street_types).first ||
      destination_location.rooms_dataset.where(safe_room: true).first ||
      destination_location.rooms_dataset.first
  end

  # Find or create a waypoint room at the current hex position
  def find_or_create_waypoint_room
    # Look for existing location at this hex
    location = Location.first(world_id: world_id, globe_hex_id: current_globe_hex_id)

    if location
      return location.rooms_dataset.where(room_type: 'street').first ||
             location.rooms_dataset.first
    end

    # Create a temporary waypoint location and room
    zone = Zone.first(world_id: world_id, zone_type: 'wilderness') || create_wilderness_zone

    location = Location.create(
      zone_id: zone.id,
      world_id: world_id,
      globe_hex_id: current_globe_hex_id,
      name: "Wilderness (globe hex #{current_globe_hex_id})",
      description: "A remote area of #{terrain_description}.",
      location_type: 'outdoor'
    )

    Room.create(
      location_id: location.id,
      name: 'Wilderness',
      short_description: "You stand in the #{terrain_description}. There are no settlements in sight.",
      room_type: 'field',
      is_outdoor: true
    )
  end

  # Create a wilderness zone for waypoints if none exists
  def create_wilderness_zone
    Zone.create(
      world_id: world_id,
      name: 'Wilderness',
      description: 'Untamed wilderness between settlements.',
      zone_type: 'wilderness',
      danger_level: 2
    )
  end
end
