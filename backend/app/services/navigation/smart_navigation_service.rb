# frozen_string_literal: true

# SmartNavigationService orchestrates intelligent city navigation.
# Chains together: exit building → taxi travel → enter destination.
#
# Based on Ravencroft's navigation system which provides seamless
# travel across complex city layouts using vehicles and walking.
class SmartNavigationService
  # Maximum direct walking distance before suggesting taxi
  MAX_DIRECT_WALK_DISTANCE = 15
  # Maximum steps for building exit/entry pathfinding
  MAX_BUILDING_PATH = 20

  def initialize(character_instance)
    @character_instance = character_instance
    @from_room = character_instance.current_room
    @messages = []
  end

  # Main entry point: navigate to any room in the city.
  # Automatically determines the best route and transport method.
  # @param destination_room [Room] where to go
  # @return [Hash] result with success, messages, and travel details
  def navigate_to(destination_room)
    return already_there_result if same_room?(destination_room)

    # Try direct walking first (same building or nearby)
    direct_path = PathfindingService.find_path(@from_room, destination_room, max_depth: MAX_DIRECT_WALK_DISTANCE)

    if direct_path.any?
      return walk_direct_path(direct_path, destination_room)
    end

    # Need smart navigation: check if taxi is available
    unless TaxiService.available?
      # No taxi available - try longer direct path
      long_path = PathfindingService.find_path(@from_room, destination_room, max_depth: 50)
      if long_path.any?
        return walk_direct_path(long_path, destination_room)
      else
        return unreachable_result(destination_room)
      end
    end

    # Plan the taxi journey - fall back to walking if can't afford fare
    taxi_result = plan_and_execute_taxi_journey(destination_room)

    if !taxi_result[:success] && taxi_result[:error]&.include?("afford")
      # Can't afford taxi - try walking the long way instead
      long_path = PathfindingService.find_path(@from_room, destination_room, max_depth: 50)
      if long_path.any?
        return walk_direct_path(long_path, destination_room)
      end
    end

    taxi_result
  end

  # Navigate using smart routing, returning a structured result.
  # @param destination_name [String] name of destination room
  # @return [Hash] result with success, messages, and travel details
  def navigate_to_named(destination_name)
    destination_room = resolve_destination(destination_name)

    unless destination_room
      return {
        success: false,
        error: "You don't know how to get to '#{destination_name}'.",
        messages: []
      }
    end

    navigate_to(destination_room)
  end

  private

  def same_room?(destination_room)
    @from_room&.id == destination_room&.id
  end

  def already_there_result
    {
      success: true,
      message: "You're already here.",
      messages: ["You're already here."],
      travel_type: :none
    }
  end

  def unreachable_result(destination_room)
    {
      success: false,
      error: "You can't find a way to reach #{destination_room.name} from here.",
      messages: []
    }
  end

  # Walk a direct path to the destination using timed movement.
  def walk_direct_path(path, destination_room)
    first_exit = path.first

    unless first_exit.can_pass?
      return {
        success: false,
        error: "The way is blocked.",
        messages: []
      }
    end

    adverb = 'walk'

    @character_instance.update(
      movement_state: 'moving',
      movement_adverb: adverb,
      final_destination_id: destination_room.id
    )

    # Calculate time based on distance to first exit
    duration = MovementConfig.time_for_movement(adverb, first_exit, @character_instance)
    start_pos = @character_instance.position
    exit_pos = DistanceService.exit_position_in_room(first_exit)

    TimedAction.start_delayed(
      @character_instance,
      'movement',
      duration,
      'MovementHandler',
      {
        direction: first_exit.direction,
        destination_room_id: first_exit.to_room.id,
        adverb: adverb,
        start_x: start_pos[0],
        start_y: start_pos[1],
        start_z: start_pos[2],
        target_x: exit_pos[0],
        target_y: exit_pos[1],
        target_z: exit_pos[2]
      }
    )

    verb_continuous = MovementConfig.conjugate(adverb, :continuous)

    {
      success: true,
      message: "You start #{verb_continuous} toward #{destination_room.name}.",
      messages: ["You start #{verb_continuous} toward #{destination_room.name}."],
      travel_type: :walk,
      path_length: path.length,
      destination: destination_room.name,
      duration: duration
    }
  end

  def format_walk_message(path, destination_room)
    if path.length == 1
      "You walk to #{destination_room.name}."
    elsif path.length <= 3
      directions = path.map(&:direction).join(', then ')
      "You walk #{directions} to #{destination_room.name}."
    else
      "You make your way through #{path.length} rooms to reach #{destination_room.name}."
    end
  end

  # Plan and execute a taxi journey with building exit/entry.
  def plan_and_execute_taxi_journey(destination_room)
    @messages = []
    current_room = @from_room

    # Phase 1: Exit building to street (if needed)
    if BuildingNavigationService.indoor_room?(current_room)
      exit_result = walk_out_of_building(current_room)
      return exit_result unless exit_result[:success]

      current_room = exit_result[:street_room]
      @messages += exit_result[:messages]
    end

    # Phase 2: Find the street near destination
    dest_street = BuildingNavigationService.find_nearest_street(destination_room)
    dest_street ||= destination_room  # Fallback if no street found

    # Phase 3: Take taxi to destination street
    taxi_result = take_taxi(current_room, dest_street)
    return taxi_result unless taxi_result[:success]

    @messages << taxi_result[:narrative] if taxi_result[:narrative] && !taxi_result[:narrative].to_s.empty?

    # Phase 4: Walk into destination building (if needed)
    if dest_street.id != destination_room.id
      entry_result = walk_into_building(dest_street, destination_room)
      return entry_result unless entry_result[:success]

      @messages += entry_result[:messages]
    end

    {
      success: true,
      message: @messages.join("\n\n"),
      messages: @messages,
      travel_type: :taxi,
      destination: destination_room.name
    }
  end

  # Walk from indoor room to the nearest street.
  def walk_out_of_building(from_room)
    exit_path = BuildingNavigationService.path_to_street(from_room)

    if exit_path.empty?
      # Can't find an exit - maybe we're actually outdoors or isolated
      if BuildingNavigationService.outdoor_room?(from_room)
        return { success: true, street_room: from_room, messages: [] }
      else
        return {
          success: false,
          error: "You can't find a way outside from here.",
          messages: []
        }
      end
    end

    # Execute the walk (exit_path contains Hashes from passable_spatial_exits)
    street_room = exit_path.last[:room]
    walk_messages = []

    # Broadcast leaving
    BroadcastService.to_room(
      from_room.id,
      "#{@character_instance.character.full_name} heads toward the exit.",
      exclude: [@character_instance.id],
      type: :movement
    )

    # Move character to street
    @character_instance.update(
      current_room_id: street_room.id,
      current_place_id: nil
    )

    walk_messages << "You make your way outside to #{street_room.name}."

    {
      success: true,
      street_room: street_room,
      messages: walk_messages,
      path_length: exit_path.length
    }
  end

  # Take a taxi from current street to destination street.
  def take_taxi(from_street, to_street)
    # Check if we can afford the taxi
    fare = calculate_taxi_fare(from_street, to_street)

    unless can_afford_fare?(fare)
      return {
        success: false,
        error: "You can't afford the #{TaxiService.taxi_name} fare of #{format_currency(fare)}.",
        messages: []
      }
    end

    # Deduct the fare
    deduct_fare(fare)

    # Use TaxiService for the actual travel with narrative
    result = TaxiService.send(:travel_with_experience, @character_instance, to_street)

    {
      success: result[:success],
      narrative: result[:narrative],
      messages: [result[:narrative]].compact
    }
  end

  # Walk from a street into a destination building.
  def walk_into_building(street_room, destination_room)
    entry_path = PathfindingService.find_path(street_room, destination_room, max_depth: MAX_BUILDING_PATH)

    if entry_path.empty?
      return {
        success: false,
        error: "You can't find a way into #{destination_room.name} from here.",
        messages: []
      }
    end

    # Execute the walk
    walk_messages = []

    # Move character to destination
    @character_instance.update(
      current_room_id: destination_room.id,
      current_place_id: nil,
      x: 0.0,
      y: 0.0,
      z: 0.0
    )

    # Broadcast arriving
    BroadcastService.to_room(
      destination_room.id,
      "#{@character_instance.character.full_name} arrives.",
      exclude: [@character_instance.id],
      type: :movement
    )

    building_name = BuildingNavigationService.building_name(destination_room)
    if building_name
      walk_messages << "You enter #{building_name} and make your way to #{destination_room.name}."
    else
      walk_messages << "You walk into #{destination_room.name}."
    end

    {
      success: true,
      messages: walk_messages,
      path_length: entry_path.length
    }
  end

  # Resolve a destination name to a Room.
  def resolve_destination(destination_name)
    return nil if destination_name.nil? || destination_name.strip.empty?

    destination_lower = destination_name.downcase.strip

    # Try to find a room matching the destination
    room = @from_room

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

    # Search public rooms (no owner) across the city
    Room.where(owner_id: nil)
        .where(Sequel.ilike(:name, "%#{destination_lower}%"))
        .first
  end

  # Calculate taxi fare based on distance.
  def calculate_taxi_fare(from_room, to_room)
    # Use pathfinding distance for fare calculation
    distance = PathfindingService.distance_between(from_room, to_room) || 10

    base_fare = case TaxiService.taxi_type
                when :carriage then 5
                when :rideshare then 10
                when :autocab then 15
                when :hovertaxi then 25
                else 10
                end

    base_fare + (distance * 0.5).round
  end

  # Check if character can afford the fare.
  def can_afford_fare?(fare)
    cur = currency
    return false unless cur

    if EraService.digital_only?
      bank_account = @character_instance.character.bank_accounts_dataset
                                        .first(currency_id: cur.id)
      return false unless bank_account

      bank_account.balance >= fare
    else
      wallet = @character_instance.wallets_dataset.first(currency_id: cur.id)
      return false unless wallet

      wallet.balance >= fare
    end
  end

  # Deduct the fare from character's money.
  def deduct_fare(fare)
    cur = currency
    return false unless cur

    if EraService.digital_only?
      bank_account = @character_instance.character.bank_accounts_dataset
                                        .first(currency_id: cur.id)
      bank_account&.withdraw(fare)
    else
      wallet = @character_instance.wallets_dataset.first(currency_id: cur.id)
      wallet&.remove(fare)
    end
  end

  def currency
    room = @from_room
    return nil unless room&.location&.zone&.world&.universe

    Currency.default_for(room.location.zone.world.universe)
  end

  def format_currency(amount)
    EraService.format_currency(amount)
  end
end
