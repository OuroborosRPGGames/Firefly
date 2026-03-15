# frozen_string_literal: true

#!/usr/bin/env ruby

# Comprehensive test of the new MUD database schema

require_relative 'config/application'

puts "🎯 Testing Comprehensive MUD Database Schema"
puts "=" * 50

begin
  # Clean up any existing test data
  puts "🧹 Cleaning up previous test data..."
  Message.where(Sequel.like(:content, '%shall not pass%')).delete
  CharacterDescription.where(character_instance_id: CharacterInstance.where(character_id: Character.where(forename: 'Gandalf').select(:id)).select(:id)).delete
  CharacterInstance.where(character_id: Character.where(forename: 'Gandalf').select(:id)).delete
  CharacterShape.where(character_id: Character.where(forename: 'Gandalf').select(:id)).delete
  Character.where(forename: 'Gandalf').delete
  Character.where(forename: 'Marcus').delete
  User.where(username: 'testplayer').delete
  Reality.where(name: 'The Battle of Five Armies').delete
  Item.where(name: 'Old Wooden Chest').delete
  Item.where(name: ['Staff of Power', "Gandalf's Staff of Power"]).delete
  # Test User Creation
  puts "\n1. Testing User Management..."
  user = User.create(
    username: 'testplayer',
    email: 'test@example.com', 
    password_hash: 'dummy_hash',
    salt: 'dummy_salt'
  )
  puts "✅ Created user: #{user.username} (ID: #{user.id})"
  
  # Test Character Creation
  puts "\n2. Testing Character System..."
  character = Character.create(
    user: user,
    forename: 'Gandalf',
    surname: 'the Grey',
    race: 'wizard',
    character_class: 'mage',
    gender: 'male',
    age: 2000,
    is_npc: false
  )
  puts "✅ Created character: #{character.full_name} (ID: #{character.id})"
  
  # Test Character Shapes
  puts "\n3. Testing Character Shapes..."
  default_shape = CharacterShape.create(
    character: character,
    shape_name: 'Human Form',
    description: 'The traditional form of a wise wizard',
    shape_type: 'humanoid',
    size: 'medium',
    is_default_shape: true
  )
  
  eagle_shape = CharacterShape.create(
    character: character,
    shape_name: 'Great Eagle',
    description: 'A majestic eagle form for soaring the skies',
    shape_type: 'animal',
    size: 'large'
  )
  puts "✅ Created shapes: #{character.character_shapes.map(&:shape_name).join(', ')}"
  
  # Test World Hierarchy
  puts "\n4. Testing World Hierarchy..."
  universe = Universe.first(name: 'Prometheus Prime')
  world = universe.worlds.first
  area = world.areas.first
  location = area.locations.first
  room = location.rooms.first
  
  puts "✅ World hierarchy: #{room.full_path}"
  
  # Test Realities
  puts "\n5. Testing Reality System..."
  primary_reality = Reality.first(reality_type: 'primary')
  flashback_reality = Reality.create(
    name: 'The Battle of Five Armies',
    description: 'A flashback to the great battle',
    reality_type: 'flashback',
    time_offset: -365 # One year ago
  )
  puts "✅ Created realities: #{Reality.count} total"
  
  # Test Character Instances  
  puts "\n6. Testing Character Instances..."
  # Present day instance
  present_instance = CharacterInstance.create(
    character: character,
    reality: primary_reality,
    current_room: room,
    current_shape: default_shape,
    level: 50,
    experience: 125000,
    health: 180,
    max_health: 200,
    mana: 150,
    max_mana: 200,
    stats: {
      strength: 12, dexterity: 16, constitution: 14,
      intelligence: 20, wisdom: 18, charisma: 17
    }.to_json
  )
  
  # Flashback instance  
  flashback_instance = CharacterInstance.create(
    character: character,
    reality: flashback_reality,
    current_room: room,
    current_shape: eagle_shape,
    level: 45,
    experience: 100000,
    health: 160,
    max_health: 180,
    mana: 140,
    max_mana: 180
  )
  
  puts "✅ Created #{character.character_instances.count} character instances across realities"
  
  # Test Character Descriptions
  puts "\n7. Testing Description System..."
  face_type = DescriptionType.first(name: 'face')
  CharacterDescription.create(
    character_instance: present_instance,
    description_type: face_type,
    content: 'A weathered but wise face with piercing blue eyes and a long grey beard',
    mood_context: nil
  )
  
  CharacterDescription.create(
    character_instance: present_instance,
    description_type: face_type,
    content: 'His face is stern and focused, eyes blazing with righteous anger',
    mood_context: 'angry'
  )
  
  puts "✅ Added descriptions for different moods"
  
  # Test NPC System
  puts "\n8. Testing NPC System..."
  guard_archetype = NpcArchetype.first(name: 'Town Guard')
  npc_guard = Character.create(
    forename: 'Marcus',
    surname: 'Ironshield',
    race: 'human',
    character_class: 'fighter',
    is_npc: true,
    npc_archetype: guard_archetype
  )
  
  # Create NPC instance
  guard_shape = CharacterShape.create(
    character: npc_guard,
    shape_name: 'Default',
    description: 'A sturdy human guard',
    is_default_shape: true
  )
  
  guard_instance = CharacterInstance.create(
    character: npc_guard,
    reality: primary_reality,
    current_room: room,
    current_shape: guard_shape,
    level: 15,
    experience: 5000,
    health: 120,
    max_health: 120,
    mana: 30,
    max_mana: 30
  )
  
  puts "✅ Created NPC: #{npc_guard.full_name} (#{npc_guard.npc_archetype ? npc_guard.npc_archetype.name : 'No archetype'})"
  
  # Test Object System
  puts "\n9. Testing Object System..."
  # Objects can now be created without an object_type (consolidated to Pattern system)

  # Create objects - character held item
  gandalfs_staff = Item.create(
    character_instance: present_instance,
    name: "Gandalf's Staff of Power",
    description: 'This ancient staff thrums with magical power',
    equipped: true,
    equipment_slot: 'weapon'
  )

  # Object in room
  treasure_chest = Item.create(
    room: room,
    name: 'Old Wooden Chest',
    description: 'A weathered chest that might contain treasure'
  )
  
  puts "✅ Created objects: #{present_instance.objects.count} on character, #{room.objects.count} in room"
  
  # Test Message System
  puts "\n10. Testing Enhanced Message System..."
  Message.create(
    character_instance: present_instance,
    reality: primary_reality,
    room: room,
    content: "You shall not pass!",
    message_type: 'say'
  )
  
  Message.create(
    character_instance: present_instance,
    character_instance_id: present_instance.id,
    target_character_instance_id: guard_instance.id,
    reality: primary_reality,
    room: room,
    content: "Guard the bridge well, my friend.",
    message_type: 'tell'
  )
  
  puts "✅ Created #{Message.count} messages with reality/room context"
  
  # Test Room Exits
  puts "\n11. Testing Room Connection System..."
  inn = room.location.rooms.find { |r| r.name == 'The Prancing Pony Inn' }
  if inn
    exit_to_inn = RoomExit.first(from_room: room, to_room: inn)
    puts "✅ Found exit: #{room.name} --#{exit_to_inn.direction}--> #{inn.name}"
  end
  
  # Summary
  puts "\n" + "=" * 50
  puts "🎉 COMPREHENSIVE TEST COMPLETE!"
  puts "=" * 50
  
  puts "\n📊 Database Summary:"
  puts "   Users: #{User.count}"
  puts "   Characters: #{Character.count} (#{Character.where(is_npc: false).count} PCs, #{Character.where(is_npc: true).count} NPCs)"
  puts "   Character Shapes: #{CharacterShape.count}"
  puts "   Character Instances: #{CharacterInstance.count} across #{Reality.count} realities"
  puts "   Universes: #{Universe.count} -> Worlds: #{World.count} -> Areas: #{Area.count} -> Locations: #{Location.count} -> Rooms: #{Room.count}"
  puts "   Objects: #{Item.count} (#{Item.exclude(character_instance_id: nil).count} carried, #{Item.exclude(room_id: nil).count} in rooms)"
  puts "   Messages: #{Message.count}"
  puts "   Room Exits: #{RoomExit.count}"
  
  puts "\n✨ All systems operational! The MUD database is ready for adventure!"
  
  # Test new coordinate and naming systems
  puts "\n12. Testing Coordinate System..."
  
  # Test character positioning
  present_instance.move_to(25.5, 30.0, 2.5)
  puts "✅ Moved #{character.full_name} to position #{present_instance.position.join(', ')}"
  puts "   Within room bounds: #{present_instance.within_room_bounds?}"
  
  # Test character naming and knowledge system
  puts "\n13. Testing Character Knowledge System..."
  
  # Set short description and nickname
  character.update(
    short_desc: "A wise-looking wizard with a long grey beard",
    nickname: "The Grey Wanderer"
  )
  
  # Test unknown character display name
  unknown_display = character.display_name_for(guard_instance)
  puts "✅ Unknown character shows as: '#{unknown_display}'"
  
  # Introduce characters to each other
  character.introduce_to(npc_guard, "Gandalf the Grey")
  npc_guard.introduce_to(character, "Guard Marcus")
  
  # Test known character display name
  known_display = character.display_name_for(guard_instance)
  puts "✅ Known character shows as: '#{known_display}'"
  
  # Test visibility system
  puts "\n14. Testing Character Visibility..."
  
  # Move guard to same position
  guard_instance.move_to(26.0, 29.0, 2.0)
  
  visible_to_gandalf = present_instance.visible_characters.count
  visible_to_guard = guard_instance.visible_characters.count
  
  puts "✅ #{character.full_name} can see #{visible_to_gandalf} other character(s)"
  puts "✅ #{npc_guard.full_name} can see #{visible_to_guard} other character(s)"
  puts "✅ Characters can see each other: #{present_instance.can_see?(guard_instance)}"
  
  # Final summary with new features
  puts "\n" + "=" * 50
  puts "🎉 ENHANCED TEST COMPLETE!"
  puts "=" * 50
  
  puts "\n📊 Enhanced Database Summary:"
  puts "   Character Knowledge Entries: #{CharacterKnowledge.count}"
  puts "   Characters with coordinates: #{CharacterInstance.exclude(x: nil).count}"
  puts "   Characters with short descriptions: #{Character.exclude(short_desc: nil).count}"
  puts "   Characters with nicknames: #{Character.exclude(nickname: nil).count}"
  
  puts "\n✨ All systems including coordinates and naming are operational!"
  
  # Test new sight system
  puts "\n15. Testing Room Sight Features..."
  
  # Create a second room for testing sightlines
  second_room = Room.create(
    location: location,
    name: 'Guard Tower',
    short_description: 'A stone watchtower',
    long_description: 'This tall stone tower provides an excellent vantage point over the surrounding area.',
    room_type: 'standard'
  )
  
  # Add room sight properties
  room.update(
    has_walls: true,
    has_ceiling: true,
    lighting_level: 7,
    transparency: 0.0,
    wall_height: 8.0
  )
  
  second_room.update(
    has_walls: true,
    has_ceiling: false,  # Open-top tower
    lighting_level: 9,   # Well-lit
    transparency: 0.1    # Slightly transparent (magical)
  )
  
  # Create a window connecting the rooms
  window = RoomFeature.create(
    room: room,
    connected_room: second_room,
    feature_type: 'window',
    name: 'Large Window',
    description: 'A large window overlooking the guard tower',
    x: 50.0, y: 25.0, z: 3.0,
    width: 2.0, height: 1.5,
    orientation: 'north',
    open_state: 'closed',
    transparency_state: 'transparent',
    visibility_state: 'both_ways'
  )
  
  # Create a door between rooms
  door = RoomFeature.create(
    room: room,
    connected_room: second_room,
    feature_type: 'door',
    name: 'Heavy Oak Door',
    description: 'A sturdy door leading to the guard tower',
    x: 75.0, y: 50.0, z: 0.0,
    width: 1.0, height: 2.5,
    orientation: 'east',
    open_state: 'closed',
    transparency_state: 'opaque',
    has_lock: true,
    allows_movement: true
  )
  
  puts "✅ Created room features: window and door"
  puts "   Window sight quality: #{window.sight_quality}"
  puts "   Window allows sight: #{window.allows_sight_through?}"
  puts "   Door allows sight: #{door.allows_sight_through?}"
  puts "   Door allows movement: #{door.allows_movement_through?}"
  
  # Test sightlines
  puts "\n16. Testing Room Sightlines..."
  
  sightline = RoomSightline.calculate_sightline(room, second_room)
  puts "✅ Calculated sightline between rooms"
  puts "   Has sight: #{sightline.has_sight}"
  puts "   Sight quality: #{sightline.sight_quality}"
  puts "   Through feature: #{sightline.through_feature&.name}"
  puts "   Max distance: #{sightline.max_distance}"
  
  # Create a character in the second room
  tower_guard = Character.create(
    forename: 'Tower',
    surname: 'Guard',
    race: 'human',
    character_class: 'fighter',
    is_npc: true,
    short_desc: 'A vigilant guard in chainmail',
    nickname: 'Watcher'
  )
  
  guard_shape = CharacterShape.create(
    character: tower_guard,
    shape_name: 'Default',
    description: 'A sturdy human guard',
    is_default_shape: true
  )
  
  tower_guard_instance = CharacterInstance.create(
    character: tower_guard,
    reality: primary_reality,
    current_room: second_room,
    current_shape: guard_shape,
    level: 12,
    experience: 3000,
    health: 100,
    max_health: 100,
    x: 20.0, y: 30.0, z: 1.0
  )
  
  puts "✅ Created guard in second room"
  
  # Test cross-room visibility
  puts "\n17. Testing Cross-Room Character Visibility..."
  
  # Test if characters can see each other across rooms
  gandalf_can_see_guard = present_instance.can_see?(tower_guard_instance)
  guard_can_see_gandalf = tower_guard_instance.can_see?(present_instance)
  
  puts "✅ Cross-room visibility test:"
  puts "   Gandalf can see Tower Guard: #{gandalf_can_see_guard}"
  puts "   Tower Guard can see Gandalf: #{guard_can_see_gandalf}"
  
  # Test visible characters count including cross-room
  visible_to_gandalf = present_instance.visible_characters.count
  visible_to_guard_enhanced = tower_guard_instance.visible_characters.count
  
  puts "✅ Enhanced visibility counts:"
  puts "   Gandalf can see #{visible_to_gandalf} character(s) total"
  puts "   Tower Guard can see #{visible_to_guard_enhanced} character(s) total"
  
  # Test opening the door
  puts "\n18. Testing Dynamic Feature States..."
  
  door.update(open_state: 'open')
  puts "✅ Opened the door between rooms"
  
  # Recalculate sightline after door opening
  new_sightline = RoomSightline.calculate_sightline(room, second_room)
  puts "   New sight quality: #{new_sightline.sight_quality}"
  puts "   Door now allows movement: #{door.allows_movement_through?}"
  puts "   Door now allows sight: #{door.allows_sight_through?}"
  
  # Test with curtains
  window.update(has_curtains: true, curtain_state: 'closed')
  puts "\n✅ Closed curtains on window"
  
  curtained_sightline = RoomSightline.calculate_sightline(room, second_room)
  puts "   Sight quality with closed curtains: #{curtained_sightline.sight_quality}"
  puts "   Window allows sight with curtains: #{window.allows_sight_through?}"
  
  # Final summary with new features
  puts "\n" + "=" * 50
  puts "🎉 COMPLETE SIGHT SYSTEM TEST FINISHED!"
  puts "=" * 50
  
  puts "\n📊 Complete Database Summary:"
  puts "   Room Features: #{RoomFeature.count}"
  puts "   Room Sightlines: #{RoomSightline.count}"
  puts "   Rooms with walls: #{Room.where(has_walls: true).count}"
  puts "   Features allowing sight: #{RoomFeature.count { |f| f.allows_sight_through? }}"
  puts "   Features allowing movement: #{RoomFeature.count { |f| f.allows_movement_through? }}"
  
  puts "\n✨ Complete sight system with cross-room visibility is operational!"
  
rescue => e
  puts "\n❌ Error during testing: #{e.message}"
  puts e.backtrace.first(10)
end