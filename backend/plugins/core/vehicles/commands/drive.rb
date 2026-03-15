# frozen_string_literal: true

require_relative '../concerns/vehicle_commands_concern'

module Commands
  module Vehicles
    class Drive < Commands::Base::Command
      include VehicleCommandsConcern

      command_name 'drive'
      aliases 'drive to'
      category :navigation
      help_text 'Drive your vehicle to a destination'
      usage 'drive to <destination>'
      examples 'drive to market', 'drive to 5th and oak', 'drive home'

      requires :not_in_combat, message: "You can't drive while in combat!"

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]&.strip
        target = target.sub(/^to\s+/i, '') if target

        if target.nil? || target.empty?
          return error_result('Where do you want to drive?')
        end

        # Find vehicle in current room owned by character
        vehicle = find_vehicle_here

        unless vehicle
          return error_result(no_vehicle_message)
        end

        # Resolve destination
        destination = resolve_destination(target)

        unless destination
          return error_result("You don't know where '#{target}' is.")
        end

        # Start the journey
        result = VehicleTravelService.start_journey(
          character_instance,
          destination: destination,
          vehicle: vehicle
        )

        if result[:success]
          success_result(result[:message], data: result[:data])
        else
          error_result(result[:message])
        end
      end

      private

      def find_vehicle_here
        char = character_instance.character
        room = character_instance.current_room

        # Check if already in a vehicle
        if character_instance.current_vehicle_id
          return Vehicle[character_instance.current_vehicle_id]
        end

        # Find owned vehicle in this room
        Vehicle.where(owner_id: char.id, current_room_id: room.id, status: 'parked').first
      end

      def no_vehicle_message
        char = character_instance.character
        vehicles = Vehicle.where(owner_id: char.id).all

        if vehicles.empty?
          "You don't have a vehicle to drive."
        else
          nearest = vehicles.first
          location_name = nearest.current_room&.name || 'somewhere'
          "Your #{nearest.name} is not here. It's parked at #{location_name}."
        end
      end

      def resolve_destination(target)
        # Use the target resolver for movement targets
        result = TargetResolverService.resolve_movement_target(target, character_instance)

        case result.type
        when :room
          result.target
        when :exit
          result.exit.to_room
        else
          nil
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Vehicles::Drive)
