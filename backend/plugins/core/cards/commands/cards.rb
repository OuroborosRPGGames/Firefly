# frozen_string_literal: true

module Commands
  module Cards
    class Cards < Commands::Base::Command
      command_name 'cards'
      aliases 'card', 'cardgame', 'cardmenu'
      category :entertainment
      help_text 'Open the card game menu to play cards'
      usage 'cards'
      examples 'cards', 'card', 'cardgame'

      protected

      def perform_command(_parsed_input)
        # Show the cards quickmenu
        menu_result = CardsQuickmenuHandler.show_menu(character_instance)

        unless menu_result
          return error_result('Unable to show card menu.')
        end

        # Generate interaction ID and store the menu as a pending interaction
        interaction_id = SecureRandom.uuid
        menu_data = {
          type: 'quickmenu',
          interaction_id: interaction_id,
          prompt: menu_result[:prompt],
          options: menu_result[:options],
          context: menu_result[:context] || {},
          created_at: Time.now.iso8601
        }

        OutputHelper.store_agent_interaction(character_instance, interaction_id, menu_data)

        # Return the quickmenu for display
        {
          success: true,
          type: :quickmenu,
          display_type: :quickmenu,
          message_type: 'quickmenu',
          prompt: menu_result[:prompt],
          options: menu_result[:options],
          interaction_id: interaction_id,
          context: menu_result[:context],
          data: {
            interaction_id: interaction_id,
            prompt: menu_result[:prompt],
            options: menu_result[:options],
            context: menu_result[:context]
          },
          target_panel: Firefly::Panels::POPOUT_FORM,
          timestamp: Time.now,
          status_bar: build_status_bar,
          character_id: character_instance.character_id,
          output_category: self.class.output_category,
          message: 'Card game options:'
        }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Cards::Cards)
