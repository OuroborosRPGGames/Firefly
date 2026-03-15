# frozen_string_literal: true

#!/usr/bin/env ruby

# Test script to verify name substitution in emote commands

require_relative '../config/application'

puts "Testing Emote Name Substitution..."

begin
  # Test database connection
  puts "Database connection: #{DB.test_connection}"
  
  # Clean up any existing test data
  puts "\n--- Cleaning Test Data ---"
  CharacterKnowledge.where(Sequel.like(:known_name, '%Test%')).delete
  CharacterInstance.where(character_id: Character.where(Sequel.like(:forename, 'Test%')).select(:id)).delete
  Character.where(Sequel.like(:forename, 'Test%')).delete
  
  puts "\n--- Creating Test Scenario ---"
  
  # Create reality and room
  test_reality = Reality.first || Reality.create(
    name: "Test Reality",
    description: "A test reality for name substitution testing",
    reality_type: "primary",
    time_offset: 0
  )
  
  test_room = Room.first || Room.create(
    name: "Test Tavern",
    description: "A cozy tavern for testing",
    x: 0, y: 0, z: 0
  )
  
  # Create three test characters
  alice = Character.create(
    forename: "Alice",
    surname: "Wonderland",
    is_npc: true,
    active: true,
    short_desc: "a curious blonde woman",
    nickname: "Wonder"
  )
  
  bob = Character.create(
    forename: "Bob",
    surname: "Builder", 
    is_npc: true,
    active: true,
    short_desc: "a burly construction worker",
    nickname: "Builder"
  )
  
  charlie = Character.create(
    forename: "Charlie",
    surname: "Brown",
    is_npc: true,
    active: true,
    short_desc: "someone in a yellow shirt",
    nickname: "Champ"
  )
  
  # Create character instances
  alice_instance = CharacterInstance.create(
    character_id: alice.id,
    current_room_id: test_room.id,
    reality_id: test_reality.id,
    online: true,
    level: 1, experience: 0, health: 100, max_health: 100, mana: 50, max_mana: 50
  )
  
  bob_instance = CharacterInstance.create(
    character_id: bob.id,
    current_room_id: test_room.id,
    reality_id: test_reality.id,
    online: true,
    level: 1, experience: 0, health: 100, max_health: 100, mana: 50, max_mana: 50
  )
  
  charlie_instance = CharacterInstance.create(
    character_id: charlie.id,
    current_room_id: test_room.id,
    reality_id: test_reality.id,
    online: true,
    level: 1, experience: 0, health: 100, max_health: 100, mana: 50, max_mana: 50
  )
  
  puts "Created characters:"
  puts "  - #{alice.full_name} (#{alice.short_desc})"
  puts "  - #{bob.full_name} (#{bob.short_desc})"
  puts "  - #{charlie.full_name} (#{charlie.short_desc})"
  
  # Set up character knowledge relationships
  puts "\n--- Setting Up Knowledge Relationships ---"
  
  # Alice knows Bob as "Bobby" but doesn't know Charlie
  CharacterKnowledge.create(
    knower_character_id: alice.id,
    known_character_id: bob.id,
    is_known: true,
    known_name: "Bobby",
    first_met_at: Time.now,
    last_seen_at: Time.now
  )
  
  # Bob knows Alice as "Ali" and Charlie by his full name
  CharacterKnowledge.create(
    knower_character_id: bob.id,
    known_character_id: alice.id,
    is_known: true,
    known_name: "Ali",
    first_met_at: Time.now,
    last_seen_at: Time.now
  )
  
  CharacterKnowledge.create(
    knower_character_id: bob.id,
    known_character_id: charlie.id,
    is_known: true,
    known_name: "Charlie Brown",
    first_met_at: Time.now,
    last_seen_at: Time.now
  )
  
  # Charlie knows no one (will see them by short descriptions)
  
  puts "Knowledge setup complete:"
  puts "  - Alice knows Bob as 'Bobby', doesn't know Charlie"
  puts "  - Bob knows Alice as 'Ali', knows Charlie as 'Charlie Brown'"
  puts "  - Charlie knows nobody (sees short descriptions)"
  
  # Load command system
  puts "\n--- Loading Command System ---"
  require_relative '../app/commands/base/command'
  require_relative '../app/commands/base/registry'
  require_relative '../app/commands/communication/emote'
  
  puts "\n--- Testing Name Substitution ---"
  
  # Test 1: Alice emotes mentioning Bob
  puts "\n1. Alice emotes: 'waves at Bob Builder'"
  alice_cmd = Commands::Communication::Emote.new(alice_instance)
  result = alice_cmd.execute("emote waves at Bob Builder")
  
  if result[:success]
    puts "✓ Alice's emote succeeded: #{result[:message]}"
  else
    puts "✗ Alice's emote failed: #{result[:error]}"
  end
  
  # Test 2: Bob emotes mentioning Alice and Charlie
  puts "\n2. Bob emotes: 'looks from Alice Wonderland to Charlie Brown'"
  bob_cmd = Commands::Communication::Emote.new(bob_instance)
  result = bob_cmd.execute("emote looks from Alice Wonderland to Charlie Brown")
  
  if result[:success]
    puts "✓ Bob's emote succeeded: #{result[:message]}"
  else
    puts "✗ Bob's emote failed: #{result[:error]}"
  end
  
  # Test 3: Charlie emotes (should work but others see him by description)
  puts "\n3. Charlie emotes: 'grins at Alice Wonderland'"
  charlie_cmd = Commands::Communication::Emote.new(charlie_instance)
  result = charlie_cmd.execute("emote grins at Alice Wonderland")
  
  if result[:success]
    puts "✓ Charlie's emote succeeded: #{result[:message]}"
  else
    puts "✗ Charlie's emote failed: #{result[:error]}"
  end
  
  # Test display_name_for method directly
  puts "\n--- Testing display_name_for Method ---"
  
  puts "How Alice appears to:"
  puts "  - Bob: #{alice.display_name_for(bob_instance)}"
  puts "  - Charlie: #{alice.display_name_for(charlie_instance)}"
  
  puts "How Bob appears to:"
  puts "  - Alice: #{bob.display_name_for(alice_instance)}"
  puts "  - Charlie: #{bob.display_name_for(charlie_instance)}"
  
  puts "How Charlie appears to:"
  puts "  - Alice: #{charlie.display_name_for(alice_instance)}"
  puts "  - Bob: #{charlie.display_name_for(bob_instance)}"
  
  # Test default instance creation
  puts "\n--- Testing Default Instance Creation ---"
  
  test_char_no_instance = Character.create(
    forename: "TestUser",
    is_npc: true,
    active: true
  )
  
  default_instance = test_char_no_instance.default_instance
  if default_instance
    puts "✓ Default instance created for #{test_char_no_instance.full_name}"
    puts "  - Reality: #{default_instance.reality_id}"
    puts "  - Room: #{default_instance.current_room_id}"
  else
    puts "✗ Failed to create default instance"
  end
  
  puts "\nName substitution tests completed! ✓"
  
rescue => e
  puts "Error during testing: #{e.message}"
  puts e.backtrace.first(5)
  exit 1
end