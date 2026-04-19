# frozen_string_literal: true

class BattleMapElementAsset < Sequel::Model
  plugin :validation_helpers

  ELEMENT_TYPES = BattleMapElement::PLACEABLE_TYPES

  def validate
    super
    validates_presence [:element_type, :variant, :image_url]
    validates_includes ELEMENT_TYPES, :element_type
    validates_unique [:element_type, :variant]
  end

  def self.random_for_type(element_type)
    where(element_type: element_type).order(Sequel.lit('RANDOM()')).first
  end
end
