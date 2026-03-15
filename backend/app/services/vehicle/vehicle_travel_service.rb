# frozen_string_literal: true

# VehicleTravelService handles all city street-level vehicle travel.
# Unified service for both taxis and owned vehicles.
#
# City travel is faster than walking - use this for distances over
# AUTODRIVE_THRESHOLD_FEET to automatically suggest vehicle travel.
#
# Usage:
#   VehicleTravelService.start_journey(character_instance, destination: room, vehicle: vehicle)
#   VehicleTravelService.start_journey(character_instance, destination: room, vehicle: nil)  # taxi
#
class VehicleTravelService
  extend ResultHandler

  # City driving speed in feet per second (~25 mph)
  CITY_DRIVING_SPEED_FPS = 36.0

  # Walking speed for comparison (feet per second, ~3 mph)
  WALKING_SPEED_FPS = 4.4


  class << self
    # Start a city vehicle journey.
    #
    # @param character_instance [CharacterInstance] the driver
    # @param destination [Room] the destination room
    # @param vehicle [Vehicle, nil] owned vehicle or nil for taxi
    # @return [ResultHandler::Result] success/error result
    def start_journey(character_instance, destination:, vehicle: nil)
      from_room = character_instance.current_room
      return error('You need to be somewhere to travel.') unless from_room

      # Calculate street route
      route = PathfindingService.street_route(from_room, destination)
      if route.empty?
        return error("Can't find a street route to #{destination.name}.")
      end

      # Calculate total distance
      total_distance = calculate_route_distance_from_rooms(route)

      # Create the journey
      begin
        journey = CityJourney.create(
          driver_id: character_instance.id,
          vehicle_id: vehicle&.id,
          destination_room_id: destination.id,
          route: route.map(&:id),
          total_distance_feet: total_distance,
          started_at: Time.now
        )
      rescue Sequel::ValidationFailed, StandardError => e
        warn "[VehicleTravelService] Journey creation failed: #{e.message}"
        return error('Failed to start journey. Please try again.')
      end

      # Board the vehicle if owned
      if vehicle
        vehicle.board!(character_instance, as_driver: true)
        vehicle.refresh # Clear cached passengers association after boarding
        unless vehicle.start!
          vehicle.disembark!(character_instance)
          return error('Failed to start vehicle. Please try again.')
        end
      end

      # Schedule first movement tick
      schedule_next_move(journey)

      # Broadcast departure
      broadcast_departure(character_instance, from_room, vehicle)

      success(
        journey_start_message(character_instance, destination, vehicle),
        data: {
          journey_id: journey.id,
          destination: destination.name,
          route_length: route.length,
          estimated_time: estimate_travel_time(total_distance)
        }
      )
    end

    # Calculate distance between two rooms via street route.
    #
    # @param from_room [Room] starting room
    # @param to_room [Room] destination room
    # @return [Integer] total distance in feet
    def calculate_route_distance(from_room, to_room)
      route = PathfindingService.street_route(from_room, to_room)
      calculate_route_distance_from_rooms(route)
    end

    # Estimate travel time in seconds for a distance.
    #
    # @param distance_feet [Integer] distance in feet
    # @return [Integer] estimated seconds
    def estimate_travel_time(distance_feet)
      (distance_feet / CITY_DRIVING_SPEED_FPS).to_i
    end

    # Estimate walking time for comparison.
    #
    # @param distance_feet [Integer] distance in feet
    # @return [Integer] estimated seconds
    def estimate_walking_time(distance_feet)
      (distance_feet / WALKING_SPEED_FPS).to_i
    end

    # Process a journey tick - move to next room if ready.
    #
    # @param journey_id [Integer] the journey ID
    def advance_journey(journey_id)
      journey = CityJourney[journey_id]
      return unless journey&.traveling?

      if journey.more_rooms?
        process_room_transition(journey)
      else
        complete_journey(journey)
      end
    end

    # Complete a journey - arrive at destination.
    #
    # @param journey [CityJourney] the journey to complete
    def complete_journey(journey)
      destination = journey.destination_room
      driver = journey.driver
      vehicle = journey.vehicle

      # Move driver to destination
      begin
        driver.update(
          current_room_id: destination.id,
          x: 0.0, y: 0.0, z: 0.0
        )
      rescue Sequel::ValidationFailed, StandardError => e
        warn "[VehicleTravelService] Driver update failed: #{e.message}"
      end

      # Park the vehicle
      if vehicle
        begin
          vehicle.park!(destination)
          vehicle.disembark!(driver)
        rescue StandardError => e
          warn "[VehicleTravelService] Vehicle parking failed: #{e.message}"
        end
      end

      # Broadcast arrival
      broadcast_arrival(driver, destination, vehicle)

      journey.complete!
    end

    private

    # Calculate total distance from a list of rooms.
    #
    # @param rooms [Array<Room>] list of rooms in route
    # @return [Integer] total distance in feet
    def calculate_route_distance_from_rooms(rooms)
      return 0 if rooms.length < 2

      total = 0
      rooms.each_cons(2) do |from, to|
        total += room_distance(from, to)
      end
      total
    end

    # Calculate distance between two adjacent rooms.
    # Uses room dimensions or a default.
    #
    # @param from [Room] first room
    # @param to [Room] second room
    # @return [Integer] distance in feet
    def room_distance(from, to)
      from_width = from.respond_to?(:width) ? (from.width || 100) : 100
      to_width = to.respond_to?(:width) ? (to.width || 100) : 100
      ((from_width + to_width) / 2).to_i
    end

    # Schedule the next movement tick for a journey.
    #
    # @param journey [CityJourney] the journey
    def schedule_next_move(journey)
      return unless journey.traveling? && journey.more_rooms?

      current_room = journey.current_room
      next_room_id = journey.route[journey.current_index + 1]
      next_room = Room[next_room_id]
      unless next_room
        warn "[VehicleTravelService] Invalid room in route: #{next_room_id}"
        return
      end

      distance = room_distance(current_room, next_room)
      delay_ms = ((distance / CITY_DRIVING_SPEED_FPS) * 1000).to_i
      delay_ms = [delay_ms, 500].max # Minimum 500ms between moves

      journey.update(next_move_at: Time.now + (delay_ms / 1000.0))

      TimedAction.start_delayed(
        journey.driver,
        'city_journey',
        delay_ms,
        'CityJourneyHandler',
        { journey_id: journey.id }
      )
    end

    # Process transitioning to the next room in the route.
    #
    # @param journey [CityJourney] the journey
    def process_room_transition(journey)
      driver = journey.driver
      vehicle = journey.vehicle
      old_room = journey.current_room

      # Fetch next room ID before advancing to avoid race condition
      new_room_id = journey.route[journey.current_index + 1]
      journey.advance!
      new_room = Room[new_room_id]

      unless new_room
        warn "[VehicleTravelService] Invalid room in advance: #{new_room_id}"
        complete_journey(journey)
        return
      end

      new_direction = determine_direction(old_room, new_room)
      old_direction = journey.last_direction

      # Broadcast turn if direction changed
      if old_direction && new_direction != old_direction
        broadcast_turn(driver, old_room, new_direction, vehicle)
      end

      journey.update(last_direction: new_direction)

      # Notify anyone passed on the street
      broadcast_passing(driver, new_room, vehicle)

      # Update driver position (for observer visibility)
      driver.update(current_room_id: new_room.id)

      if journey.more_rooms?
        schedule_next_move(journey)
      else
        complete_journey(journey)
      end
    end

    # Determine travel direction between two rooms.
    # Uses spatial adjacency to find the direction
    #
    # @param from_room [Room] source room
    # @param to_room [Room] destination room
    # @return [String] direction name
    def determine_direction(from_room, to_room)
      direction = RoomAdjacencyService.direction_to_room(from_room, to_room)
      direction&.to_s || 'forward'
    end

    # Broadcast departure message to room.
    #
    # @param character_instance [CharacterInstance] the driver
    # @param room [Room] the departure room
    # @param vehicle [Vehicle, nil] the vehicle or nil for taxi
    def broadcast_departure(character_instance, room, vehicle)
      char_name = character_instance.character.full_name
      vehicle_desc = vehicle ? vehicle.name : taxi_description

      BroadcastService.to_room(
        room.id,
        "#{char_name} departs in #{vehicle_desc}.",
        exclude: [character_instance.id],
        type: :action
      )
    end

    # Broadcast arrival message to room.
    #
    # @param character_instance [CharacterInstance] the driver
    # @param room [Room] the arrival room
    # @param vehicle [Vehicle, nil] the vehicle or nil for taxi
    def broadcast_arrival(character_instance, room, vehicle)
      char_name = character_instance.character.full_name
      vehicle_desc = vehicle ? vehicle.name : taxi_description

      BroadcastService.to_room(
        room.id,
        "#{vehicle_desc} arrives, and #{char_name} steps out.",
        exclude: [character_instance.id],
        type: :action
      )
    end

    # Broadcast turn message when vehicle changes direction.
    #
    # @param driver [CharacterInstance] the driver
    # @param room [Room] the room where turn occurs
    # @param direction [String] new direction
    # @param vehicle [Vehicle, nil] the vehicle
    def broadcast_turn(driver, room, direction, vehicle)
      vehicle_desc = vehicle_description(vehicle)

      BroadcastService.to_room(
        room.id,
        "#{vehicle_desc} turns #{direction}.",
        exclude: [driver.id],
        type: :action
      )
    end

    # Broadcast passing message to characters on the street.
    #
    # @param driver [CharacterInstance] the driver
    # @param room [Room] the room being passed through
    # @param vehicle [Vehicle, nil] the vehicle
    def broadcast_passing(driver, room, vehicle)
      characters = CharacterInstance.where(
        current_room_id: room.id,
        online: true
      ).exclude(id: driver.id)
        .eager(:character)
        .all

      return if characters.empty?

      vehicle_desc = vehicle_description(vehicle)
      driver_char = driver.character

      characters.each do |observer|
        observer_name = driver_char.display_name_for(observer.character)
        BroadcastService.to_character(
          driver,
          "You pass #{observer_name} on the street.",
          type: :travel
        )

        if vehicle&.occupants_visible?
          driver_name = observer.character.display_name_for(driver_char)
          visible_msg = "#{vehicle_desc} drives past. #{driver_name} is at the wheel."
          BroadcastService.to_character(
            observer,
            visible_msg,
            type: :action
          )

          # Log vehicle sighting to character story
          IcActivityService.record_for(
            recipients: [observer], content: visible_msg,
            sender: nil, type: :movement
          )
        else
          hidden_msg = "#{vehicle_desc} drives past."
          BroadcastService.to_character(
            observer,
            hidden_msg,
            type: :action
          )

          # Log vehicle sighting to character story
          IcActivityService.record_for(
            recipients: [observer], content: hidden_msg,
            sender: nil, type: :movement
          )
        end
      end
    end

    # Get vehicle description for messages.
    #
    # @param vehicle [Vehicle, nil] the vehicle
    # @return [String] description
    def vehicle_description(vehicle)
      if vehicle
        "A #{vehicle.name}"
      else
        taxi_description
      end
    end

    # Get era-appropriate taxi name.
    #
    # @return [String] taxi description
    def taxi_description
      EraService.taxi_name || 'taxi'
    end

    # Build journey start message for the driver.
    #
    # @param character_instance [CharacterInstance] the driver
    # @param destination [Room] the destination
    # @param vehicle [Vehicle, nil] the vehicle
    # @return [String] message
    def journey_start_message(character_instance, destination, vehicle)
      if vehicle
        "You get in your #{vehicle.name} and head toward #{destination.name}."
      else
        "You board the #{taxi_description} heading to #{destination.name}."
      end
    end
  end
end
