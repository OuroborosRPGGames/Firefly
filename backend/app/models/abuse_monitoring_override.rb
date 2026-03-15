# frozen_string_literal: true

# AbuseMonitoringOverride tracks staff-triggered periods of enhanced monitoring.
#
# When a staff member triggers a "check all" override, ALL players are subject
# to abuse monitoring regardless of their playtime exemption status.
#
# Overrides automatically expire after 1 hour (or configured duration).
#
# Examples:
#   override = AbuseMonitoringOverride.activate!(
#     staff_user: staff,
#     reason: "Suspected coordinated harassment"
#   )
#   AbuseMonitoringOverride.active?  # => true
#   # After 1 hour...
#   AbuseMonitoringOverride.active?  # => false
#
class AbuseMonitoringOverride < Sequel::Model
  plugin :timestamps, update: false  # Only created_at, no updated_at

  many_to_one :triggered_by_user, class: :User, key: :triggered_by_user_id

  DEFAULT_DURATION_SECONDS = 3600  # 1 hour

  # Check if any override is currently active
  #
  # @return [Boolean]
  def self.active?
    where(active: true)
      .where { active_until > Time.now }
      .any?
  end

  # Get the current active override (if any)
  #
  # @return [AbuseMonitoringOverride, nil]
  def self.current
    where(active: true)
      .where { active_until > Time.now }
      .order(Sequel.desc(:active_until))
      .first
  end

  # Alias for consistency with route code
  class << self
    alias current_active current
  end

  # Activate a new override
  #
  # @param staff_user [User] The staff member triggering the override
  # @param reason [String, nil] Optional reason
  # @param duration_seconds [Integer] Duration in seconds (default: 1 hour)
  # @return [AbuseMonitoringOverride]
  def self.activate!(staff_user:, reason: nil, duration_seconds: DEFAULT_DURATION_SECONDS)
    create(
      triggered_by_user_id: staff_user.id,
      active_until: Time.now + duration_seconds,
      active: true,
      reason: reason
    )
  end

  # Expire all active overrides (for cleanup)
  #
  # @return [Integer] Number of overrides expired
  def self.expire_all!
    where(active: true)
      .where { active_until < Time.now }
      .update(active: false)
  end

  # Deactivate a specific override manually
  #
  # @return [self]
  def deactivate!
    update(active: false)
    self
  end

  # Get remaining time in seconds
  #
  # @return [Integer, nil] Seconds remaining, or nil if expired/inactive
  def remaining_seconds
    return nil unless active && active_until

    remaining = active_until - Time.now
    remaining > 0 ? remaining.to_i : 0
  end

  # Check if this override has expired
  #
  # @return [Boolean]
  def expired?
    active_until < Time.now
  end

  # Format for admin display
  #
  # @return [Hash]
  def to_admin_hash
    {
      id: id,
      triggered_by: triggered_by_user&.username,
      active_until: active_until&.iso8601,
      active: active,
      expired: expired?,
      remaining_seconds: remaining_seconds,
      reason: reason,
      created_at: created_at&.iso8601
    }
  end
end
