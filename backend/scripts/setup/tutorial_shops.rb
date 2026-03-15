# frozen_string_literal: true

# Tutorial Shops Setup Script
# Creates shops in the newbie mall and populates them with patterns.
# This script is idempotent - safe to run multiple times.
# Must be run AFTER tutorial_universe.rb

require_relative 'helpers'
include SetupHelpers

log 'Creating Tutorial Shops...'

DB.transaction do
  # Find the shop rooms
  location = DB[:locations].first(name: 'Newbie School Building')
  unless location
    raise 'Newbie School Building not found! Run tutorial_universe.rb first.'
  end

  rooms = DB[:rooms].where(location_id: location[:id])

  # Map room names to IDs
  room_ids = {}
  rooms.each do |room|
    room_ids[room[:name]] = room[:id]
  end

  # Verify all shop rooms exist
  shop_rooms = [
    'Underwear Shop',
    'Bottoms Shop',
    'Tops Shop',
    'Footwear Shop',
    'Outerwear Shop',
    'Equipment Shop'
  ]

  shop_rooms.each do |room_name|
    unless room_ids[room_name]
      raise "Shop room '#{room_name}' not found! Run tutorial_universe.rb first."
    end
  end

  # ============================================
  # CATEGORY MAPPINGS
  # ============================================
  # Based on Ravencroft's shop queries and unified_object_types categories

  shop_categories = {
    'Underwear Shop' => {
      categories: %w[Underwear Swimwear]
    },
    'Bottoms Shop' => {
      categories: %w[Pants Skirt Shorts]
    },
    'Tops Shop' => {
      categories: %w[Top Dress Fullbody Shirt Blouse]
    },
    'Footwear Shop' => {
      categories: %w[Shoes],
      subcategories: %w[Socks]
    },
    'Outerwear Shop' => {
      categories: %w[Outerwear Jacket Coat Cloak]
    },
    'Equipment Shop' => {
      categories: %w[Accessory Bag Hat Gloves Belt Sword Firearm Knife]
    }
  }

  # ============================================
  # CREATE SHOPS AND POPULATE INVENTORY
  # ============================================

  shop_categories.each do |shop_name, config|
    room_id = room_ids[shop_name]

    # Create or update shop record
    shop_id = ensure_record(
      :shops,
      { room_id: room_id },
      {
        name: shop_name,
        sname: shop_name,
        shopkeeper_name: 'Shopkeeper',
        free_items: true
      }
    )

    log "  Shop: #{shop_name} (ID: #{shop_id})"

    # Build query for patterns
    categories = config[:categories] || []
    subcategories = config[:subcategories] || []

    # Find patterns matching the categories
    conditions = []
    conditions << { Sequel[:unified_object_types][:category] => categories } if categories.any?
    conditions << { Sequel[:unified_object_types][:subcategory] => subcategories } if subcategories.any?

    if conditions.any?
      patterns = Pattern.join(:unified_object_types, id: :unified_object_type_id)
                        .where(Sequel.|(*conditions))
                        .select_all(:patterns)
                        .all

      # Add patterns to shop
      pattern_count = 0
      patterns.each do |pattern|
        # Check if item already exists
        existing = DB[:shop_items].first(shop_id: shop_id, pattern_id: pattern.id)
        next if existing

        DB[:shop_items].insert(
          shop_id: shop_id,
          pattern_id: pattern.id,
          price: 0,
          stock: -1,
          created_at: Time.now,
          updated_at: Time.now
        )
        pattern_count += 1
      end

      log "    Added #{pattern_count} new items (#{patterns.count} total patterns matched)"
    else
      log "    No category filters defined, skipping inventory"
    end
  end

  # ============================================
  # SUMMARY
  # ============================================

  total_shops = DB[:shops].where(room_id: room_ids.values).count
  total_items = DB[:shop_items].join(:shops, id: :shop_id)
                               .where(Sequel[:shops][:room_id] => room_ids.values)
                               .count

  log ''
  log 'Tutorial Shops setup complete!'
  log "  - #{total_shops} shops created"
  log "  - #{total_items} total shop items"
  log '  - All items are FREE (free_items: true)'
end
