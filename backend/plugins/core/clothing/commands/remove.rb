# frozen_string_literal: true

module Commands
  module Clothing
    class Remove < Commands::Base::Command
      command_name 'remove'
      aliases 'doff', 'take off', 'tear off', 'rip off'
      category :clothing
      help_text 'Take off worn clothing or jewelry'
      usage 'remove <item> [, item2, item3...]'
      examples 'remove shirt', 'remove gold ring', 'take off jacket', 'remove hat, scarf, gloves', 'remove hat and scarf'

      protected

      def perform_command(parsed_input)
        standard_item_command(
          input: parsed_input[:text],
          items_getter: -> { character_instance.worn_items.all },
          action_method: :remove!,
          action_name: 'remove',
          menu_prompt: 'What would you like to remove?',
          self_verb: 'remove',
          other_verb: 'removes',
          empty_error: "You're not wearing anything.",
          not_found_error: "You're not wearing '%{input}'.",
          description_field: ->(item) { item.jewelry? ? 'jewelry' : 'clothing' },
          allow_multiple: true
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Remove)
