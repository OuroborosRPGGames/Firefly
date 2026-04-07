# frozen_string_literal: true

# WorldTravelService handles long-distance travel between locations on the globe hex grid.
# Characters on a journey are placed in a shared "traveling room" where they can interact.
# Travel speed is affected by era, vehicle type, terrain, and road infrastructure.
#
# Uses globe_hex_id for all hex identification. Paths are arrays of globe_hex_id integers.
class WorldTravelService
  # Travel mode constants
  TRAVEL_MODES = %w[land water air rail].freeze

  # Era-based speed multipliers (higher = faster)
  ERA_SPEED_MODIFIERS = {
    medieval: 0.5,
    gaslight: 1.0,
    modern: 2.0,
    near_future: 2.5,
    scifi: 3.0
  }.freeze

  # Default vehicles by travel mode and era
  DEFAULT_VEHICLES = {
    medieval: { land: 'horse', water: 'ferry', air: nil, rail: nil },
    gaslight: { land: 'carriage', water: 'steamship', air: nil, rail: 'steam_train' },
    modern: { land: 'car', water: 'ferry', air: 'airplane', rail: 'train' },
    near_future: { land: 'maglev', water: 'hydrofoil', air: 'aircraft', rail: 'maglev' },
    scifi: { land: 'hovercar', water: 'hovercraft', air: 'shuttle', rail: nil }
  }.freeze

  class << self
    # Start a journey from current location to destination
    # @param character_instance [CharacterInstance] the traveling character
    # @param destination [Location] the destination location
    # @param travel_mode [String] land, water, air, or rail (default: auto-detect)
    # @param vehicle_type [String, nil] specific vehicle type or nil for era default
    # @return [Hash] result with :success, :journey, :error
    def start_journey(character_instance, destination:, travel_mode: nil, vehicle_type: nil)
      # Validate character is not already traveling
      if character_instance.traveling?
        return { success: false, error: 'You are already on a journey. Use disembark to exit.' }
      end

      # Get current location and its hex coordinates
      current_room = character_instance.current_room
      current_location = current_room&.location

      unless current_location&.has_globe_hex?
        return { success: false, error: 'Your current location has no world coordinates.' }
      end

      unless destination.has_globe_hex?
        return { success: false, error: 'The destination has no world coordinates.' }
      end

      # Validate same world
      if destination.world_id != current_location.world_id
        return { success: false, error: 'Cannot travel to a location in a different world.' }
      end

      world = current_location.world

      # Determine travel mode if not specified
      travel_mode ||= determine_travel_mode(current_location, destination)
      unless TRAVEL_MODES.include?(travel_mode)
        return { success: false, error: "Invalid travel mode: #{travel_mode}" }
      end

      # Validate travel mode is available
      mode_validation = validate_travel_mode(current_location, destination, travel_mode)
      unless mode_validation[:valid]
        return { success: false, error: mode_validation[:error] }
      end

      # Plan journey segments (handles partial rail/water coverage with land fallback)
      segments = plan_journey_segments(
        origin: current_location,
        destination: destination,
        travel_mode: travel_mode
      )

      if segments.empty?
        return { success: false, error: 'No viable route found to the destination.' }
      end

      # Get the first segment's path for the initial journey
      first_segment = segments.first
      path = first_segment[:path]
      segment_mode = first_segment[:mode]
      segment_vehicle = vehicle_type || first_segment[:vehicle]

      unless segment_vehicle
        return { success: false, error: "No vehicles available for #{segment_mode} travel in this era." }
      end

      # Create the journey (excluding starting position from remaining path)
      # path is now an array of globe_hex_id integers
      journey = WorldJourney.create(
        world_id: world.id,
        current_globe_hex_id: path.first,
        path_remaining: Sequel.pg_json(path[1..]),
        origin_location_id: current_location.id,
        destination_location_id: destination.id,
        travel_mode: segment_mode,
        vehicle_type: segment_vehicle,
        segments: Sequel.pg_json(segments),
        current_segment_index: 0,
        started_at: Time.now,
        next_hex_at: nil,
        status: 'traveling'
      )

      # Calculate timing
      journey.update(
        next_hex_at: journey.calculate_next_hex_time,
        estimated_arrival_at: estimate_arrival_time(journey)
      )

      # Add character as passenger (and driver for solo journey)
      WorldJourneyPassenger.board!(journey, character_instance, is_driver: true)

      # Build success message with transfer info if multi-segment
      message = build_journey_message(destination, segment_vehicle, segments)

      {
        success: true,
        journey: journey,
        message: message
      }
    end

    # Board an existing journey
    # @param character_instance [CharacterInstance] the boarding character
    # @param journey [WorldJourney] the journey to board
    # @return [Hash] result with :success, :error
    def board_journey(character_instance, journey)
      if character_instance.traveling?
        return { success: false, error: 'You are already on a journey.' }
      end

      unless journey.traveling?
        return { success: false, error: 'This journey has already concluded.' }
      end

      # Check if character is at the journey's current hex
      current_room = character_instance.current_room
      current_location = current_room&.location

      unless current_location&.has_globe_hex?
        return { success: false, error: 'You cannot board from here.' }
      end

      # Must be at the same hex as the journey
      unless current_location.globe_hex_id == journey.current_globe_hex_id
        return { success: false, error: 'You are not at the same location as this transport.' }
      end

      WorldJourneyPassenger.board!(journey, character_instance, is_driver: false)

      {
        success: true,
        journey: journey,
        message: "You board the #{journey.vehicle_type.tr('_', ' ')}."
      }
    end

    # Disembark from current journey
    # @param character_instance [CharacterInstance] the disembarking character
    # @return [Hash] result with :success, :room, :error
    def disembark(character_instance)
      journey = character_instance.current_world_journey
      unless journey
        return { success: false, error: 'You are not currently traveling.' }
      end

      # Find the passenger record
      passenger = WorldJourneyPassenger.first(
        world_journey_id: journey.id,
        character_instance_id: character_instance.id
      )

      unless passenger
        return { success: false, error: 'You are not a passenger on this journey.' }
      end

      # Find or create a room at the current hex
      destination_room = find_or_create_waypoint_room(
        journey.world,
        journey.current_globe_hex_id
      )

      unless destination_room
        return { success: false, error: 'Cannot find a safe place to disembark.' }
      end

      # Remove passenger from journey
      passenger.disembark!

      # Move character to the waypoint room with proper positioning
      character_instance.teleport_to_room!(destination_room)

      # Check if journey should be cancelled (no passengers left)
      if journey.passengers.empty?
        journey.cancel!(reason: 'All passengers disembarked')
      end

      {
        success: true,
        room: destination_room,
        message: "You disembark and find yourself in #{destination_room.name}."
      }
    end

    # Get ETA information for a journey
    # @param journey [WorldJourney] the journey
    # @return [Hash] with :hexes_remaining, :time_remaining, :arrival_time
    def journey_eta(journey)
      return nil unless journey&.traveling?

      hexes_remaining = journey.path_remaining&.length || 0

      {
        hexes_remaining: hexes_remaining,
        time_remaining: journey.time_remaining_display,
        arrival_time: journey.estimated_arrival_at,
        destination: journey.destination_location&.display_name || 'Unknown destination'
      }
    end

    # Estimate total arrival time for a journey
    # @param journey [WorldJourney] the journey
    # @return [Time] estimated arrival time
    def estimate_arrival_time(journey)
      return Time.now if journey.path_remaining.nil? || journey.path_remaining.empty?

      # Sum up time for each remaining hex
      total_seconds = journey.path_remaining.length * journey.time_per_hex_seconds

      Time.now + total_seconds
    end

    # Cancel an ongoing journey
    # Only the driver or a solo passenger can cancel a journey
    # @param character_instance [CharacterInstance] the character canceling
    # @param reason [String, nil] optional cancellation reason
    # @return [Hash] result with :success, :room, :error
    def cancel_journey(character_instance, reason: nil)
      journey = character_instance.current_world_journey
      unless journey
        return { success: false, error: 'You are not currently on a journey.' }
      end

      unless journey.traveling?
        return { success: false, error: 'This journey has already concluded.' }
      end

      # Check if character can cancel (driver or solo passenger)
      is_driver = journey.driver&.id == character_instance.id
      is_solo = journey.passengers.count == 1

      unless is_driver || is_solo
        driver_name = journey.driver&.character&.full_name || 'the driver'
        return { success: false, error: "Only #{driver_name} can cancel this journey." }
      end

      # Cancel the journey - this moves all passengers to a waypoint
      journey.cancel!(reason: reason)

      # Find the room the character ended up in
      character_instance.reload
      current_room = character_instance.current_room

      {
        success: true,
        room: current_room,
        message: "You cancel the journey. Everyone disembarks at #{current_room&.name || 'a waypoint'}."
      }
    end

    # Get comprehensive journey status
    # @param journey [WorldJourney] the journey
    # @return [Hash, nil] status information or nil if journey doesn't exist
    def journey_status(journey)
      return nil unless journey

      # Get current hex for lat/lon info
      current_hex = journey.current_hex

      {
        id: journey.id,
        status: journey.status,
        traveling: journey.traveling?,
        arrived: journey.arrived?,
        current_globe_hex_id: journey.current_globe_hex_id,
        current_hex: current_hex ? { latitude: current_hex.latitude, longitude: current_hex.longitude } : nil,
        destination: {
          name: journey.destination_location&.display_name,
          globe_hex_id: journey.destination_location&.globe_hex_id
        },
        origin: {
          name: journey.origin_location&.name,
          id: journey.origin_location_id
        },
        vehicle: journey.vehicle_type,
        travel_mode: journey.travel_mode,
        terrain: journey.terrain_description,
        passengers: journey.passengers.map do |p|
          { id: p.id, name: p.character.full_name, is_driver: journey.driver&.id == p.id }
        end,
        driver: journey.driver&.character&.full_name,
        hexes_remaining: journey.path_remaining&.length || 0,
        time_remaining: journey.time_remaining_display,
        estimated_arrival: journey.estimated_arrival_at,
        started_at: journey.started_at
      }
    end

    # Plan journey segments, handling partial rail/water coverage
    # When rail/water routes can't reach the destination, plans a transfer to land travel
    # @param origin [Location] starting location
    # @param destination [Location] end location
    # @param travel_mode [String] preferred travel mode (land, water, rail)
    # @return [Array<Hash>] array of journey segments with :mode, :vehicle, :path, :start_hex, :end_hex
    def plan_journey_segments(origin:, destination:, travel_mode:)
      world = origin.world

      case travel_mode
      when 'rail'
        plan_rail_segments(world, origin, destination)
      when 'water'
        plan_water_segments(world, origin, destination)
      else
        plan_land_segments(world, origin, destination)
      end
    end

    # Calculate route options between two locations
    # Returns multiple route options with different travel modes
    # @param origin [Location] starting location
    # @param destination [Location] end location
    # @param travel_modes [Array<String>, nil] modes to consider (default: all valid)
    # @return [Hash] result with :success, :routes, :error
    def calculate_route(origin:, destination:, travel_modes: nil)
      # Validate locations
      unless origin.has_globe_hex?
        return { success: false, error: 'Origin location has no world coordinates.', routes: [] }
      end

      unless destination.has_globe_hex?
        return { success: false, error: 'Destination has no world coordinates.', routes: [] }
      end

      unless origin.world_id == destination.world_id
        return { success: false, error: 'Cannot calculate route between different worlds.', routes: [] }
      end

      world = origin.world
      travel_modes ||= TRAVEL_MODES

      routes = []

      travel_modes.each do |mode|
        # Check if mode is valid for these locations
        mode_validation = validate_travel_mode(origin, destination, mode)
        next unless mode_validation[:valid]

        # Calculate path for this mode using GlobePathfindingService
        avoid_water = mode != 'water'
        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: origin.globe_hex_id,
          end_globe_hex_id: destination.globe_hex_id,
          avoid_water: avoid_water,
          travel_mode: mode
        )

        next if path.empty? || path.length < 2

        vehicle = default_vehicle_for_mode(mode)
        next unless vehicle

        # Calculate estimated time
        vehicle_speed = WorldJourney::VEHICLE_SPEEDS[vehicle] || 1.0
        era_mod = WorldJourney.new.send(:era_speed_modifier) rescue 1.0
        base_time = WorldJourney::BASE_TIME_PER_HEX
        time_per_hex = (base_time / (era_mod * vehicle_speed)).round
        total_seconds = (path.length - 1) * time_per_hex

        # Get hex details for preview
        path_preview = path.take(5).map do |hex_id|
          hex = WorldHex.find_by_globe_hex(world.id, hex_id)
          hex ? { globe_hex_id: hex_id, latitude: hex.latitude, longitude: hex.longitude } : { globe_hex_id: hex_id }
        end

        routes << {
          travel_mode: mode,
          vehicle: vehicle,
          path_length: path.length - 1, # Exclude starting hex
          estimated_seconds: total_seconds,
          estimated_time: format_duration(total_seconds),
          path_preview: path_preview
        }
      end

      if routes.empty?
        return { success: false, error: 'No viable routes found to the destination.', routes: [] }
      end

      # Sort by estimated time (fastest first)
      routes.sort_by! { |r| r[:estimated_seconds] }

      { success: true, routes: routes }
    end

    # Get the default vehicle for a travel mode in the current era
    # Public because JourneyService needs to call this
    def default_vehicle_for_mode(mode)
      era = current_era
      era_vehicles = DEFAULT_VEHICLES[era] || DEFAULT_VEHICLES[:modern]
      era_vehicles[mode.to_sym]
    end

    private

    # Get the current era from EraService
    def current_era
      return :modern unless defined?(EraService)

      EraService.current_era
    rescue StandardError => e
      warn "[WorldTravelService] Failed to get current era: #{e.message}"
      :modern
    end

    # Build journey message, including transfer info for multi-segment journeys
    # @param destination [Location] destination location
    # @param vehicle [String] vehicle type for first segment
    # @param segments [Array<Hash>] journey segments
    # @return [String] journey start message
    def build_journey_message(destination, vehicle, segments)
      vehicle_display = vehicle.to_s.tr('_', ' ')

      if segments.length > 1
        next_mode = segments[1][:mode]
        next_vehicle = segments[1][:vehicle].to_s.tr('_', ' ')

        "You begin your journey to #{destination.display_name}. " \
        "#{vehicle_display.capitalize} to transfer point, then continue by #{next_vehicle}."
      else
        "You begin your journey to #{destination.display_name} by #{vehicle_display}."
      end
    end

    # Format duration in seconds to human-readable string
    def format_duration(seconds)
      return 'instant' if seconds < 60

      if seconds < 3600
        "#{(seconds / 60.0).ceil} minutes"
      else
        hours = seconds / 3600
        minutes = (seconds % 3600) / 60
        minutes > 0 ? "#{hours}h #{minutes}m" : "#{hours} hour#{'s' if hours > 1}"
      end
    end

    # Determine the best travel mode between two locations
    def determine_travel_mode(origin, destination)
      # Check if water travel is needed (origin or destination is water type)
      if requires_water_travel?(origin, destination)
        'water'
      elsif has_rail_connection?(origin, destination)
        'rail'
      else
        'land'
      end
    end

    # Check if water travel is required
    def requires_water_travel?(origin, destination)
      # Check if either has a port and the other is across water
      origin.respond_to?(:has_port) && origin.has_port? ||
        destination.respond_to?(:has_port) && destination.has_port?
    end

    # Check if rail connection exists between locations
    def has_rail_connection?(origin, destination)
      origin.respond_to?(:has_train_station) && origin.has_train_station? &&
        destination.respond_to?(:has_train_station) && destination.has_train_station?
    end

    # Validate that the travel mode is possible
    def validate_travel_mode(origin, destination, mode)
      case mode
      when 'water'
        # Need port access at origin
        unless origin.respond_to?(:has_port) && origin.has_port?
          return { valid: false, error: 'No port available at your current location.' }
        end
      when 'rail'
        # Need train station at origin
        unless origin.respond_to?(:has_train_station) && origin.has_train_station?
          return { valid: false, error: 'No train station at your current location.' }
        end
      when 'air'
        era = current_era
        unless %i[modern near_future scifi].include?(era)
          return { valid: false, error: 'Air travel is not available in this era.' }
        end
      end

      { valid: true }
    end

    # Find or create a waypoint room at the given globe hex
    # @param world [World] the world
    # @param globe_hex_id [Integer] the globe hex ID
    # @return [Room, nil] the waypoint room
    def find_or_create_waypoint_room(world, globe_hex_id)
      # First check if there's an existing location at this hex
      location = Location.first(world_id: world.id, globe_hex_id: globe_hex_id)

      if location
        # Return a street/public room, or any room
        room = location.rooms_dataset.where(room_type: RoomTypeConfig.tagged(:street) + %w[plaza]).first ||
               location.rooms_dataset.where(safe_room: true).first ||
               location.rooms_dataset.first
        return room if room

        # Location exists but has no rooms - create one
        return create_waypoint_room_in_location(location, world, globe_hex_id)
      end

      # Get terrain info for this hex
      hex = WorldHex.find_by_globe_hex(world.id, globe_hex_id)
      terrain = hex&.terrain_type || 'grassy_plains'

      # Find or create a wilderness zone
      zone = Zone.first(world_id: world.id, zone_type: 'wilderness') ||
             Zone.create(
               world_id: world.id,
               name: 'Wilderness',
               description: 'Untamed wilderness between settlements.',
               zone_type: 'wilderness',
               danger_level: 2
             )

      # Create a temporary location
      location = Location.create(
        zone_id: zone.id,
        world_id: world.id,
        globe_hex_id: globe_hex_id,
        name: "Wilderness (globe hex #{globe_hex_id})",
        description: terrain_description(terrain),
        location_type: 'outdoor'
      )

      create_waypoint_room_in_location(location, world, globe_hex_id)
    rescue StandardError => e
      warn "[WorldTravelService] Waypoint creation failed: #{e.class}: #{e.message}"
      nil
    end

    # Create a waypoint room inside a location with proper dimensions
    def create_waypoint_room_in_location(location, world, globe_hex_id)
      hex = WorldHex.find_by_globe_hex(world.id, globe_hex_id)
      terrain = hex&.terrain_type || 'grassy_plains'

      Room.create(
        location_id: location.id,
        name: terrain_room_name(terrain),
        short_description: hex ? HexDescriptionService.describe(hex)[:description] : "You stand in the #{terrain_description(terrain)}.",
        room_type: 'field',
        is_outdoor: true,
        safe_room: true,
        min_x: 0,
        max_x: 100,
        min_y: 0,
        max_y: 100
      )
    rescue StandardError => e
      warn "[WorldTravelService] Waypoint room creation failed: #{e.class}: #{e.message}"
      nil
    end

    # Get a description for terrain type
    def terrain_description(terrain)
      descriptions = {
        'ocean' => 'open ocean waters',
        'lake' => 'calm lake waters',
        'rocky_coast' => 'rocky coastline',
        'sandy_coast' => 'sandy beach',
        'grassy_plains' => 'rolling grasslands',
        'rocky_plains' => 'rocky flatlands',
        'light_forest' => 'scattered woodland',
        'dense_forest' => 'dense forest',
        'jungle' => 'tropical jungle',
        'swamp' => 'murky swampland',
        'mountain' => 'rugged mountain terrain',
        'grassy_hills' => 'grassy hills',
        'rocky_hills' => 'rocky hills',
        'tundra' => 'frozen tundra',
        'desert' => 'arid desert sands',
        'volcanic' => 'volcanic terrain',
        'urban' => 'developed urban area',
        'light_urban' => 'suburban area'
      }
      descriptions[terrain] || 'open terrain'
    end

    # Get a room name for terrain type
    def terrain_room_name(terrain)
      names = {
        'ocean' => 'Open Sea',
        'lake' => 'Lakeshore',
        'rocky_coast' => 'Rocky Coastline',
        'sandy_coast' => 'Sandy Beach',
        'grassy_plains' => 'Open Plains',
        'rocky_plains' => 'Rocky Flatlands',
        'light_forest' => 'Forest Edge',
        'dense_forest' => 'Forest Clearing',
        'jungle' => 'Jungle Path',
        'swamp' => 'Swamp Edge',
        'mountain' => 'Mountain Pass',
        'grassy_hills' => 'Grassy Hilltop',
        'rocky_hills' => 'Rocky Hilltop',
        'tundra' => 'Frozen Wasteland',
        'desert' => 'Desert Expanse',
        'volcanic' => 'Volcanic Wasteland',
        'urban' => 'City Street',
        'light_urban' => 'Suburban Road'
      }
      names[terrain] || 'Wilderness'
    end

    # Plan rail journey with land fallback
    # @param world [World] the world
    # @param origin [Location] starting location
    # @param destination [Location] destination location
    # @return [Array<Hash>] journey segments (paths are arrays of globe_hex_id integers)
    def plan_rail_segments(world, origin, destination)
      # Try full rail path first
      rail_path = GlobePathfindingService.find_path(
        world: world,
        start_globe_hex_id: origin.globe_hex_id,
        end_globe_hex_id: destination.globe_hex_id,
        travel_mode: 'rail'
      )

      if rail_path.length >= 2 && rail_path.last == destination.globe_hex_id
        # Full rail route exists
        return [{
          mode: 'rail',
          vehicle: default_vehicle_for_mode('rail'),
          path: rail_path,
          start_hex: rail_path.first,
          end_hex: rail_path.last
        }]
      end

      # Find furthest point rail can reach toward destination
      furthest_rail = find_furthest_rail_point(world, origin, destination)

      if furthest_rail && furthest_rail != origin.globe_hex_id
        # Partial rail then land
        rail_path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: origin.globe_hex_id,
          end_globe_hex_id: furthest_rail,
          travel_mode: 'rail'
        )

        land_path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: furthest_rail,
          end_globe_hex_id: destination.globe_hex_id,
          travel_mode: 'land'
        )

        segments = []

        if rail_path.length >= 2
          segments << {
            mode: 'rail',
            vehicle: default_vehicle_for_mode('rail'),
            path: rail_path,
            start_hex: rail_path.first,
            end_hex: rail_path.last
          }
        end

        if land_path.length >= 2
          segments << {
            mode: 'land',
            vehicle: default_vehicle_for_mode('land'),
            path: land_path,
            start_hex: land_path.first,
            end_hex: land_path.last
          }
        end

        return segments if segments.any?
      end

      # Fallback to pure land
      plan_land_segments(world, origin, destination)
    end

    # Find furthest railway point toward destination using BFS
    # Explores ALL reachable railway hexes first, THEN returns the one closest to destination
    # @param world [World] the world
    # @param origin [Location] starting location
    # @param destination [Location] destination location
    # @return [Integer, nil] globe_hex_id of furthest reachable rail point
    def find_furthest_rail_point(world, origin, destination)
      visited = Set.new
      queue = [origin.globe_hex_id]
      all_reachable = []

      # Cache destination hex for distance calculation
      dest_hex = WorldHex.find_by_globe_hex(world.id, destination.globe_hex_id)
      return nil unless dest_hex

      # BFS phase: find ALL reachable railway hexes
      while queue.any?
        current_id = queue.shift
        next if visited.include?(current_id)

        visited.add(current_id)
        all_reachable << current_id

        hex = WorldHex.find_by_globe_hex(world.id, current_id)
        next unless hex

        # Follow railway features to neighbors
        WorldHex::DIRECTIONS.each do |dir|
          next unless hex.directional_feature(dir) == 'railway'

          # Find neighbor in that direction using WorldHex.neighbors_of
          neighbors = WorldHex.neighbors_of(hex)
          neighbor = neighbors.find do |n|
            direction_between_hexes(hex, n) == dir
          end
          next unless neighbor
          next if visited.include?(neighbor.globe_hex_id)

          queue << neighbor.globe_hex_id
        end
      end

      if all_reachable.empty? || all_reachable == [origin.globe_hex_id]
        warn "[WorldTravelService] No railway route found from globe_hex_id #{origin.globe_hex_id}"
        return nil
      end

      # Return reachable hex closest to destination (using great circle distance)
      all_reachable.min_by do |hex_id|
        hex = WorldHex.find_by_globe_hex(world.id, hex_id)
        next Float::INFINITY unless hex

        GlobePathfindingService.distance(hex, dest_hex)
      end
    end

    # Determine direction from one hex to another based on lat/lon
    # Returns one of WorldHex::DIRECTIONS ('n', 'ne', 'se', 's', 'sw', 'nw')
    # @param from_hex [WorldHex] source hex
    # @param to_hex [WorldHex] destination hex
    # @return [String, nil] direction from source to destination
    def direction_between_hexes(from_hex, to_hex)
      WorldHex.direction_between_hexes(from_hex, to_hex)
    end

    # Plan water journey with land fallback
    # @param world [World] the world
    # @param origin [Location] starting location
    # @param destination [Location] destination location
    # @return [Array<Hash>] journey segments (paths are arrays of globe_hex_id integers)
    def plan_water_segments(world, origin, destination)
      # Try full water path
      water_path = GlobePathfindingService.find_path(
        world: world,
        start_globe_hex_id: origin.globe_hex_id,
        end_globe_hex_id: destination.globe_hex_id,
        travel_mode: 'water'
      )

      if water_path.length >= 2 && water_path.last == destination.globe_hex_id
        return [{
          mode: 'water',
          vehicle: default_vehicle_for_mode('water'),
          path: water_path,
          start_hex: water_path.first,
          end_hex: water_path.last
        }]
      end

      # Fallback to land if water route impossible
      plan_land_segments(world, origin, destination)
    end

    # Plan simple land journey
    # @param world [World] the world
    # @param origin [Location] starting location
    # @param destination [Location] destination location
    # @return [Array<Hash>] journey segments (paths are arrays of globe_hex_id integers)
    def plan_land_segments(world, origin, destination)
      path = GlobePathfindingService.find_path(
        world: world,
        start_globe_hex_id: origin.globe_hex_id,
        end_globe_hex_id: destination.globe_hex_id,
        travel_mode: 'land'
      )

      return [] if path.length < 2

      [{
        mode: 'land',
        vehicle: default_vehicle_for_mode('land'),
        path: path,
        start_hex: path.first,
        end_hex: path.last
      }]
    end
  end
end
