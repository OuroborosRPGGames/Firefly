# frozen_string_literal: true

class UnifiedObjectType < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  # Category groupings for type checking (shared with Pattern)
  CLOTHING_CATEGORIES = %w[Top Pants Dress Skirt Underwear Outerwear Swimwear Fullbody Shoes Accessory Bag].freeze
  JEWELRY_CATEGORIES = %w[Ring Necklace Bracelet Piercing].freeze
  WEAPON_CATEGORIES = %w[Sword Knife Firearm].freeze
  CONSUMABLE_CATEGORIES = %w[consumable].freeze
  OTHER_CATEGORIES = %w[Other].freeze

  # Associations
  one_to_many :patterns
  one_to_many :objects, class: :Item, through: :patterns

  def validate
    super
    validates_presence [:name, :category]
    validates_unique :name
    validates_max_length 100, :name
    validates_max_length 50, :category
    validates_max_length 50, :subcategory, allow_nil: true
  end

  # Get all covered body positions (bone fields) as an array
  def covered_positions
    (1..20).map { |i| send("covered_position_#{i}") }.compact.reject(&:empty?)
  end

  # Get all zippable positions (zone fields) as an array
  def zippable_positions
    (1..10).map { |i| send("zone_#{i}") }.compact.reject(&:empty?)
  end

  # Set covered positions from array (maps to bone fields)
  def covered_positions=(array)
    # Clear all existing covered positions
    (1..20).each { |i| send("covered_position_#{i}=", nil) }

    # Set new covered positions
    array.compact.first(20).each_with_index do |position, index|
      send("covered_position_#{index + 1}=", position) unless position.empty?
    end
  end

  # Set zippable positions from array (maps to zone fields)
  def zippable_positions=(array)
    # Clear all existing zippable positions
    (1..10).each { |i| send("zone_#{i}=", nil) }

    # Set new zippable positions
    array.compact.first(10).each_with_index do |position, index|
      send("zone_#{index + 1}=", position) unless position.empty?
    end
  end

  # Class methods for querying by category
  def self.clothing_types
    where(category: CLOTHING_CATEGORIES)
  end

  def self.jewelry_types
    where(category: JEWELRY_CATEGORIES)
  end

  def self.weapon_types
    where(category: WEAPON_CATEGORIES)
  end

  def self.consumable_types
    where(category: CONSUMABLE_CATEGORIES)
  end

  def self.other_types
    where(category: OTHER_CATEGORIES)
  end

  def self.pet_types
    # Pet types are marked with a specific flag or category
    where(category: 'Pet')
  end

  def self.by_category(*categories)
    where(category: categories.flatten)
  end

  def self.by_layer(layer)
    where(layer: layer).order(:dorder)
  end

  # Check if this is a clothing type
  def clothing?
    CLOTHING_CATEGORIES.include?(category)
  end

  # Check if this is a jewelry type
  def jewelry?
    JEWELRY_CATEGORIES.include?(category)
  end

  # Check if this is a weapon type
  def weapon?
    WEAPON_CATEGORIES.include?(category)
  end

  # Check if this is a consumable type
  def consumable?
    CONSUMABLE_CATEGORIES.include?(category)
  end

  # Check if this is an other type
  def other?
    OTHER_CATEGORIES.include?(category)
  end

  # Check if this is a pet type
  def pet?
    category == 'Pet'
  end
end