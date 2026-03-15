# frozen_string_literal: true

class Pattern < Sequel::Model
  include StringHelper

  plugin :validation_helpers
  plugin :timestamps
  unrestrict_primary_key

  # Category groupings for type checking
  CLOTHING_CATEGORIES = %w[Top Pants Dress Skirt Underwear Outerwear Swimwear Fullbody Shoes Accessory Bag].freeze
  JEWELRY_CATEGORIES = %w[Ring Necklace Bracelet Piercing].freeze
  WEAPON_CATEGORIES = %w[Sword Knife Firearm].freeze
  CONSUMABLE_CATEGORIES = %w[consumable].freeze
  OTHER_CATEGORIES = %w[Other].freeze

  # Associations
  many_to_one :unified_object_type
  one_to_many :objects, class: :Item, key: :pattern_id

  def validate
    super
    validates_presence [:description, :unified_object_type_id]
    validates_numeric :price, minimum: 0, allow_nil: true
  end

  # Delegate type information to unified_object_type
  def name
    unified_object_type&.name
  end

  def category
    unified_object_type&.category
  end

  def subcategory
    unified_object_type&.subcategory
  end

  def layer
    unified_object_type&.layer
  end

  def covered_positions
    unified_object_type&.covered_positions || []
  end

  def zippable_positions
    unified_object_type&.zippable_positions || []
  end

  # Check pattern type based on unified_object_type category
  def clothing?
    CLOTHING_CATEGORIES.include?(category)
  end

  def jewelry?
    JEWELRY_CATEGORIES.include?(category)
  end

  def weapon?
    WEAPON_CATEGORIES.include?(category) || is_melee || is_ranged
  end

  def piercing?
    category == 'Piercing'
  end

  def other?
    OTHER_CATEGORIES.include?(category)
  end

  # Pet pattern check (uses is_pet flag)
  def pet?
    is_pet == true
  end

  # Check if pattern has an image
  def has_image?
    present?(image_url)
  end
  alias image? has_image?

  # Consumable checks
  def consumable?
    CONSUMABLE_CATEGORIES.include?(category)
  end

  def food?
    consume_type == 'food'
  end

  def drink?
    consume_type == 'drink'
  end

  def smokeable?
    consume_type == 'smoke'
  end

  # === Weapon Combat Methods ===

  # Check if this is a melee weapon
  def melee_weapon?
    weapon? && is_melee
  end

  # Check if this is a ranged weapon
  def ranged_weapon?
    weapon? && is_ranged
  end

  # Check if weapon can be used in both modes
  def dual_mode_weapon?
    is_melee && is_ranged
  end

  # Get attack interval based on speed (100 / speed)
  def attack_interval
    speed = attack_speed || 5
    return 100 if speed <= 0

    (100.0 / speed).round
  end

  # Convert weapon_range to hex distance
  def range_in_hexes
    case weapon_range
    when 'melee' then 1
    when 'short' then 5
    when 'medium' then 10
    when 'long' then 15
    else 1
    end
  end

  # Get melee reach value (1-5 scale)
  # Returns nil for ranged-only weapons
  # Defaults to 2 for melee weapons without explicit reach
  def melee_reach_value
    return nil unless melee_weapon?

    (respond_to?(:melee_reach) && melee_reach) || GameConfig::Mechanics::REACH[:unarmed_reach]
  end

  # Get attacks per round based on speed
  def attacks_per_round
    attack_speed || 5
  end

  # === Holster/Sheath Methods ===

  # Check if this pattern is a holster/sheath
  def holster?
    holster_capacity&.positive?
  end

  # Check if a weapon pattern is compatible with this holster
  def accepts_weapon_type?(weapon_pattern)
    return false unless holster?
    return false unless weapon_pattern&.weapon?

    case holster_weapon_type
    when 'sword'
      # Swords are blades that are not knives
      weapon_pattern.is_melee &&
        weapon_pattern.unified_object_type&.category == 'blade' &&
        weapon_pattern.unified_object_type&.subcategory != 'knife'
    when 'pistol'
      weapon_pattern.is_ranged && weapon_pattern.unified_object_type&.category == 'firearm'
    when 'knife'
      weapon_pattern.is_melee && weapon_pattern.unified_object_type&.subcategory == 'knife'
    else
      false
    end
  end

  # Create an Item instance from this pattern
  def instantiate(options = {})
    item = Item.create(
      pattern: self,
      name: options[:name] || description,
      description: options[:description] || desc_desc || description,
      quantity: options[:quantity] || 1,
      condition: options[:condition] || 'good',
      character_instance: options[:character_instance],
      room: options[:room],
      is_clothing: clothing?,
      is_jewelry: jewelry?,
      is_tattoo: false,
      is_piercing: piercing?,
      worn_layer: layer
    )

    # Create ItemBodyPosition records for covered positions
    covered_positions.each do |position_label|
      # Convert from Title Case ("Upper Back") to snake_case ("upper_back")
      normalized_label = position_label.downcase.gsub(' ', '_')

      # Resolve aliases from legacy seed data (CSV uses old Ravencroft names)
      resolved_labels = resolve_position_label(normalized_label)

      resolved_labels.each do |label|
        body_pos = BodyPosition.by_label(label)
        next unless body_pos

        ItemBodyPosition.create(
          item_id: item.id,
          body_position_id: body_pos.id,
          covers: true
        )
      end
    end

    item
  end
  
  # Search patterns
  def self.search(query, limit: 50)
    where(Sequel.ilike(:description, "%#{query}%")).limit(limit)
  end

  # Query by unified_object_type category
  def self.by_category(*categories)
    join(:unified_object_types, id: :unified_object_type_id)
      .where(Sequel[:unified_object_types][:category] => categories.flatten)
      .select_all(:patterns)
  end

  def self.clothing
    by_category(CLOTHING_CATEGORIES)
  end

  def self.jewelry
    by_category(JEWELRY_CATEGORIES)
  end

  def self.weapons
    by_category(WEAPON_CATEGORIES)
  end

  def self.others
    by_category(OTHER_CATEGORIES)
  end

  def self.consumables
    by_category(CONSUMABLE_CATEGORIES)
  end

  def self.pets
    where(is_pet: true)
  end

  def self.magical
    where(Sequel.~(magic_type: nil))
  end
  
  def self.in_price_range(min, max)
    where(price: min..max)
  end
  
  def self.for_year(year)
    where((Sequel[:min_year] <= year) | (Sequel[:min_year] =~ nil))
      .where((Sequel[:max_year] >= year) | (Sequel[:max_year] =~ nil))
  end

  private

  # Map legacy seed position labels to current DB labels.
  # The CSV seed data uses Ravencroft naming ("Rear", "Thighs") but
  # migration 030 renamed body positions to anatomical terms.
  # Returns an array since some labels expand to multiple positions.
  POSITION_ALIASES = {
    'rear' => ['buttocks'],
    'thighs' => %w[left_thigh right_thigh]
  }.freeze

  def resolve_position_label(normalized_label)
    POSITION_ALIASES[normalized_label] || [normalized_label]
  end
end