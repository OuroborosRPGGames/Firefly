# frozen_string_literal: true

module Commands
  module Economy
    class BuyVehicle < Commands::Base::Command
      command_name 'buy vehicle'
      aliases 'buyvehicle', 'purchase vehicle'
      category :economy
      help_text 'Purchase a vehicle (requires web interface)'
      usage 'buy vehicle'
      examples 'buy vehicle'

      protected

      def perform_command(_parsed_input)
        web_interface_required_result(
          'buy_vehicle',
          "Vehicle purchases require the web interface. Visit the vehicle dealership page to " \
          "configure and purchase your vehicle."
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::BuyVehicle)
