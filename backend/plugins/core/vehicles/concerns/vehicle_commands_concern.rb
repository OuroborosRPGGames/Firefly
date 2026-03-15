# frozen_string_literal: true

module Commands
  module Vehicles
    # Shared helpers for vehicle commands
    # Include this in any command that needs to work with vehicles
    module VehicleCommandsConcern
      # Find the vehicle the character is currently in
      # @return [Vehicle, nil] The current vehicle or nil if not in one
      def find_current_vehicle
        character_instance.current_vehicle
      end

      # Broadcast a message to all occupants of a vehicle (except self)
      # Messages are personalized for each viewer
      # @param vehicle [Vehicle] The vehicle to broadcast to
      # @param message [String] The message to send
      # @param type [Symbol] Message type (:action, :speech, etc.)
      def broadcast_to_vehicle(vehicle, message, type: :action)
        # Use passengers_dataset for eager loading - passengers method returns array
        occupants = vehicle.passengers_dataset.eager(:character).all
        occupants.each do |occupant|
          next if occupant.id == character_instance.id

          personalized = MessagePersonalizationService.personalize(
            message: message,
            viewer: occupant,
            room_characters: occupants
          )
          BroadcastService.to_character(occupant, personalized, type: type)
        end
      end

      # Check if character is in a vehicle
      # @return [Boolean] true if in a vehicle
      def in_vehicle?
        !character_instance.current_vehicle.nil?
      end

      # Check if character is the driver of their current vehicle
      # @return [Boolean] true if character is driving
      def is_driver?
        vehicle = find_current_vehicle
        return false unless vehicle

        vehicle.driver_id == character_instance.id
      end

      # Get all occupants of the current vehicle
      # @return [Array<CharacterInstance>] List of occupants
      def vehicle_occupants
        vehicle = find_current_vehicle
        return [] unless vehicle

        # Use passengers_dataset for eager loading - passengers method returns array
        vehicle.passengers_dataset.eager(:character).all
      end
    end
  end
end
