# frozen_string_literal: true

#!/usr/bin/env ruby

require 'csv'
require 'sequel'

# Connect to the Firefly database
DB = Sequel.connect(
  adapter: 'postgres',
  host: 'localhost',
  database: 'firefly',
  user: 'prom_user',
  password: 'prom_password'
)

# Load models
require_relative '../app/models/universe'
require_relative '../app/models/world'
require_relative '../app/models/area'
require_relative '../app/models/room'
require_relative '../app/models/body_position'
require_relative '../app/models/unified_object_type'
require_relative '../app/models/pattern'

puts "🚀 Initializing new game with standard data..."

# Helper method to handle empty CSV fields
def empty_to_nil(value)
  return nil if value.nil? || value.empty?
  value
end

# Data directory path
data_dir = File.join(__dir__, '../data/initial_data')

# Initialize body positions from CSV
puts "📋 Loading body positions..."
body_position_count = 0
CSV.foreach(File.join(data_dir, 'body_positions.csv'), headers: true) do |row|
  existing = BodyPosition.find(id: row['id'].to_i)
  next if existing
  
  BodyPosition.unrestrict_primary_key
  BodyPosition.create(
    id: row['id'].to_i,
    label: row['label'],
    created_at: Time.parse(row['created_at']),
    updated_at: Time.parse(row['updated_at'])
  )
  body_position_count += 1
end
puts "✅ Created #{body_position_count} body positions"

# Initialize unified object types from CSV
puts "📋 Loading unified object types..."
object_type_count = 0
CSV.foreach(File.join(data_dir, 'unified_object_types.csv'), headers: true) do |row|
  existing = UnifiedObjectType.find(id: row['id'].to_i)
  next if existing
  
  UnifiedObjectType.unrestrict_primary_key
  UnifiedObjectType.create(
    id: row['id'].to_i,
    name: row['name'],
    category: row['category'],
    subcategory: empty_to_nil(row['subcategory']),
    source_table: row['source_table'],
    source_id: row['source_id'].to_i,
    layer: empty_to_nil(row['layer'])&.to_i,
    sheer: row['sheer'] == 'true',
    dorder: empty_to_nil(row['dorder'])&.to_i,
    # Covered positions (bone fields)
    covered_position_1: empty_to_nil(row['covered_position_1']),
    covered_position_2: empty_to_nil(row['covered_position_2']),
    covered_position_3: empty_to_nil(row['covered_position_3']),
    covered_position_4: empty_to_nil(row['covered_position_4']),
    covered_position_5: empty_to_nil(row['covered_position_5']),
    covered_position_6: empty_to_nil(row['covered_position_6']),
    covered_position_7: empty_to_nil(row['covered_position_7']),
    covered_position_8: empty_to_nil(row['covered_position_8']),
    covered_position_9: empty_to_nil(row['covered_position_9']),
    covered_position_10: empty_to_nil(row['covered_position_10']),
    covered_position_11: empty_to_nil(row['covered_position_11']),
    covered_position_12: empty_to_nil(row['covered_position_12']),
    covered_position_13: empty_to_nil(row['covered_position_13']),
    covered_position_14: empty_to_nil(row['covered_position_14']),
    covered_position_15: empty_to_nil(row['covered_position_15']),
    covered_position_16: empty_to_nil(row['covered_position_16']),
    covered_position_17: empty_to_nil(row['covered_position_17']),
    covered_position_18: empty_to_nil(row['covered_position_18']),
    covered_position_19: empty_to_nil(row['covered_position_19']),
    covered_position_20: empty_to_nil(row['covered_position_20']),
    # Zone fields (zippable positions)
    zone_1: empty_to_nil(row['zone_1']),
    zone_2: empty_to_nil(row['zone_2']),
    zone_3: empty_to_nil(row['zone_3']),
    zone_4: empty_to_nil(row['zone_4']),
    zone_5: empty_to_nil(row['zone_5']),
    zone_6: empty_to_nil(row['zone_6']),
    zone_7: empty_to_nil(row['zone_7']),
    zone_8: empty_to_nil(row['zone_8']),
    zone_9: empty_to_nil(row['zone_9']),
    zone_10: empty_to_nil(row['zone_10']),
    created_at: Time.parse(row['created_at']),
    updated_at: Time.parse(row['updated_at'])
  )
  object_type_count += 1
end
puts "✅ Created #{object_type_count} unified object types"

# Initialize patterns from CSV
puts "📋 Loading patterns..."
pattern_count = 0
CSV.foreach(File.join(data_dir, 'patterns.csv'), headers: true) do |row|
  existing = Pattern.find(id: row['id'].to_i)
  next if existing
  
  Pattern.unrestrict_primary_key
  Pattern.create(
    id: row['id'].to_i,
    unified_object_type_id: empty_to_nil(row['unified_object_type_id'])&.to_i,
    description: row['description'],
    source_table: row['source_table'],
    source_id: row['source_id'].to_i,
    created_by: empty_to_nil(row['created_by'])&.to_i,
    price: empty_to_nil(row['price'])&.to_f || 0,
    last_used: empty_to_nil(row['last_used'])&.then { |d| Time.parse(d) },
    magic_type: empty_to_nil(row['magic_type']),
    min_year: empty_to_nil(row['min_year'])&.to_i,
    max_year: empty_to_nil(row['max_year'])&.to_i,
    desc_type: empty_to_nil(row['desc_type']),
    desc_desc: empty_to_nil(row['desc_desc']),
    sheer: row['sheer'] == 'true',
    container: row['container'] == 'true',
    arev_one: empty_to_nil(row['arev_one']),
    arev_two: empty_to_nil(row['arev_two']),
    acon_one: empty_to_nil(row['acon_one']),
    acon_two: empty_to_nil(row['acon_two']),
    stone: empty_to_nil(row['stone']),
    metal: empty_to_nil(row['metal']),
    handle_desc: empty_to_nil(row['handle_desc']),
    created_at: Time.parse(row['created_at']),
    updated_at: Time.parse(row['updated_at'])
  )
  pattern_count += 1
end
puts "✅ Created #{pattern_count} patterns"

# Set weapon flags on patterns based on unified_object_type category
puts "🗡️ Setting weapon flags on patterns..."
weapon_categories = {
  'Knife'   => { is_melee: true, weapon_range: 'melee', damage_type: 'slashing', attack_speed: 6 },
  'Sword'   => { is_melee: true, weapon_range: 'melee', damage_type: 'slashing', attack_speed: 5 },
  'Firearm' => { is_ranged: true, weapon_range: 'short', damage_type: 'piercing', attack_speed: 4 }
}

weapon_count = 0
weapon_categories.each do |category, attrs|
  uot_ids = UnifiedObjectType.where(category: category).select_map(:id)
  next if uot_ids.empty?

  # Override range for rifles
  if category == 'Firearm'
    rifle_ids = UnifiedObjectType.where(category: category, name: 'Rifle').select_map(:id)
    if rifle_ids.any?
      count = Pattern.where(unified_object_type_id: rifle_ids, is_ranged: false)
                     .update(attrs.merge(weapon_range: 'long', attack_speed: 2))
      weapon_count += count
      uot_ids -= rifle_ids
    end
  end

  # Two-handed swords are slower
  if category == 'Sword'
    two_hand_ids = UnifiedObjectType.where(category: category, name: 'Two-Handed Sword').select_map(:id)
    if two_hand_ids.any?
      melee_field = attrs[:is_melee] ? :is_melee : :is_ranged
      count = Pattern.where(unified_object_type_id: two_hand_ids, melee_field => false)
                     .update(attrs.merge(attack_speed: 3))
      weapon_count += count
      uot_ids -= two_hand_ids
    end
  end

  melee_field = attrs[:is_melee] ? :is_melee : :is_ranged
  count = Pattern.where(unified_object_type_id: uot_ids, melee_field => false).update(attrs)
  weapon_count += count
end
puts "✅ Updated #{weapon_count} weapon patterns"

# Create the standard three universes
puts "🌌 Creating standard universes..."

# Out of Character Universe
ooc_universe = Universe.find(name: "Out of Character")
if ooc_universe.nil?
  ooc_universe = Universe.create(
    name: "Out of Character",
    description: "The out-of-character areas for player discussion and administration.",
    theme: "modern"
  )
end

# OOC World
ooc_world = World.find(universe: ooc_universe, name: "OOC World")
if ooc_world.nil?
  ooc_world = World.create(
    universe: ooc_universe,
    name: "OOC World",
    description: "General out-of-character areas.",
    gravity_multiplier: 1.0,
    coordinates_x: 0,
    coordinates_y: 0,
    coordinates_z: 0
  )
end

# OOC Areas
ooc_lounge_area = Area.create(
  world: ooc_world,
  name: "Player Lounge",
  description: "A comfortable space for players to chat out of character.",
  area_type: "city",
  danger_level: 1
)

admin_area = Area.create(
  world: ooc_world,
  name: "Administrative Area", 
  description: "Restricted area for game administration.",
  area_type: "city",
  danger_level: 1
)

# OOC Locations
ooc_lounge_location = Location.create(
  area: ooc_lounge_area,
  name: "Player Lounge Building",
  description: "The building housing the player lounge.",
  location_type: "building"
)

admin_location = Location.create(
  area: admin_area,
  name: "Administrative Building",
  description: "The building housing administrative offices.",
  location_type: "building"
)

# OOC Rooms
Room.create(
  location: ooc_lounge_location,
  name: "Player Lounge",
  short_description: "A welcoming lounge for new and veteran players alike.",
  long_description: "This comfortable lounge features soft seating arranged around low tables, with large windows offering views of the game worlds beyond. Bulletin boards line the walls with helpful information for new players, while experienced gamers share stories and advice. The atmosphere is friendly and welcoming, making it the perfect place to meet other players and get oriented to the game.",
  room_type: "safe"
)

Room.create(
  location: admin_location,
  name: "Admin Office",
  short_description: "The central administrative office.",
  long_description: "A professional office space with modern furnishings and multiple monitors displaying game statistics and player activity. Filing cabinets contain important game documentation, while comfortable chairs are arranged for meetings and discussions. This is where the game administrators coordinate their efforts to maintain and improve the gaming experience.",
  room_type: "standard"
)

# In Character Universe
ic_universe = Universe.find(name: "In Character")
if ic_universe.nil?
  ic_universe = Universe.create(
    name: "In Character", 
    description: "The main roleplaying universe where most game action takes place.",
    theme: "fantasy"
  )
end

# IC World
ic_world = World.create(
  universe: ic_universe,
  name: "Main World",
  description: "The primary world for roleplaying adventures.",
  gravity_multiplier: 1.0,
  coordinates_x: 2,
  coordinates_y: 0,
  coordinates_z: 0
)

# IC Areas
starting_area = Area.create(
  world: ic_world,
  name: "Starting Town",
  description: "A small, peaceful town where new adventurers begin their journeys.",
  area_type: "city",
  danger_level: 1,
  min_longitude: -122.5,
  max_longitude: -122.3,
  min_latitude: 37.7,
  max_latitude: 37.9
)

market_area = Area.create(
  world: ic_world,
  name: "Town Market",
  description: "The bustling commercial heart of the starting town.",
  area_type: "city",
  danger_level: 1,
  min_longitude: -122.3,
  max_longitude: -122.1,
  min_latitude: 37.7,
  max_latitude: 37.9
)

# IC Locations
town_center_location = Location.create(
  area: starting_area,
  name: "Town Center",
  description: "The central area of the starting town.",
  location_type: "outdoor"
)

market_location = Location.create(
  area: market_area,
  name: "Market District",
  description: "The commercial district of the town.",
  location_type: "outdoor"
)

# IC Rooms  
town_square = Room.create(
  location: town_center_location,
  name: "Town Square",
  short_description: "The central square of a peaceful starting town.",
  long_description: "This pleasant town square serves as the heart of the community, with a decorative fountain at its center surrounded by well-maintained flower beds. Cobblestone paths radiate outward toward various shops and services, while wooden benches provide places for residents and visitors to rest. The square buzzes with friendly activity as people go about their daily business, creating a welcoming atmosphere for newcomers.",
  room_type: "safe"
)

Room.create(
  location: market_location,
  name: "Market Square",
  short_description: "A busy marketplace filled with merchants and shoppers.",
  long_description: "The market square comes alive with the sounds of commerce - vendors calling out their wares, customers haggling over prices, and the general bustle of a thriving marketplace. Colorful stalls line the square selling everything from fresh produce to handcrafted goods, while permanent shops with large windows display more expensive items. The cobblestone ground shows wear from countless feet, and the air carries a mixture of enticing aromas from food vendors and the leather goods of craftsmen.",
  room_type: "shop"
)

# Sandbox Universe
sandbox_universe = Universe.find(name: "Sandbox")
if sandbox_universe.nil?
  sandbox_universe = Universe.create(
    name: "Sandbox",
    description: "An experimental universe for testing new features and player creativity.",
    theme: "modern"
  )
end

# Sandbox World
sandbox_world = World.create(
  universe: sandbox_universe,
  name: "Creative World", 
  description: "A world where players can experiment and create freely.",
  gravity_multiplier: 1.0,
  coordinates_x: 1,
  coordinates_y: 2,
  coordinates_z: 0
)

# Sandbox Areas
creative_area = Area.create(
  world: sandbox_world,
  name: "Creative Workshop",
  description: "An area designed for player experimentation and building.",
  area_type: "city",
  danger_level: 1
)

# Sandbox Locations
workshop_location = Location.create(
  area: creative_area,
  name: "Workshop Building",
  description: "A large workshop building for experimentation.",
  location_type: "building"
)

# Sandbox Rooms
Room.create(
  location: workshop_location,
  name: "Workshop",
  short_description: "An open workshop space for creative projects.",
  long_description: "This expansive workshop provides ample space for creative projects and experimentation. Workbenches line the walls, equipped with various tools and materials, while the center of the room remains open for larger constructions. Good lighting and ventilation make it comfortable to work for extended periods, and storage areas keep supplies organized and accessible. The atmosphere encourages creativity and innovation, making it perfect for testing new ideas and building unique creations.",
  room_type: "safe"
)

puts "✅ Created 3 universes with worlds, areas, and rooms"

puts "🎉 Game initialization complete!"
puts "   📍 #{body_position_count} body positions loaded"
puts "   📍 #{object_type_count} object types loaded" 
puts "   📍 #{pattern_count} patterns loaded"
puts "   📍 3 universes created (OOC, IC, Sandbox)"
puts "   📍 3 worlds created"
puts "   📍 4 areas created" 
puts "   📍 4 rooms created"
puts ""
puts "🚀 Your game is ready to play!"