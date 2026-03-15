# frozen_string_literal: true

# Shared module for models that track cooldowns.
# Provides consistent time-based methods for checking cooldown status.
#
# Models should define `cooldown_expires_at` to return the Time when cooldown ends.
#
# @example
#   class CharacterAbility < Sequel::Model
#     include Cooldownable
#
#     def cooldown_expires_at
#       return nil unless last_used_at && ability&.cooldown_seconds.to_i > 0
#       last_used_at + ability.cooldown_seconds
#     end
#   end
#
#   class ActionCooldown < Sequel::Model
#     include Cooldownable
#
#     def cooldown_expires_at
#       expires_at
#     end
#   end
#
module Cooldownable
  # Check if cooldown is still active
  # @return [Boolean]
  def cooldown_active?
    expires_at = cooldown_expires_at
    return false if expires_at.nil?

    Time.now < expires_at
  end

  # Check if cooldown has expired (or was never set)
  # @return [Boolean]
  def cooldown_available?
    !cooldown_active?
  end

  # Get remaining cooldown time in seconds
  # @return [Integer] 0 if expired or not set
  def cooldown_remaining_seconds
    expires_at = cooldown_expires_at
    return 0 if expires_at.nil?

    [(expires_at - Time.now).to_i, 0].max
  end

  # Get remaining cooldown time in milliseconds
  # @return [Integer] 0 if expired or not set
  def cooldown_remaining_ms
    expires_at = cooldown_expires_at
    return 0 if expires_at.nil?

    [((expires_at - Time.now) * 1000).to_i, 0].max
  end

  # Get remaining cooldown as a percentage (0.0 to 1.0)
  # Requires cooldown_duration_seconds to be defined
  # @return [Float] 0.0 if expired
  def cooldown_remaining_percent
    return 0.0 unless respond_to?(:cooldown_duration_seconds) && cooldown_duration_seconds.to_i > 0
    return 0.0 unless cooldown_active?

    (cooldown_remaining_seconds.to_f / cooldown_duration_seconds).clamp(0.0, 1.0)
  end
end
