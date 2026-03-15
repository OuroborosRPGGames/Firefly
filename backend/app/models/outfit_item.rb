# frozen_string_literal: true

# OutfitItem links an Outfit to a Pattern with positioning info.
class OutfitItem < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :outfit
  many_to_one :pattern

  def validate
    super
    validates_presence [:outfit_id]
    # pattern_id is optional - items without patterns can still be saved
  end

  def before_save
    super
    self.display_order ||= 0
  end

  def item_name
    pattern&.description || 'Unknown item'
  end
end
