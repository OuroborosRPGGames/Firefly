# frozen_string_literal: true

class BattleMapTemplate < Sequel::Model(:battle_map_templates)
  # Find a random template for a category + shape
  def self.random_for(category, shape_key)
    templates = where(category: category, shape_key: shape_key).all
    templates.sample
  end

  # Find all templates for a category + shape
  def self.for_shape(category, shape_key)
    where(category: category, shape_key: shape_key).all
  end

  def touch!
    update(last_used_at: Time.now)
  end
end
