# frozen_string_literal: true

# Test helpers that create test objects with sensible defaults.
# These methods supplement FactoryBot factories for more complex setup scenarios.
module TestHelpers
  # Create a test reality with default values
  def create_test_reality(attrs = {})
    Reality.create({ name: "Test Reality #{SecureRandom.hex(4)}", reality_type: 'primary', time_offset: 0 }.merge(attrs))
  end

  # Create a test room with full hierarchy (universe -> world -> area -> location -> room)
  # Note: attrs like reality_id that don't belong to Room are ignored
  def create_test_room(attrs = {})
    # Extract Room-specific attributes, ignoring non-Room attributes like reality_id
    room_attrs = attrs.reject { |k, _| [:reality_id, :reality].include?(k) }

    universe = Universe.create(name: "Test Universe #{SecureRandom.hex(4)}", theme: 'fantasy')
    world = World.create(name: 'Test World', universe: universe, gravity_multiplier: 1.0, world_size: 1000.0)
    area = Area.create(name: 'Test Area', world: world, zone_type: 'wilderness', danger_level: 1)
    location = Location.create(name: 'Test Location', zone: area, location_type: 'outdoor')
    Room.create({ name: 'Test Room', short_description: 'A room', location: location, room_type: 'standard',
                   min_x: 0, max_x: 100, min_y: 0, max_y: 100 }.merge(room_attrs))
  end

  # Create a test character with associated user
  def create_test_character(attrs = {})
    hex = SecureRandom.hex(4)
    user = User.create(email: "user#{hex}@example.com", password_hash: 'hash', username: "user#{hex}", salt: SecureRandom.hex(16))
    # Use unique forename and surname unless explicitly provided
    forename = attrs.delete(:forename) || "Test#{hex[0..3]}"
    surname = attrs.delete(:surname) || "Char#{hex[4..7]}"
    Character.create({ forename: forename, surname: surname, user: user, is_npc: false }.merge(attrs))
  end

  # Create a test character instance with all required fields
  def create_test_character_instance(character:, room:, reality:, **attrs)
    CharacterInstance.create({
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      level: 1,
      experience: 0,
      health: 100,
      max_health: 100,
      mana: 50,
      max_mana: 50
    }.merge(attrs))
  end

  # Create a test pattern (item template)
  def create_test_pattern(attrs = {})
    # Pattern requires unified_object_type, so create one if not provided
    unless attrs[:unified_object_type] || attrs[:unified_object_type_id]
      uot = UnifiedObjectType.create(
        name: "Type #{SecureRandom.hex(4)}",
        category: 'Top'
      )
      attrs = attrs.merge(unified_object_type: uot)
    end

    Pattern.create({
      description: "Pattern #{SecureRandom.hex(4)}",
      price: 100
    }.merge(attrs))
  end

  # Create a test item
  def create_test_item(name:, pattern:, character_instance:, **attrs)
    Item.create({ name: name, pattern: pattern, character_instance: character_instance }.merge(attrs))
  end

  # Create a test user
  def create_test_user(attrs = {})
    hex = SecureRandom.hex(4)
    User.create({ email: "user#{hex}@example.com", password_hash: 'hash', username: "user#{hex}", salt: SecureRandom.hex(16) }.merge(attrs))
  end

  # Create a test place within a room
  def create_test_place(room:, **attrs)
    Place.create({ name: "Test Place #{SecureRandom.hex(4)}", room: room }.merge(attrs))
  end

  # Create test world hierarchy and return all components
  def create_test_world_hierarchy
    universe = Universe.create(name: "Test Universe #{SecureRandom.hex(4)}", theme: 'fantasy')
    world = World.create(name: 'Test World', universe: universe, gravity_multiplier: 1.0, world_size: 1000.0)
    area = Area.create(name: 'Test Area', world: world, zone_type: 'wilderness', danger_level: 1)
    location = Location.create(name: 'Test Location', zone: area, location_type: 'outdoor')
    room = Room.create(name: 'Test Room', short_description: 'A room', location: location, room_type: 'standard',
                        min_x: 0, max_x: 100, min_y: 0, max_y: 100)
    { universe: universe, world: world, zone: area, location: location, room: room }
  end
end
