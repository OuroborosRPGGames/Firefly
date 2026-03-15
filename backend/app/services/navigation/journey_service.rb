# frozen_string_literal: true

# JourneyService - Unified facade for all world travel functionality
#
# This service coordinates WorldTravelService, FlashbackTravelService,
# and TravelParty logic into a single interface for the journey command and API.
#
# Usage:
#   JourneyService.travel_options(character_instance, destination)
#   JourneyService.start_journey(character_instance, destination:, travel_mode:, flashback_mode:)
#   JourneyService.start_party_journey(travelers:, destination:, ...)
#   JourneyService.world_map_data(character_instance)
#
class JourneyService
  class << self
    # Get comprehensive travel options for a destination
    # Combines WorldTravelService mode detection with FlashbackTravelService options
    #
    # @param character_instance [CharacterInstance]
    # @param destination [Location]
    # @return [Hash] all available travel options
    def travel_options(character_instance, destination)
      current_location = character_instance.current_room&.location

      unless current_location&.has_globe_hex? && destination.has_globe_hex?
        return { success: false, error: 'Locations do not have valid coordinates' }
      end

      if current_location.id == destination.id
        return { success: false, error: 'You are already at this location' }
      end

      # Get flashback options
      flashback_opts = FlashbackTravelService.travel_options(character_instance, destination)
      return { success: false, error: flashback_opts[:error] } if flashback_opts[:error]

      # Determine available travel modes
      available_modes = determine_available_modes(current_location, destination)

      # Calculate distance
      hex_distance = calculate_hex_distance(current_location, destination)
      distance_miles = calculate_distance_miles(current_location, destination)

      {
        success: true,
        destination: {
          id: destination.id,
          name: destination.city_name.to_s.empty? ? destination.name : destination.city_name,
          latitude: destination.latitude,
          longitude: destination.longitude
        },
        origin: {
          id: current_location.id,
          name: current_location.name,
          latitude: current_location.latitude,
          longitude: current_location.longitude
        },
        hex_distance: hex_distance,
        distance_miles: distance_miles,
        journey_time: flashback_opts[:journey_time],
        journey_time_display: flashback_opts[:journey_time_display],
        available_modes: available_modes,
        flashback: {
          available: flashback_opts[:flashback_available],
          available_display: flashback_opts[:flashback_display],
          basic: flashback_opts[:basic],
          return: flashback_opts[:return],
          backloaded: flashback_opts[:backloaded]
        },
        standard: {
          time: flashback_opts[:journey_time],
          time_display: flashback_opts[:journey_time_display],
          vehicle: WorldTravelService.default_vehicle_for_mode(available_modes.first || 'land')
        }
      }
    end

    # Start a journey (solo or party)
    #
    # @param character_instance [CharacterInstance]
    # @param destination [Location]
    # @param travel_mode [String] land/water/rail/air
    # @param flashback_mode [Symbol, String, nil] :basic, :return, :backloaded, or nil for standard
    # @return [Hash] result
    def start_journey(character_instance, destination:, travel_mode: nil, flashback_mode: nil)
      flashback_mode = flashback_mode&.to_sym

      if flashback_mode && %i[basic return backloaded].include?(flashback_mode)
        FlashbackTravelService.start_flashback_journey(
          character_instance,
          destination: destination,
          mode: flashback_mode
        )
      else
        WorldTravelService.start_journey(
          character_instance,
          destination: destination,
          travel_mode: travel_mode
        )
      end
    end

    # Start a party journey for multiple travelers
    #
    # @param travelers [Array<CharacterInstance>] all accepted travelers
    # @param destination [Location]
    # @param travel_mode [String] land/water/rail/air
    # @param flashback_mode [Symbol, String, nil]
    # @param co_traveler_ids [Array<Integer>] IDs of all co-travelers (for instancing)
    # @return [Hash] result
    def start_party_journey(travelers:, destination:, travel_mode: nil, flashback_mode: nil, co_traveler_ids: [])
      return { success: false, error: 'No travelers specified' } if travelers.empty?

      flashback_mode = flashback_mode&.to_sym

      if flashback_mode && %i[return backloaded].include?(flashback_mode)
        # Calculate minimum flashback time across all travelers
        min_flashback = travelers.map(&:flashback_time_available).min
        journey_seconds = FlashbackTravelService.estimate_journey_time(travelers.first, destination)

        # Validate all travelers have enough flashback time
        coverage = FlashbackTimeService.calculate_flashback_coverage_with_available(
          min_flashback,
          journey_seconds,
          mode: flashback_mode
        )

        unless coverage[:success]
          return {
            success: false,
            error: "Party does not have enough collective flashback time. Minimum in party: #{FlashbackTimeService.format_time(min_flashback)}"
          }
        end

        # Start flashback journey with co-travelers
        start_instanced_party_journey(travelers, destination, flashback_mode, coverage)
      elsif flashback_mode == :basic
        # Basic mode - check if can instant, otherwise start reduced journey
        start_basic_party_journey(travelers, destination)
      else
        # Standard journey - all travelers board same journey
        start_standard_party_journey(travelers, destination, travel_mode)
      end
    end

    # Get world map data for the player's current world
    #
    # @param character_instance [CharacterInstance]
    # @return [Hash] map data including terrain, locations, current position
    def world_map_data(character_instance)
      current_location = character_instance.current_room&.location
      return { success: false, error: 'No current location' } unless current_location

      world = current_location.world
      return { success: false, error: 'No world found' } unless world

      # Get all locations in this world that can be traveled to (have globe_hex_id)
      locations = Location.where(world_id: world.id)
                          .exclude(globe_hex_id: nil)
                          .all

      # Calculate lat/lon bounds from locations
      lats = locations.map(&:latitude).compact
      lons = locations.map(&:longitude).compact

      min_lat = [lats.min || -90, -90].max
      max_lat = [lats.max || 90, 90].min
      min_lon = [lons.min || -180, -180].max
      max_lon = [lons.max || 180, 180].min

      # Get terrain data for the region (using lat/lon bounds)
      terrain = WorldHex.where(world_id: world.id)
                        .where { (latitude >= min_lat) & (latitude <= max_lat) }
                        .where { (longitude >= min_lon) & (longitude <= max_lon) }
                        .limit(1000)  # Limit to prevent excessive data
                        .all

      {
        success: true,
        world: {
          id: world.id,
          name: world.name
        },
        current_location: {
          id: current_location.id,
          name: current_location.name,
          latitude: current_location.latitude,
          longitude: current_location.longitude,
          globe_hex_id: current_location.globe_hex_id
        },
        bounds: {
          min_lat: min_lat,
          max_lat: max_lat,
          min_lon: min_lon,
          max_lon: max_lon
        },
        locations: locations.map do |loc|
          {
            id: loc.id,
            name: loc.name,
            city_name: loc.city_name,
            latitude: loc.latitude,
            longitude: loc.longitude,
            globe_hex_id: loc.globe_hex_id,
            has_port: loc.has_port?,
            has_station: loc.has_train_station?
          }
        end,
        terrain: terrain.map do |hex|
          {
            latitude: hex.latitude,
            longitude: hex.longitude,
            globe_hex_id: hex.globe_hex_id,
            terrain: hex.terrain_type,
            traversable: hex.traversable
          }
        end,
        flashback_available: character_instance.flashback_time_available,
        flashback_display: FlashbackTimeService.format_time(character_instance.flashback_time_available)
      }
    end

    # Get available destinations from current location
    #
    # @param character_instance [CharacterInstance]
    # @return [Array<Hash>] destinations with distance/time info
    def available_destinations(character_instance)
      current_location = character_instance.current_room&.location
      return [] unless current_location&.world_id

      Location.where(world_id: current_location.world_id)
              .exclude(id: current_location.id)
              .exclude(globe_hex_id: nil)
              .all
              .map do |dest|
        hex_distance = calculate_hex_distance(current_location, dest)
        journey_time = FlashbackTravelService.estimate_journey_time(character_instance, dest)

        {
          id: dest.id,
          name: dest.name,
          city_name: dest.city_name,
          latitude: dest.latitude,
          longitude: dest.longitude,
          globe_hex_id: dest.globe_hex_id,
          hex_distance: hex_distance,
          journey_time: journey_time,
          journey_time_display: FlashbackTimeService.format_journey_time(journey_time || 0)
        }
      end.sort_by { |d| d[:hex_distance] }
    end

    private

    def calculate_hex_distance(origin, destination)
      WorldHex.location_hex_distance(origin, destination)
    end

    # Calculate distance between two locations in miles
    # @param origin [Location] starting location
    # @param destination [Location] ending location
    # @return [Integer] distance in miles
    def calculate_distance_miles(origin, destination)
      return 0 unless origin.latitude && origin.longitude && destination.latitude && destination.longitude

      distance_rad = WorldHex.great_circle_distance_rad(
        origin.latitude, origin.longitude,
        destination.latitude, destination.longitude
      )

      # Earth radius in miles = 3959
      (distance_rad * 3959).round
    end

    # Determine available travel modes between two locations
    def determine_available_modes(origin, destination)
      modes = []

      # Land is always available if not separated by water
      modes << 'land'

      # Water if both have ports
      if origin.has_port? && destination.has_port?
        modes << 'water'
      end

      # Rail if both have train stations
      if origin.has_train_station? && destination.has_train_station?
        modes << 'rail'
      end

      # Air is available in modern+ eras
      era = origin.world&.respond_to?(:era) ? origin.world.era&.to_sym : :modern
      era ||= :modern
      if %i[modern near_future scifi].include?(era)
        modes << 'air'
      end

      modes
    end

    # Start instanced party journey (return or backloaded mode)
    def start_instanced_party_journey(travelers, destination, mode, coverage)
      leader = travelers.first
      co_traveler_ids = travelers.map(&:id)
      origin_room = leader.current_room

      # Find arrival room
      arrival_room = FlashbackTravelService.send(:find_arrival_room, destination)
      unless arrival_room
        return { success: false, error: "No valid arrival room found at #{destination.name}." }
      end

      begin
        DB.transaction do
          travelers.each do |traveler|
            other_ids = co_traveler_ids - [traveler.id]
            traveler.enter_flashback_instance!(
              mode: mode.to_s,
              origin_room: origin_room,
              destination_location: destination,
              co_travelers: other_ids,
              reserved_time: mode == :return ? coverage[:reserved_for_return] : 0,
              return_debt: mode == :backloaded ? coverage[:return_debt] : 0
            )

            traveler.teleport_to_room!(arrival_room)
          end
        end
      rescue StandardError => e
        warn "[JourneyService] Instanced party journey failed: #{e.message}"
        return { success: false, error: 'Failed to start instanced party journey.' }
      end

      time_info = mode == :return ?
        "#{FlashbackTimeService.format_time(coverage[:reserved_for_return])} reserved for return" :
        "#{FlashbackTimeService.format_time(coverage[:return_debt])} return debt"

      {
        success: true,
        message: "Your party arrives at #{destination.name} via #{mode} travel. #{time_info}. Use 'freturn' when ready to leave.",
        instanced: true,
        destination: destination.name,
        traveler_count: travelers.count
      }
    end

    # Start basic party journey
    def start_basic_party_journey(travelers, destination)
      # Use minimum flashback time across party
      min_flashback = travelers.map(&:flashback_time_available).min
      journey_seconds = FlashbackTravelService.estimate_journey_time(travelers.first, destination)

      coverage = FlashbackTimeService.calculate_flashback_coverage_with_available(
        min_flashback,
        journey_seconds,
        mode: :basic
      )

      if coverage[:can_instant]
        # Instant arrival for all
        arrival_room = FlashbackTravelService.send(:find_arrival_room, destination)
        travelers.each do |traveler|
          traveler.teleport_to_room!(arrival_room)
          traveler.touch_rp_activity!
        end

        {
          success: true,
          message: "Using accumulated flashback time, your party arrives instantly at #{destination.name}.",
          instanced: false,
          destination: destination.name,
          traveler_count: travelers.count
        }
      else
        start_reduced_basic_party_journey(
          travelers,
          destination,
          journey_seconds: journey_seconds,
          remaining_time_seconds: coverage[:time_remaining]
        )
      end
    end

    # Start standard (non-flashback) party journey
    def start_standard_party_journey(travelers, destination, travel_mode)
      leader = travelers.first

      # Start journey with leader
      result = WorldTravelService.start_journey(
        leader,
        destination: destination,
        travel_mode: travel_mode
      )

      return result unless result[:success]

      journey = result[:journey]

      # Board remaining travelers
      boarding_failures = []
      travelers[1..].each do |traveler|
        board_result = WorldTravelService.board_journey(traveler, journey)
        next if board_result[:success]

        name = traveler.character&.full_name || traveler.full_name || "Traveler ##{traveler.id}"
        boarding_failures << { name: name, error: board_result[:error] || 'Unknown boarding error' }
      end

      if boarding_failures.any?
        begin
          journey.cancel!(reason: 'Party boarding failed')
        rescue StandardError => e
          warn "[JourneyService] Failed to cancel journey after boarding errors: #{e.message}"
        end

        failure_lines = boarding_failures.map { |f| "#{f[:name]} (#{f[:error]})" }
        return {
          success: false,
          error: "Party launch failed. Could not board: #{failure_lines.join(', ')}."
        }
      end

      {
        success: true,
        journey: journey,
        message: "Your party of #{travelers.count} begins the journey to #{destination.name}.",
        traveler_count: travelers.count,
        destination: destination.name,
        eta: journey.time_remaining_display
      }
    end

    # Start a basic flashback party journey that reduces travel duration
    def start_reduced_basic_party_journey(travelers, destination, journey_seconds:, remaining_time_seconds:)
      return { success: false, error: 'Cannot calculate reduced journey time.' } if remaining_time_seconds.nil? || remaining_time_seconds <= 0

      result = start_standard_party_journey(travelers, destination, nil)
      return result unless result[:success]

      journey = result[:journey]
      return result unless journey

      begin
        speed_boost = journey_seconds.to_f / remaining_time_seconds
        journey.update(speed_modifier: (journey.speed_modifier || 1.0) * speed_boost)
        journey.update(estimated_arrival_at: Time.now + remaining_time_seconds)
      rescue StandardError => e
        warn "[JourneyService] Reduced party journey timing update failed: #{e.message}"
        begin
          journey.cancel!(reason: 'Reduced party journey timing failed')
        rescue StandardError => cancel_error
          warn "[JourneyService] Failed to cancel reduced party journey: #{cancel_error.message}"
        end

        return { success: false, error: 'Party journey timing failed. No one has departed.' }
      end

      time_saved = [journey_seconds - remaining_time_seconds, 0].max

      {
        success: true,
        journey: journey,
        message: "Using flashback time, your party saves #{FlashbackTimeService.format_time(time_saved)}. Journey to #{destination.name} will take #{FlashbackTimeService.format_time(remaining_time_seconds)}.",
        traveler_count: travelers.count,
        destination: destination.name,
        eta: journey.time_remaining_display
      }
    end
  end
end
