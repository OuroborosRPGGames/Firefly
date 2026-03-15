# frozen_string_literal: true

module Commands
  module Staff
    class CheckAllOff < ::Commands::Base::Command
      command_name 'checkalloff'
      aliases 'abusecheckoff', 'moderatealloff'
      category :staff
      help_text 'Cancel the abuse monitoring override (staff only)'
      usage 'checkalloff'
      examples 'checkalloff'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        # Check if override is active
        unless AbuseMonitoringService.override_active?
          return error_result('No abuse monitoring override is currently active.')
        end

        override = AbuseMonitoringOverride.current
        original_activator = override.triggered_by_user&.username || 'Unknown'

        # Deactivate the override
        override.deactivate!

        # Notify all staff
        StaffAlertService.broadcast_to_staff(
          "#{character.full_name} cancelled the abuse monitoring override " \
          "(originally activated by #{original_activator}).",
          category: :moderation
        )

        success_result(
          "Abuse monitoring override cancelled.\n" \
          "Players with 100+ hours playtime are now exempt again.\n" \
          "Staff have been notified.",
          type: :status,
          data: {
            action: 'abuse_override_cancelled'
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::CheckAllOff)
