# frozen_string_literal: true

require_relative '../../../../app/helpers/lead_follow_helper'

module Commands
  module Navigation
    class Follow < Commands::Base::Command
      include LeadFollowHelper
      command_name 'follow'
      category :navigation
      help_text 'Follow another character as they move'
      usage 'follow <character>'
      examples 'follow John', 'follow the tall man'

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]

        error = require_input(target_name, 'Who do you want to follow?')
        return error if error

        # Find the character to follow with disambiguation
        result = resolve_character_with_menu(target_name)

        # If disambiguation needed, return the quickmenu
        if result[:disambiguation]
          return disambiguation_result(result[:result], "Who do you want to follow?")
        end

        # If error (no match found)
        return error_result(result[:error] || "You don't see '#{target_name}' here.") if result[:error]

        target = result[:match]

        # Check lead/follow permission
        error = check_lead_follow_permission(target)
        return error if error

        movement_result = MovementService.start_following(character_instance, target)

        if movement_result.success
          success_result(movement_result.message, following: target.character.full_name)
        else
          error_result(movement_result.message)
        end
      end

      private

    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Follow)
