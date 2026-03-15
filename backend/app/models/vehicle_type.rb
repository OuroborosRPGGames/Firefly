# frozen_string_literal: true

# VehicleType defines base templates for vehicles (car, motorcycle, horse, etc.)
class VehicleType < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  one_to_many :vehicles

  CATEGORIES = %w[ground water air space mount].freeze

  # Database column is max_passengers, alias for backward compatibility
  def passenger_capacity
    max_passengers || 4
  end

  def passenger_capacity=(val)
    self.max_passengers = val
  end

  # Alias for speed modifier
  def speed_modifier
    base_speed || 1.0
  end

  def speed_modifier=(val)
    self.base_speed = val
  end

  def validate
    super
    validates_presence [:name, :category]
    validates_max_length 100, :name
    validates_unique [:universe_id, :name]
    validates_includes CATEGORIES, :category
  end

  def before_save
    super
    self.category ||= 'ground'
    self.max_passengers ||= 1
    self.base_speed ||= 1.0
  end

  def ground?
    category == 'ground'
  end

  def mount?
    category == 'mount'
  end

  def can_carry_passengers?
    passenger_capacity > 1
  end

  def always_open?
    always_open == true
  end
end
