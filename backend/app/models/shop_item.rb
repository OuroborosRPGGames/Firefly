# frozen_string_literal: true

class ShopItem < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :shop
  many_to_one :pattern

  def validate
    super
    validates_presence [:shop_id, :pattern_id]
    validates_numeric :price, minimum: 0, allow_nil: true
    validates_numeric :stock, allow_nil: true
  end

  # Check if item has stock available
  # nil stock is treated as unlimited (available)
  def available?
    return true if stock.nil?

    stock.negative? || stock.positive?
  end

  # Check if unlimited stock
  # nil or negative stock is treated as unlimited
  def unlimited_stock?
    stock.nil? || stock.negative?
  end

  # Get effective price (considers shop free_items setting)
  # Returns 0 if price is nil or shop has free_items
  def effective_price
    return 0 if shop&.free_items

    price || 0
  end

  # Delegate pattern info
  def description
    pattern&.description
  end

  def category
    pattern&.category
  end

  def name
    pattern&.name
  end

  def image_url
    pattern&.image_url
  end

  def has_image?
    pattern&.has_image? || false
  end
  alias image? has_image?
end
