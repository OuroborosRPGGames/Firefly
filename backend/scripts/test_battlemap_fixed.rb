# frozen_string_literal: true

require_relative '../app'

$stdout.sync = true

# Use the Closet room (small room for testing)
room = Room[182]
puts "Room: #{room.name} (ID: #{room.id})"
puts "Bounds: (#{room.min_x}, #{room.min_y}) to (#{room.max_x}, #{room.max_y})"

room_width = room.max_x - room.min_x
room_height = room.max_y - room.min_y
arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
puts "Size: #{room_width}ft x #{room_height}ft = #{arena_w}x#{arena_h} hexes (expected: #{arena_w * arena_h})"

# Clear existing hex data
room.room_hexes_dataset.delete
room.update(has_battle_map: false, battle_map_image_url: nil)

puts ''
puts '=== Generating Battle Map ==='
service = AIBattleMapGeneratorService.new(room)

# Check hex coordinates first
hex_coords = service.send(:generate_hex_coordinates)
puts "Generated #{hex_coords.count} hex coordinates:"
hex_coords.each { |x, y| puts "  (#{x}, #{y})" }

puts ''
result = service.generate
puts "Result: #{result.inspect}"

if result[:success]
  room.refresh
  puts ''
  puts "has_battle_map: #{room.has_battle_map}"
  puts "image_url: #{room.battle_map_image_url}"
  puts "hex_count: #{room.room_hexes_dataset.count}"

  if room.room_hexes_dataset.count > 0
    puts ''
    puts '=== Hexes ==='
    room.room_hexes.each do |hex|
      details = []
      details << "cover=#{hex.cover_object}" if hex.cover_object
      details << "hazard=#{hex.hazard_type}" if hex.hazard_type
      details << "elev=#{hex.elevation_level}" if hex.elevation_level != 0
      extra = details.any? ? " (#{details.join(', ')})" : ''
      puts "  (#{hex.hex_x}, #{hex.hex_y}): #{hex.hex_type}#{extra}"
    end
  end
end
