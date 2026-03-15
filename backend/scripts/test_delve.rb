#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../app'

puts "=== Testing Delve System ==="

# Test creating a delve
delve = Delve.create(
  name: 'Test Cave',
  difficulty: 'normal',
  time_limit_minutes: 60,
  grid_width: 15,
  grid_height: 15,
  levels_generated: 1,
  seed: 12345
)

puts "Delve created: #{delve.id}"

# Generate first level
puts "Generating level 1..."
begin
  result = DelveGeneratorService.generate_level!(delve, 1)
  puts "Generation result: #{result}"
rescue => e
  puts "Error generating level: #{e.message}"
  puts e.backtrace.first(10).join("\n")
  delve.destroy
  exit 1
end

# Check rooms
rooms = delve.delve_rooms_dataset.all
puts "Rooms created: #{rooms.count}"

# Show some room details
rooms.first(5).each do |room|
  puts "  Room: (#{room.grid_x}, #{room.grid_y}) level=#{room.level} type=#{room.room_type} entrance=#{room.is_entrance} exit=#{room.is_exit}"
end

# Find entrance
entrance = delve.entrance_room(1)
if entrance
  puts "Entrance found at (#{entrance.grid_x}, #{entrance.grid_y})"
else
  puts "ERROR: No entrance found!"
end

# Find exit
exit_room = delve.exit_room(1)
if exit_room
  puts "Exit found at (#{exit_room.grid_x}, #{exit_room.grid_y})"
else
  puts "ERROR: No exit found!"
end

# Test visibility service
if entrance
  # Create a test participant
  user = User.first
  if user
    char = user.characters.first
    if char
      ci = char.character_instances.first
      if ci
        puts "Using character instance: #{ci.id}"

        participant = DelveParticipant.create(
          delve_id: delve.id,
          character_instance_id: ci.id,
          status: 'exploring',
          current_level: 1,
          current_room_id: entrance.id,
          time_spent_minutes: 0,
          loot_collected: 0,
          rooms_explored: 1
        )

        puts "Participant created: #{participant.id}"

        # Test map rendering
        map = DelveMapService.render_ascii(participant)
        puts "\n=== ASCII Map ==="
        puts map

        # Test visibility
        visible = DelveVisibilityService.visible_rooms(participant)
        puts "\nVisible rooms: #{visible.count}"

        # Test status
        status = DelveActionService.status(participant)
        puts "\n=== Status ==="
        puts status.message

        # Clean up participant
        participant.destroy
        puts "\nParticipant cleaned up"
      end
    end
  end
end

# Clean up
delve.destroy
puts "\nDelve cleaned up"
puts "=== Test Completed ==="
