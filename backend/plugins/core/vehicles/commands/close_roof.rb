# frozen_string_literal: true

require_relative '../concerns/vehicle_commands_concern'

module Commands
  module Vehicles
    class CloseRoof < Commands::Base::Command
      include VehicleCommandsConcern

      command_name 'close roof'
      aliases 'roof close'
      category :navigation
      help_text 'Close the convertible roof of your vehicle'
      usage 'close roof'
      examples 'close roof'

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

        # Check if already closed
        if vehicle.roof_closed?
          return error_result("The roof is already closed.")
        end

        # Close the roof
        vehicle.close_roof!

        # Broadcast to vehicle occupants
        broadcast_to_vehicle(vehicle, "#{character.full_name} closes the roof.")

        success_result(
          'You close the roof.',
          type: :action,
          data: {
            action: 'close_roof',
            vehicle_id: vehicle.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Vehicles::CloseRoof)
