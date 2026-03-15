# frozen_string_literal: true

module Commands
  module Economy
    class BuyShop < Commands::Base::Command
      command_name 'buy shop'
      aliases 'buyshop', 'purchase shop'
      category :economy
      help_text 'Purchase a shop (requires web interface)'
      usage 'buy shop'
      examples 'buy shop'

      protected

      def perform_command(_parsed_input)
        web_interface_required_result(
          'buy_shop',
          "Shop purchases require the web interface. Visit the commercial real estate page to " \
          "browse available shop locations and complete your purchase."
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::BuyShop)
