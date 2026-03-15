#!/usr/bin/env ruby
# frozen_string_literal: true

# Setup a test universe with complex nested public rooms for pathfinding testing
# Run with: bundle exec ruby scripts/setup_test_universe.rb

require_relative '../app'

puts 'Setting up test universe with nested rooms...'

# Get the default reality and location
reality = Reality.first || Reality.create(name: 'Test Reality', description: 'Testing reality')
location = Location.first || Location.create(
  reality: reality,
  name: 'Test City',
  description: 'A test city for pathfinding'
)

# Create a central plaza (public hub)
plaza = Room.find_or_create(location_id: location.id, name: 'Central Plaza') do |r|
  r.short_description = 'A bustling central plaza'
  r.long_description = 'The heart of the city, with paths leading in all directions.'
  r.room_type = 'standard'
  r.min_x = 0.0
  r.max_x = 200.0
  r.min_y = 0.0
  r.max_y = 200.0
  r.min_z = 0.0
  r.max_z = 10.0
end
puts "Created plaza: #{plaza.name} (id: #{plaza.id})"

# Create a building (nested container)
building = Room.find_or_create(location_id: location.id, name: 'Town Hall') do |r|
  r.short_description = 'The grand Town Hall building'
  r.long_description = 'A large administrative building with multiple floors.'
  r.room_type = 'standard'
  r.min_x = 0.0
  r.max_x = 100.0
  r.min_y = 0.0
  r.max_y = 100.0
  r.min_z = 0.0
  r.max_z = 30.0
end
puts "Created building: #{building.name} (id: #{building.id})"

# Create floors inside the building
ground_floor = Room.find_or_create(location_id: location.id, name: 'Town Hall - Ground Floor') do |r|
  r.short_description = 'The ground floor lobby'
  r.long_description = 'A marble-floored lobby with a reception desk.'
  r.room_type = 'standard'
  r.inside_room_id = building.id
  r.min_x = 0.0
  r.max_x = 100.0
  r.min_y = 0.0
  r.max_y = 100.0
  r.min_z = 0.0
  r.max_z = 10.0
end
puts "Created nested room: #{ground_floor.name} (id: #{ground_floor.id})"

second_floor = Room.find_or_create(location_id: location.id, name: 'Town Hall - Second Floor') do |r|
  r.short_description = 'The second floor offices'
  r.long_description = 'Administrative offices line the hallway.'
  r.room_type = 'standard'
  r.inside_room_id = building.id
  r.min_x = 0.0
  r.max_x = 100.0
  r.min_y = 0.0
  r.max_y = 100.0
  r.min_z = 10.0
  r.max_z = 20.0
end
puts "Created nested room: #{second_floor.name} (id: #{second_floor.id})"

# Create an office inside the second floor (double nested)
mayors_office = Room.find_or_create(location_id: location.id, name: "Mayor's Office") do |r|
  r.short_description = "The Mayor's private office"
  r.long_description = 'A richly decorated office with a large desk.'
  r.room_type = 'standard'
  r.inside_room_id = second_floor.id
  r.min_x = 60.0
  r.max_x = 100.0
  r.min_y = 60.0
  r.max_y = 100.0
  r.min_z = 10.0
  r.max_z = 20.0
end
puts "Created double-nested room: #{mayors_office.name} (id: #{mayors_office.id})"

# Create streets around the plaza
north_street = Room.find_or_create(location_id: location.id, name: 'North Street') do |r|
  r.short_description = 'A street heading north'
  r.long_description = 'A cobblestone street with shops on both sides.'
  r.room_type = 'standard'
  r.min_x = 80.0
  r.max_x = 120.0
  r.min_y = 200.0
  r.max_y = 300.0
  r.min_z = 0.0
  r.max_z = 10.0
end
puts "Created room: #{north_street.name} (id: #{north_street.id})"

south_street = Room.find_or_create(location_id: location.id, name: 'South Street') do |r|
  r.short_description = 'A street heading south'
  r.long_description = 'A wide avenue leading to the southern gate.'
  r.room_type = 'standard'
  r.min_x = 80.0
  r.max_x = 120.0
  r.min_y = -100.0
  r.max_y = 0.0
  r.min_z = 0.0
  r.max_z = 10.0
end
puts "Created room: #{south_street.name} (id: #{south_street.id})"

# Create exits between rooms
def create_exit(from, to, direction, from_pos: nil, to_pos: nil)
  exit_data = {
    from_room_id: from.id,
    to_room_id: to.id,
    direction: direction,
    visible: true,
    passable: true
  }
  exit_data[:from_x] = from_pos[0] if from_pos
  exit_data[:from_y] = from_pos[1] if from_pos
  exit_data[:from_z] = from_pos[2] if from_pos
  exit_data[:to_x] = to_pos[0] if to_pos
  exit_data[:to_y] = to_pos[1] if to_pos
  exit_data[:to_z] = to_pos[2] if to_pos

  existing = RoomExit.where(from_room_id: from.id, direction: direction).first
  return existing if existing

  RoomExit.create(exit_data)
end

# Plaza connections
create_exit(plaza, north_street, 'north',
            from_pos: [100.0, 200.0, 0.0],
            to_pos: [100.0, 200.0, 0.0])
create_exit(north_street, plaza, 'south',
            from_pos: [100.0, 200.0, 0.0],
            to_pos: [100.0, 200.0, 0.0])

create_exit(plaza, south_street, 'south',
            from_pos: [100.0, 0.0, 0.0],
            to_pos: [100.0, 0.0, 0.0])
create_exit(south_street, plaza, 'north',
            from_pos: [100.0, 0.0, 0.0],
            to_pos: [100.0, 0.0, 0.0])

create_exit(plaza, ground_floor, 'enter',
            from_pos: [50.0, 100.0, 0.0],
            to_pos: [50.0, 0.0, 0.0])
create_exit(ground_floor, plaza, 'out',
            from_pos: [50.0, 0.0, 0.0],
            to_pos: [50.0, 100.0, 0.0])

# Building internal connections
create_exit(ground_floor, second_floor, 'up',
            from_pos: [80.0, 50.0, 10.0],
            to_pos: [80.0, 50.0, 10.0])
create_exit(second_floor, ground_floor, 'down',
            from_pos: [80.0, 50.0, 10.0],
            to_pos: [80.0, 50.0, 10.0])

create_exit(second_floor, mayors_office, 'enter',
            from_pos: [60.0, 80.0, 10.0],
            to_pos: [60.0, 80.0, 10.0])
create_exit(mayors_office, second_floor, 'out',
            from_pos: [60.0, 80.0, 10.0],
            to_pos: [60.0, 80.0, 10.0])

puts "\nTest universe setup complete!"
puts "\nRoom structure:"
puts "  Central Plaza"
puts "    ├── North Street (north)"
puts "    ├── South Street (south)"
puts "    └── Town Hall (enter)"
puts "          └── Ground Floor"
puts "                └── Second Floor (up)"
puts "                      └── Mayor's Office (enter)"
puts "\nPathfinding test: From South Street to Mayor's Office requires 4 room transitions"
