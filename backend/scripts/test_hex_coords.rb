# frozen_string_literal: true

require_relative '../app'

$stdout.sync = true

room = Room[182]
room_min_x = room.min_x
room_min_y = room.min_y

puts "Room bounds: (#{room_min_x}, #{room_min_y}) to (#{room.max_x}, #{room.max_y})"
puts ''

# Test the snapping logic
test_positions = [
  [192.0, 182.0],
  [196.0, 186.0],
  [190.0, 180.0],
  [194.5, 184.5]
]

test_positions.each do |char_x, char_y|
  # Snap to 4-foot grid
  offset_x = char_x - room_min_x
  offset_y = char_y - room_min_y
  grid_x = (offset_x / HexGrid::HEX_SIZE_FEET).round * HexGrid::HEX_SIZE_FEET
  grid_y = (offset_y / HexGrid::HEX_SIZE_FEET).round * HexGrid::HEX_SIZE_FEET
  world_x = room_min_x + grid_x
  world_y = room_min_y + grid_y
  hex_x, hex_y = HexGrid.to_hex_coords(world_x.to_i, world_y.to_i)

  room_hex = room.room_hexes_dataset.where(hex_x: hex_x, hex_y: hex_y).first
  puts "Char (#{char_x}, #{char_y}) → grid (#{world_x}, #{world_y}) → hex (#{hex_x}, #{hex_y}) → terrain: #{room_hex&.hex_type || 'NOT FOUND'}"
end
