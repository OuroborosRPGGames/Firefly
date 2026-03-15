# frozen_string_literal: true

# FlashbackTravelService handles the three flashback travel modes:
#
# 1. Basic - Use flashback time to reduce journey time, travel normally
# 2. Return - Reserve flashback time for return, traveler is instanced at destination
# 3. Backloaded - Arrive instantly, but return takes 2x the travel time
#
# Usage:
#   FlashbackTravelService.start_flashback_journey(character_instance, destination: loc, mode: :basic)
#   FlashbackTravelService.end_flashback_instance(character_instance)
#   FlashbackTravelService.estimate_journey_time(character_instance, destination)
#
class FlashbackTravelService
  class << self
    # Start a flashback journey
    #
    # @param character_instance [CharacterInstance]
    # @param destination [Location]
    # @param mode [Symbol] :basic, :return, or :backloaded
    # @param co_travelers [Array<CharacterInstance>] characters traveling together
    # @return [Hash] result with :success, :message, :journey
    def start_flashback_journey(character_instance, destination:, mode: :basic, co_travelers: [])
      # Validate character is not already traveling
      if character_instance.traveling?
        return { success: false, error: 'You are already on a journey.' }
      end

      if character_instance.flashback_instanced?
        return { success: false, error: 'You are already in a flashback instance.' }
      end

      current_location = character_instance.current_room&.location
      if current_location&.world_id && destination&.world_id && current_location.world_id != destination.world_id
        return { success: false, error: 'Cannot travel to a location in a different world.' }
      end

      # Calculate base journey time
      journey_seconds = estimate_journey_time(character_instance, destination)
      if journey_seconds.nil?
        return { success: false, error: 'Cannot calculate journey time - check location coordinates.' }
      end

      if journey_seconds <= 0
        return { success: false, error: 'You are already at that location.' }
      end

      # Calculate flashback coverage
      coverage = FlashbackTimeService.calculate_flashback_coverage(
        character_instance,
        journey_seconds,
        mode: mode
      )

      unless coverage[:success]
        return { success: false, error: coverage[:error] }
      end

      case mode
      when :basic
        start_basic_journey(character_instance, destination, coverage, co_travelers)
      when :return
        start_return_journey(character_instance, destination, coverage, co_travelers, journey_seconds)
      when :backloaded
        start_backloaded_journey(character_instance, destination, coverage, co_travelers, journey_seconds)
      else
        { success: false, error: "Unknown flashback mode: #{mode}" }
      end
    end

    # End flashback instance (when leaving destination)
    #
    # @param character_instance [CharacterInstance]
    # @return [Hash] result
    def end_flashback_instance(character_instance)
      unless character_instance.flashback_instanced?
        return { success: false, error: 'You are not in a flashback instance.' }
      end

      mode = character_instance.flashback_travel_mode
      origin_room = character_instance.flashback_origin_room

      unless origin_room
        # Fallback: just clear state
        character_instance.clear_flashback_state!
        return { success: true, message: 'Flashback instance ended.' }
      end

      case mode
      when 'return'
        handle_return_with_reserved_time(character_instance, origin_room)
      when 'backloaded'
        handle_backloaded_return(character_instance, origin_room)
      else
        # Should not happen
        character_instance.clear_flashback_state!
        { success: true, message: 'Flashback instance ended.' }
      end
    end

    # Estimate journey time between character's current location and destination
    #
    # @param character_instance [CharacterInstance]
    # @param destination [Location]
    # @return [Integer, nil] journey time in seconds, or nil if cannot calculate
    def estimate_journey_time(character_instance, destination)
      current_location = character_instance.current_room&.location
      return nil unless current_location&.has_globe_hex? && destination.has_globe_hex?
      return nil if current_location.world_id && destination.world_id && current_location.world_id != destination.world_id

      # Same location check
      if current_location.id == destination.id
        return 0
      end

      # Calculate hex distance using great circle distance
      hex_distance = calculate_hex_distance(current_location, destination)

      return 0 if hex_distance <= 0

      # Base time per hex (from WorldJourney config)
      base_time_per_hex = WorldJourney::BASE_TIME_PER_HEX

      # Use default modern car speed for estimates (3.0x multiplier)
      # This gives a reasonable estimate without needing to specify vehicle
      vehicle_multiplier = 3.0
      era_multiplier = 2.0  # Modern era

      effective_time = base_time_per_hex / (vehicle_multiplier * era_multiplier)

      (hex_distance * effective_time).round
    end

    # Get travel options for a destination
    #
    # @param character_instance [CharacterInstance]
    # @param destination [Location]
    # @return [Hash] options for each travel mode
    def travel_options(character_instance, destination)
      journey_seconds = estimate_journey_time(character_instance, destination)
      return { error: 'Cannot calculate journey time' } if journey_seconds.nil?

      available = FlashbackTimeService.available_time(character_instance)

      {
        journey_time: journey_seconds,
        journey_time_display: FlashbackTimeService.format_journey_time(journey_seconds),
        flashback_available: available,
        flashback_display: FlashbackTimeService.format_time(available),
        basic: FlashbackTimeService.calculate_flashback_coverage(character_instance, journey_seconds, mode: :basic),
        return: FlashbackTimeService.calculate_flashback_coverage(character_instance, journey_seconds, mode: :return),
        backloaded: FlashbackTimeService.calculate_flashback_coverage(character_instance, journey_seconds, mode: :backloaded)
      }
    end

    private

    # Start basic flashback travel
    # Uses flashback time to reduce or eliminate journey time
    def start_basic_journey(character_instance, destination, coverage, co_travelers)
      if coverage[:can_instant]
        # Instant arrival - no journey needed
        instant_arrival(character_instance, destination, co_travelers)
      else
        # Start normal journey with reduced time
        start_reduced_journey(character_instance, destination, coverage[:time_remaining], co_travelers)
      end
    end

    # Start return flashback travel
    # Reserves flashback time for return, traveler is instanced
    def start_return_journey(character_instance, destination, coverage, co_travelers, journey_seconds)
      unless coverage[:can_instant]
        return {
          success: false,
          error: "Not enough flashback time for return travel. Need #{FlashbackTimeService.format_time(journey_seconds * 2)} total, have #{FlashbackTimeService.format_time(FlashbackTimeService.available_time(character_instance))}."
        }
      end

      origin_room = character_instance.current_room
      arrival_room = find_arrival_room(destination)
      unless arrival_room
        return { success: false, error: "No valid arrival room found at #{destination.display_name}." }
      end

      begin
        DB.transaction do
          co_traveler_ids = co_travelers.map(&:id)
          character_instance.enter_flashback_instance!(
            mode: 'return',
            origin_room: origin_room,
            destination_location: destination,
            co_travelers: co_traveler_ids,
            reserved_time: coverage[:reserved_for_return]
          )

          co_travelers.each do |traveler|
            traveler.enter_flashback_instance!(
              mode: 'return',
              origin_room: origin_room,
              destination_location: destination,
              co_travelers: (co_traveler_ids - [traveler.id]) + [character_instance.id],
              reserved_time: coverage[:reserved_for_return]
            )
          end

          character_instance.teleport_to_room!(arrival_room)
          co_travelers.each { |traveler| traveler.teleport_to_room!(arrival_room) }
        end
      rescue StandardError => e
        warn "[FlashbackTravelService] Return journey setup failed: #{e.message}"
        return { success: false, error: 'Failed to start return flashback journey.' }
      end

      {
        success: true,
        message: "You arrive at #{destination.display_name} via flashback return travel. You are instanced and can only interact with your co-travelers. Use 'return' to travel back.",
        instanced: true,
        return_time_available: FlashbackTimeService.format_time(coverage[:reserved_for_return]),
        destination: destination.display_name
      }
    end

    # Start backloaded flashback travel
    # Instant arrival, but return takes 2x the travel time
    def start_backloaded_journey(character_instance, destination, coverage, co_travelers, journey_seconds)
      origin_room = character_instance.current_room
      arrival_room = find_arrival_room(destination)
      unless arrival_room
        return { success: false, error: "No valid arrival room found at #{destination.display_name}." }
      end

      begin
        DB.transaction do
          co_traveler_ids = co_travelers.map(&:id)
          character_instance.enter_flashback_instance!(
            mode: 'backloaded',
            origin_room: origin_room,
            destination_location: destination,
            co_travelers: co_traveler_ids,
            reserved_time: 0,
            return_debt: coverage[:return_debt]
          )

          co_travelers.each do |traveler|
            traveler.enter_flashback_instance!(
              mode: 'backloaded',
              origin_room: origin_room,
              destination_location: destination,
              co_travelers: (co_traveler_ids - [traveler.id]) + [character_instance.id],
              reserved_time: 0,
              return_debt: coverage[:return_debt]
            )
          end

          character_instance.teleport_to_room!(arrival_room)
          co_travelers.each { |traveler| traveler.teleport_to_room!(arrival_room) }
        end
      rescue StandardError => e
        warn "[FlashbackTravelService] Backloaded journey setup failed: #{e.message}"
        return { success: false, error: 'Failed to start backloaded flashback journey.' }
      end

      {
        success: true,
        message: "You arrive instantly at #{destination.display_name} via backloaded travel. Return will take #{FlashbackTimeService.format_time(coverage[:return_debt])}. Use 'return' when ready to leave.",
        instanced: true,
        return_debt: coverage[:return_debt],
        return_debt_display: FlashbackTimeService.format_time(coverage[:return_debt]),
        destination: destination.display_name
      }
    end

    # Handle instant arrival (basic mode with full coverage)
    def instant_arrival(character_instance, destination, co_travelers)
      arrival_room = find_arrival_room(destination)
      unless arrival_room
        return { success: false, error: "No valid arrival room found at #{destination.display_name}." }
      end

      # Just teleport - no instancing
      character_instance.teleport_to_room!(arrival_room)
      co_travelers.each { |t| t.teleport_to_room!(arrival_room) }

      # Reset RP activity since this was flashback
      character_instance.touch_rp_activity!
      co_travelers.each(&:touch_rp_activity!)

      {
        success: true,
        message: "Using your accumulated flashback time, you arrive instantly at #{destination.display_name}.",
        instanced: false,
        destination: destination.display_name
      }
    end

    # Start a reduced-time journey using WorldTravelService
    def start_reduced_journey(character_instance, destination, remaining_time_seconds, co_travelers)
      # Calculate what speed modifier gives us the remaining time
      # This is a simplification - we apply a speed boost to reduce travel time
      base_journey_seconds = estimate_journey_time(character_instance, destination)
      return { success: false, error: 'Cannot calculate journey time' } if base_journey_seconds.nil? || base_journey_seconds <= 0

      speed_boost = base_journey_seconds.to_f / remaining_time_seconds

      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination
      )

      return result unless result[:success]

      journey = result[:journey]

      begin
        # Apply speed boost to reduce journey time
        journey.update(speed_modifier: (journey.speed_modifier || 1.0) * speed_boost)

        # Recalculate arrival time
        journey.update(estimated_arrival_at: Time.now + remaining_time_seconds)
      rescue StandardError => e
        warn "[FlashbackTravelService] Reduced journey timing update failed: #{e.message}"
        # Cancel the journey and teleport back to original room
        journey.cancel! rescue nil
        original_room = character_instance.current_room
        character_instance.teleport_to_room!(original_room) if original_room
        return { success: false, error: 'Journey timing failed. You have not moved.' }
      end

      time_saved = base_journey_seconds - remaining_time_seconds

      {
        success: true,
        message: "Using flashback time, you save #{FlashbackTimeService.format_time(time_saved)}. Journey to #{destination.display_name} will take #{FlashbackTimeService.format_time(remaining_time_seconds)}.",
        journey: journey,
        instanced: false,
        destination: destination.display_name
      }
    end

    # Handle return from instanced state with reserved time
    def handle_return_with_reserved_time(character_instance, origin_room)
      reserved_time = character_instance.flashback_time_reserved
      origin_location = origin_room.location

      # Calculate return time
      return_journey_time = estimate_return_journey_time(character_instance, origin_location)

      # Clear flashback state first
      character_instance.clear_flashback_state!

      if reserved_time >= return_journey_time
        # Instant return
        character_instance.teleport_to_room!(origin_room)
        character_instance.touch_rp_activity!

        {
          success: true,
          message: "Using reserved flashback time, you return instantly to #{origin_room.name}.",
          instant: true
        }
      else
        # Start journey with remaining time
        remaining = return_journey_time - reserved_time

        result = WorldTravelService.start_journey(character_instance, destination: origin_location)

        if result[:success]
          journey = result[:journey]
          # Set return_to_room_id so complete_arrival! returns to exact origin room
          journey.update(return_to_room_id: origin_room.id)

          begin
            # Apply speed boost for the time we saved
            speed_boost = return_journey_time.to_f / remaining
            journey.update(speed_modifier: (journey.speed_modifier || 1.0) * speed_boost)
            journey.update(estimated_arrival_at: Time.now + remaining)
          rescue StandardError => e
            warn "[FlashbackTravelService] Return timing update failed: #{e.message}"
            # Journey created but timing failed - cancel and teleport
            journey.cancel! rescue nil
            character_instance.teleport_to_room!(origin_room)
            return { success: true, message: "You return to #{origin_room.name}.", instant: true }
          end

          {
            success: true,
            message: "Reserved flashback time saved #{FlashbackTimeService.format_time(reserved_time)}. Return journey will take #{FlashbackTimeService.format_time(remaining)}.",
            journey: journey,
            instant: false
          }
        else
          # Fallback - just teleport
          character_instance.teleport_to_room!(origin_room)
          { success: true, message: "You return to #{origin_room.name}.", instant: true }
        end
      end
    end

    # Handle return from backloaded travel (2x time)
    def handle_backloaded_return(character_instance, origin_room)
      return_debt = character_instance.flashback_return_debt || 0
      origin_location = origin_room.location

      # Clear flashback state
      character_instance.clear_flashback_state!

      if return_debt <= 0
        # No debt - instant return
        character_instance.teleport_to_room!(origin_room)
        character_instance.touch_rp_activity!
        return { success: true, message: "You return to #{origin_room.name}.", instant: true }
      end

      # Start return journey with 2x time (already calculated as return_debt)
      begin
        result = WorldTravelService.start_journey(character_instance, destination: origin_location)
      rescue StandardError => e
        warn "[FlashbackTravelService] Return journey failed: #{e.message}"
        character_instance.teleport_to_room!(origin_room)
        return { success: true, message: "You return to #{origin_room.name}.", instant: true }
      end

      if result[:success]
        journey = result[:journey]
        # Set return_to_room_id so complete_arrival! returns to exact origin room
        journey.update(return_to_room_id: origin_room.id)

        begin
          # Calculate speed modifier to achieve the debt time
          base_time = estimate_return_journey_time(character_instance, origin_location)
          if base_time && base_time > 0
            speed_modifier = base_time.to_f / return_debt
            journey.update(speed_modifier: (journey.speed_modifier || 1.0) * speed_modifier)
          end
          journey.update(estimated_arrival_at: Time.now + return_debt)
        rescue StandardError => e
          warn "[FlashbackTravelService] Backloaded return timing update failed: #{e.message}"
          # Journey created but timing failed - cancel and teleport
          journey.cancel! rescue nil
          character_instance.teleport_to_room!(origin_room)
          return { success: true, message: "You return to #{origin_room.name}.", instant: true }
        end

        {
          success: true,
          message: "Your backloaded return begins. Travel time: #{FlashbackTimeService.format_time(return_debt)}.",
          journey: journey,
          instant: false
        }
      else
        # Fallback - just teleport
        character_instance.teleport_to_room!(origin_room)
        { success: true, message: "You return to #{origin_room.name}.", instant: true }
      end
    rescue StandardError => e
      warn "[FlashbackTravelService] Backloaded return error: #{e.message}"
      # Emergency fallback - clear state and teleport
      character_instance.clear_flashback_state! if character_instance.flashback_instanced?
      character_instance.teleport_to_room!(origin_room)
      { success: true, message: "You return to #{origin_room.name}.", instant: true }
    end

    # Find an arrival room at a location
    def find_arrival_room(location)
      # Prefer street/public rooms
      location.rooms_dataset.where(room_type: %w[street avenue plaza intersection]).first ||
        location.rooms_dataset.where(safe_room: true).first ||
        location.rooms_dataset.first
    end

    # Estimate return journey time
    def estimate_return_journey_time(character_instance, origin_location)
      current_location = character_instance.current_room&.location
      return 0 unless current_location&.has_globe_hex? && origin_location&.has_globe_hex?

      hex_distance = calculate_hex_distance(current_location, origin_location)

      return 0 if hex_distance <= 0

      base_time_per_hex = WorldJourney::BASE_TIME_PER_HEX
      vehicle_multiplier = 3.0
      era_multiplier = 2.0

      effective_time = base_time_per_hex / (vehicle_multiplier * era_multiplier)

      (hex_distance * effective_time).round
    end

    def calculate_hex_distance(origin, destination)
      WorldHex.location_hex_distance(origin, destination)
    end
  end
end
