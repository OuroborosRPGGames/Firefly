# frozen_string_literal: true

# AccessControlService - Central enforcement point for IP bans and account suspensions
#
# Call this service at all authentication points (login, API auth, WebSocket)
# to ensure banned IPs and suspended users are blocked consistently.
#
# Usage:
#   access = AccessControlService.check_access(
#     user: user,
#     ip_address: request.ip,
#     connection_type: 'web_login',
#     user_agent: request.user_agent
#   )
#   unless access[:allowed]
#     halt 403, { error: access[:reason] }.to_json
#   end
#
class AccessControlService
  class << self
    # Main access check - call at all auth points
    #
    # @param user [User, nil] The user attempting access (nil if not yet identified)
    # @param ip_address [String] The connecting IP address
    # @param connection_type [String] Type: 'web_login', 'api_auth', 'websocket'
    # @param user_agent [String, nil] Browser/client user agent
    # @return [Hash] { allowed: Boolean, reason: String?, ban: IpBan? }
    def check_access(user:, ip_address:, connection_type:, user_agent: nil)
      # 1. Check IP ban first (before even looking at user)
      ip_ban = IpBan.find_matching_ban(ip_address)
      if ip_ban
        log_blocked_connection(
          user_id: user&.id,
          ip_address: ip_address,
          connection_type: connection_type,
          outcome: 'banned_ip',
          user_agent: user_agent,
          reason: "IP banned: #{ip_ban.reason}"
        )

        return {
          allowed: false,
          reason: format_ip_ban_message(ip_ban),
          ban: ip_ban
        }
      end

      # 2. Check user suspension
      if user&.suspended?
        log_blocked_connection(
          user_id: user.id,
          ip_address: ip_address,
          connection_type: connection_type,
          outcome: 'suspended',
          user_agent: user_agent,
          reason: user.suspension_reason
        )

        return {
          allowed: false,
          reason: format_suspension_message(user)
        }
      end

      # 3. Log successful connection
      log_successful_connection(
        user_id: user&.id,
        ip_address: ip_address,
        connection_type: connection_type,
        user_agent: user_agent
      )

      { allowed: true }
    end

    # Quick check if an IP is banned (for pre-auth filtering)
    #
    # @param ip_address [String]
    # @return [Boolean]
    def ip_banned?(ip_address)
      IpBan.banned?(ip_address)
    end

    # Log a failed login attempt (wrong credentials)
    #
    # @param username_or_email [String] What the user tried to login with
    # @param ip_address [String]
    # @param user_agent [String, nil]
    def log_failed_login(username_or_email:, ip_address:, user_agent: nil)
      # Try to find user for logging purposes
      user = User.where(
        Sequel.ilike(:username, username_or_email) |
        Sequel.ilike(:email, username_or_email)
      ).first

      ConnectionLog.log_connection(
        user_id: user&.id,
        ip_address: ip_address,
        connection_type: 'web_login',
        outcome: 'invalid_credentials',
        user_agent: user_agent,
        failure_reason: "Invalid credentials for: #{username_or_email}"
      )
    end

    # Check for brute force attempts from an IP
    # Returns true if too many failed attempts
    #
    # @param ip_address [String]
    # @param threshold [Integer] Max failed attempts
    # @param window_minutes [Integer] Time window
    # @return [Boolean]
    def brute_force_detected?(ip_address, threshold: 10, window_minutes: 15)
      count = ConnectionLog.recent_failed_attempts(ip_address, minutes: window_minutes)
      count >= threshold
    end

    private

    def log_successful_connection(user_id:, ip_address:, connection_type:, user_agent:)
      ConnectionLog.log_connection(
        user_id: user_id,
        ip_address: ip_address,
        connection_type: connection_type,
        outcome: 'success',
        user_agent: user_agent
      )
    end

    def log_blocked_connection(user_id:, ip_address:, connection_type:, outcome:, user_agent:, reason:)
      ConnectionLog.log_connection(
        user_id: user_id,
        ip_address: ip_address,
        connection_type: connection_type,
        outcome: outcome,
        user_agent: user_agent,
        failure_reason: reason
      )
    end

    def format_ip_ban_message(ip_ban)
      msg = "This IP address has been banned."
      msg += " Reason: #{ip_ban.reason}" if ip_ban.reason && !ip_ban.reason.empty?

      if ip_ban.expires_at
        remaining = ip_ban.expires_at - Time.now
        if remaining > 86400
          days = (remaining / 86400).ceil
          msg += " Ban expires in #{days} day#{'s' if days != 1}."
        elsif remaining > 3600
          hours = (remaining / 3600).ceil
          msg += " Ban expires in #{hours} hour#{'s' if hours != 1}."
        else
          minutes = (remaining / 60).ceil
          msg += " Ban expires in #{minutes} minute#{'s' if minutes != 1}."
        end
      end

      msg
    end

    def format_suspension_message(user)
      msg = "Your account has been suspended."
      msg += " Reason: #{user.suspension_reason}" if user.suspension_reason && !user.suspension_reason.empty?

      if user.suspended_until
        remaining = user.suspension_remaining
        if remaining && remaining > 0
          if remaining > 86400
            days = (remaining / 86400).ceil
            msg += " Suspension ends in #{days} day#{'s' if days != 1}."
          elsif remaining > 3600
            hours = (remaining / 3600).ceil
            msg += " Suspension ends in #{hours} hour#{'s' if hours != 1}."
          else
            minutes = (remaining / 60).ceil
            msg += " Suspension ends in #{minutes} minute#{'s' if minutes != 1}."
          end
        end
      else
        msg += " This is a permanent suspension."
      end

      msg
    end
  end
end
