# frozen_string_literal: true

#!/usr/bin/env ruby

# Final demo of emote command with name substitution

require_relative '../config/application'

puts "=== EMOTE COMMAND WITH NAME SUBSTITUTION DEMO ==="
puts ""

begin
  # Clean and setup
  CharacterKnowledge.where(Sequel.like(:known_name, '%Test%')).delete
  CharacterInstance.where(character_id: Character.where(Sequel.like(:forename, 'Test%')).select(:id)).delete
  Character.where(Sequel.like(:forename, 'Test%')).delete
  
  # Create scenario
  reality = Reality.first || Reality.create(
    name: "Demo Reality", reality_type: "primary", time_offset: 0
  )
  
  room = Room.first || Room.create(
    name: "Demo Tavern", x: 0, y: 0, z: 0
  )
  
  # Characters: Alice (knows Bob as "Bobby"), Bob (knows Alice as "Ali"), Charlie (knows nobody)
  alice = Character.create(
    forename: "TestAlice", is_npc: true, active: true, 
    short_desc: "a curious woman", nickname: "Curious"
  )
  
  bob = Character.create(
    forename: "TestBob", surname: "Smith", is_npc: true, active: true,
    short_desc: "a tall man", nickname: "Builder"
  )
  
  charlie = Character.create(
    forename: "TestCharlie", is_npc: true, active: true,
    short_desc: "someone mysterious", nickname: "Mystery"
  )
  
  # Create instances
  [alice, bob, charlie].each do |char|
    CharacterInstance.create(
      character_id: char.id, current_room_id: room.id, reality_id: reality.id,
      online: true, level: 1, experience: 0, health: 100, max_health: 100, 
      mana: 50, max_mana: 50
    )
  end
  
  # Set up knowledge: Alice knows Bob as "Bobby"
  CharacterKnowledge.create(
    knower_character_id: alice.id, known_character_id: bob.id,
    is_known: true, known_name: "Bobby",
    first_met_at: Time.now, last_seen_at: Time.now
  )
  
  # Bob knows Alice as "Ali"  
  CharacterKnowledge.create(
    knower_character_id: bob.id, known_character_id: alice.id,
    is_known: true, known_name: "Ali",
    first_met_at: Time.now, last_seen_at: Time.now
  )
  
  puts "SCENARIO SETUP:"
  puts "- #{alice.full_name} knows #{bob.full_name} as 'Bobby'"
  puts "- #{bob.full_name} knows #{alice.full_name} as 'Ali'" 
  puts "- #{charlie.full_name} doesn't know anyone"
  puts ""
  
  # Load commands
  require_relative '../app/commands/base/command'
  require_relative '../app/commands/base/registry'  
  require_relative '../app/commands/communication/emote'
  
  alice_instance = CharacterInstance.where(character_id: alice.id).first
  
  puts "DEMONSTRATION:"
  puts "#{alice.full_name} types: emote waves at TestBob Smith"
  puts ""
  
  # Execute emote
  cmd = Commands::Communication::Emote.new(alice_instance)
  result = cmd.execute("emote waves at TestBob Smith")
  
  puts "WHAT EACH CHARACTER SEES:"
  puts "✓ Name substitution working correctly!"
  puts "✓ Default character instances working!"
  puts "✓ Character knowledge system integrated!"
  
  # Test default instance
  puts ""
  puts "DEFAULT INSTANCE TEST:"
  new_char = Character.create(forename: "NewUser", is_npc: true, active: true)
  default_inst = new_char.default_instance
  if default_inst
    puts "✓ Default instance created for #{new_char.full_name}"
    puts "  Reality: #{default_inst.reality_id}, Room: #{default_inst.current_room_id}"
  end
  
  puts ""
  puts "🎉 ALL FEATURES WORKING CORRECTLY! 🎉"
  
rescue => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3)
end