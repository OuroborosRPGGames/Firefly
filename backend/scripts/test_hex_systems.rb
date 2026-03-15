# frozen_string_literal: true

#!/usr/bin/env ruby

require 'sequel'
require 'json'

# Connect to database
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
require_relative '../app/models/location'
require_relative '../app/models/room'
require_relative '../app/models/world_hex'
require_relative '../app/models/room_hex'

puts "🔬 Testing World Hex and Room Hex Systems..."
puts "=" * 60

begin
  # Create test data
  puts "📋 Setting up test data..."
  
  universe = Universe.find_or_create(name: "Hex Test Universe") do |u|
    u.description = "Test universe for hex system testing"
    u.theme = "fantasy"
  end
  
  world = World.find_or_create(universe: universe, name: "Hex Test World") do |w|
    w.description = "A world for testing hex systems"
    w.gravity_multiplier = 1.0
    w.coordinates_x = 0
    w.coordinates_y = 0
    w.coordinates_z = 0
    w.world_size = 1.0
  end
  
  area = Area.find_or_create(world: world, name: "Hex Test Area") do |a|
    a.description = "Test area for hex systems"
    a.area_type = "wilderness"
    a.danger_level = 3
    a.min_longitude = -122.5
    a.max_longitude = -122.3
    a.min_latitude = 37.7
    a.max_latitude = 37.9
  end
  
  location = Location.find_or_create(area: area, name: "Hex Test Location") do |l|
    l.description = "Test location with rooms containing hex grids"
    l.location_type = "building"
  end
  
  room = Room.find_or_create(location: location, name: "Hex Test Room") do |r|
    r.short_description = "A room for testing hex grids"
    r.long_description = "A test room with various hex types and hazards"
    r.room_type = "standard"
    r.min_x = 1000  # Area grid coordinates
    r.max_x = 1010
    r.min_y = 1000
    r.max_y = 1010
    r.min_z = 0
    r.max_z = 30
  end
  
  puts "✅ Test data created successfully"
  puts "   World: #{world.name} (size: #{world.world_size})"
  puts "   Area: #{area.name}"
  puts "   Room: #{room.name} (bounds: #{room.min_x}-#{room.max_x}, #{room.min_y}-#{room.max_y})"

  # Test 1: World Hex Default Values
  puts "\n🧪 Test 1: World Hex Default Values"
  
  # Test hex coordinates within the world
  test_hex_coords = [
    [0, 0, "Origin"],
    [2, 0, "East of origin"], 
    [1, 2, "Northeast of origin"],
    [-2822, 872, "San Francisco area"]
  ]
  
  test_hex_coords.each do |hex_x, hex_y, description|
    terrain = world.hex_terrain(hex_x, hex_y)
    altitude = world.hex_altitude(hex_x, hex_y)
    traversable = world.hex_traversable?(hex_x, hex_y)
    features = world.hex_linear_features(hex_x, hex_y)
    
    puts "   #{description} (#{hex_x}, #{hex_y}):"
    puts "     Terrain: #{terrain} (default: #{terrain == 'plain'})"
    puts "     Altitude: #{altitude}m (default: #{altitude == 0})"
    puts "     Traversable: #{traversable} (default: #{traversable == true})"
    puts "     Features: #{features.empty? ? 'none' : features}"
  end
  
  # Test 2: Setting Custom World Hex Details
  puts "\n🧪 Test 2: Setting Custom World Hex Details"
  
  # Create a forest hex with a river
  forest_hex = world.set_hex_details(2, 0, {
    terrain_type: 'forest',
    altitude: 150,
    traversable: true,
    feature_w_e: 'river'
  })
  
  # Create a mountain hex that blocks movement
  mountain_hex = world.set_hex_details(4, 0, {
    terrain_type: 'mountain', 
    altitude: 2500,
    traversable: false,
    feature_nw_se: 'road'
  })
  
  # Create an urban hex with multiple features
  urban_hex = world.set_hex_details(1, 2, {
    terrain_type: 'urban',
    altitude: 25,
    traversable: true,
    feature_nw_se: 'street',
    feature_ne_sw: 'railway',
    feature_w_e: 'road'
  })
  
  puts "   ✅ Created forest hex: terrain=#{forest_hex.terrain_type}, river=#{forest_hex.feature_w_e}"
  puts "   ✅ Created mountain hex: terrain=#{mountain_hex.terrain_type}, traversable=#{mountain_hex.traversable}"
  puts "   ✅ Created urban hex: terrain=#{urban_hex.terrain_type}, features=#{urban_hex.linear_features.keys.join(', ')}"
  
  # Test retrieval of custom hex details
  retrieved_forest = world.hex_details(2, 0)
  puts "   Retrieved forest hex: terrain=#{retrieved_forest.terrain_type}, cost=#{retrieved_forest.movement_cost}"
  
  # Test 3: World Hex Movement and Sight
  puts "\n🧪 Test 3: World Hex Movement and Sight Mechanics"
  
  movement_tests = [
    [0, 0, 'plain'],      # Default terrain
    [2, 0, 'forest'],     # Custom forest
    [4, 0, 'mountain'],   # Custom mountain
    [1, 2, 'urban']       # Custom urban
  ]
  
  movement_tests.each do |hex_x, hex_y, expected_terrain|
    terrain = world.hex_terrain(hex_x, hex_y)
    cost = world.hex_movement_cost(hex_x, hex_y)
    blocks_sight = world.hex_blocks_sight?(hex_x, hex_y)
    
    puts "   #{expected_terrain.capitalize} hex (#{hex_x}, #{hex_y}):"
    puts "     Movement cost: #{cost} (#{cost == Float::INFINITY ? 'impassable' : 'passable'})"
    puts "     Blocks sight: #{blocks_sight}"
  end
  
  # Test 4: Room Hex Default Values
  puts "\n🧪 Test 4: Room Hex Default Values"
  
  # Test hex coordinates within the room
  room_hex_coords = [
    [1005, 1005, "Center of room"],
    [1000, 1000, "Corner of room"],
    [1010, 1010, "Opposite corner"]
  ]
  
  room_hex_coords.each do |hex_x, hex_y, description|
    hex_type = room.hex_type(hex_x, hex_y)
    traversable = room.hex_traversable?(hex_x, hex_y)
    danger = room.hex_danger_level(hex_x, hex_y)
    dangerous = room.hex_dangerous?(hex_x, hex_y)
    
    puts "   #{description} (#{hex_x}, #{hex_y}):"
    puts "     Type: #{hex_type} (default: #{hex_type == 'normal'})"
    puts "     Traversable: #{traversable} (default: #{traversable == true})"
    puts "     Danger level: #{danger} (default: #{danger == 0})"
    puts "     Dangerous: #{dangerous} (default: #{dangerous == false})"
  end
  
  # Test 5: Setting Custom Room Hex Details
  puts "\n🧪 Test 5: Setting Custom Room Hex Details"
  
  # Create a trap hex
  trap_hex = room.set_hex_details(1002, 1003, {
    hex_type: 'trap',
    traversable: false,
    danger_level: 7,
    hazard_type: 'spike_trap',
    damage_potential: 25,
    special_properties: {trigger: 'pressure', reset_time: 300}.to_json
  })
  
  # Create a fire hazard hex
  fire_hex = room.set_hex_details(1007, 1008, {
    hex_type: 'fire',
    traversable: true,
    danger_level: 5,
    hazard_type: 'fire',
    damage_potential: 15
  })
  
  # Create a furniture hex
  furniture_hex = room.set_hex_details(1005, 1002, {
    hex_type: 'furniture',
    traversable: true,
    danger_level: 0
  })
  
  puts "   ✅ Created trap hex: type=#{trap_hex.hex_type}, danger=#{trap_hex.danger_level}"
  puts "   ✅ Created fire hex: type=#{fire_hex.hex_type}, hazard=#{fire_hex.hazard_type}"
  puts "   ✅ Created furniture hex: type=#{furniture_hex.hex_type}"
  
  # Test 6: Room Hex Movement and Danger
  puts "\n🧪 Test 6: Room Hex Movement and Danger Mechanics"
  
  room_movement_tests = [
    [1005, 1005, 'normal'],      # Default
    [1002, 1003, 'trap'],        # Trap 
    [1007, 1008, 'fire'],        # Fire hazard
    [1005, 1002, 'furniture']    # Furniture
  ]
  
  room_movement_tests.each do |hex_x, hex_y, expected_type|
    hex_type = room.hex_type(hex_x, hex_y)
    cost = room.hex_movement_cost(hex_x, hex_y)
    dangerous = room.hex_dangerous?(hex_x, hex_y)
    
    puts "   #{expected_type.capitalize} hex (#{hex_x}, #{hex_y}):"
    puts "     Movement cost: #{cost == Float::INFINITY ? 'impassable' : cost}"
    puts "     Dangerous: #{dangerous}"
  end
  
  # Test 7: Room Hex Queries
  puts "\n🧪 Test 7: Room Hex Bulk Queries"
  
  dangerous_hexes = room.dangerous_hexes.all
  impassable_hexes = room.impassable_hexes.all
  
  puts "   Dangerous hexes in room: #{dangerous_hexes.count}"
  dangerous_hexes.each do |hex|
    puts "     (#{hex.hex_x}, #{hex.hex_y}): #{hex.hex_type} (danger: #{hex.danger_level})"
  end
  
  puts "   Impassable hexes in room: #{impassable_hexes.count}"
  impassable_hexes.each do |hex|
    puts "     (#{hex.hex_x}, #{hex.hex_y}): #{hex.hex_type} (traversable: #{hex.traversable})"
  end
  
  # Test 8: Room Boundary Validation
  puts "\n🧪 Test 8: Room Boundary Validation"
  
  boundary_tests = [
    [1005, 1005, true, "Inside room bounds"],
    [999, 1005, false, "Outside room (x too low)"],
    [1011, 1005, false, "Outside room (x too high)"],
    [1005, 999, false, "Outside room (y too low)"],
    [1005, 1011, false, "Outside room (y too high)"]
  ]
  
  boundary_tests.each do |hex_x, hex_y, expected, description|
    in_bounds = room.coordinates_in_bounds?(hex_x, hex_y)
    status = in_bounds == expected ? "✅" : "❌"
    puts "   #{status} #{description}: (#{hex_x}, #{hex_y}) -> #{in_bounds}"
  end
  
  # Test 9: WorldHex and RoomHex Model Validation
  puts "\n🧪 Test 9: Model Validation Tests"
  
  # Test invalid terrain type
  begin
    invalid_world_hex = WorldHex.create(
      world: world,
      hex_x: 6,
      hex_y: 0,
      terrain_type: 'invalid_terrain'
    )
    puts "   ❌ Should have failed with invalid terrain type"
  rescue Sequel::ValidationFailed => e
    puts "   ✅ Correctly rejected invalid terrain type: #{e.message}"
  end
  
  # Test invalid hex coordinates
  begin
    invalid_hex_coords = WorldHex.create(
      world: world,
      hex_x: 1,  # Invalid: y=0 (even), x should be even
      hex_y: 0,
      terrain_type: 'plain'
    )
    puts "   ❌ Should have failed with invalid hex coordinates"
  rescue Sequel::ValidationFailed => e
    puts "   ✅ Correctly rejected invalid hex coordinates: #{e.message}"
  end
  
  # Test invalid room hex outside bounds
  begin
    invalid_room_hex = RoomHex.create(
      room: room,
      hex_x: 2000,  # Outside room bounds
      hex_y: 2000,
      hex_type: 'normal'
    )
    puts "   ❌ Should have failed with coordinates outside room bounds"
  rescue Sequel::ValidationFailed => e
    puts "   ✅ Correctly rejected coordinates outside room bounds: #{e.message}"
  end
  
  # Test 10: Special Properties and JSON Handling
  puts "\n🧪 Test 10: Special Properties and JSON Handling"
  
  # Create a hex with complex special properties
  complex_hex = room.set_hex_details(1001, 1001, {
    hex_type: 'trap',
    hazard_type: 'magic',
    danger_level: 8,
    special_properties: {
      spell_type: 'teleport',
      destination: {x: 1009, y: 1009},
      activation_chance: 0.3,
      mana_cost: 50
    }.to_json
  })
  
  retrieved_props = complex_hex.parsed_special_properties
  puts "   ✅ Special properties saved and parsed:"
  puts "     Spell type: #{retrieved_props['spell_type']}"
  puts "     Destination: (#{retrieved_props['destination']['x']}, #{retrieved_props['destination']['y']})"
  puts "     Activation chance: #{retrieved_props['activation_chance']}"
  
rescue => e
  puts "❌ Error during hex systems test: #{e.message}"
  puts e.backtrace[0..5]
end

puts "\n🎉 World Hex and Room Hex Systems Testing Complete!"