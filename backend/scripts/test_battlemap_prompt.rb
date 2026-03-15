# frozen_string_literal: true

require_relative '../app'

# Test the battle map prompt generation
room = Room.where(Sequel.lit('min_x IS NOT NULL AND max_x IS NOT NULL')).first

if room.nil?
  puts "No room with bounds found"
  exit
end

puts "=== Room: #{room.name} (ID: #{room.id}) ==="
puts "Bounds: (#{room.min_x}, #{room.min_y}) to (#{room.max_x}, #{room.max_y})"

room_width = room.max_x - room.min_x
room_height = room.max_y - room.min_y
puts "Room size: #{room_width}ft x #{room_height}ft"

arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
puts "Arena size: #{arena_w} x #{arena_h} hexes"
puts "HEX_SIZE_FEET: #{HexGrid::HEX_SIZE_FEET}"

puts ""
puts "=== Image Generation Prompt ==="
service = AIBattleMapGeneratorService.new(room)
prompt = service.send(:build_image_prompt)
puts prompt
puts ""
puts "=== Key Points ==="
puts "- Includes 'NO grid lines, NO hexagons': #{prompt.include?('NO grid lines')}"
puts "- Includes X-axis label: #{prompt.include?('X-axis')}"
puts "- Includes Y-axis label: #{prompt.include?('Y-axis')}"
puts "- Includes room dimensions: #{prompt.include?('Room dimensions')}"
puts "- Includes scale info: #{prompt.include?('Scale:')}"
