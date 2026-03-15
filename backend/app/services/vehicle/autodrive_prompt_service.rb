# frozen_string_literal: true

require_relative '../../lib/time_format_helper'

# AutodrivePromptService determines when to offer vehicle travel options
# and builds the quickmenu choices for the navigation system.
#
# This service is called by navigation commands (like 'go' or 'walk') to
# determine if the user should be prompted with travel options before
# walking a long distance.
#
# Usage:
#   if AutodrivePromptService.should_prompt?(character_instance, destination)
#     options = AutodrivePromptService.build_options(character_instance, destination)
#     # Present quickmenu with options
#   end
#
class AutodrivePromptService
  extend ResultHandler
  extend TimeFormatHelper


  class << self
    # Determine if we should prompt the user with travel options.
    #
    # Returns true if:
    # - Character has a vehicle parked in the current room, OR
    # - Distance exceeds threshold AND (taxi is available OR character owns a vehicle)
    #
    # @param character_instance [CharacterInstance] the traveler
    # @param destination [Room] the destination room
    # @return [Boolean] whether to prompt for travel options
    def should_prompt?(character_instance, destination)
      # Always prompt if vehicle is right here
      return true if vehicle_here?(character_instance)

      # Check if any transportation is available
      return false unless TaxiService.available? || has_vehicle?(character_instance)

      # Calculate distance and check threshold
      distance = VehicleTravelService.calculate_route_distance(
        character_instance.current_room,
        destination
      )

      distance >= GameConfig::Navigation::AUTODRIVE_THRESHOLD_FEET
    end

    # Build the quickmenu options for travel choices.
    #
    # Options may include:
    # - Drive (if vehicle is in current room)
    # - Taxi (if taxi service available)
    # - Walk (always available)
    #
    # @param character_instance [CharacterInstance] the traveler
    # @param destination [Room] the destination room
    # @return [Array<Hash>] list of option hashes with :key, :action, :label, :description
    def build_options(character_instance, destination)
      options = []
      from_room = character_instance.current_room
      character = character_instance.character

      # Calculate distances and times
      distance = VehicleTravelService.calculate_route_distance(from_room, destination)
      walk_time = format_duration(VehicleTravelService.estimate_walking_time(distance), style: :abbreviated)
      drive_time = format_duration(VehicleTravelService.estimate_travel_time(distance), style: :abbreviated)

      # Check for vehicle in current room
      vehicle_here = find_vehicle_here(character, from_room)

      if vehicle_here
        options << {
          key: 'drive',
          action: 'drive',
          label: "Drive your #{vehicle_here.name} (~#{drive_time})",
          description: 'Take your vehicle'
        }
      end

      # Check for taxi
      if TaxiService.available?
        fare = estimate_fare(from_room, destination)
        options << {
          key: 'taxi',
          action: 'taxi',
          label: "Hail a #{TaxiService.taxi_name} (#{fare}, ~#{drive_time})",
          description: 'Rideshare service'
        }
      end

      # Always include walk option
      options << {
        key: 'walk',
        action: 'walk',
        label: "Walk (~#{walk_time})",
        description: 'Go on foot'
      }

      # Add reminder about parked vehicles
      add_vehicle_reminder(options, vehicle_here)

      options
    end

    private

    # Check if character has a vehicle parked in the current room.
    #
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def vehicle_here?(character_instance)
      character = character_instance.character
      room = character_instance.current_room

      Vehicle.where(owner_id: character.id, current_room_id: room.id, status: 'parked').any?
    end

    # Find vehicle parked in current room (for building options).
    #
    # @param character [Character]
    # @param room [Room]
    # @return [Vehicle, nil]
    def find_vehicle_here(character, room)
      Vehicle.where(owner_id: character.id, current_room_id: room.id, status: 'parked').first
    end

    # Check if character owns any vehicle.
    #
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def has_vehicle?(character_instance)
      character = character_instance.character
      Vehicle.where(owner_id: character.id).any?
    end

    # Estimate taxi fare for display.
    #
    # @param from_room [Room]
    # @param to_room [Room]
    # @return [String] formatted fare string
    def estimate_fare(from_room, to_room)
      # TaxiService.calculate_fare is private, so we estimate based on distance
      distance = VehicleTravelService.calculate_route_distance(from_room, to_room)
      base_fare = 5
      per_1000_feet = 2
      estimated = base_fare + ((distance / 1000.0) * per_1000_feet).round

      EraService.format_currency(estimated)
    rescue StandardError => e
      warn "[AutodrivePromptService] Fare estimation failed: #{e.message}"
      '$??'
    end

    # Add reminder notes to non-drive options about parked vehicle.
    #
    # @param options [Array<Hash>] the options array to modify
    # @param vehicle [Vehicle, nil] the vehicle parked here (if any)
    def add_vehicle_reminder(options, vehicle)
      return unless vehicle

      options.each do |opt|
        next if opt[:action] == 'drive'

        opt[:note] = "Your #{vehicle.name} will remain parked here."
      end
    end
  end
end
