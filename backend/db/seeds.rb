#!/usr/bin/env ruby
# frozen_string_literal: true

# If DATABASE_URL is set, parse it into DB_HOST/DB_NAME/DB_USER/DB_PASSWORD
# so the app's database.rb picks up the right database.
if ENV['DATABASE_URL'] && !ENV['DATABASE_URL'].empty?
  require 'uri'
  uri = URI.parse(ENV['DATABASE_URL'])
  ENV['DB_HOST'] = uri.host if uri.host
  ENV['DB_NAME'] = uri.path&.sub('/', '') if uri.path && uri.path != '/'
  ENV['DB_USER'] = uri.user if uri.user
  ENV['DB_PASSWORD'] = uri.password if uri.password
end

# Load the full application (sets up DB connection, models, services)
require_relative '../app'

def ensure_record(table_name, unique_attrs, attrs = {})
  dataset = DB[table_name]
  existing = dataset.where(unique_attrs).first
  return existing[:id] if existing

  dataset.insert(unique_attrs.merge(attrs))
end

DB.transaction do
  # ============================================
  # WORLD HIERARCHY
  # ============================================

  reality_id = ensure_record(
    :realities,
    { name: 'Default Reality' },
    {
      description: 'Primary gameplay reality',
      reality_type: 'primary'
    }
  )

  universe_id = ensure_record(
    :universes,
    { name: 'Default Universe' },
    {
      description: 'Universe that hosts the default world hierarchy',
      theme: 'fantasy'
    }
  )

  world_id = ensure_record(
    :worlds,
    { universe_id: universe_id, name: 'Default World' },
    {
      description: 'Starter world for new characters',
      climate: 'temperate',
      gravity_multiplier: 1.0,
      coordinates_x: 0,
      coordinates_y: 0,
      coordinates_z: 0,
      world_size: 1.0
    }
  )

  zone_id = ensure_record(
    :zones,
    { world_id: world_id, name: 'Starting Zone' },
    {
      description: 'Initial zone that anchors the first location',
      danger_level: 1
    }
  )

  location_id = ensure_record(
    :locations,
    { zone_id: zone_id, name: 'Starting Location' },
    {
      description: 'Default entry location for characters',
      location_type: 'outdoor'
    }
  )

  # ============================================
  # BASE ROOMS (Town Square cross pattern)
  # ============================================
  # Rooms are laid out in a cross pattern:
  #   Market (0,100 -> 100,200)
  #        |
  # Temple-Square-Tavern (horizontal at y=0-100)
  #        |
  #    Gate (0,-100 -> 100,0)

  town_square_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'Town Square' },
    {
      short_description: 'The central square of town',
      long_description: 'A bustling town square with cobblestone paths. A fountain sits in the center, and paths lead in all directions.',
      room_type: 'safe',
      safe_room: true,
      min_x: 0, max_x: 100, min_y: 0, max_y: 100
    }
  )

  market_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'Market Street' },
    {
      short_description: 'A busy market street',
      long_description: 'Colorful stalls line both sides of this cobblestone street. Merchants call out their wares while shoppers browse the goods.',
      room_type: 'safe',
      safe_room: true,
      min_x: 0, max_x: 100, min_y: 100, max_y: 200
    }
  )

  tavern_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'The Rusty Tankard' },
    {
      short_description: 'A cozy tavern',
      long_description: 'Warm light spills from the hearth of this well-worn tavern. Wooden tables are scattered about, and the smell of ale and roasted meat fills the air.',
      room_type: 'safe',
      safe_room: true,
      min_x: 100, max_x: 200, min_y: 0, max_y: 100
    }
  )

  temple_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'Temple Gardens' },
    {
      short_description: 'Peaceful temple gardens',
      long_description: 'A serene garden surrounds a small temple. Well-tended flower beds and quiet paths provide a refuge from the bustle of town.',
      room_type: 'safe',
      safe_room: true,
      min_x: -100, max_x: 0, min_y: 0, max_y: 100
    }
  )

  gate_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'Town Gate' },
    {
      short_description: 'The main town gate',
      long_description: 'Massive wooden gates stand open here, guarded by watchful soldiers. Beyond lies the road leading out into the wilderness.',
      room_type: 'safe',
      safe_room: true,
      min_x: 0, max_x: 100, min_y: -100, max_y: 0
    }
  )

  # NOTE: Room exits are now calculated automatically via spatial adjacency
  # Rooms with shared edges are automatically connected
  # The room bounds set above create the following connections:
  #   - Town Square (north) <-> Market Street (south)
  #   - Town Square (east) <-> Tavern (west)
  #   - Town Square (west) <-> Temple (east)
  #   - Town Square (south) <-> Gate (north)

  # ============================================
  # SYSTEM ROOMS (Global singletons)
  # ============================================

  # Staff Room - accessible only to staff characters (isolated, no spatial connections)
  staff_room_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'Staff Room' },
    {
      short_description: 'The staff room',
      long_description: <<~DESC.strip,
        A private space for game staff. This room exists outside the normal game world.

        Staff can use this room to discuss game issues, observe players, and coordinate events.

        Commands available here:
        - TELEPORT <player> - Teleport to a player's location
        - SUMMON <player> - Summon a player here
        - INVISIBLE - Toggle staff invisibility
        - OBSERVE <player> - Watch a player's actions
      DESC
      room_type: 'staff',
      safe_room: true,
      staff_only: true,
      min_x: 1000, max_x: 1100, min_y: 1000, max_y: 1100
    }
  )

  # Death Room (The Void) - where characters go when they die (isolated, no spatial connections)
  death_room_id = ensure_record(
    :rooms,
    { location_id: location_id, name: 'The Void' },
    {
      short_description: 'An endless void',
      long_description: <<~DESC.strip,
        You float in an endless darkness. The world of the living is beyond your reach.

        From here, the mortal realm seems impossibly distant. Your voice cannot reach those who still draw breath.

        You may wait for resurrection, or use REROLL to create a new character and start anew.

        Type REROLL to begin a new life.
      DESC
      room_type: 'death',
      safe_room: true,
      no_ic_communication: true,
      min_x: 2000, max_x: 2100, min_y: 2000, max_y: 2100
    }
  )

  # ============================================
  # DEFAULT STAT BLOCK
  # ============================================

  stat_block_id = ensure_record(
    :stat_blocks,
    { universe_id: universe_id, name: 'Basic Attributes' },
    {
      description: 'Core physical and mental attributes for characters',
      block_type: 'single',
      total_points: 50,
      secondary_points: 0,
      min_stat_value: 1,
      max_stat_value: 10,
      cost_formula: 'doubling_every_other',
      is_default: true,
      is_active: true,
      primary_label: 'Attributes',
      secondary_label: ''
    }
  )

  default_stats = [
    { name: 'Strength', abbreviation: 'STR', description: 'Physical power and carrying capacity' },
    { name: 'Dexterity', abbreviation: 'DEX', description: 'Agility, reflexes, and fine motor control' },
    { name: 'Constitution', abbreviation: 'CON', description: 'Health, stamina, and resistance' },
    { name: 'Intelligence', abbreviation: 'INT', description: 'Reasoning, memory, and knowledge' },
    { name: 'Wisdom', abbreviation: 'WIS', description: 'Perception, intuition, and willpower' }
  ]

  default_stats.each_with_index do |stat_data, index|
    ensure_record(
      :stats,
      { stat_block_id: stat_block_id, name: stat_data[:name] },
      {
        abbreviation: stat_data[:abbreviation],
        description: stat_data[:description],
        stat_category: 'primary',
        display_order: index + 1,
        min_value: 1,
        max_value: 10,
        default_value: 1
      }
    )
  end

  # ============================================
  # GAME SETTINGS
  # ============================================

  ensure_record(
    :game_settings,
    { key: 'test_account_enabled' },
    {
      value: 'true',
      value_type: 'boolean',
      category: 'general',
      description: 'Development mode - enables test account, test API endpoints, and test pages. Disable for production.',
      is_secret: false,
      created_at: Time.now,
      updated_at: Time.now
    }
  )

  ensure_record(
    :game_settings,
    { key: 'ai_battle_maps_enabled' },
    {
      value: 'false',
      value_type: 'boolean',
      category: 'ai',
      description: 'Enable AI-powered battle map generation using Gemini',
      is_secret: false,
      created_at: Time.now,
      updated_at: Time.now
    }
  )

  ensure_record(
    :game_settings,
    { key: 'chapter_ai_titles_enabled' },
    {
      value: 'false',
      value_type: 'boolean',
      category: 'ai',
      description: 'Enable AI-generated chapter titles for character stories',
      is_secret: false,
      created_at: Time.now,
      updated_at: Time.now
    }
  )

  # ============================================
  # COMBAT ABILITIES
  # ============================================

  seed_dir = File.join(__dir__, 'seeds')

  combat_abilities_seed = File.join(seed_dir, 'combat_abilities.rb')
  load combat_abilities_seed if File.exist?(combat_abilities_seed)

  # ============================================
  # WEAPON DAMAGE TYPES
  # ============================================

  weapon_damage_seed = File.join(seed_dir, 'weapon_damage_types.rb')
  load weapon_damage_seed if File.exist?(weapon_damage_seed)

  # ============================================
  # CONTENT RESTRICTIONS
  # ============================================

  content_restrictions_seed = File.join(seed_dir, 'content_restrictions.rb')
  load content_restrictions_seed if File.exist?(content_restrictions_seed)

  # ============================================
  # TUTORIAL UNIVERSE
  # ============================================

  setup_dir = File.join(__dir__, '..', 'scripts', 'setup')

  tutorial_universe_script = File.join(setup_dir, 'tutorial_universe.rb')
  load tutorial_universe_script if File.exist?(tutorial_universe_script)

  # ============================================
  # TUTORIAL SHOPS
  # ============================================

  tutorial_shops_script = File.join(setup_dir, 'tutorial_shops.rb')
  load tutorial_shops_script if File.exist?(tutorial_shops_script)

  # ============================================
  # TEST USER & CHARACTERS
  # ============================================

  test_user = DB[:users].where(username: 'Firefly_Test').first
  unless test_user
    test_user = User.create(
      username: 'Firefly_Test',
      email: 'test@firefly.local',
      active: true,
      is_admin: true,
      is_test_account: true
    )
    test_user.set_password('firefly_test_2024')
    test_user.save

    puts "\nCreated test user: Firefly_Test (admin)"
    puts "  Password: firefly_test_2024"

    # Create two test characters for the test user
    char1 = Character.create(
      name: 'TestChar1',
      forename: 'TestChar1',
      user_id: test_user.id
    )

    char2 = Character.create(
      name: 'TestChar2',
      forename: 'TestChar2',
      user_id: test_user.id
    )

    # Create character instances in town square
    ci1 = CharacterInstance.create(
      character_id: char1.id,
      current_room_id: town_square_id,
      reality_id: reality_id
    )

    ci2 = CharacterInstance.create(
      character_id: char2.id,
      current_room_id: town_square_id,
      reality_id: reality_id
    )

    puts "  Characters: #{char1.name}, #{char2.name}"

    # Create API token for MCP testing
    token = test_user.generate_api_token!
    puts "  API Token: #{token}"
    puts "  (Add this to .env as FIREFLY_API_TOKEN for MCP testing)"
  end

  # ============================================
  # DECK PATTERNS (Card Game System)
  # ============================================

  unless DB[:deck_patterns].where(name: 'Standard Playing Cards').first
    admin_character = Character.first
    if admin_character
      puts 'Creating deck patterns...'

      standard = DeckPattern.first(name: 'Standard Playing Cards') ||
                 DeckPattern.create_standard_deck(creator: admin_character)
      standard.update(is_public: true) unless standard.is_public

      jokers = DeckPattern.first(name: 'Standard Playing Cards (with Jokers)') ||
               DeckPattern.create_standard_deck_with_jokers(creator: admin_character)
      jokers.update(is_public: true) unless jokers.is_public

      tarot = DeckPattern.first(name: 'Tarot Deck') ||
              DeckPattern.create_tarot_deck(creator: admin_character)
      tarot.update(is_public: true) unless tarot.is_public

      puts "  Standard deck: #{standard.card_count} cards"
      puts "  Jokers deck: #{jokers.card_count} cards"
      puts "  Tarot deck: #{tarot.card_count} cards"
    else
      puts 'Skipping deck patterns: No characters exist yet'
    end
  end

  # ============================================
  # HELP FILES
  # ============================================

  helpfile_descriptions_seed = File.join(seed_dir, 'helpfile_descriptions.rb')
  if File.exist?(helpfile_descriptions_seed)
    puts "\n"
    load helpfile_descriptions_seed
  end

  # ============================================
  # ACTIVITY GAME SETTINGS
  # ============================================

  activity_settings_seed = File.join(seed_dir, 'activity_game_settings.rb')
  load activity_settings_seed if File.exist?(activity_settings_seed)

  # ============================================
  # SYSTEM DOCUMENTATION
  # ============================================

  system_docs_script = File.join(setup_dir, 'seed_system_documentation.rb')
  load system_docs_script if File.exist?(system_docs_script)

  # ============================================
  # ROOM TEMPLATES
  # ============================================

  room_templates_script = File.join(setup_dir, 'seed_room_templates.rb')
  load room_templates_script if File.exist?(room_templates_script)

  # ============================================
  # BATTLE MAP TEMPLATES
  # ============================================

  battle_map_templates_seed = File.join(seed_dir, 'battle_map_templates.rb')
  load battle_map_templates_seed if File.exist?(battle_map_templates_seed)
end

puts "\n"
puts 'Default world data seeded successfully.'
puts "  Staff Room ID: #{DB[:rooms].first(name: 'Staff Room')&.[](:id)}"
puts "  Death Room ID: #{DB[:rooms].first(name: 'The Void')&.[](:id)}"
puts "  Default Stat Block: #{DB[:stat_blocks].first(name: 'Basic Attributes')&.[](:name)}"
puts "  Stats: #{DB[:stats].where(stat_block_id: DB[:stat_blocks].first(name: 'Basic Attributes')&.[](:id)).select_map(:abbreviation).join(', ')}"
puts "  AI Battle Maps: #{DB[:game_settings].first(key: 'ai_battle_maps_enabled')&.[](:value)}"
puts "  AI Chapter Titles: #{DB[:game_settings].first(key: 'chapter_ai_titles_enabled')&.[](:value)}"
