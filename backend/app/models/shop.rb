# frozen_string_literal: true

class Shop < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room
  one_to_many :shop_items

  def validate
    super
    validates_presence [:room_id]
    validates_unique :room_id
    validates_max_length 100, :name, allow_nil: true
    validates_max_length 100, :shopkeeper_name, allow_nil: true
  end

  # Support both 'name' and legacy 'sname' columns
  # Returns 'Shop' as default if neither is set
  def display_name
    return name if name && !name.to_s.empty?
    return sname if sname && !sname.to_s.empty?

    'Shop'
  end

  # ========================================
  # Public Directory Methods
  # ========================================

  # Scope for publicly visible shops (open shops only)
  def self.publicly_visible
    dataset.where(is_open: true)
  end

  # Check if this shop is publicly visible
  def publicly_visible?
    !!is_open
  end

  # Get location name for display
  def location_display_name
    room&.location&.name || 'Unknown Location'
  end

  # Get zone name for display
  def zone_display_name
    room&.location&.zone&.name || 'Unknown Zone'
  end

  # Backward compatibility alias
  alias_method :area_display_name, :zone_display_name

  def before_save
    super
    # Sync name and sname for backwards compatibility
    self.sname = name if name && respond_to?(:sname=)
  end

  # Get all available items (with stock)
  def available_items
    shop_items_dataset.where { (stock < 0) | (stock > 0) }
  end

  # Check if an item is in stock
  # nil stock is treated as unlimited (in stock)
  def in_stock?(pattern_id)
    item = shop_items_dataset.first(pattern_id: pattern_id)
    return false unless item

    item.available?
  end

  # Get item price (or 0 if free_items is true)
  # Returns nil if item doesn't exist
  def price_for(pattern_id)
    return 0 if free_items

    item = shop_items_dataset.first(pattern_id: pattern_id)
    return nil unless item

    item.price || 0
  end

  # Decrement stock for an item (returns true if successful)
  # nil or negative stock is treated as unlimited
  def decrement_stock(pattern_id)
    item = shop_items_dataset.first(pattern_id: pattern_id)
    return false unless item
    return true if item.unlimited_stock?

    return false if item.stock.nil? || item.stock.zero?

    item.update(stock: item.stock - 1)
    true
  end
end
