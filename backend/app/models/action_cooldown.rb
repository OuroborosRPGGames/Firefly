# frozen_string_literal: true

require_relative 'concerns/cooldownable'

# ActionCooldown model for tracking ability cooldowns
#
# Provides fast O(1) lookup for checking if abilities are available.
# Cooldowns are indexed by character instance and ability name.
#
class ActionCooldown < Sequel::Model
  include Cooldownable

  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :character_instance

  # Implement Cooldownable interface
  # @return [Time, nil]
  def cooldown_expires_at
    expires_at
  end

  # Implement Cooldownable interface for percentage calculation
  # @return [Integer, nil]
  def cooldown_duration_seconds
    return nil unless duration_ms

    (duration_ms / 1000.0).to_i
  end

  # Validations
  def validate
    super
    validates_presence [:character_instance_id, :ability_name, :expires_at]
  end

  # Implement Cooldownable interface
  def cooldown_expires_at
    expires_at
  end

  # Aliases for backward compatibility
  def active?
    cooldown_active?
  end

  def available?
    cooldown_available?
  end

  def remaining_ms
    cooldown_remaining_ms
  end

  def remaining_seconds
    cooldown_remaining_seconds.to_f
  end

  # Format for API consumption
  # @return [Hash]
  def to_api_format
    {
      ability_name: ability_name,
      active: active?,
      expires_at: expires_at&.iso8601,
      remaining_ms: remaining_ms
    }
  end

  class << self
    # Set a cooldown for an ability
    # @param char_instance [CharacterInstance] character
    # @param ability [String] ability name
    # @param duration_ms [Integer] cooldown duration in milliseconds
    # @return [ActionCooldown]
    def set(char_instance, ability, duration_ms)
      expires = Time.now + (duration_ms / 1000.0)

      existing = first(
        character_instance_id: char_instance.id,
        ability_name: ability
      )

      if existing
        existing.update(expires_at: expires, duration_ms: duration_ms)
        existing
      else
        create(
          character_instance_id: char_instance.id,
          ability_name: ability,
          expires_at: expires,
          duration_ms: duration_ms
        )
      end
    end

    # Check if an ability is available (no active cooldown)
    # @param char_instance [CharacterInstance] character
    # @param ability [String] ability name
    # @return [Boolean]
    def available?(char_instance, ability)
      cooldown = first(
        character_instance_id: char_instance.id,
        ability_name: ability
      )
      return true unless cooldown

      cooldown.available?
    end

    # Get remaining cooldown time in milliseconds
    # @param char_instance [CharacterInstance] character
    # @param ability [String] ability name
    # @return [Integer] 0 if available
    def remaining_ms(char_instance, ability)
      cooldown = first(
        character_instance_id: char_instance.id,
        ability_name: ability
      )
      return 0 unless cooldown

      cooldown.remaining_ms
    end

    # Get all active cooldowns for a character
    # @param char_instance_id [Integer]
    # @return [Array<ActionCooldown>]
    def active_for_character(char_instance_id)
      where(character_instance_id: char_instance_id)
        .where { expires_at > Time.now }
        .all
    end

    # Clear a specific cooldown
    # @param char_instance [CharacterInstance] character
    # @param ability [String] ability name
    # @return [Boolean]
    def clear(char_instance, ability)
      deleted = where(
        character_instance_id: char_instance.id,
        ability_name: ability
      ).delete
      deleted.positive?
    end

    # Clear all cooldowns for a character
    # @param char_instance_id [Integer]
    # @return [Integer] number cleared
    def clear_all(char_instance_id)
      where(character_instance_id: char_instance_id).delete
    end

    # Clean up expired cooldowns (maintenance task)
    # @return [Integer] number cleaned
    def cleanup_expired!
      where { expires_at < Time.now }.delete
    end
  end
end
