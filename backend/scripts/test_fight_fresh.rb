# frozen_string_literal: true

require_relative '../app'

$stdout.sync = true

room = Room[182]
agent = CharacterInstance[2]
npc = CharacterInstance[6]

puts "Room: #{room.name}"
puts "Agent at: (#{agent.x}, #{agent.y})"
puts "NPC at: (#{npc.x}, #{npc.y})"
puts ''

# Create fight using FightService.start_fight
service = FightService.start_fight(room: room, initiator: agent, target: npc)
fight = service.fight

puts "Fight ##{fight.id} created"
puts ''
puts 'Participants:'
fight.fight_participants.each do |p|
  char = p.character_instance.character
  room_hex = fight.room.room_hexes_dataset.where(hex_x: p.hex_x, hex_y: p.hex_y).first
  terrain = room_hex ? room_hex.hex_type : 'NOT FOUND'
  puts "  #{char.full_name}: hex (#{p.hex_x}, #{p.hex_y}) -> terrain: #{terrain}"
end
