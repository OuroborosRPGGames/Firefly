# frozen_string_literal: true

module Commands
  module Staff
    class CheckAll < ::Commands::Base::Command
      command_name 'checkall'
      aliases 'abusecheck', 'moderateall', 'abusescan'
      category :staff
      help_text 'Activate abuse monitoring for ALL players, bypassing playtime exemption (staff only)'
      usage 'checkall [duration_hours] [reason]'
      examples 'checkall', 'checkall 2', 'checkall 4 Suspected coordinated abuse'

      protected

      def perform_command(parsed_input)
        error = require_staff
        return error if error

        text = parsed_input[:text]

        # Parse optional duration and reason
        duration_hours = 1
        reason = nil

        if text && !text.strip.empty?
          parts = text.strip.split(/\s+/, 2)
          first_part = parts[0]

          # Check if first part is a number (duration)
          if first_part =~ /^\d+$/
            duration_hours = first_part.to_i
            duration_hours = 1 if duration_hours < 1
            duration_hours = 24 if duration_hours > 24
            reason = parts[1]
          else
            # No duration specified, entire text is reason
            reason = text.strip
          end
        end

        # Check if override is already active
        if AbuseMonitoringService.override_active?
          current = AbuseMonitoringOverride.current
          return error_result(
            "Abuse monitoring override is already active.\n" \
            "Activated by: #{current.triggered_by_user&.username || 'Unknown'}\n" \
            "Expires: #{current.active_until&.strftime('%Y-%m-%d %H:%M') || 'Unknown'}"
          )
        end

        # Activate the override
        override = AbuseMonitoringService.activate_override!(
          staff_user: character.user,
          reason: reason || "Activated via checkall command by #{character.full_name}",
          duration_hours: duration_hours
        )

        # Notify all staff
        StaffAlertService.broadcast_to_staff(
          "#{character.full_name} activated abuse monitoring override for #{duration_hours} hour(s). " \
          "Reason: #{reason || 'Not specified'}",
          category: :moderation
        )

        success_result(
          "Abuse monitoring override activated for #{duration_hours} hour(s).\n" \
          "All players will be monitored regardless of playtime.\n" \
          "Staff have been notified.\n" \
          "Use 'checkalloff' to cancel early.",
          type: :status,
          data: {
            action: 'abuse_override_activated',
            duration_hours: duration_hours,
            reason: reason,
            expires_at: override.active_until&.iso8601
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Staff::CheckAll)
