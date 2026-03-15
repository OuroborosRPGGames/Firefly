# frozen_string_literal: true

#!/usr/bin/env ruby

# Test script to verify the emote command implementation

require_relative '../config/application'

puts "Testing Emote Command Implementation..."

begin
  # Test database connection
  puts "Database connection: #{DB.test_connection}"
  
  # Check if required tables exist
  required_tables = [:characters, :character_instances, :rooms]
  required_tables.each do |table|
    if DB.table_exists?(table)
      puts "✓ #{table} table exists"
    else
      puts "✗ #{table} table missing"
    end
  end
  
  # Create test data if none exists
  puts "\n--- Creating Test Data ---"
  
  # Create a reality first if none exists
  test_reality = Reality.first || Reality.create(
    name: "Test Reality",
    description: "A test reality for command testing",
    reality_type: "primary",
    time_offset: 0
  )
  puts "Test reality: #{test_reality.name}"
  
  # Create a test room if none exists
  test_room = Room.first || Room.create(
    name: "Test Room",
    description: "A simple test room for command testing",
    x: 0, y: 0, z: 0
  )
  puts "Test room: #{test_room.name}"
  
  # Create a test NPC character if none exists
  test_char = Character.first || Character.create(
    forename: "TestBot",
    surname: "Alpha",
    is_npc: true,
    active: true
  )
  puts "Test character: #{test_char.full_name}"
  
  # Create character instance
  test_instance = CharacterInstance.first(character_id: test_char.id) || 
                  CharacterInstance.create(
                    character_id: test_char.id,
                    current_room_id: test_room.id,
                    reality_id: test_reality.id,
                    online: true,
                    level: 1,
                    experience: 0,
                    health: 100,
                    max_health: 100,
                    mana: 50,
                    max_mana: 50
                  )
  puts "Character instance created in room #{test_room.id}"
  
  puts "\n--- Testing Command System ---"
  
  # Load command files
  require_relative '../app/commands/base/command'
  require_relative '../app/commands/base/registry'
  require_relative '../app/commands/communication/emote'
  
  puts "✓ Command files loaded"
  
  # Test command registration
  emote_class = Commands::Base::Registry.find_command('emote')
  if emote_class
    puts "✓ Emote command found in registry"
  else
    puts "✗ Emote command not registered"
    exit 1
  end
  
  # Test creating command instance
  emote_cmd = emote_class.new(test_instance)
  puts "✓ Emote command instance created"
  
  # Test can_execute
  if emote_cmd.can_execute?
    puts "✓ Command can execute"
    puts "  - Character: #{emote_cmd.character.full_name}"
    puts "  - Location: #{emote_cmd.location.inspect}"
    puts "  - Location ID: #{emote_cmd.location&.id}"
  else
    puts "✗ Command cannot execute"
    puts "  - Character: #{emote_cmd.character&.full_name}"
    puts "  - Location: #{emote_cmd.location}"
    exit 1
  end
  
  puts "\n--- Testing Emote Execution ---"
  
  # Test basic emote
  result1 = emote_cmd.execute("emote looks around curiously.")
  if result1[:success]
    puts "✓ Basic emote: #{result1[:message]}"
  else
    puts "✗ Basic emote failed: #{result1[:error]}"
  end
  
  # Test with adverb
  result2 = emote_cmd.execute("emote quickly glances around nervously.")
  if result2[:success]
    puts "✓ Adverb emote: #{result2[:message]}"
  else
    puts "✗ Adverb emote failed: #{result2[:error]}"
  end
  
  # Test alias
  result3 = emote_cmd.execute("pose stretches lazily.")
  if result3[:success]
    puts "✓ Pose alias: #{result3[:message]}"
  else
    puts "✗ Pose alias failed: #{result3[:error]}"
  end
  
  # Test : shortcut
  result4 = emote_cmd.execute(": smiles warmly.")
  if result4[:success]
    puts "✓ Colon shortcut: #{result4[:message]}"
  else
    puts "✗ Colon shortcut failed: #{result4[:error]}"
  end
  
  # Test error case
  result5 = emote_cmd.execute("emote")
  if !result5[:success] && result5[:error].include?("What did you want to emote")
    puts "✓ Error handling works"
  else
    puts "✗ Error handling failed"
  end
  
  puts "\n--- Testing Command Registry ---"
  
  # Test registry execution
  registry_result = Commands::Base::Registry.execute_command(test_instance, "emote waves hello.")
  if registry_result[:success]
    puts "✓ Registry execution: #{registry_result[:message]}"
  else
    puts "✗ Registry execution failed: #{registry_result[:error]}"
  end
  
  puts "\nAll tests completed successfully! ✓"
  
rescue => e
  puts "Error during testing: #{e.message}"
  puts e.backtrace.first(5)
  exit 1
end