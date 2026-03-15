# frozen_string_literal: true

# ConnectionLog tracks all login and connection attempts
#
# Stores IP addresses, user agents, and outcomes for security auditing.
# Used by staff to investigate suspicious activity and identify ban-evading users.
#
# Connection types:
#   - web_login: Browser-based login
#   - api_auth: API token authentication
#   - websocket: WebSocket connection
#
# Outcomes:
#   - success: Connection allowed
#   - banned_ip: Blocked due to IP ban
#   - suspended: Blocked due to account suspension
#   - invalid_credentials: Wrong username/password
#   - expired_session: Session expired
#
class ConnectionLog < Sequel::Model
  many_to_one :user

  CONNECTION_TYPES = %w[web_login api_auth websocket].freeze
  OUTCOMES = %w[success banned_ip suspended invalid_credentials expired_session].freeze

  # Log a connection attempt
  #
  # @param user_id [Integer, nil] User ID (nil for failed logins with unknown user)
  # @param ip_address [String] The connecting IP address
  # @param connection_type [String] Type of connection (web_login, api_auth, websocket)
  # @param outcome [String] Result of the connection attempt
  # @param user_agent [String, nil] Browser/client user agent
  # @param failure_reason [String, nil] Reason for failure (if applicable)
  # @return [ConnectionLog]
  def self.log_connection(user_id:, ip_address:, connection_type:, outcome:, user_agent: nil, failure_reason: nil)
    create(
      user_id: user_id,
      ip_address: ip_address.to_s,
      connection_type: connection_type.to_s,
      outcome: outcome.to_s,
      user_agent: user_agent&.to_s&.slice(0, 500),
      failure_reason: failure_reason
    )
  rescue Sequel::Error => e
    warn "[ConnectionLog] Failed to log connection: #{e.message}"
    nil
  end

  # Get recent connections for a user
  #
  # @param user_id [Integer]
  # @param limit [Integer]
  # @return [Array<ConnectionLog>]
  def self.recent_for_user(user_id, limit: 50)
    where(user_id: user_id)
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .all
  end

  # Get recent connections from an IP address
  #
  # @param ip_address [String]
  # @param limit [Integer]
  # @return [Array<ConnectionLog>]
  def self.recent_for_ip(ip_address, limit: 50)
    where(ip_address: ip_address)
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .all
  end

  # Get all unique IPs a user has connected from
  #
  # @param user_id [Integer]
  # @return [Array<String>]
  def self.unique_ips_for_user(user_id)
    where(user_id: user_id, outcome: 'success')
      .select(:ip_address)
      .distinct
      .map(:ip_address)
  end

  # Find users who have connected from an IP
  #
  # @param ip_address [String]
  # @return [Array<User>]
  def self.users_from_ip(ip_address)
    user_ids = where(ip_address: ip_address, outcome: 'success')
                 .select(:user_id)
                 .distinct
                 .map(:user_id)
                 .compact

    User.where(id: user_ids).all
  end

  # Get recent failed login attempts (for detecting brute force)
  #
  # @param ip_address [String]
  # @param minutes [Integer] Lookback window
  # @return [Integer] Count of failed attempts
  def self.recent_failed_attempts(ip_address, minutes: 15)
    cutoff = Time.now - (minutes * 60)
    where(ip_address: ip_address)
      .where(outcome: 'invalid_credentials')
      .where { created_at > cutoff }
      .count
  end

  # Cleanup old logs
  #
  # @param days [Integer] Delete logs older than this many days
  # @return [Integer] Number of deleted records
  def self.cleanup_old_logs!(days: 90)
    cutoff = Time.now - (days * 86400)
    where { created_at < cutoff }.delete
  end

  # Format for admin display
  #
  # @return [Hash]
  def to_admin_hash
    {
      id: id,
      user_id: user_id,
      username: user&.username,
      ip_address: ip_address,
      user_agent: user_agent,
      connection_type: connection_type,
      outcome: outcome,
      failure_reason: failure_reason,
      created_at: created_at&.iso8601
    }
  end
end
