# frozen_string_literal: true

module Commands
  module Customization
    class Describe < Commands::Base::Command
      command_name 'describe'
      aliases 'desc', 'descriptions', 'customize'
      category :customization
      help_text 'Open the description editor to manage your character appearance'
      usage 'describe, customize'
      examples 'describe', 'desc', 'customize'

      protected

      def perform_command(_parsed_input)
        success_result(
          'Opening description editor...',
          type: :open_gui,
          data: { gui: 'descriptions', character_id: character.id }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Customization::Describe)
