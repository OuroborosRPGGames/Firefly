# frozen_string_literal: true

# Tutorial Universe Setup Script
# Creates the tutorial universe with newbie school and mall rooms.
# This script is idempotent - safe to run multiple times.

require_relative '../../app'
require_relative 'helpers'
include SetupHelpers

log 'Creating Tutorial Universe...'

DB.transaction do
  # ============================================
  # TUTORIAL UNIVERSE HIERARCHY
  # ============================================

  # Create Tutorial Universe
  tutorial_universe_id = ensure_record(
    :universes,
    { name: 'Tutorial' },
    {
      description: 'Tutorial universe for new players to learn game mechanics.',
      theme: 'modern'
    }
  )
  log "  Universe: Tutorial (ID: #{tutorial_universe_id})"

  # Create Tutorial World
  tutorial_world_id = ensure_record(
    :worlds,
    { universe_id: tutorial_universe_id, name: 'Tutorial World' },
    {
      description: 'A learning environment for new players.',
      climate: 'temperate',
      gravity_multiplier: 1.0,
      coordinates_x: 0,
      coordinates_y: 0,
      coordinates_z: 0,
      world_size: 100.0
    }
  )
  log "  World: Tutorial World (ID: #{tutorial_world_id})"

  # Create Newbie School Zone
  newbie_school_zone_id = ensure_record(
    :zones,
    { world_id: tutorial_world_id, name: 'Newbie School' },
    {
      description: 'The orientation center for new players.',
      zone_type: 'city',
      danger_level: 0
    }
  )
  log "  Zone: Newbie School (ID: #{newbie_school_zone_id})"

  # Create Newbie School Location
  newbie_school_location_id = ensure_record(
    :locations,
    { zone_id: newbie_school_zone_id, name: 'Newbie School Building' },
    {
      description: 'The main building of the newbie orientation center.',
      location_type: 'building'
    }
  )
  log "  Location: Newbie School Building (ID: #{newbie_school_location_id})"

  # ============================================
  # TUTORIAL ROOMS
  # ============================================

  # Room 1: Looking and Moving (SPAWN ROOM)
  looking_moving_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Looking and Moving' },
    {
      short_description: 'The first room of the newbie orientation.',
      long_description: <<~DESC.strip,
        Welcome to the game! This is where you'll learn the basics of navigation and observation.

        To look around your environment, use the <b>look</b> command. Without arguments, it shows the current room. You can also use <b>look self</b> to see your character, or <b>look &lt;thing&gt;</b> to examine specific things.

        To move around, just type a direction: <b>north</b>, <b>south</b>, <b>east</b>, <b>west</b> (or <b>n</b>, <b>s</b>, <b>e</b>, <b>w</b> for short). Use <b>exits</b> to see which directions are available.

        You can also use <b>walk &lt;name&gt;</b> to walk toward a named room or person.

        When you're ready, head <b>north</b> to continue to the next room.
      DESC
      room_type: 'safe',
      safe_room: true
    }
  )
  log "  Room: Looking and Moving (ID: #{looking_moving_id}) [SPAWN]"

  # Set this as the tutorial spawn room via GameSetting
  GameSetting.set('tutorial_spawn_room_id', looking_moving_id, type: 'integer')
  log "  GameSetting: tutorial_spawn_room_id = #{looking_moving_id}"

  # Room 2: Getting Help
  getting_help_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Getting Help' },
    {
      short_description: 'Learn how to get help and information.',
      long_description: <<~DESC.strip,
        The <b>help</b> command is your guide to all game systems.

        Use <b>help &lt;command&gt;</b> for specific help (e.g. <b>help look</b>, <b>help emote</b>).

        Got a question? Type <b>help &lt;question&gt;?</b> for an AI-powered answer (e.g. <b>help how do I buy things?</b>). The question mark at the end triggers the AI helper.

        Use <b>helpsearch &lt;keyword&gt;</b> to search all help topics, <b>help systems</b> for system overviews, or <b>commands</b> to list all available commands.

        For live help, use <b>channel newbie &lt;message&gt;</b> (or the shorthand <b>+ &lt;message&gt;</b>) to chat on the newbie channel. Other players are often happy to help!

        Head <b>north</b> to continue learning about roleplaying.
      DESC
      room_type: 'safe',
      safe_room: true
    }
  )
  log "  Room: Getting Help (ID: #{getting_help_id})"

  # Room 3: Roleplaying
  roleplaying_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Roleplaying' },
    {
      short_description: 'Learn the art of roleplay.',
      long_description: <<~DESC.strip,
        This game is a roleplaying environment. Everything you do in the game world is considered "in character" (IC).

        The <b>emote</b> command lets you describe your character's actions. For example:
        <i>emote stretches and yawns, looking tired.</i>

        The <b>say</b> command is for speaking:
        <i>say Hello, nice to meet you!</i>
        You can also use the shorthand: <b>"Hello, nice to meet you!</b>

        The <b>attempt</b> command is for actions that affect other characters. It asks for their consent before proceeding:
        <i>attempt shakes hands with John.</i>

        Remember: Don't write what happens to other characters - let them react!

        Head <b>north</b> to learn about character customization.
      DESC
      room_type: 'safe',
      safe_room: true
    }
  )
  log "  Room: Roleplaying (ID: #{roleplaying_id})"

  # Room 4: Customizing Your Character
  customizing_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Customizing Your Character' },
    {
      short_description: 'Personalize your character.',
      long_description: <<~DESC.strip,
        Your character is yours to customize! Here are some ways to personalize them:

        Use <b>profile</b> to view and edit your character's public profile, including pictures and background information.

        You can create multiple <b>outfit</b> configurations to switch between different looks. Use <b>help outfit</b> for more details.

        Use <b>wear &lt;item&gt;</b> and <b>remove &lt;item&gt;</b> to manage your clothing. The free shops ahead in the Newbie Mall have everything you need to get started!

        Head <b>north</b> to enter the Newbie Mall and get some starting clothes!
      DESC
      room_type: 'safe',
      safe_room: true
    }
  )
  log "  Room: Customizing Your Character (ID: #{customizing_id})"

  # Room 5: Newbie Mall (Hub for shops)
  newbie_mall_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Newbie Mall' },
    {
      short_description: 'A shopping center for new players.',
      long_description: <<~DESC.strip,
        Welcome to the Newbie Mall! Here you can get free starting clothes and equipment.

        The mall has several shops you can enter:
        - <b>Underwear Shop</b> - undergarments and swimwear
        - <b>Bottoms Shop</b> - pants, skirts, shorts
        - <b>Tops Shop</b> - shirts, blouses, dresses
        - <b>Footwear Shop</b> - shoes, boots, socks
        - <b>Outerwear Shop</b> - coats, jackets, cloaks
        - <b>Equipment Shop</b> - weapons, armor, accessories

        Type <b>enter [shop name]</b> to browse a shop (e.g., <b>enter tops shop</b>).
        Inside each shop, use <b>list</b> to see items, <b>preview [item]</b> for details, and <b>buy [item]</b> to purchase.
        Use <b>store [item]</b> to save items for later - all shops here serve as stash locations!

        Items here are <b>free</b>! Once you enter the main game, you'll need money for purchases.

        When you're dressed and ready, head <b>north</b> to the Exit Hall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true
    }
  )
  log "  Room: Newbie Mall (ID: #{newbie_mall_id})"

  # ============================================
  # SHOP ROOMS (inside the Newbie Mall)
  # ============================================

  # Underwear Shop
  underwear_shop_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Underwear Shop' },
    {
      short_description: 'A shop selling undergarments and swimwear.',
      long_description: <<~DESC.strip,
        Welcome to the Underwear Shop! Here you'll find undergarments and swimwear.

        Use <b>list</b> to see available items.
        Use <b>preview [item name]</b> to see details about an item.
        Use <b>buy [item name]</b> to purchase an item.
        Use <b>wear [item name]</b> to put on an item you've bought.
        Use <b>store [item name]</b> to save an item for later.

        All items here are free! Type <b>leave</b> to return to the mall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true,
      inside_room_id: newbie_mall_id
    }
  )
  log "  Room: Underwear Shop (ID: #{underwear_shop_id}) [inside mall]"

  # Bottoms Shop
  bottoms_shop_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Bottoms Shop' },
    {
      short_description: 'A shop selling pants, skirts, and shorts.',
      long_description: <<~DESC.strip,
        Welcome to the Bottoms Shop! Here you'll find pants, skirts, shorts, and other lower-body clothing.

        Use <b>list</b> to see available items.
        Use <b>preview [item name]</b> to see details about an item.
        Use <b>buy [item name]</b> to purchase an item.

        All items here are free! Type <b>leave</b> to return to the mall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true,
      inside_room_id: newbie_mall_id
    }
  )
  log "  Room: Bottoms Shop (ID: #{bottoms_shop_id}) [inside mall]"

  # Tops Shop
  tops_shop_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Tops Shop' },
    {
      short_description: 'A shop selling shirts, dresses, and upper-body clothing.',
      long_description: <<~DESC.strip,
        Welcome to the Tops Shop! Here you'll find shirts, blouses, dresses, and full-body outfits.

        Use <b>list</b> to see available items.
        Use <b>preview [item name]</b> to see details about an item.
        Use <b>buy [item name]</b> to purchase an item.

        All items here are free! Type <b>leave</b> to return to the mall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true,
      inside_room_id: newbie_mall_id
    }
  )
  log "  Room: Tops Shop (ID: #{tops_shop_id}) [inside mall]"

  # Footwear Shop
  footwear_shop_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Footwear Shop' },
    {
      short_description: 'A shop selling shoes, boots, and socks.',
      long_description: <<~DESC.strip,
        Welcome to the Footwear Shop! Here you'll find shoes, boots, sandals, socks, and other footwear.

        Use <b>list</b> to see available items.
        Use <b>preview [item name]</b> to see details about an item.
        Use <b>buy [item name]</b> to purchase an item.

        All items here are free! Type <b>leave</b> to return to the mall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true,
      inside_room_id: newbie_mall_id
    }
  )
  log "  Room: Footwear Shop (ID: #{footwear_shop_id}) [inside mall]"

  # Outerwear Shop
  outerwear_shop_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Outerwear Shop' },
    {
      short_description: 'A shop selling coats, jackets, and outer layers.',
      long_description: <<~DESC.strip,
        Welcome to the Outerwear Shop! Here you'll find coats, jackets, cloaks, and other outerwear.

        Use <b>list</b> to see available items.
        Use <b>preview [item name]</b> to see details about an item.
        Use <b>buy [item name]</b> to purchase an item.

        All items here are free! Type <b>leave</b> to return to the mall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true,
      inside_room_id: newbie_mall_id
    }
  )
  log "  Room: Outerwear Shop (ID: #{outerwear_shop_id}) [inside mall]"

  # Equipment Shop (weapons, armor, accessories)
  equipment_shop_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Equipment Shop' },
    {
      short_description: 'A shop selling weapons, armor, and accessories.',
      long_description: <<~DESC.strip,
        Welcome to the Equipment Shop! Here you'll find weapons, armor, bags, and accessories.

        Use <b>list</b> to see available items.
        Use <b>preview [item name]</b> to see details about an item.
        Use <b>buy [item name]</b> to purchase an item.
        Use <b>store [item name]</b> to save items in your personal stash.

        All items here are free! Type <b>leave</b> to return to the mall.
      DESC
      room_type: 'shop',
      safe_room: true,
      is_vault: true,
      inside_room_id: newbie_mall_id
    }
  )
  log "  Room: Equipment Shop (ID: #{equipment_shop_id}) [inside mall]"

  # Room 6: Exit Hall
  exit_hall_id = ensure_record(
    :rooms,
    { location_id: newbie_school_location_id, name: 'Exit Hall' },
    {
      short_description: 'The final room before entering the game world.',
      long_description: <<~DESC.strip,
        Congratulations! You've completed the tutorial!

        From here, you can enter the main game world. Here are some final tips:

        - Type <b>enter game</b> to leave the tutorial and start playing.
        - Type <b>home</b> anytime to return to your personal space.
        - Use <b>channel newbie &lt;message&gt;</b> (or <b>+ &lt;message&gt;</b>) if you have questions.

        If you need to go back and review anything, head <b>south</b> to return to the Newbie Mall.

        Good luck, and have fun!
      DESC
      room_type: 'safe',
      safe_room: true
    }
  )
  log "  Room: Exit Hall (ID: #{exit_hall_id})"

  # ============================================
  # ROOM SPATIAL LAYOUT
  # ============================================
  # ROOM SPATIAL LAYOUT
  # ============================================
  # Note: The game uses spatial adjacency for navigation.
  # Rooms are arranged vertically with polygon bounds that share edges.
  # Room layout: Looking and Moving (south) -> Getting Help -> Roleplaying ->
  #              Customizing -> Newbie Mall (with shops inside) -> Exit Hall (north)

  log '  Setting up room spatial layout...'

  # Helper to set room bounds (rooms are 20x20 feet by default)
  room_size = 20

  # Arrange tutorial rooms in a north-south chain
  # The Newbie Mall is larger (40x40) to visually distinguish it on the minimap
  tutorial_rooms = [
    # [room_id, min_x, min_y, max_x, max_y]
    [looking_moving_id, 0, 0, 20, 20],        # Start room at origin
    [getting_help_id, 0, 20, 20, 40],         # North of start
    [roleplaying_id, 0, 40, 20, 60],          # Further north
    [customizing_id, 0, 60, 20, 80],          # Further north
    [newbie_mall_id, -10, 80, 30, 120],       # Mall - 40x40 (wider + taller)
    [exit_hall_id, 0, 120, 20, 140]           # Exit hall below expanded mall
  ]

  tutorial_rooms.each do |room_id, min_x, min_y, max_x, max_y|
    DB[:rooms].where(id: room_id).update(
      min_x: min_x, min_y: min_y, min_z: 0,
      max_x: max_x, max_y: max_y, max_z: 10
    )
  end

  # ============================================
  # SHOP SPATIAL LAYOUT (inside the mall)
  # ============================================
  # Shops are spatially contained within the mall bounds (-10,80 to 30,120)
  # Arranged in a 2x3 grid - players can "walk [shop name]" to enter
  #
  # Layout (each shop 15x10 feet):
  #   Row 3 (y=109-119): Outerwear | Equipment
  #   Row 2 (y=96-106):  Tops      | Footwear
  #   Row 1 (y=83-93):   Underwear | Bottoms
  #
  log '  Setting up shop spatial layout inside mall...'

  shop_rooms = [
    # [room_id, min_x, min_y, max_x, max_y] - all within mall bounds
    [underwear_shop_id, -7, 83, 8, 93],     # Bottom-left
    [bottoms_shop_id, 12, 83, 27, 93],      # Bottom-right
    [tops_shop_id, -7, 96, 8, 106],         # Middle-left
    [footwear_shop_id, 12, 96, 27, 106],    # Middle-right
    [outerwear_shop_id, -7, 109, 8, 119],   # Top-left
    [equipment_shop_id, 12, 109, 27, 119]   # Top-right
  ]

  shop_rooms.each do |room_id, min_x, min_y, max_x, max_y|
    DB[:rooms].where(id: room_id).update(
      min_x: min_x, min_y: min_y, min_z: 0,
      max_x: max_x, max_y: max_y, max_z: 10
    )
  end

  log '  Shop spatial layout configured (6 shops inside mall).'

  # ============================================
  # SHOP RECORDS (for the shop command)
  # ============================================
  # The shop command requires a Shop model record associated with each room.
  # These are free shops (free_items: true) for the tutorial.

  log '  Creating shop records...'

  shop_configs = [
    { room_id: underwear_shop_id, name: 'Underwear Shop', category: 'undergarments' },
    { room_id: bottoms_shop_id, name: 'Bottoms Shop', category: 'pants' },
    { room_id: tops_shop_id, name: 'Tops Shop', category: 'shirts' },
    { room_id: footwear_shop_id, name: 'Footwear Shop', category: 'footwear' },
    { room_id: outerwear_shop_id, name: 'Outerwear Shop', category: 'outerwear' },
    { room_id: equipment_shop_id, name: 'Equipment Shop', category: 'equipment' }
  ]

  shop_configs.each do |config|
    existing_shop = Shop.first(room_id: config[:room_id])
    if existing_shop
      log "    Shop already exists for #{config[:name]} (ID: #{existing_shop.id})"
    else
      shop = Shop.create(
        room_id: config[:room_id],
        name: config[:name],
        is_open: true,
        free_items: true  # All items are free in tutorial shops
      )
      log "    Created Shop: #{config[:name]} (ID: #{shop.id})"
    end
  end

  log '  Shop records created.'

  # ============================================
  # SHOP ITEM STOCKING
  # ============================================
  # Stock each shop with appropriate patterns based on UnifiedObjectType
  # Items are free (price: 0) and unlimited stock (stock: -1)

  log '  Stocking shops with items...'

  # Map unified object type IDs to shop categories
  # Based on UnifiedObjectType names from the database
  shop_type_mappings = {
    underwear_shop_id => [
      35, 36, 37, 38, 39, 40, 41,  # Briefs, Boxers, Boxer-briefs, Panties, Thong, G-string, Boyshorts
      190, 191, 192, 193           # Bra, Sports Bra, Bustier, Corset
    ],
    bottoms_shop_id => [
      24, 25, 26, 27, 28,          # Slacks, Jeans, Long Shorts, Shorts, Booty Shorts
      85, 86, 87, 88, 89, 90, 91, 92, 93, 94,  # Skirts (various lengths/styles)
      42, 43, 44, 45, 46           # Stockings, Pantyhose, Leggings
    ],
    tops_shop_id => [
      98, 99, 100, 101, 102, 103, 104, 105, 106,  # Shirts, tops
      114, 115, 116, 117,          # T-shirt, Vest, Button Down
      107, 108, 109, 110, 111, 112, 113,  # Minidresses
      118, 119, 120, 121, 122, 123, 124, 125, 126  # Knee/Ankle dresses
    ],
    footwear_shop_id => [
      67, 68, 69, 70, 71, 72, 73, 74, 75,  # Sneakers, Flats, Sandals, Pumps, Boots
      50, 51, 52                    # Socks, Over-knee Socks, Thigh-high Socks
    ],
    outerwear_shop_id => [
      17, 18, 19, 20, 21, 22, 23,  # Coats, Blazer, Jackets, Hoodie, Sweater
      95, 96                        # Gloves, Elbow-length Gloves
    ],
    equipment_shop_id => [
      61, 62, 63, 76,              # Purses, Messenger Bag, Backpack
      77, 78, 79,                  # Bandolier, Boot Sheath, Thigh Holster
      82, 83, 84,                  # Hats (Fedora, Baseball Cap, Cowboy Hat)
      80, 81, 97                   # Necktie, Scarf, Belt
    ]
  }

  items_stocked = 0
  shop_type_mappings.each do |shop_room_id, type_ids|
    shop = Shop.first(room_id: shop_room_id)
    next unless shop

    type_ids.each do |type_id|
      # Find patterns with this unified_object_type_id
      patterns = Pattern.where(unified_object_type_id: type_id).all
      patterns.each do |pattern|
        # Skip if already stocked
        next if ShopItem.first(shop_id: shop.id, pattern_id: pattern.id)

        ShopItem.create(
          shop_id: shop.id,
          pattern_id: pattern.id,
          price: 0,      # Free for tutorial
          stock: -1      # Unlimited stock
        )
        items_stocked += 1
      end
    end
  end

  log "  Stocked #{items_stocked} items across 6 shops."

  # ============================================
  # SUMMARY
  # ============================================

  log ''
  log 'Tutorial Universe setup complete!'
  log "  - 1 Universe: Tutorial"
  log "  - 1 World: Tutorial World"
  log "  - 1 Zone: Newbie School"
  log "  - 1 Location: Newbie School Building"
  log "  - 12 Rooms: 6 tutorial + 6 shops"
  log "  - Spawn room: Looking and Moving (ID: #{looking_moving_id})"
end
