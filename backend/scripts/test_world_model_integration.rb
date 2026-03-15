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

puts "🌍 Testing World Model Integration with Hex Grid..."
puts "=" * 60

begin
  # Create test universe and world
  universe = Universe.find_or_create(name: "Test Hex Universe") do |u|
    u.description = "Test universe for hex grid testing"
    u.theme = "modern"
  end

  world = World.find_or_create(universe: universe, name: "Round Test World") do |w|
    w.description = "A round world for testing hex grid navigation"
    w.gravity_multiplier = 1.0
    w.coordinates_x = 100
    w.coordinates_y = 200
    w.coordinates_z = 300
  end

  puts "✅ Created test world: #{world.name}"
  puts "   World coordinates: #{world.coordinates}"
  puts "   Distance calculation ready: #{world.coordinates_x && world.coordinates_y && world.coordinates_z ? 'Yes' : 'No'}"

  # Test world coordinate methods
  puts "\n📋 Testing World coordinate methods:"
  
  # Test another world for distance calculation
  world2 = World.find_or_create(universe: universe, name: "Nearby World") do |w|
    w.description = "Another world for distance testing"
    w.gravity_multiplier = 1.0
    w.coordinates_x = 103
    w.coordinates_y = 204
    w.coordinates_z = 305
  end

  distance = world.distance_to(world2)
  puts "   Distance to nearby world: #{distance&.round(2)} units"
  
  nearby = world.nearby_worlds(10)
  puts "   Nearby worlds within 10 units: #{nearby.length}"

  # Test longitude/latitude to hex conversion within world
  puts "\n📋 Testing lonlat to hex conversion within world:"
  
  test_locations = [
    [0.0, 0.0, "Equator/Prime Meridian"],
    [-122.4, 37.8, "San Francisco"],
    [2.3, 48.9, "Paris"],
    [180.0, 0.0, "International Date Line"]
  ]

  test_locations.each do |lon, lat, name|
    hex_coord = world.lonlat_to_hex(lon, lat)
    back_lonlat = world.hex_to_lonlat(hex_coord[0], hex_coord[1])
    
    puts "   #{name}: (#{lon}, #{lat}) -> #{hex_coord} -> (#{back_lonlat[0].round(3)}, #{back_lonlat[1].round(3)})"
  end

  # Test hex navigation within world
  puts "\n📋 Testing hex navigation within world:"
  
  # Start at equator/prime meridian
  start_hex = world.lonlat_to_hex(0.0, 0.0)
  puts "   Starting at hex: #{start_hex}"
  
  directions = ['NE', 'E', 'SE', 'SW', 'W', 'NW']
  directions.each do |direction|
    next_hex = world.navigate_hex_direction(start_hex[0], start_hex[1], direction)
    if next_hex
      next_lonlat = world.hex_to_lonlat(next_hex[0], next_hex[1])
      distance = world.hex_distance_miles(start_hex[0], start_hex[1], next_hex[0], next_hex[1])
      puts "   #{direction}: #{next_hex} = (#{next_lonlat[0].round(3)}, #{next_lonlat[1].round(3)}) [#{distance} miles]"
    else
      puts "   #{direction}: no valid hex"
    end
  end

  # Test area integration
  puts "\n📋 Testing area integration with hex coordinates:"
  
  # Create test areas
  sf_area = Area.find_or_create(world: world, name: "SF Test Area") do |a|
    a.description = "San Francisco test area"
    a.area_type = "city"
    a.danger_level = 1
    a.min_longitude = -122.5
    a.max_longitude = -122.3
    a.min_latitude = 37.7
    a.max_latitude = 37.9
  end

  # Test finding areas at hex coordinates
  sf_hex = world.lonlat_to_hex(-122.4, 37.8)  # Center of SF
  areas_at_sf = world.areas_at_hex(sf_hex[0], sf_hex[1])
  primary_area = world.primary_area_at_hex(sf_hex[0], sf_hex[1])
  
  puts "   SF hex coordinate: #{sf_hex}"
  puts "   Areas at SF hex: #{areas_at_sf.map(&:name)}"
  puts "   Primary area: #{primary_area&.name}"

  # Test area hexes
  area_hexes = world.area_hexes
  puts "   Area hexes calculated: #{area_hexes.keys.length} areas"
  if sf_area_hexes = area_hexes[sf_area.id]
    puts "   SF area contains #{sf_area_hexes.length} hexes"
    puts "   Sample SF hexes: #{sf_area_hexes.first(3)}"
  end

  # Test world edge detection
  puts "\n📋 Testing world edge detection:"
  
  edge_test_locations = [
    [179.5, 0.0, "Near date line east"],
    [-179.5, 0.0, "Near date line west"], 
    [0.0, 89.0, "Near north pole"],
    [0.0, -89.0, "Near south pole"]
  ]

  edge_test_locations.each do |lon, lat, name|
    hex = world.lonlat_to_hex(lon, lat)
    at_edge = world.hex_at_world_edge?(hex[0], hex[1])
    puts "   #{name}: #{hex} -> at edge: #{at_edge}"
  end

  # Test east/west wrapping more specifically
  puts "\n📋 Testing east/west wrapping around the world:"
  
  # Start near the date line and navigate east
  start_lon = 179.0
  current_hex = world.lonlat_to_hex(start_lon, 0.0)
  puts "   Starting near date line: #{current_hex} = #{world.hex_to_lonlat(current_hex[0], current_hex[1])}"
  
  # Move east several times
  5.times do |i|
    next_hex = world.navigate_hex_direction(current_hex[0], current_hex[1], 'E')
    if next_hex
      lonlat = world.hex_to_lonlat(next_hex[0], next_hex[1])
      puts "   Step #{i+1} east: #{next_hex} = (#{lonlat[0].round(3)}, #{lonlat[1].round(3)})"
      current_hex = next_hex
    else
      puts "   Step #{i+1}: Could not move east"
      break
    end
  end

rescue => e
  puts "❌ Error during world model integration test: #{e.message}"
  puts e.backtrace[0..3]
end

puts "\n🎉 World Model Integration Testing Complete!"