# frozen_string_literal: true

require_relative '../app'

$stdout.sync = true

room = Room.where { (Sequel.cast(max_x, Float) - Sequel.cast(min_x, Float)) > 80 }.first
if room
  room_width = room.max_x - room.min_x
  room_height = room.max_y - room.min_y
  arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
  puts "Room: #{room.name} (ID: #{room.id})"
  puts "Size: #{room_width.round}ft x #{room_height.round}ft = #{arena_w}x#{arena_h} hexes (#{arena_w * arena_h} expected)"

  room.room_hexes_dataset.delete
  room.update(has_battle_map: false, battle_map_image_url: nil)

  puts ''
  puts '=== Testing AI Battle Map Generator ==='
  service = AIBattleMapGeneratorService.new(room)

  # Check hex coordinates first
  hex_coords = service.send(:generate_hex_coordinates)
  puts "Generated #{hex_coords.count} hex coordinates"

  puts ''
  result = service.generate
  puts "Result: #{result.inspect}"

  if result[:success]
    room.refresh
    puts ''
    puts "has_battle_map: #{room.has_battle_map}"
    puts "image_url: #{room.battle_map_image_url}"
    puts "hex_count: #{room.room_hexes_dataset.count}"
    puts "fallback: #{result[:fallback]}"
  end
else
  puts 'No large room found'
end
