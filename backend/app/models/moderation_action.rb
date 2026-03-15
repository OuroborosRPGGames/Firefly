# frozen_string_literal: true

# ModerationAction tracks all moderation actions taken against users.
#
# Used to audit auto-moderation actions and support reversal workflows.
# Links to AbuseCheck records for actions triggered by abuse detection.
#
# Examples:
#   action = ModerationAction.create_ip_ban(
#     user: user,
#     ip_address: "192.168.1.1",
#     reason: "Confirmed harassment",
#     duration_seconds: 90.days.to_i,
#     abuse_check: check
#   )
#   action.reverse!(by_user: staff, reason: "False positive")
#
class ModerationAction < Sequel::Model
  plugin :timestamps

  many_to_one :user
  many_to_one :abuse_check
  many_to_one :triggered_by_user, class: :User, key: :triggered_by_user_id
  many_to_one :reversed_by_user, class: :User, key: :reversed_by_user_id

  ACTION_TYPES = %w[ip_ban range_ban suspend logout registration_freeze warn].freeze
  TRIGGER_TYPES = %w[auto_moderation staff system].freeze

  # Create an IP ban action
  #
  # @param user [User] The target user
  # @param ip_address [String] The IP to ban
  # @param reason [String] Reason for the ban
  # @param duration_seconds [Integer] Duration in seconds
  # @param abuse_check [AbuseCheck, nil] Linked abuse check
  # @param triggered_by [String] Who triggered it
  # @param triggered_by_user [User, nil] Staff member if applicable
  # @return [ModerationAction]
  def self.create_ip_ban(user:, ip_address:, reason:, duration_seconds:, abuse_check: nil,
                         triggered_by: 'auto_moderation', triggered_by_user: nil)
    expires_at = duration_seconds ? Time.now + duration_seconds : nil

    create(
      user_id: user.id,
      abuse_check_id: abuse_check&.id,
      action_type: 'ip_ban',
      ip_address: ip_address,
      reason: reason,
      expires_at: expires_at,
      duration_seconds: duration_seconds,
      triggered_by: triggered_by,
      triggered_by_user_id: triggered_by_user&.id
    )
  end

  # Create an IP range ban action
  #
  # @param user [User] The target user
  # @param ip_range [String] The IP range (CIDR notation)
  # @param reason [String] Reason for the ban
  # @param duration_seconds [Integer] Duration in seconds
  # @param abuse_check [AbuseCheck, nil] Linked abuse check
  # @return [ModerationAction]
  def self.create_range_ban(user:, ip_range:, reason:, duration_seconds:, abuse_check: nil)
    expires_at = duration_seconds ? Time.now + duration_seconds : nil

    create(
      user_id: user.id,
      abuse_check_id: abuse_check&.id,
      action_type: 'range_ban',
      ip_range: ip_range,
      reason: reason,
      expires_at: expires_at,
      duration_seconds: duration_seconds,
      triggered_by: 'auto_moderation'
    )
  end

  # Create a user suspension action
  #
  # @param user [User] The target user
  # @param reason [String] Reason for suspension
  # @param abuse_check [AbuseCheck, nil] Linked abuse check
  # @return [ModerationAction]
  def self.create_suspension(user:, reason:, abuse_check: nil)
    create(
      user_id: user.id,
      abuse_check_id: abuse_check&.id,
      action_type: 'suspend',
      reason: reason,
      triggered_by: 'auto_moderation'
    )
  end

  # Create a logout action
  #
  # @param user [User] The target user
  # @param reason [String] Reason for logout
  # @param abuse_check [AbuseCheck, nil] Linked abuse check
  # @return [ModerationAction]
  def self.create_logout(user:, reason:, abuse_check: nil)
    create(
      user_id: user.id,
      abuse_check_id: abuse_check&.id,
      action_type: 'logout',
      reason: reason,
      triggered_by: 'auto_moderation'
    )
  end

  # Create a registration freeze action
  #
  # @param reason [String] Reason for freeze
  # @param duration_seconds [Integer] Duration in seconds
  # @param abuse_check [AbuseCheck, nil] Linked abuse check
  # @return [ModerationAction]
  def self.create_registration_freeze(reason:, duration_seconds:, abuse_check: nil)
    expires_at = Time.now + duration_seconds

    create(
      abuse_check_id: abuse_check&.id,
      action_type: 'registration_freeze',
      reason: reason,
      expires_at: expires_at,
      duration_seconds: duration_seconds,
      triggered_by: 'auto_moderation'
    )
  end

  # Get recent actions for a user
  #
  # @param user_id [Integer]
  # @param limit [Integer]
  # @return [Array<ModerationAction>]
  def self.recent_for_user(user_id, limit: 50)
    where(user_id: user_id)
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .all
  end

  # Get recent auto-moderation actions
  #
  # @param limit [Integer]
  # @return [Array<ModerationAction>]
  def self.recent_auto_actions(limit: 50)
    where(triggered_by: 'auto_moderation')
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .all
  end

  # Reverse this action
  #
  # @param by_user [User] Staff member reversing
  # @param reason [String] Reason for reversal
  # @return [self]
  def reverse!(by_user:, reason:)
    update(
      reversed: true,
      reversed_at: Time.now,
      reversed_by_user_id: by_user.id,
      reversal_reason: reason
    )
    self
  end

  # Check if this action is still active (not reversed, not expired)
  #
  # @return [Boolean]
  def active?
    return false if reversed

    expires_at.nil? || expires_at > Time.now
  end

  # Check if this action has expired
  #
  # @return [Boolean]
  def expired?
    !expires_at.nil? && expires_at < Time.now
  end

  # Format for admin display
  #
  # @return [Hash]
  def to_admin_hash
    {
      id: id,
      user_id: user_id,
      abuse_check_id: abuse_check_id,
      action_type: action_type,
      reason: reason,
      ip_address: ip_address,
      ip_range: ip_range,
      expires_at: expires_at&.iso8601,
      duration_seconds: duration_seconds,
      triggered_by: triggered_by,
      triggered_by_user: triggered_by_user&.username,
      reversed: reversed,
      reversed_at: reversed_at&.iso8601,
      reversed_by: reversed_by_user&.username,
      reversal_reason: reversal_reason,
      active: active?,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end
end
