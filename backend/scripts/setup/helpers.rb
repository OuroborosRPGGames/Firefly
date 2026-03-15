# frozen_string_literal: true

require_relative '../../app/helpers/canvas_helper'

# Shared helper methods for setup scripts
module SetupHelpers
  # Idempotent record creation/retrieval
  # Returns the record ID, creating if it doesn't exist
  def ensure_record(table_name, unique_attrs, attrs = {})
    dataset = DB[table_name]
    existing = dataset.where(unique_attrs).first
    return existing[:id] if existing

    now = Time.now
    full_attrs = unique_attrs.merge(attrs)
    full_attrs[:created_at] ||= now if dataset.columns.include?(:created_at)
    full_attrs[:updated_at] ||= now if dataset.columns.include?(:updated_at)

    dataset.insert(full_attrs)
  end

  # Find or create a model instance (for Sequel models)
  def ensure_model(model_class, unique_attrs, attrs = {})
    existing = model_class.first(unique_attrs)
    return existing if existing

    model_class.create(unique_attrs.merge(attrs))
  end

  # Get the opposite direction for bidirectional exits
  # Navigation now uses spatial adjacency, but opposite_direction is still useful for other setup tasks
  def opposite_direction(direction)
    CanvasHelper.opposite_direction(direction)
  end

  # Get patterns by category from unified_object_types
  def patterns_by_category(*categories)
    Pattern.join(:unified_object_types, id: :unified_object_type_id)
           .where(Sequel[:unified_object_types][:category] => categories)
           .select_all(:patterns)
  end

  # Get patterns by category or subcategory
  def patterns_by_category_or_subcategory(categories: [], subcategories: [])
    conditions = []
    conditions << { Sequel[:unified_object_types][:category] => categories } if categories.any?
    conditions << { Sequel[:unified_object_types][:subcategory] => subcategories } if subcategories.any?

    Pattern.join(:unified_object_types, id: :unified_object_type_id)
           .where(Sequel.|(*conditions))
           .select_all(:patterns)
  end

  # Add items to a shop from patterns
  def populate_shop(shop_id, patterns, price: 0)
    patterns.each do |pattern|
      pattern_id = pattern.is_a?(Integer) ? pattern : pattern.id
      ensure_record(
        :shop_items,
        { shop_id: shop_id, pattern_id: pattern_id },
        { price: price, stock: -1 }
      )
    end
  end

  # Print progress message
  def log(message)
    puts "[Setup] #{message}"
  end
end
