# frozen_string_literal: true

# Test City Setup Script
# Creates a comprehensive test city for exhaustive command testing
# Run with: bundle exec ruby scripts/setup/test_city.rb

require_relative '../../app'
require_relative 'helpers'

include SetupHelpers

log "Starting Test City setup..."

DB.transaction do
  # ========================================
  # WORLD HIERARCHY
  # ========================================

  log "Creating universe, world, and area..."

  universe = ensure_model(Universe, { name: 'Test City Universe' }, {
    theme: 'modern',
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Universe: #{universe.name} (ID: #{universe.id})"

  world = ensure_model(World, { name: 'Test World', universe_id: universe.id }, {
    gravity_multiplier: 1.0,
    world_size: 1000.0,
    coordinates_x: 0,
    coordinates_y: 0,
    coordinates_z: 0,
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  World: #{world.name} (ID: #{world.id})"

  area = ensure_model(Zone, { name: 'Downtown', world_id: world.id }, {
    zone_type: 'city',
    danger_level: 1,
    min_longitude: -100.0,
    max_longitude: 100.0,
    min_latitude: -100.0,
    max_latitude: 100.0,
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Area: #{area.name} (ID: #{area.id})"

  location = ensure_model(Location, { name: 'Main Street', zone_id: area.id }, {
    location_type: 'outdoor',
    is_active: true,
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Location: #{location.name} (ID: #{location.id})"

  # Create a second location for apartments
  apartment_location = ensure_model(Location, { name: 'Residential Block', zone_id: area.id }, {
    location_type: 'building',
    is_active: true,
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Location: #{apartment_location.name} (ID: #{apartment_location.id})"

  # ========================================
  # ROOMS
  # ========================================

  log "Creating rooms..."

  # Default room dimensions (base min/max coordinates required by Room model)
  default_dims = { min_x: 0, max_x: 100, min_y: 0, max_y: 100 }

  # Town Square - Central hub
  town_square = ensure_model(Room, { name: 'Town Square', location_id: location.id }, default_dims.merge(
    short_description: 'A bustling town square with a fountain in the center.',
    long_description: 'The heart of downtown, this square features a beautiful stone fountain surrounded by benches. Street vendors line the edges, and people bustle about their daily business.',
    room_type: 'street',
    safe_room: true,
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{town_square.name} (ID: #{town_square.id}) [SPAWN]"

  # General Store - Shop testing
  general_store = ensure_model(Room, { name: 'General Store', location_id: location.id }, default_dims.merge(
    short_description: 'A well-stocked general store.',
    long_description: 'Shelves line the walls, filled with everyday items. A cheerful shopkeeper stands behind the counter, ready to help customers.',
    room_type: 'shop',
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{general_store.name} (ID: #{general_store.id})"

  # Clothing Boutique - Clothing/outfit testing
  boutique = ensure_model(Room, { name: 'Fashion Boutique', location_id: location.id }, default_dims.merge(
    short_description: 'A trendy clothing boutique.',
    long_description: 'Mannequins display the latest fashions. Racks of clothing in every style fill the store, and mirrors line the walls.',
    room_type: 'shop',
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{boutique.name} (ID: #{boutique.id})"

  # Bank - Economy testing
  bank = ensure_model(Room, { name: 'First National Bank', location_id: location.id }, default_dims.merge(
    short_description: 'A grand bank building.',
    long_description: 'Marble floors and tall columns give this bank an imposing presence. Teller windows line one wall, and a vault door gleams in the back.',
    room_type: 'bank',
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{bank.name} (ID: #{bank.id})"

  # Coffee Shop - Indoor location with furniture
  coffee_shop = ensure_model(Room, { name: 'The Daily Grind', location_id: location.id }, default_dims.merge(
    short_description: 'A cozy coffee shop.',
    long_description: 'The aroma of fresh coffee fills the air. Comfortable armchairs and small tables invite patrons to sit and relax. A chalkboard menu lists the daily specials.',
    room_type: 'building',
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{coffee_shop.name} (ID: #{coffee_shop.id})"

  # City Park - Outdoor activities
  city_park = ensure_model(Room, { name: 'City Park', location_id: location.id }, default_dims.merge(
    short_description: 'A peaceful urban park.',
    long_description: 'Green grass and tall trees provide a natural oasis in the city. Park benches dot the walking paths, and a small pond reflects the sky.',
    room_type: 'park',
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{city_park.name} (ID: #{city_park.id})"

  # Pool Area - Water room for swimming
  pool = ensure_model(Room, { name: 'Community Pool', location_id: location.id }, default_dims.merge(
    short_description: 'A public swimming pool.',
    long_description: 'Crystal clear water fills the Olympic-sized pool. Lounge chairs line the deck, and lifeguard stations overlook the water.',
    room_type: 'pool',
    created_at: Time.now,
    updated_at: Time.now
  ))
  log "  Room: #{pool.name} (ID: #{pool.id})"

  # Alice's Apartment - Ownership/access testing
  alices_apartment = ensure_model(Room, { name: "Alice's Apartment", location_id: apartment_location.id }, {
    short_description: "A cozy studio apartment.",
    long_description: "A comfortable studio apartment with modern furnishings. A large window overlooks the city, and personal touches make it feel like home.",
    room_type: 'apartment',
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Room: #{alices_apartment.name} (ID: #{alices_apartment.id})"

  # Apartment Hallway - Building navigation
  hallway = ensure_model(Room, { name: 'Apartment Hallway', location_id: apartment_location.id }, {
    short_description: 'A carpeted hallway.',
    long_description: 'A long hallway with numbered doors on either side. Soft lighting illuminates the neutral-toned carpet.',
    room_type: 'hallway',
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Room: #{hallway.name} (ID: #{hallway.id})"

  # Bulletin Board Room - Communication testing
  community_center = ensure_model(Room, { name: 'Community Center', location_id: location.id }, {
    short_description: 'A community gathering space.',
    long_description: 'A large open room with folding chairs and tables. A bulletin board covers one wall, and a small stage sits at one end.',
    room_type: 'building',
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Room: #{community_center.name} (ID: #{community_center.id})"

  # ========================================
  # ROOM EXITS (Bidirectional)
  # ========================================

  log "Creating room exits..."

  # Town Square is the central hub
  create_bidirectional_exit(town_square.id, general_store.id, 'north')
  create_bidirectional_exit(town_square.id, boutique.id, 'east')
  create_bidirectional_exit(town_square.id, bank.id, 'south')
  create_bidirectional_exit(town_square.id, coffee_shop.id, 'west')
  create_bidirectional_exit(town_square.id, city_park.id, 'northeast')
  create_bidirectional_exit(town_square.id, community_center.id, 'northwest')
  create_bidirectional_exit(town_square.id, hallway.id, 'southeast')

  # Pool is adjacent to park
  create_bidirectional_exit(city_park.id, pool.id, 'east')

  # Hallway connects to apartment
  create_bidirectional_exit(hallway.id, alices_apartment.id, 'in', 'out')

  log "  Created #{RoomExit.count} room exits"

  # ========================================
  # PLACES (Furniture)
  # ========================================

  log "Creating places/furniture..."

  # Town Square
  ensure_model(Place, { name: 'the fountain edge', room_id: town_square.id }, {
    description: 'the edge of the ornate stone fountain',
    place_type: 'furniture',
    capacity: 4,
    created_at: Time.now,
    updated_at: Time.now
  })

  ensure_model(Place, { name: 'a park bench', room_id: town_square.id }, {
    description: 'a weathered wooden park bench',
    place_type: 'furniture',
    capacity: 3,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Coffee Shop
  ensure_model(Place, { name: 'an armchair', room_id: coffee_shop.id }, {
    description: 'a comfortable leather armchair',
    place_type: 'furniture',
    capacity: 1,
    created_at: Time.now,
    updated_at: Time.now
  })

  ensure_model(Place, { name: 'a corner table', room_id: coffee_shop.id }, {
    description: 'a small table in the corner by the window',
    place_type: 'furniture',
    capacity: 2,
    created_at: Time.now,
    updated_at: Time.now
  })

  ensure_model(Place, { name: 'the counter', room_id: coffee_shop.id }, {
    description: 'a long wooden counter with bar stools',
    place_type: 'furniture',
    capacity: 4,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Park
  ensure_model(Place, { name: 'a park bench', room_id: city_park.id }, {
    description: 'a green iron park bench under a tree',
    place_type: 'furniture',
    capacity: 3,
    created_at: Time.now,
    updated_at: Time.now
  })

  ensure_model(Place, { name: 'the grass', room_id: city_park.id }, {
    description: 'a soft patch of grass',
    place_type: 'floor',
    capacity: 10,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Alice's apartment
  ensure_model(Place, { name: 'the bed', room_id: alices_apartment.id }, {
    description: 'a comfortable queen-sized bed',
    place_type: 'furniture',
    capacity: 2,
    created_at: Time.now,
    updated_at: Time.now
  })

  ensure_model(Place, { name: 'a sofa', room_id: alices_apartment.id }, {
    description: 'a cozy leather sofa',
    place_type: 'furniture',
    capacity: 3,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Pool
  ensure_model(Place, { name: 'a lounge chair', room_id: pool.id }, {
    description: 'a plastic lounge chair by the pool',
    place_type: 'furniture',
    capacity: 1,
    created_at: Time.now,
    updated_at: Time.now
  })

  log "  Created #{Place.count} places"

  # ========================================
  # REALITY
  # ========================================

  log "Ensuring primary reality exists..."

  reality = ensure_model(Reality, { name: 'Primary', reality_type: 'primary' }, {
    time_offset: 0,
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Reality: #{reality.name} (ID: #{reality.id})"

  # ========================================
  # CURRENCY
  # ========================================

  log "Creating currency..."

  currency = ensure_model(Currency, { name: 'Dollar', universe_id: universe.id }, {
    symbol: '$',
    decimal_places: 2,
    is_default: true,
    created_at: Time.now,
    updated_at: Time.now
  })
  log "  Currency: #{currency.name} (#{currency.symbol})"

  # ========================================
  # OBJECT TYPES AND PATTERNS
  # ========================================

  log "Creating object types and patterns..."

  # Create object types using category-based approach
  # Categories: Top, Pants, Ring, Necklace, consumable, etc.

  # Misc type for general items
  misc_type = ensure_model(UnifiedObjectType, { name: 'Test Misc Item' }, {
    category: 'Accessory',
    subcategory: 'general',
    created_at: Time.now,
    updated_at: Time.now
  })

  # Clothing type (Top category)
  clothing_type = ensure_model(UnifiedObjectType, { name: 'Test Shirt' }, {
    category: 'Top',
    subcategory: 'general',
    created_at: Time.now,
    updated_at: Time.now
  })

  # Pants type
  pants_type = ensure_model(UnifiedObjectType, { name: 'Test Pants' }, {
    category: 'Pants',
    subcategory: 'general',
    created_at: Time.now,
    updated_at: Time.now
  })

  # Accessory type (Ring category for jewelry)
  accessory_type = ensure_model(UnifiedObjectType, { name: 'Test Ring' }, {
    category: 'Ring',
    subcategory: 'general',
    created_at: Time.now,
    updated_at: Time.now
  })

  # Consumable type
  consumable_type = ensure_model(UnifiedObjectType, { name: 'Test Consumable' }, {
    category: 'consumable',
    subcategory: 'food',
    created_at: Time.now,
    updated_at: Time.now
  })

  log "  Created object types"

  # Create some patterns for testing - lookup by description (unique)
  patterns = []

  # Clothing patterns (Top category)
  patterns << ensure_model(Pattern, { description: 'A comfortable cotton t-shirt in blue' }, {
    unified_object_type_id: clothing_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  patterns << ensure_model(Pattern, { description: 'A pair of classic black jeans' }, {
    unified_object_type_id: pants_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  patterns << ensure_model(Pattern, { description: 'An elegant red cocktail dress' }, {
    unified_object_type_id: clothing_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  patterns << ensure_model(Pattern, { description: 'Classic white canvas sneakers' }, {
    unified_object_type_id: clothing_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Accessory patterns (Ring category for jewelry)
  patterns << ensure_model(Pattern, { description: 'Stylish aviator sunglasses' }, {
    unified_object_type_id: accessory_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  patterns << ensure_model(Pattern, { description: 'A classic silver wristwatch' }, {
    unified_object_type_id: accessory_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Misc patterns
  patterns << ensure_model(Pattern, { description: 'A leather-bound notebook' }, {
    unified_object_type_id: misc_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  patterns << ensure_model(Pattern, { description: 'A compact black umbrella' }, {
    unified_object_type_id: misc_type.id,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Consumable patterns
  patterns << ensure_model(Pattern, { description: 'A hot cup of coffee' }, {
    unified_object_type_id: consumable_type.id,
    consume_type: 'drink',
    created_at: Time.now,
    updated_at: Time.now
  })

  patterns << ensure_model(Pattern, { description: 'A delicious ham and cheese sandwich' }, {
    unified_object_type_id: consumable_type.id,
    consume_type: 'food',
    created_at: Time.now,
    updated_at: Time.now
  })

  log "  Created #{patterns.size} patterns"

  # ========================================
  # SHOPS
  # ========================================

  log "Creating shops and stocking items..."

  # General Store
  general_shop = ensure_model(Shop, { room_id: general_store.id }, {
    name: 'General Store',
    shopkeeper_name: 'Bob',
    free_items: false,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Stock the general store with misc and consumables
  misc_patterns = patterns.select { |p| p.unified_object_type_id == misc_type.id }
  consumable_patterns = patterns.select { |p| p.unified_object_type_id == consumable_type.id }

  (misc_patterns + consumable_patterns).each do |pattern|
    ensure_model(ShopItem, { shop_id: general_shop.id, pattern_id: pattern.id }, {
      price: rand(10..50),
      stock: -1, # Unlimited
      created_at: Time.now,
      updated_at: Time.now
    })
  end

  log "  Shop: #{general_shop.name} with #{misc_patterns.size + consumable_patterns.size} items"

  # Clothing Boutique
  boutique_shop = ensure_model(Shop, { room_id: boutique.id }, {
    name: 'Fashion Boutique',
    shopkeeper_name: 'Sophia',
    free_items: false,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Stock with clothing and accessories
  clothing_patterns = patterns.select { |p| p.unified_object_type_id == clothing_type.id }
  accessory_patterns = patterns.select { |p| p.unified_object_type_id == accessory_type.id }

  (clothing_patterns + accessory_patterns).each do |pattern|
    ensure_model(ShopItem, { shop_id: boutique_shop.id, pattern_id: pattern.id }, {
      price: rand(25..150),
      stock: rand(5..20),
      created_at: Time.now,
      updated_at: Time.now
    })
  end

  log "  Shop: #{boutique_shop.name} with #{clothing_patterns.size + accessory_patterns.size} items"

  # ========================================
  # TEST CHARACTERS
  # ========================================

  log "Setting up test characters..."

  # Find or create the test agent user/character (should exist from create_test_agent.rb)
  test_user = User.first(username: 'test_agent')
  if test_user
    test_character = test_user.characters.first
    test_instance = test_character&.character_instances&.first

    if test_instance
      # Update location to town square
      test_instance.update(current_room_id: town_square.id)

      # Ensure wallet exists
      ensure_model(Wallet, { character_instance_id: test_instance.id, currency_id: currency.id }, {
        balance: 1000,
        created_at: Time.now,
        updated_at: Time.now
      })

      log "  Updated TestBot Agent: Room #{town_square.name}, Wallet $1000"
    else
      log "  WARNING: TestBot has no character instance"
    end
  else
    log "  WARNING: test_agent user not found - run scripts/create_test_agent.rb first"
  end

  # Create additional test characters

  # Alice - for ownership testing
  alice_user = ensure_model(User, { username: 'alice_test' }, {
    email: 'alice@test.local',
    password_hash: SecureRandom.hex(32),
    salt: SecureRandom.hex(16),
    created_at: Time.now,
    updated_at: Time.now
  })

  alice = ensure_model(Character, { forename: 'Alice', user_id: alice_user.id }, {
    surname: 'Tester',
    short_desc: 'A friendly woman in casual clothes',
    is_npc: false,
    created_at: Time.now,
    updated_at: Time.now
  })

  alice_instance = ensure_model(CharacterInstance, { character_id: alice.id, reality_id: reality.id }, {
    current_room_id: town_square.id,
    online: true,
    status: 'alive',
    stance: 'standing',
    level: 1,
    experience: 0,
    health: 100,
    max_health: 100,
    mana: 50,
    max_mana: 50,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Give Alice a wallet
  ensure_model(Wallet, { character_instance_id: alice_instance.id, currency_id: currency.id }, {
    balance: 500,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Give Alice ownership of her apartment
  alices_apartment.update(owner_id: alice.id)

  log "  Created Alice Tester (owns apartment, $500)"

  # Bob - for interaction testing
  bob_user = ensure_model(User, { username: 'bob_test' }, {
    email: 'bob@test.local',
    password_hash: SecureRandom.hex(32),
    salt: SecureRandom.hex(16),
    created_at: Time.now,
    updated_at: Time.now
  })

  bob = ensure_model(Character, { forename: 'Bob', user_id: bob_user.id }, {
    surname: 'Builder',
    short_desc: 'A sturdy man in work clothes',
    is_npc: false,
    created_at: Time.now,
    updated_at: Time.now
  })

  bob_instance = ensure_model(CharacterInstance, { character_id: bob.id, reality_id: reality.id }, {
    current_room_id: coffee_shop.id,
    online: true,
    status: 'alive',
    stance: 'standing',
    level: 1,
    experience: 0,
    health: 100,
    max_health: 100,
    mana: 50,
    max_mana: 50,
    created_at: Time.now,
    updated_at: Time.now
  })

  # Give Bob a wallet
  ensure_model(Wallet, { character_instance_id: bob_instance.id, currency_id: currency.id }, {
    balance: 250,
    created_at: Time.now,
    updated_at: Time.now
  })

  log "  Created Bob Builder (in coffee shop, $250)"

  # Charlie - NPC shopkeeper
  charlie = ensure_model(Character, { forename: 'Charlie' }, {
    surname: 'Merchant',
    short_desc: 'A cheerful shopkeeper',
    is_npc: true,
    created_at: Time.now,
    updated_at: Time.now
  })

  charlie_instance = ensure_model(CharacterInstance, { character_id: charlie.id, reality_id: reality.id }, {
    current_room_id: general_store.id,
    online: true,
    status: 'alive',
    stance: 'standing',
    level: 5,
    experience: 0,
    health: 100,
    max_health: 100,
    mana: 50,
    max_mana: 50,
    created_at: Time.now,
    updated_at: Time.now
  })

  log "  Created Charlie Merchant (NPC in General Store)"

  # ========================================
  # DROP SOME ITEMS IN ROOMS
  # ========================================

  log "Dropping some items in rooms for pickup testing..."

  # Drop a notebook in the coffee shop
  notebook_pattern = patterns.find { |p| p.name == 'Notebook' }
  if notebook_pattern
    ensure_model(Item, { name: 'a leather notebook', room_id: coffee_shop.id }, {
      description: notebook_pattern.description,
      pattern_id: notebook_pattern.id,
      created_at: Time.now,
      updated_at: Time.now
    })
    log "  Dropped notebook in coffee shop"
  end

  # Drop an umbrella in the town square
  umbrella_pattern = patterns.find { |p| p.name == 'Umbrella' }
  if umbrella_pattern
    ensure_model(Item, { name: 'a black umbrella', room_id: town_square.id }, {
      description: umbrella_pattern.description,
      pattern_id: umbrella_pattern.id,
      created_at: Time.now,
      updated_at: Time.now
    })
    log "  Dropped umbrella in town square"
  end

  # ========================================
  # GAME SETTINGS
  # ========================================

  log "Setting game configuration..."

  # Set era to modern for phone/taxi testing
  GameSetting.set('time_period', 'modern', type: 'string')
  log "  Time period: modern"

  # ========================================
  # SUMMARY
  # ========================================

  log ""
  log "=" * 50
  log "TEST CITY SETUP COMPLETE"
  log "=" * 50
  log ""
  log "Universe: #{universe.name}"
  log "World: #{world.name}"
  log "Area: #{area.name} (#{area.area_type})"
  log "Locations: #{Location.where(zone_id: area.id).count}"
  log "Rooms: #{Room.count}"
  log "Exits: #{RoomExit.count}"
  log "Places: #{Place.count}"
  log "Patterns: #{Pattern.count}"
  log "Shops: #{Shop.count}"
  log "Characters: #{Character.count}"
  log "Spawn Room: #{town_square.name} (ID: #{town_square.id})"
  log ""
  log "Test Characters:"
  log "  - TestBot Agent (test_agent) - Main test agent"
  log "  - Alice Tester (alice_test) - Owns apartment"
  log "  - Bob Builder (bob_test) - In coffee shop"
  log "  - Charlie Merchant (NPC) - In general store"
  log ""
end

log "Setup complete!"
