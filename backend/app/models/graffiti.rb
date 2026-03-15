# frozen_string_literal: true

class Graffiti < Sequel::Model(:graffiti)
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :room
  many_to_one :character

  MAX_LENGTH = 220

  # Database columns are: x, y, text, created_at
  # Legacy aliases for backward compatibility
  def g_x
    x
  end

  def g_x=(val)
    self.x = val
  end

  def g_y
    y
  end

  def g_y=(val)
    self.y = val
  end

  def gdesc
    text
  end

  def gdesc=(val)
    self.text = val
  end

  def made_at
    created_at
  end

  def made_at=(val)
    self.created_at = val
  end

  def validate
    super
    validates_presence :room_id
    validates_presence :text
    validates_max_length MAX_LENGTH, :text
  end
end
