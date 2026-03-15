# frozen_string_literal: true

# TaxiService handles era-appropriate taxi/rideshare functionality.
# Different eras have different types of taxi service:
#
# - Medieval: No taxi service (walk everywhere)
# - Gaslight: Hansom cab / carriage taxi
# - Modern: Rideshare (Uber/Lyft style)
# - Near-Future: Autocab (self-driving)
# - Sci-Fi: Hover taxi
class TaxiService
  extend ResultHandler
  class << self
    # Check if taxi service is available in the current era
    # @return [Boolean]
    def available?
      EraService.taxi_available?
    end

    # Get the taxi type for the current era
    # @return [Symbol, nil]
    def taxi_type
      EraService.taxi_type
    end

    # Get the human-readable name for the taxi type
    # @return [String]
    def taxi_name
      EraService.taxi_name
    end

    # Call a taxi to the character's current location
    # @param character_instance [CharacterInstance] the character calling the taxi
    # @param destination [String, nil] optional destination name
    # @return [Hash] result with success status and message
    def call_taxi(character_instance, destination = nil)
      unless available?
        return error(
          "There's no taxi service in this era. " \
          "You'll need to walk or use your own transportation."
        )
      end

      current_room = character_instance.current_room
      unless current_room
        return error("You need to be somewhere to call a #{taxi_name}.")
      end

      # Check if outdoors or at a taxi stand
      unless can_call_taxi_from?(current_room)
        return error(
          "You can't call a #{taxi_name} from here. " \
          "Try going outside or to a taxi stand."
        )
      end

      # Spawn the appropriate taxi
      result = spawn_taxi(character_instance, current_room, destination)

      if result[:success]
        # Broadcast taxi arrival to room
        broadcast_taxi_arrival(character_instance, current_room)
      end

      result
    end

    # Board a waiting taxi
    # @param character_instance [CharacterInstance] the character boarding
    # @param destination [String] where they want to go
    # @return [Hash] result with success status
    def board_taxi(character_instance, destination)
      # Find waiting taxi at character's location
      taxi = find_waiting_taxi(character_instance.current_room)

      unless taxi
        return error("There's no #{taxi_name} waiting here.")
      end

      # Resolve destination
      target_room = resolve_destination(character_instance, destination)

      unless target_room
        return error("The driver doesn't know where '#{destination}' is.")
      end

      # Calculate fare
      fare = calculate_fare(character_instance.current_room, target_room)

      # Check if character can afford it
      unless can_afford?(character_instance, fare)
        return error(
          "The fare would be #{EraService.format_currency(fare)}. You can't afford that."
        )
      end

      # Process payment and travel
      deduct_fare(character_instance, fare)
      travel_to_destination(character_instance, target_room, taxi)

      success(
        "You pay #{EraService.format_currency(fare)} and the #{taxi_name} takes you to #{target_room.name}.",
        data: {
          fare: fare,
          destination: target_room.name,
          destination_id: target_room.id
        }
      )
    end

    private

    def can_call_taxi_from?(room)
      # Can call from outdoors (streets, intersections, parks)
      return true if RoomTypeConfig.street?(room.room_type) || %w[park plaza outdoor].include?(room.room_type)

      # Can call from taxi stands
      return true if room.name&.downcase&.include?('taxi')
      return true if room.name&.downcase&.include?('cab stand')

      # Modern+ eras: can call from anywhere with a phone
      if EraService.modern? || EraService.near_future? || EraService.scifi?
        return true # App-based ride hailing
      end

      false
    end

    def spawn_taxi(character_instance, room, destination)
      # In a full implementation, this would create a vehicle NPC
      # For now, we'll simulate the taxi arrival with a message

      wait_time = calculate_wait_time(room)

      # Different descriptions based on era
      description = case taxi_type
                    when :carriage
                      "A hansom cab clatters up to the curb, the driver tipping his hat."
                    when :rideshare
                      "A car pulls up with a rideshare sticker in the window."
                    when :autocab
                      "A sleek autonomous vehicle glides silently to a stop."
                    when :hovertaxi
                      "A hover taxi descends smoothly from the skylane."
                    else
                      "A taxi arrives."
                    end

      success(
        "#{description}\n\nUse 'taxi to <destination>' to travel.",
        data: {
          taxi_type: taxi_type,
          wait_time: wait_time,
          destination: destination
        }
      )
    end

    def calculate_wait_time(room)
      # Wait time varies by era and location type
      base_wait = case taxi_type
                  when :carriage then 300     # 5 minutes
                  when :rideshare then 180    # 3 minutes
                  when :autocab then 60       # 1 minute
                  when :hovertaxi then 30     # 30 seconds
                  else 120
                  end

      # Reduce wait time at taxi stands
      if room.name&.downcase&.include?('taxi') || room.name&.downcase&.include?('cab stand')
        base_wait / 2
      else
        base_wait
      end
    end

    def calculate_fare(from_room, to_room)
      # Simple fare calculation based on room ID difference
      # In a full implementation, this would use actual pathfinding distance
      distance = (from_room.id - to_room.id).abs
      base_fare = case taxi_type
                  when :carriage then 5
                  when :rideshare then 10
                  when :autocab then 15
                  when :hovertaxi then 25
                  else 10
                  end

      base_fare + (distance * 0.5).round
    end

    def can_afford?(character_instance, fare)
      # Check if character can pay the fare
      # For digital-only eras, check bank account; otherwise, check wallet

      currency = currency(character_instance)
      return false unless currency

      if EraService.digital_only?
        # Check bank account
        bank_account = character_instance.character.bank_accounts_dataset
                                         .first(currency_id: currency.id)
        return false unless bank_account

        bank_account.balance >= fare
      else
        # Check wallet (cash on hand)
        wallet = character_instance.wallets_dataset.first(currency_id: currency.id)
        return false unless wallet

        wallet.balance >= fare
      end
    end

    def deduct_fare(character_instance, fare)
      currency = currency(character_instance)
      return false unless currency

      if EraService.digital_only?
        bank_account = character_instance.character.bank_accounts_dataset
                                         .first(currency_id: currency.id)
        bank_account&.withdraw(fare)
      else
        wallet = character_instance.wallets_dataset.first(currency_id: currency.id)
        wallet&.remove(fare)
      end
    end

    def currency(character_instance)
      room = character_instance.current_room
      return nil unless room&.location&.zone&.world&.universe

      Currency.default_for(room.location.zone.world.universe)
    end

    def find_waiting_taxi(room)
      # In a full implementation, this would find an actual taxi vehicle
      # For now, we assume a taxi is always available after calling
      true
    end

    def resolve_destination(character_instance, destination)
      return nil if destination.nil? || destination.strip.empty?

      destination_lower = destination.downcase.strip

      # Try to find a room matching the destination
      room = character_instance.current_room

      # Search within same location first
      if room&.location
        match = Room.where(location_id: room.location_id)
                    .where(Sequel.ilike(:name, "%#{destination_lower}%"))
                    .first
        return match if match
      end

      # Search within same zone
      if room&.location&.zone
        match = Room.join(:locations, id: :location_id)
                    .where(Sequel[:locations][:zone_id] => room.location.zone_id)
                    .where(Sequel.ilike(Sequel[:rooms][:name], "%#{destination_lower}%"))
                    .select_all(:rooms)
                    .first
        return match if match
      end

      # Search the entire world (taxis can go anywhere in the city)
      if room&.location&.zone&.world
        match = Room.join(:locations, id: :location_id)
                    .join(:zones, id: Sequel[:locations][:zone_id])
                    .where(Sequel[:zones][:world_id] => room.location.zone.world_id)
                    .where(Sequel.ilike(Sequel[:rooms][:name], "%#{destination_lower}%"))
                    .select_all(:rooms)
                    .first
        return match if match
      end

      # Last resort: search all public rooms (no owner)
      Room.where(owner_id: nil)
          .where(Sequel.ilike(:name, "%#{destination_lower}%"))
          .first
    end

    def travel_to_destination(character_instance, destination_room, _taxi)
      # Use the enhanced travel experience
      travel_with_experience(character_instance, destination_room)
    end

    # Enhanced taxi travel with vehicle interior experience.
    # Provides a narrative of the journey while instantly moving the character.
    # @param character_instance [CharacterInstance]
    # @param destination_room [Room]
    # @return [Hash] travel result with narrative
    def travel_with_experience(character_instance, destination_room)
      from_room = character_instance.current_room

      # Find or create a taxi vehicle
      vehicle = assign_taxi_vehicle(character_instance)

      # Put character in the taxi
      character_instance.update(current_vehicle_id: vehicle&.id) if vehicle

      # Calculate the street route for the narrative
      route = calculate_taxi_route(from_room, destination_room)

      # Generate the travel narrative
      narrative = generate_travel_narrative(route, vehicle)

      # Broadcast departure
      broadcast_departure(character_instance, from_room, destination_room)

      # Move the character to the destination (instant)
      character_instance.update(
        current_room_id: destination_room.id,
        current_vehicle_id: nil,
        x: 0.0,
        y: 0.0,
        z: 0.0
      )

      # Clear any place assignment
      character_instance.leave_place! if character_instance.at_place?

      # Broadcast arrival
      broadcast_arrival(character_instance, destination_room)

      {
        success: true,
        narrative: narrative,
        route: route,
        from_room: from_room,
        to_room: destination_room
      }
    end

    # Find or create a taxi vehicle for the character
    def assign_taxi_vehicle(character_instance)
      room = character_instance.current_room
      return nil unless room

      # Look for existing taxi in the zone
      zone = room.location&.zone
      return nil unless zone

      # Find an available taxi (joins through VehicleType)
      taxi_type = VehicleType.first(name: 'taxi')
      taxi = if taxi_type
               Vehicle.where(vehicle_type_id: taxi_type.id, status: 'parked').first
             end
      taxi || create_virtual_taxi(zone)
    end

    # Create a virtual taxi if none exists
    def create_virtual_taxi(zone)
      # In a full implementation, this would create a persistent vehicle
      # For now, return nil and use narrative-only experience
      nil
    end

    # Calculate the route the taxi takes through the streets
    def calculate_taxi_route(from_room, to_room)
      return [] if from_room.nil? || to_room.nil?

      # Use pathfinding to get the street route
      PathfindingService.street_route(from_room, to_room)
    end

    # Generate narrative text describing the taxi journey
    def generate_travel_narrative(route, vehicle)
      lines = []

      # Interior description
      lines << vehicle_interior_text(vehicle)
      lines << ""

      # Journey description
      lines << departure_text

      # Route narration (show passing streets)
      if route.length > 2
        # Show a few intermediate stops
        shown_rooms = select_route_highlights(route)
        shown_rooms.each do |room|
          lines << "  ...passing through #{room.name}..."
        end
      end

      lines << ""
      lines << arrival_text

      lines.join("\n")
    end

    # Get vehicle interior description text
    def vehicle_interior_text(vehicle)
      if vehicle && vehicle.in_desc && !vehicle.in_desc.to_s.empty?
        vehicle.in_desc
      else
        case taxi_type
        when :carriage
          "You climb into the hansom cab. The leather seat is worn but comfortable, and the driver closes the half-door behind you."
        when :rideshare
          "You slide into the back seat. The driver confirms your destination on their phone app."
        when :autocab
          "The autocab door slides open smoothly. You settle into the clean interior as a gentle chime confirms your destination."
        when :hovertaxi
          "The hover taxi descends, its side door gull-winging open. You step in and sink into the form-fitting seat as the city spreads out below."
        else
          "You settle into the back of the taxi. The driver glances at you in the rearview mirror."
        end
      end
    end

    def departure_text
      case taxi_type
      when :carriage
        "With a click of the driver's tongue, the horse moves forward and the cab rattles into motion..."
      when :rideshare
        "The driver merges into traffic..."
      when :autocab
        "The autocab smoothly accelerates, joining the flow of automated traffic..."
      when :hovertaxi
        "The hover taxi lifts and joins the aerial traffic lane..."
      else
        "The taxi pulls away from the curb..."
      end
    end

    def arrival_text
      case taxi_type
      when :carriage
        "The cab slows and pulls to the side of the street. 'Here we are,' the driver announces."
      when :rideshare
        "The driver pulls to the curb. 'This is your stop.'"
      when :autocab
        "The autocab gently decelerates and parks. 'You have arrived at your destination,' it announces."
      when :hovertaxi
        "The hover taxi descends gracefully to street level. 'Destination reached.'"
      else
        "The taxi arrives at your destination."
      end
    end

    # Select a few interesting rooms from the route to mention
    def select_route_highlights(route)
      return [] if route.length <= 2

      # Show up to 3 intermediate rooms
      highlights = []
      step = [(route.length - 2) / 3, 1].max

      (1...route.length - 1).step(step).each do |i|
        room = route[i]
        next unless room

        # Prefer named streets/intersections
        if RoomTypeConfig.street?(room.room_type)
          highlights << room
        end
        break if highlights.length >= 3
      end

      highlights
    end

    def broadcast_departure(character_instance, from_room, destination_room)
      description = case taxi_type
                    when :carriage
                      "#{character_instance.character.full_name} departs in a hansom cab heading toward #{destination_room.name}."
                    when :rideshare
                      "#{character_instance.character.full_name} gets into a rideshare and heads off."
                    when :autocab
                      "#{character_instance.character.full_name} departs in an autocab."
                    when :hovertaxi
                      "#{character_instance.character.full_name} lifts off in a hover taxi."
                    else
                      "#{character_instance.character.full_name} departs in a taxi."
                    end

      BroadcastService.to_room(
        from_room.id,
        description,
        exclude: [character_instance.id],
        type: :action
      )
    end

    def broadcast_arrival(character_instance, destination_room)
      description = case taxi_type
                    when :carriage
                      "A hansom cab arrives, and #{character_instance.character.full_name} steps out."
                    when :rideshare
                      "A car pulls up, and #{character_instance.character.full_name} gets out."
                    when :autocab
                      "An autocab arrives, and #{character_instance.character.full_name} exits."
                    when :hovertaxi
                      "A hover taxi descends, and #{character_instance.character.full_name} steps out."
                    else
                      "A taxi arrives, and #{character_instance.character.full_name} gets out."
                    end

      BroadcastService.to_room(
        destination_room.id,
        description,
        exclude: [character_instance.id],
        type: :action
      )
    end

    def broadcast_taxi_arrival(character_instance, room)
      description = case taxi_type
                    when :carriage
                      "A hansom cab arrives for #{character_instance.character.full_name}."
                    when :rideshare
                      "A rideshare vehicle arrives for #{character_instance.character.full_name}."
                    when :autocab
                      "An autocab arrives for #{character_instance.character.full_name}."
                    when :hovertaxi
                      "A hover taxi descends for #{character_instance.character.full_name}."
                    else
                      "A taxi arrives for #{character_instance.character.full_name}."
                    end

      BroadcastService.to_room(
        room.id,
        description,
        exclude: [character_instance.id],
        type: :action
      )
    end

  end
end
