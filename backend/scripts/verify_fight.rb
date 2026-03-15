# frozen_string_literal: true

require_relative '../app'

$stdout.sync = true

fight = Fight[75]
puts "Fight ##{fight.id}"
puts "Room: #{fight.room.name}"
puts ''
puts 'Participants:'
fight.fight_participants.each do |p|
  char = p.character_instance.character
  room_hex = fight.room.room_hexes_dataset.where(hex_x: p.hex_x, hex_y: p.hex_y).first
  terrain = room_hex ? room_hex.hex_type : 'NOT FOUND'
  puts "  #{char.full_name}: hex (#{p.hex_x}, #{p.hex_y}) -> terrain: #{terrain}"
end
