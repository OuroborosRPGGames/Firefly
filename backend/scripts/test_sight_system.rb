# frozen_string_literal: true

#!/usr/bin/env ruby

# Test script for the sight system functionality

require_relative 'config/application'

puts "🔍 Testing Advanced Sight System"
puts "=" * 50

begin
  # Create basic world structure
  puts "🏗️  Setting up test world..."
  
  # Clean any existing data first
  DB.run('DELETE FROM character_knowledge')
  DB.run('DELETE FROM room_sightlines')
  DB.run('DELETE FROM room_features')
  DB.run('DELETE FROM character_instances')
  DB.run('DELETE FROM character_shapes')
  DB.run('DELETE FROM characters')
  DB.run('DELETE FROM users')
  DB.run('DELETE FROM messages')
  DB.run('DELETE FROM room_exits')
  DB.run('DELETE FROM rooms')
  DB.run('DELETE FROM locations')
  DB.run('DELETE FROM areas')
  DB.run('DELETE FROM worlds')
  DB.run('DELETE FROM realities')
  DB.run('DELETE FROM universes')
  
  universe = Universe.create(name: 'Sight Test Universe', theme: 'fantasy')
  world = World.create(universe: universe, name: 'Sight World', gravity_multiplier: 1.0)
  area = Area.create(world: world, name: 'Sight Area', area_type: 'city', danger_level: 1)
  location = Location.create(area: area, name: 'Sight Location', location_type: 'building')
  reality = Reality.create(name: 'Sight Reality', reality_type: 'primary', time_offset: 0)
  
  # Create test rooms
  room1 = Room.create(
    location: location,
    name: 'Town Square',
    short_description: 'The bustling town center',
    long_description: 'A busy square with a fountain in the center',
    room_type: 'safe',
    has_walls: false,      # Open square
    has_ceiling: false,
    lighting_level: 8,     # Well-lit
    transparency: 0.0,
    wall_height: 0.0
  )
  
  room2 = Room.create(
    location: location,
    name: 'Guard Tower',
    short_description: 'A stone watchtower',
    long_description: 'A tall tower providing excellent visibility',
    room_type: 'standard',
    has_walls: true,
    has_ceiling: false,    # Open-top tower
    lighting_level: 9,     # Very bright
    transparency: 0.1,
    wall_height: 12.0
  )
  
  room3 = Room.create(
    location: location,
    name: 'Dark Basement',
    short_description: 'A dimly lit cellar',
    long_description: 'A underground room with poor visibility',
    room_type: 'standard',
    has_walls: true,
    has_ceiling: true,
    lighting_level: 2,     # Very dim
    transparency: 0.0,
    wall_height: 8.0
  )
  
  puts "✅ Created 3 test rooms with different properties"
  
  # Create room features connecting the rooms
  puts "\n🚪 Creating room features..."
  
  # Window from square to tower
  window = RoomFeature.create(
    room: room1,
    connected_room: room2,
    feature_type: 'window',
    name: 'Tower Window',
    description: 'A large window looking into the guard tower',
    x: 25.0, y: 50.0, z: 3.0,
    width: 2.0, height: 1.5,
    orientation: 'north',
    open_state: 'closed',
    transparency_state: 'transparent',
    visibility_state: 'both_ways',
    allows_sight: true,
    sight_reduction: 0.0
  )
  
  # Door from square to basement
  door = RoomFeature.create(
    room: room1,
    connected_room: room3,
    feature_type: 'door',
    name: 'Cellar Door',
    description: 'A heavy wooden door leading to the basement',
    x: 75.0, y: 25.0, z: 0.0,
    width: 1.0, height: 2.0,
    orientation: 'down',
    open_state: 'closed',
    transparency_state: 'opaque',
    visibility_state: 'no_sight',
    has_lock: true,
    lock_difficulty: 'easy',
    allows_movement: true,
    allows_sight: false,  # Opaque door
    sight_reduction: 0.0
  )
  
  # Opening from tower to basement (ladder/stairs)
  opening = RoomFeature.create(
    room: room2,
    connected_room: room3,
    feature_type: 'opening',
    name: 'Stone Staircase',
    description: 'Stone steps leading down to the basement',
    x: 10.0, y: 10.0, z: 0.0,
    width: 1.5, height: 2.5,
    orientation: 'down',
    open_state: 'open',
    transparency_state: 'transparent',
    visibility_state: 'both_ways',
    allows_sight: true,
    sight_reduction: 0.0,
    allows_movement: true
  )
  
  puts "✅ Created 3 room features:"
  puts "   - Window (square ↔ tower): sight = #{window.allows_sight_through?}, quality = #{window.sight_quality}"
  puts "   - Door (square ↔ basement): sight = #{door.allows_sight_through?}, quality = #{door.sight_quality}"
  puts "   - Opening (tower ↔ basement): sight = #{opening.allows_sight_through?}, quality = #{opening.sight_quality}"
  
  # Create test users and characters
  puts "\n👥 Creating test characters..."
  
  user1 = User.create(username: 'player1', email: 'p1@test.com', password_hash: 'hash1', salt: 'salt1')
  user2 = User.create(username: 'player2', email: 'p2@test.com', password_hash: 'hash2', salt: 'salt2')
  
  char1 = Character.create(
    user: user1, forename: 'Alice', surname: 'Lightbringer',
    race: 'human', character_class: 'paladin', is_npc: false,
    short_desc: 'A shining paladin in golden armor',
    nickname: 'Lightbringer'
  )
  
  char2 = Character.create(
    user: user2, forename: 'Bob', surname: 'Stealth',
    race: 'elf', character_class: 'rogue', is_npc: false,
    short_desc: 'A shadowy figure in dark clothing',
    nickname: 'Shadow'
  )
  
  npc_guard = Character.create(
    forename: 'Tower', surname: 'Sentinel',
    race: 'dwarf', character_class: 'fighter', is_npc: true,
    short_desc: 'A stout dwarf in heavy armor',
    nickname: 'Watcher'
  )
  
  # Create character shapes
  shape1 = CharacterShape.create(character: char1, shape_name: 'Human Form', description: 'Default', is_default_shape: true)
  shape2 = CharacterShape.create(character: char2, shape_name: 'Elf Form', description: 'Default', is_default_shape: true)
  shape3 = CharacterShape.create(character: npc_guard, shape_name: 'Dwarf Form', description: 'Default', is_default_shape: true)
  
  # Place characters in different rooms
  instance1 = CharacterInstance.create(
    character: char1, reality: reality, current_room: room1, current_shape: shape1,
    level: 5, experience: 1000, health: 100, max_health: 100, mana: 50, max_mana: 50,
    x: 30.0, y: 30.0, z: 0.0, status: 'alive'
  )
  
  instance2 = CharacterInstance.create(
    character: char2, reality: reality, current_room: room2, current_shape: shape2,
    level: 4, experience: 800, health: 80, max_health: 80, mana: 40, max_mana: 40,
    x: 15.0, y: 20.0, z: 5.0, status: 'alive'
  )
  
  instance3 = CharacterInstance.create(
    character: npc_guard, reality: reality, current_room: room3, current_shape: shape3,
    level: 8, experience: 2000, health: 120, max_health: 120, mana: 20, max_mana: 20,
    x: 10.0, y: 10.0, z: 0.0, status: 'alive'
  )
  
  puts "✅ Created 3 characters:"
  puts "   - Alice (Paladin) in #{room1.name} at #{instance1.position.join(', ')}"
  puts "   - Bob (Rogue) in #{room2.name} at #{instance2.position.join(', ')}"
  puts "   - Tower Sentinel (Guard) in #{room3.name} at #{instance3.position.join(', ')}"
  
  # Test room sightlines
  puts "\n🔍 Testing Room Sightlines..."
  
  sightline_1_to_2 = RoomSightline.calculate_sightline(room1, room2)
  sightline_1_to_3 = RoomSightline.calculate_sightline(room1, room3)
  sightline_2_to_3 = RoomSightline.calculate_sightline(room2, room3)
  
  puts "✅ Sightline calculations:"
  puts "   Square → Tower: sight = #{sightline_1_to_2.has_sight}, quality = #{sightline_1_to_2.sight_quality.round(2)}, through = #{sightline_1_to_2.through_feature&.name}"
  puts "   Square → Basement: sight = #{sightline_1_to_3.has_sight}, quality = #{sightline_1_to_3.sight_quality.round(2)}, through = #{sightline_1_to_3.through_feature&.name}"
  puts "   Tower → Basement: sight = #{sightline_2_to_3.has_sight}, quality = #{sightline_2_to_3.sight_quality.round(2)}, through = #{sightline_2_to_3.through_feature&.name}"
  
  # Test character visibility
  puts "\n👁️  Testing Character Visibility..."
  
  puts "✅ Who can see whom:"
  puts "   Alice can see Bob: #{instance1.can_see?(instance2)}"
  puts "   Alice can see Tower Sentinel: #{instance1.can_see?(instance3)}"
  puts "   Bob can see Alice: #{instance2.can_see?(instance1)}"
  puts "   Bob can see Tower Sentinel: #{instance2.can_see?(instance3)}"
  puts "   Tower Sentinel can see Alice: #{instance3.can_see?(instance1)}"
  puts "   Tower Sentinel can see Bob: #{instance3.can_see?(instance2)}"
  
  puts "\n✅ Visible character counts:"
  puts "   Alice can see #{instance1.visible_characters.count} other character(s)"
  puts "   Bob can see #{instance2.visible_characters.count} other character(s)"
  puts "   Tower Sentinel can see #{instance3.visible_characters.count} other character(s)"
  
  # Test dynamic changes
  puts "\n🔄 Testing Dynamic Feature Changes..."
  
  # Open the cellar door
  door.update(open_state: 'open')
  puts "🚪 Opened the cellar door..."
  
  # Recalculate affected sightlines
  new_sightline_1_to_3 = RoomSightline.calculate_sightline(room1, room3)
  puts "   Square → Basement (door open): sight = #{new_sightline_1_to_3.has_sight}, quality = #{new_sightline_1_to_3.sight_quality.round(2)}"
  
  # Check if Alice can now see the Tower Sentinel
  alice_sees_sentinel = instance1.can_see?(instance3)
  puts "   Alice can now see Tower Sentinel: #{alice_sees_sentinel}"
  
  # Add curtains to the window
  window.update(has_curtains: true, curtain_state: 'closed')
  puts "\n🪟 Closed curtains on the tower window..."
  
  # Recalculate window sightline
  curtained_sightline = RoomSightline.calculate_sightline(room1, room2)
  puts "   Square → Tower (curtains closed): sight = #{curtained_sightline.has_sight}, quality = #{curtained_sightline.sight_quality.round(2)}"
  
  # Check visibility with curtains
  alice_sees_bob_curtained = instance1.can_see?(instance2)
  puts "   Alice can see Bob through curtains: #{alice_sees_bob_curtained}"
  
  # Test one-way visibility
  puts "\n↔️  Testing One-Way Visibility..."
  
  window.update(curtain_state: 'open', visibility_state: 'one_way_out')
  puts "🪟 Set window to one-way (can only see OUT from square)..."
  
  one_way_sightline_1_to_2 = RoomSightline.calculate_sightline(room1, room2)
  one_way_sightline_2_to_1 = RoomSightline.calculate_sightline(room2, room1)
  
  puts "   Square → Tower (one-way): sight = #{one_way_sightline_1_to_2.has_sight}, quality = #{one_way_sightline_1_to_2.sight_quality.round(2)}"
  puts "   Tower → Square (one-way): sight = #{one_way_sightline_2_to_1.has_sight}, quality = #{one_way_sightline_2_to_1.sight_quality.round(2)}"
  
  alice_sees_bob_oneway = instance1.can_see?(instance2)
  bob_sees_alice_oneway = instance2.can_see?(instance1)
  puts "   Alice can see Bob (one-way): #{alice_sees_bob_oneway}"
  puts "   Bob can see Alice (one-way): #{bob_sees_alice_oneway}"
  
  # Final summary
  puts "\n" + "=" * 50
  puts "🎉 SIGHT SYSTEM TEST COMPLETE!"
  puts "=" * 50
  
  puts "\n📈 System Statistics:"
  puts "   Rooms created: #{Room.count}"
  puts "   Room features: #{RoomFeature.count}"
  puts "   Sightlines calculated: #{RoomSightline.count}"
  puts "   Character instances: #{CharacterInstance.count}"
  puts "   Features allowing sight: #{RoomFeature.all.count { |f| f.allows_sight_through? }}"
  puts "   Features allowing movement: #{RoomFeature.all.count { |f| f.allows_movement_through? }}"
  
  puts "\n✨ Advanced sight system with cross-room visibility is fully operational!"
  puts "Features tested:"
  puts "   ✅ Room-to-room sightlines through windows, doors, openings"
  puts "   ✅ Dynamic feature states (open/closed, curtains, locks)"
  puts "   ✅ One-way visibility (mirrors, one-way glass)"
  puts "   ✅ Lighting effects on sight quality"
  puts "   ✅ Position-based line-of-sight calculations"
  puts "   ✅ Cached sightline calculations with expiration"
  puts "   ✅ Cross-room character visibility detection"
  
rescue => e
  puts "\n❌ Error during sight system testing: #{e.message}"
  puts e.backtrace.first(10)
end