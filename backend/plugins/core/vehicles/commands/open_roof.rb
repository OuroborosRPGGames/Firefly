# frozen_string_literal: true

require_relative '../concerns/vehicle_commands_concern'

module Commands
  module Vehicles
    class OpenRoof < Commands::Base::Command
      include VehicleCommandsConcern

      command_name 'open roof'
      aliases 'roof open'
      category :navigation
      help_text 'Open the convertible roof of your vehicle'
      usage 'open roof'
      examples 'open roof'

      protected

      def perform_command(_parsed_input)
        # Find current vehicle
        vehicle = find_current_vehicle
        unless vehicle
          return error_result("You're not in a vehicle.")
        end

        # Check if convertible
        unless vehicle.convertible?
          return error_result("This vehicle doesn't have a convertible roof.")
        end

        # Check if already open
        if vehicle.roof_open?
          return error_result("The roof is already open.")
        end

        # Open the roof
        vehicle.open_roof!

        # Broadcast to vehicle occupants
        broadcast_to_vehicle(vehicle, "#{character.full_name} opens the roof.")

        success_result(
          'You open the roof.',
          type: :action,
          data: {
            action: 'open_roof',
            vehicle_id: vehicle.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Vehicles::OpenRoof)
