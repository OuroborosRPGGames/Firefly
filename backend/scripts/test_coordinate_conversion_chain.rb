# frozen_string_literal: true

#!/usr/bin/env ruby

require 'sequel'

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

puts "🌐 Testing Complete Coordinate Conversion Chain..."
puts "=" * 60

begin
  # Create test data
  puts "📋 Setting up test data..."
  
  universe = Universe.find_or_create(name: "Test Coordinate Universe") do |u|
    u.description = "Test universe for coordinate conversions"
    u.theme = "modern"
  end
  
  # Test different world sizes
  earth_world = World.find_or_create(universe: universe, name: "Earth-sized World") do |w|
    w.description = "Normal Earth-sized world"
    w.gravity_multiplier = 1.0
    w.coordinates_x = 0
    w.coordinates_y = 0
    w.coordinates_z = 0
    w.world_size = 1.0  # Earth-sized
  end
  
  big_world = World.find_or_create(universe: universe, name: "Double-sized World") do |w|
    w.description = "Double-sized world"
    w.gravity_multiplier = 1.0
    w.coordinates_x = 100
    w.coordinates_y = 0
    w.coordinates_z = 0
    w.world_size = 2.0  # Double Earth size
  end
  
  # Create test area in the Earth-sized world
  sf_area = Area.find_or_create(world: earth_world, name: "SF Test Area") do |a|
    a.description = "San Francisco test area for coordinate conversion"
    a.area_type = "city"
    a.danger_level = 1
    a.min_longitude = -122.5
    a.max_longitude = -122.3
    a.min_latitude = 37.7
    a.max_latitude = 37.9
  end
  
  # Create location and rooms for testing nesting
  sf_location = Location.find_or_create(area: sf_area, name: "SF Downtown") do |l|
    l.description = "Downtown San Francisco"
    l.location_type = "building"
  end
  
  # Create nested rooms (house > bedroom > closet)
  house_room = Room.find_or_create(location: sf_location, name: "House") do |r|
    r.short_description = "A test house"
    r.long_description = "A test house for coordinate conversion testing"
    r.room_type = "standard"
    r.min_x = 1000  # Grid coordinates (2 units = 1 meter)
    r.max_x = 1200
    r.min_y = 1000
    r.max_y = 1200
    r.min_z = 0
    r.max_z = 50    # 25 meters high
  end
  
  bedroom_room = Room.find_or_create(location: sf_location, name: "Bedroom") do |r|
    r.short_description = "A bedroom inside the house"
    r.long_description = "A bedroom inside the house for testing room nesting"
    r.room_type = "standard"
    r.inside_room_id = house_room.id
    r.min_x = 1050  # Inside the house
    r.max_x = 1150
    r.min_y = 1050
    r.max_y = 1100
    r.min_z = 0
    r.max_z = 30
  end
  
  closet_room = Room.find_or_create(location: sf_location, name: "Closet") do |r|
    r.short_description = "A closet inside the bedroom"
    r.long_description = "A closet inside the bedroom for testing innermost room detection"
    r.room_type = "standard"
    r.inside_room_id = bedroom_room.id
    r.min_x = 1080  # Inside the bedroom
    r.max_x = 1120
    r.min_y = 1080
    r.max_y = 1100
    r.min_z = 0
    r.max_z = 30
  end
  
  puts "✅ Test data created successfully"
  puts "   Universe: #{universe.name}"
  puts "   Earth World: #{earth_world.name} (size: #{earth_world.world_size})"
  puts "   Big World: #{big_world.name} (size: #{big_world.world_size})"
  puts "   Area: #{sf_area.name} (#{sf_area.min_longitude}, #{sf_area.min_latitude}) to (#{sf_area.max_longitude}, #{sf_area.max_latitude})"
  puts "   Rooms: #{house_room.name} > #{bedroom_room.name} > #{closet_room.name}"
  
  # Test 1: World size scaling for hex grids
  puts "\n🧪 Test 1: World size scaling for hex grids"
  test_lon, test_lat = -122.4, 37.8  # SF coordinates
  
  earth_hex = earth_world.lonlat_to_hex(test_lon, test_lat)
  big_hex = big_world.lonlat_to_hex(test_lon, test_lat)
  
  puts "   SF coordinates: (#{test_lon}, #{test_lat})"
  puts "   Earth-sized world hex: #{earth_hex}"
  puts "   Double-sized world hex: #{big_hex}"
  puts "   ✅ Bigger worlds should have more hexes (bigger coordinate numbers): #{big_hex[0].abs > earth_hex[0].abs}"
  
  # Test 2: Longitude/Latitude to Area Grid conversion
  puts "\n🧪 Test 2: Longitude/Latitude to Area Grid conversion"
  area_result = earth_world.lonlat_to_area_grid(test_lon, test_lat)
  
  if area_result
    grid_x, grid_y, found_area = area_result
    puts "   ✅ Found area: #{found_area.name}"
    puts "   Area grid coordinates: (#{grid_x}, #{grid_y})"
    puts "   Grid units to meters: #{grid_x / 2.0}m, #{grid_y / 2.0}m"
  else
    puts "   ❌ No area found for coordinates"
  end
  
  # Test 3: Area Grid to Longitude/Latitude conversion (round-trip)
  if area_result
    puts "\n🧪 Test 3: Area Grid to Longitude/Latitude conversion (round-trip)"
    grid_x, grid_y, found_area = area_result
    
    back_lonlat = found_area.area_grid_to_lonlat(grid_x, grid_y)
    if back_lonlat
      lon_error = (back_lonlat[0] - test_lon).abs
      lat_error = (back_lonlat[1] - test_lat).abs
      
      puts "   Original: (#{test_lon}, #{test_lat})"
      puts "   Round-trip: (#{back_lonlat[0].round(6)}, #{back_lonlat[1].round(6)})"
      puts "   Error: #{lon_error.round(6)}° lon, #{lat_error.round(6)}° lat"
      puts "   ✅ Round-trip successful: #{lon_error < 0.001 && lat_error < 0.001}"
    else
      puts "   ❌ Failed to convert back to lonlat"
    end
  end
  
  # Test 4: Area Grid to World Hex conversion
  if area_result
    puts "\n🧪 Test 4: Area Grid to World Hex conversion"
    grid_x, grid_y, found_area = area_result
    
    area_hex = found_area.area_grid_to_world_hex(grid_x, grid_y)
    direct_hex = earth_world.lonlat_to_hex(test_lon, test_lat)
    
    puts "   Area grid hex: #{area_hex}"
    puts "   Direct lonlat hex: #{direct_hex}"
    puts "   ✅ Coordinates match: #{area_hex == direct_hex}"
  end
  
  # Test 5: Room nesting and innermost room finding
  puts "\n🧪 Test 5: Room nesting and innermost room finding"
  
  # Test coordinates inside the closet
  closet_x = 1100  # Inside closet bounds (1080-1120)
  closet_y = 1090  # Inside closet bounds (1080-1100)  
  closet_z = 15    # Inside closet bounds (0-30)
  
  innermost = sf_area.innermost_room_at(closet_x, closet_y, closet_z)
  
  puts "   Test coordinates: (#{closet_x}, #{closet_y}, #{closet_z})"
  puts "   House bounds: (#{house_room.min_x}-#{house_room.max_x}, #{house_room.min_y}-#{house_room.max_y}, #{house_room.min_z}-#{house_room.max_z})"
  puts "   Bedroom bounds: (#{bedroom_room.min_x}-#{bedroom_room.max_x}, #{bedroom_room.min_y}-#{bedroom_room.max_y}, #{bedroom_room.min_z}-#{bedroom_room.max_z})"
  puts "   Closet bounds: (#{closet_room.min_x}-#{closet_room.max_x}, #{closet_room.min_y}-#{closet_room.max_y}, #{closet_room.min_z}-#{closet_room.max_z})"
  
  if innermost
    puts "   ✅ Innermost room found: #{innermost.name}"
    puts "   ✅ Correct nesting: #{innermost.name == 'Closet'}"
  else
    puts "   ❌ No innermost room found"
  end
  
  # Test 6: Complete coordinate conversion chain
  puts "\n🧪 Test 6: Complete coordinate conversion chain"
  puts "   lonlat -> area_grid -> lonlat -> world_hex -> lonlat"
  
  # Start with SF coordinates
  start_lon, start_lat = -122.4, 37.8
  puts "   1. Start: (#{start_lon}, #{start_lat})"
  
  # Convert to area grid
  area_result = earth_world.lonlat_to_area_grid(start_lon, start_lat)
  if area_result
    grid_x, grid_y, area = area_result
    puts "   2. Area grid: (#{grid_x}, #{grid_y}) in #{area.name}"
    
    # Convert back to lonlat
    step3_lonlat = area.area_grid_to_lonlat(grid_x, grid_y)
    if step3_lonlat
      puts "   3. Back to lonlat: (#{step3_lonlat[0].round(6)}, #{step3_lonlat[1].round(6)})"
      
      # Convert to world hex
      world_hex = earth_world.lonlat_to_hex(step3_lonlat[0], step3_lonlat[1])
      puts "   4. World hex: #{world_hex}"
      
      # Convert hex back to lonlat
      final_lonlat = earth_world.hex_to_lonlat(world_hex[0], world_hex[1])
      if final_lonlat
        puts "   5. Final lonlat: (#{final_lonlat[0].round(6)}, #{final_lonlat[1].round(6)})"
        
        final_error_lon = (final_lonlat[0] - start_lon).abs
        final_error_lat = (final_lonlat[1] - start_lat).abs
        puts "   Final error: #{final_error_lon.round(6)}° lon, #{final_error_lat.round(6)}° lat"
        puts "   ✅ Chain complete: #{final_error_lon < 0.01 && final_error_lat < 0.01}"
      else
        puts "   ❌ Failed to convert hex back to lonlat"
      end
    else
      puts "   ❌ Failed to convert area grid back to lonlat"
    end
  else
    puts "   ❌ Failed to convert lonlat to area grid"
  end
  
  # Test 7: Distance and scaling verification
  puts "\n🧪 Test 7: Distance and scaling verification"
  
  # Check hex spacing on both worlds
  origin_hex = [0, 0]
  east_neighbor = earth_world.navigate_hex_direction(0, 0, 'E')
  
  if east_neighbor
    distance = earth_world.hex_distance_miles(0, 0, east_neighbor[0], east_neighbor[1])
    puts "   Earth world hex spacing: #{distance} miles (should be ~3)"
  end
  
  # Area grid distance verification (2 units = 1 meter)
  if area_result
    grid_x, grid_y, area = area_result
    
    # Move 10 grid units east (should be 5 meters)
    test_distance_grid = 10
    expected_meters = test_distance_grid / 2.0
    
    nearby_lonlat = area.area_grid_to_lonlat(grid_x + test_distance_grid, grid_y)
    if nearby_lonlat && step3_lonlat
      # Calculate distance using rough degree-to-meter conversion
      lon_diff = nearby_lonlat[0] - step3_lonlat[0]
      lat_diff = nearby_lonlat[1] - step3_lonlat[1]
      
      # At this latitude, rough meter conversion
      meters_per_degree_lon = 111320 * Math.cos(step3_lonlat[1] * Math::PI / 180)
      distance_meters = Math.sqrt((lon_diff * meters_per_degree_lon)**2 + (lat_diff * 111320)**2)
      
      puts "   Area grid distance test:"
      puts "     Grid units moved: #{test_distance_grid}"
      puts "     Expected meters: #{expected_meters}"
      puts "     Calculated meters: #{distance_meters.round(2)}"
      puts "   ✅ Distance scaling correct: #{(distance_meters - expected_meters).abs < 1.0}"
    end
  end

rescue => e
  puts "❌ Error during coordinate conversion chain test: #{e.message}"
  puts e.backtrace[0..5]
end

puts "\n🎉 Coordinate Conversion Chain Testing Complete!"