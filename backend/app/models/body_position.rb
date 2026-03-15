# frozen_string_literal: true

class BodyPosition < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  one_to_many :item_body_positions
  one_to_many :description_type_body_positions

  def validate
    super
    validates_presence [:label]
    validates_unique :label
    validates_max_length 50, :label
  end

  def is_private?
    is_private == true
  end

  def to_s
    label
  end

  # Class methods for common body positions
  def self.by_label(label)
    where(label: label).first
  end

  def self.private_positions
    where(is_private: true)
  end

  def self.public_positions
    where(is_private: false)
  end

  def self.by_region(region)
    where(region: region)
  end

  def self.ordered
    order(:display_order)
  end

  def self.head_positions
    by_region('head')
  end

  def self.torso_positions
    by_region('torso')
  end

  def self.arm_positions
    by_region('arms')
  end

  def self.hand_positions
    by_region('hands')
  end

  def self.leg_positions
    by_region('legs')
  end

  def self.foot_positions
    by_region('feet')
  end
end
