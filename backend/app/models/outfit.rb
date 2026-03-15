# frozen_string_literal: true

# Outfit represents a saved clothing combination.
# Can be full outfits or partial (e.g., just accessories).
# The outfit_class determines what items are removed when wearing:
#   - full: removes everything worn
#   - underwear/overwear/bottoms/top/jewelry/accessories: removes only items of that class
#   - other: removes nothing
class Outfit < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  # Valid outfit classes
  CLASSES = %w[full underwear overwear bottoms top jewelry accessories other].freeze

  many_to_one :character_instance
  one_to_many :outfit_items

  def validate
    super
    validates_presence [:character_instance_id, :name]
    validates_max_length 100, :name
    validates_unique [:character_instance_id, :name]
    validates_includes CLASSES, :outfit_class, message: "must be one of: #{CLASSES.join(', ')}"
  end

  def before_validation
    super
    # Set default outfit_class if not provided
    self.outfit_class ||= 'full'
  end

  def items
    outfit_items_dataset.eager(:pattern)
  end

  def item_count
    outfit_items.count
  end

  # Save current worn items as this outfit
  def save_from_worn!(character_instance)
    # Clear existing items
    outfit_items_dataset.delete

    # Save currently worn items
    character_instance.worn_items.each do |item|
      OutfitItem.create(
        outfit_id: id,
        pattern_id: item.pattern_id,
        display_order: item.display_order || 0
      )
    end
    self
  end

  # Apply this outfit to a character (creates new Item instances)
  # Respects outfit_class to determine what gets removed first
  def apply_to!(character_instance)
    # Remove items based on outfit class
    items_to_remove = items_to_remove_for_class(character_instance)
    items_to_remove.each(&:remove!)

    outfit_items.each do |oi|
      next unless oi.pattern

      item = oi.pattern.instantiate(character_instance: character_instance)
      item.update(display_order: oi.display_order)
      next if wear_outfit_item(item, character_instance)

      item.destroy
    end
    true
  end

  # Determine which worn items should be removed based on outfit class
  # @param ci [CharacterInstance] The character instance
  # @return [Array<Item>] Items to remove before wearing this outfit
  def items_to_remove_for_class(character_instance)
    return [] if outfit_class == 'other'

    worn = character_instance.worn_items.all

    if outfit_class == 'full'
      worn
    else
      # Only remove items of the same clothing class
      worn.select { |item| item.clothing_class == outfit_class }
    end
  end

  private

  def wear_outfit_item(item, character_instance)
    if item.piercing?
      positions = character_instance.pierced_positions
      return false if positions.empty? || positions.length > 1

      item.wear!(position: positions.first) == true
    else
      item.wear! == true
    end
  end
end
