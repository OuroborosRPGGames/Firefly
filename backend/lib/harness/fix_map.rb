require_relative '../app'

room = Room[155]
fight = Fight[132]

puts "Deleting #{RoomHex.where(room_id: 155).count} broken hexes"
RoomHex.where(room_id: 155).delete

room.update(battle_map_image_url: nil)

puts "Generating procedural battle map..."
svc = BattleMapGeneratorService.new(room)
svc.generate!
puts "Done! RoomHex count: #{RoomHex.where(room_id: 155).count}"

hexes = RoomHex.where(room_id: 155).all
bad = hexes.reject { |h| HexGrid.valid_hex_coords?(h.hex_x, h.hex_y) }
puts "Invalid parity: #{bad.count}"

if hexes.any?
  max_x = hexes.map(&:hex_x).max
  max_y = hexes.map(&:hex_y).max
  types = hexes.group_by(&:hex_type).transform_values(&:count)
  trav = hexes.count(&:traversable)
  puts "Max coords: (#{max_x}, #{max_y})"
  puts "Types: #{types}"
  puts "Traversable: #{trav}/#{hexes.size}"

  fight.refresh
  puts "Fight arena: #{fight.arena_width}x#{fight.arena_height}"
end
