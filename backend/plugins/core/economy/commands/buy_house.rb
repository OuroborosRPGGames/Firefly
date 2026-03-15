# frozen_string_literal: true

module Commands
  module Economy
    class BuyHouse < Commands::Base::Command
      command_name 'buy house'
      aliases 'buyhouse', 'purchase house'
      category :economy
      help_text 'Purchase a house (requires web interface)'
      usage 'buy house'
      examples 'buy house'

      protected

      def perform_command(_parsed_input)
        web_interface_required_result(
          'buy_house',
          "House purchases require the web interface. Visit the real estate page to " \
          "browse available properties and complete your purchase."
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::BuyHouse)
