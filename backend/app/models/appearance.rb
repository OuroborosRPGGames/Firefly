# frozen_string_literal: true

# Appearance belongs to a CharacterShape and represents a disguise or alternate look.
# Default appearance is the undisguised state; additional appearances are disguises.
class Appearance < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character_shape

  def validate
    super
    validates_presence [:character_shape_id, :name]
    validates_max_length 100, :name
    validates_unique [:character_shape_id, :name]
  end

  def before_save
    super
    self.is_default ||= false if is_default.nil?
  end

  # Make this the active appearance for the shape
  def activate!
    Appearance.where(character_shape_id: character_shape_id).update(is_active: false)
    update(is_active: true)
  end

  def disguised?
    !is_default
  end

  def self.default_for(shape)
    first(character_shape_id: shape.id, is_default: true)
  end
end
