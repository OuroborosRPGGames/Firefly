# frozen_string_literal: true

# Test Universe Setup Script
# Creates a test universe with complex room layouts for testing pathfinding,
# navigation, and edge cases.
# This script is idempotent - safe to run multiple times.

require_relative 'helpers'
include SetupHelpers

log 'Creating Test Universe...'

DB.transaction do
  # ============================================
  # TEST UNIVERSE HIERARCHY
  # ============================================

  # Create Test Universe
  test_universe_id = ensure_record(
    :universes,
    { name: 'Test' },
    {
      description: 'Test universe for development and testing purposes.',
      theme: 'test'
    }
  )
  log "  Universe: Test (ID: #{test_universe_id})"

  # Create Test World
  test_world_id = ensure_record(
    :worlds,
    { universe_id: test_universe_id, name: 'Test World' },
    {
      description: 'A world designed for testing game systems.',
      climate: 'temperate',
      gravity_multiplier: 1.0,
      coordinates_x: 100,
      coordinates_y: 0,
      coordinates_z: 0,
      world_size: 500.0
    }
  )
  log "  World: Test World (ID: #{test_world_id})"

  # Create Navigation Test Area
  nav_test_area_id = ensure_record(
    :areas,
    { world_id: test_world_id, name: 'Navigation Test Area' },
    {
      description: 'An area for testing navigation and pathfinding.',
      area_type: 'wilderness',
      danger_level: 1
    }
  )
  log "  Area: Navigation Test Area (ID: #{nav_test_area_id})"

  # Create Test Grid Location
  test_grid_location_id = ensure_record(
    :locations,
    { area_id: nav_test_area_id, name: 'Test Grid' },
    {
      description: 'A grid of interconnected rooms for testing.',
      location_type: 'outdoor'
    }
  )
  log "  Location: Test Grid (ID: #{test_grid_location_id})"

  # ============================================
  # 5x5 GRID OF TEST ROOMS
  # ============================================

  log '  Creating 5x5 room grid...'

  # Create rooms in a 5x5 grid (A1-E5)
  grid_rooms = {}
  rows = %w[A B C D E]
  cols = (1..5).to_a

  rows.each_with_index do |row, row_idx|
    cols.each do |col|
      room_name = "Test Room #{row}#{col}"
      room_id = ensure_record(
        :rooms,
        { location_id: test_grid_location_id, name: room_name },
        {
          short_description: "Grid room at position #{row}#{col}.",
          long_description: "A test room at grid position #{row}#{col}. Row #{row_idx + 1}, Column #{col}.",
          room_type: 'standard',
          safe_room: false
        }
      )
      grid_rooms["#{row}#{col}"] = room_id
    end
  end
  log "    Created #{grid_rooms.size} grid rooms"

  # Create horizontal exits (east-west)
  rows.each do |row|
    (1..4).each do |col|
      from_key = "#{row}#{col}"
      to_key = "#{row}#{col + 1}"
      create_bidirectional_exit(grid_rooms[from_key], grid_rooms[to_key], 'east')
    end
  end
  log '    Created horizontal exits'

  # Create vertical exits (north-south)
  (0..3).each do |row_idx|
    cols.each do |col|
      from_key = "#{rows[row_idx]}#{col}"
      to_key = "#{rows[row_idx + 1]}#{col}"
      create_bidirectional_exit(grid_rooms[from_key], grid_rooms[to_key], 'south')
    end
  end
  log '    Created vertical exits'

  # ============================================
  # SPECIAL TEST ROOMS
  # ============================================

  log '  Creating special test rooms...'

  # Create Special Rooms Location
  special_location_id = ensure_record(
    :locations,
    { area_id: nav_test_area_id, name: 'Special Test Rooms' },
    {
      description: 'Special rooms for testing edge cases.',
      location_type: 'dungeon'
    }
  )

  # Intersection Hub - 8 exits
  intersection_hub_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Intersection Hub' },
    {
      short_description: 'A room with exits in all directions.',
      long_description: 'A central hub room with exits in all eight cardinal and ordinal directions. Used for testing multi-exit navigation.',
      room_type: 'standard',
      safe_room: true
    }
  )
  log "    Intersection Hub (ID: #{intersection_hub_id})"

  # Create 8 satellite rooms around the intersection hub
  directions = %w[north south east west northeast northwest southeast southwest]
  satellite_rooms = {}

  directions.each do |dir|
    satellite_name = "Satellite Room (#{dir.capitalize})"
    satellite_id = ensure_record(
      :rooms,
      { location_id: special_location_id, name: satellite_name },
      {
        short_description: "A room #{dir} of the intersection hub.",
        long_description: "A satellite room connected to the intersection hub via the #{dir} exit.",
        room_type: 'standard'
      }
    )
    satellite_rooms[dir] = satellite_id
    create_bidirectional_exit(intersection_hub_id, satellite_id, dir)
  end
  log '    Created 8 satellite rooms with exits'

  # Dead End Cave - single exit
  dead_end_cave_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Dead End Cave' },
    {
      short_description: 'A cave with only one way out.',
      long_description: 'A small, dark cave with only a single exit. Used for testing dead-end handling in pathfinding.',
      room_type: 'standard'
    }
  )
  # Only one exit - no bidirectional, just one way
  create_exit(grid_rooms['C3'], dead_end_cave_id, 'down')
  create_exit(dead_end_cave_id, grid_rooms['C3'], 'up')
  log "    Dead End Cave (ID: #{dead_end_cave_id})"

  # Locked Chamber - locked exit
  locked_chamber_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Locked Chamber' },
    {
      short_description: 'A room behind a locked door.',
      long_description: 'A mysterious chamber accessible only through a locked door. Used for testing locked exit handling.',
      room_type: 'standard'
    }
  )
  # Create one-way exits with lock
  ensure_record(
    :room_exits,
    { from_room_id: grid_rooms['A1'], direction: 'up' },
    { to_room_id: locked_chamber_id, visible: true, passable: true, lock_type: 'locked' }
  )
  ensure_record(
    :room_exits,
    { from_room_id: locked_chamber_id, direction: 'down' },
    { to_room_id: grid_rooms['A1'], visible: true, passable: true }
  )
  log "    Locked Chamber (ID: #{locked_chamber_id})"

  # Hidden Passage - hidden exit
  hidden_passage_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Hidden Passage' },
    {
      short_description: 'A secret passage.',
      long_description: 'A hidden passage that can only be found by those who know where to look. Used for testing hidden exit handling.',
      room_type: 'standard'
    }
  )
  # Create hidden exit from E5
  ensure_record(
    :room_exits,
    { from_room_id: grid_rooms['E5'], direction: 'down' },
    { to_room_id: hidden_passage_id, visible: false, passable: true }
  )
  ensure_record(
    :room_exits,
    { from_room_id: hidden_passage_id, direction: 'up' },
    { to_room_id: grid_rooms['E5'], visible: true, passable: true }
  )
  log "    Hidden Passage (ID: #{hidden_passage_id})"

  # ============================================
  # SPECIAL ROOM TYPES
  # ============================================

  log '  Creating special room type rooms...'

  # Deep Pool - water room
  deep_pool_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Deep Pool' },
    {
      short_description: 'A deep pool of water.',
      long_description: 'A large pool of deep, clear water. Swimming required to navigate. Used for testing water room mechanics.',
      room_type: 'water'
    }
  )
  create_bidirectional_exit(grid_rooms['B2'], deep_pool_id, 'down')
  log "    Deep Pool (ID: #{deep_pool_id}) [type: water]"

  # Underwater Grotto - ocean room
  underwater_grotto_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Underwater Grotto' },
    {
      short_description: 'An underwater cave.',
      long_description: 'A submerged grotto beneath the pool. Breath-holding or water breathing required. Used for testing underwater mechanics.',
      room_type: 'ocean'
    }
  )
  create_bidirectional_exit(deep_pool_id, underwater_grotto_id, 'down')
  log "    Underwater Grotto (ID: #{underwater_grotto_id}) [type: ocean]"

  # Cliff Face - for climbing tests (using standard type since climbing not in validates_includes)
  cliff_face_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Cliff Face' },
    {
      short_description: 'A sheer cliff face.',
      long_description: 'A vertical cliff requiring climbing to navigate. Used for testing climbing mechanics.',
      room_type: 'standard'
    }
  )
  create_bidirectional_exit(grid_rooms['D4'], cliff_face_id, 'up')
  log "    Cliff Face (ID: #{cliff_face_id})"

  # Sky Platform - for flying tests
  sky_platform_id = ensure_record(
    :rooms,
    { location_id: special_location_id, name: 'Sky Platform' },
    {
      short_description: 'A floating platform in the sky.',
      long_description: 'A magical platform floating high above the ground. Flight or levitation required. Used for testing aerial mechanics.',
      room_type: 'standard'
    }
  )
  create_bidirectional_exit(cliff_face_id, sky_platform_id, 'up')
  log "    Sky Platform (ID: #{sky_platform_id})"

  # ============================================
  # LOOP PATH FOR PATHFINDING TESTS
  # ============================================

  log '  Creating loop path...'

  loop_location_id = ensure_record(
    :locations,
    { area_id: nav_test_area_id, name: 'Loop Test Path' },
    {
      description: 'A circular path for testing pathfinding loops.',
      location_type: 'outdoor'
    }
  )

  # Create 6 rooms in a loop
  loop_rooms = []
  (1..6).each do |i|
    room_id = ensure_record(
      :rooms,
      { location_id: loop_location_id, name: "Loop Room #{i}" },
      {
        short_description: "Loop room #{i} of 6.",
        long_description: "Room #{i} in a circular loop of 6 rooms. Used for testing circular pathfinding.",
        room_type: 'standard'
      }
    )
    loop_rooms << room_id
  end

  # Connect in a circle
  (0..5).each do |i|
    next_i = (i + 1) % 6
    create_bidirectional_exit(loop_rooms[i], loop_rooms[next_i], 'east')
  end

  # Connect loop to main grid
  create_bidirectional_exit(grid_rooms['E1'], loop_rooms[0], 'east')
  log "    Created loop path with #{loop_rooms.size} rooms"

  # ============================================
  # SUMMARY
  # ============================================

  total_rooms = DB[:rooms].where(
    location_id: [test_grid_location_id, special_location_id, loop_location_id]
  ).count

  total_exits = DB[:room_exits].join(:rooms, id: :from_room_id)
                               .where(Sequel[:rooms][:location_id] => [test_grid_location_id, special_location_id, loop_location_id])
                               .count

  log ''
  log 'Test Universe setup complete!'
  log "  - 1 Universe: Test"
  log "  - 1 World: Test World"
  log "  - 1 Area: Navigation Test Area"
  log "  - 3 Locations: Test Grid, Special Test Rooms, Loop Test Path"
  log "  - #{total_rooms} rooms total"
  log "  - #{total_exits} exits total"
  log '  Special features:'
  log '    - 5x5 grid for basic pathfinding'
  log '    - Intersection hub with 8 exits'
  log '    - Dead end room'
  log '    - Locked exit'
  log '    - Hidden exit'
  log '    - Water/underwater rooms'
  log '    - Climbing/flying rooms'
  log '    - Circular loop path'
end
