# frozen_string_literal: true

# CharacterStat links a CharacterInstance to a Stat with their current value.
# Tracks base value and any temporary modifiers.
class CharacterStat < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character_instance
  many_to_one :stat

  def validate
    super
    validates_presence [:character_instance_id, :stat_id, :base_value]
    validates_unique [:character_instance_id, :stat_id]
    validates_integer :base_value
  end

  def before_save
    super
    self.base_value ||= stat&.default_value || 10
    self.temp_modifier ||= 0
  end

  # Current effective value including modifiers
  def current_value
    [stat.min_value, base_value + temp_modifier.to_i].max
      .clamp(stat.min_value, stat.max_value)
  end

  # Apply a temporary modifier
  def apply_modifier(amount, duration_seconds: nil)
    update(
      temp_modifier: temp_modifier.to_i + amount,
      modifier_expires_at: duration_seconds ? Time.now + duration_seconds : nil
    )
  end

  # Clear expired modifiers
  def clear_expired_modifiers!
    return unless modifier_expires_at && Time.now >= modifier_expires_at
    update(temp_modifier: 0, modifier_expires_at: nil)
  end

  # Increase base stat (from leveling, training, etc.)
  def increase_base!(amount = 1)
    new_value = [base_value + amount, stat.max_value].min
    update(base_value: new_value)
  end

  def at_max?
    base_value >= stat.max_value
  end

  def at_min?
    base_value <= stat.min_value
  end
end
