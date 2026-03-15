# frozen_string_literal: true

require_relative 'concerns/cooldownable'

# CharacterAbility links a CharacterInstance to an Ability they possess.
# Tracks when it was learned and current cooldown state.
class CharacterAbility < Sequel::Model
  include Cooldownable

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character_instance
  many_to_one :ability

  def validate
    super
    validates_presence [:character_instance_id, :ability_id]
    validates_unique [:character_instance_id, :ability_id]
  end

  def before_save
    super
    self.learned_at ||= Time.now
    self.uses_today ||= 0
  end

  # Implement Cooldownable interface
  def cooldown_expires_at
    return nil unless last_used_at && ability&.cooldown_seconds.to_i > 0

    last_used_at + ability.cooldown_seconds
  end

  # Aliases for backward compatibility
  def on_cooldown?
    cooldown_active?
  end

  def cooldown_ends_at
    cooldown_expires_at
  end

  def cooldown_remaining
    cooldown_remaining_seconds
  end

  def trigger_cooldown!
    return unless ability&.has_cooldown?
    update(last_used_at: Time.now)
  end

  def reset_cooldown!
    update(last_used_at: nil)
  end

  def can_use?
    !on_cooldown?
  end
end
