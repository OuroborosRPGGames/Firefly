# frozen_string_literal: true

module Commands
  module Clothing
    class Strip < Commands::Base::Command
      command_name 'strip'
      aliases 'undress'
      category :clothing
      help_text 'Remove all worn clothing'
      usage 'strip all | strip naked'
      examples 'strip all', 'strip naked', 'undress all'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        target = target&.strip&.downcase || ''

        # Require explicit "all" or "naked" to prevent accidents
        unless %w[all naked].include?(target)
          return error_result("Usage: strip all - Remove all worn clothing")
        end

        items = character_instance.worn_items.all
        return error_result("You aren't wearing anything.") if items.empty?

        names = items.map(&:name)
        items.each(&:remove!)

        broadcast_to_room(
          "#{character.full_name} strips off all their clothing.",
          exclude_character: character_instance
        )

        success_result(
          "You strip off #{names.join(', ')}.",
          type: :message,
          data: { action: 'strip', items: names }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Strip)
