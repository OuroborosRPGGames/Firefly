# frozen_string_literal: true

# Handles multi-hex occupation for monsters.
# Manages hex marking, movement, and scatter positioning.
class MonsterHexService
  def initialize(monster_instance)
    @monster = monster_instance
    @fight = monster_instance.fight
    @room = @fight.room
  end

  # Get all hexes the monster currently occupies
  # @return [Array<Array<Integer>>] Array of [x, y] pairs
  def occupied_hexes
    @monster.occupied_hexes
  end

  # Check if a specific hex is occupied by this monster
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [Boolean]
  def hex_occupied?(hex_x, hex_y)
    @monster.occupies_hex?(hex_x, hex_y)
  end

  # Check if a participant is adjacent to the monster
  # @param participant [FightParticipant]
  # @return [Boolean]
  def adjacent_to_monster?(participant)
    occupied_hexes.any? do |mx, my|
      distance = hex_distance(participant.hex_x, participant.hex_y, mx, my)
      distance == 1
    end
  end

  # Turn the monster to face a new direction.
  # Also rotates all mounted participants around the monster center.
  # @param new_facing [Integer] 0-5 (0=N, 1=NE, 2=SE, 3=S, 4=SW, 5=NW)
  def turn_monster(new_facing)
    old_facing = @monster.facing_direction || 0
    rotation_steps = (new_facing - old_facing) % 6

    return if rotation_steps.zero?

    # Rotate mounted participants around monster center
    @monster.monster_mount_states.each do |mount_state|
      next unless %w[mounted climbing at_weak_point].include?(mount_state.mount_status)

      participant = mount_state.fight_participant
      dx = participant.hex_x - @monster.center_hex_x
      dy = participant.hex_y - @monster.center_hex_y

      rotated_dx, rotated_dy = rotate_offset(dx, dy, rotation_steps)

      # Clamp to valid arena hex bounds
      new_x, new_y = clamp_to_arena_hex(@monster.center_hex_x + rotated_dx, @monster.center_hex_y + rotated_dy)

      participant.update(hex_x: new_x, hex_y: new_y)
    end

    @monster.update(facing_direction: new_facing)
  end

  # Turn monster to face a specific hex position
  # @param target_x [Integer]
  # @param target_y [Integer]
  def turn_towards(target_x, target_y)
    direction = calculate_facing_towards(target_x, target_y)
    turn_monster(direction)
  end

  # Calculate which hex direction faces a target
  # @param target_x [Integer]
  # @param target_y [Integer]
  # @return [Integer] 0-5 direction
  def calculate_facing_towards(target_x, target_y)
    dx = target_x - @monster.center_hex_x
    dy = target_y - @monster.center_hex_y

    return @monster.facing_direction || 0 if dx.zero? && dy.zero?

    # Calculate angle and map to hex direction
    # Directions: 0=N, 1=NE, 2=SE, 3=S, 4=SW, 5=NW
    # In hex coordinate space (positive y = north):
    #   N at 90°, NE at ~63°, SE at ~-63°, S at -90°, SW at ~-117°, NW at ~117°
    angle = Math.atan2(dy, dx) * 180 / Math::PI

    if angle.abs <= 77
      angle >= 0 ? 1 : 2      # NE or SE
    elsif angle.abs <= 103
      angle >= 0 ? 0 : 3      # N or S
    else
      angle >= 0 ? 5 : 4      # NW or SW
    end
  end

  # Move the monster to a new center position
  # Also moves all mounted participants
  # @param new_x [Integer]
  # @param new_y [Integer]
  def move_monster(new_x, new_y)
    old_center_x = @monster.center_hex_x
    old_center_y = @monster.center_hex_y

    # Calculate movement delta
    dx = new_x - old_center_x
    dy = new_y - old_center_y

    # Move the monster
    @monster.move_to(new_x, new_y)

    # Move all mounted participants with the monster
    @monster.monster_mount_states.each do |mount_state|
      next unless %w[mounted climbing at_weak_point].include?(mount_state.mount_status)

      participant = mount_state.fight_participant
      participant.update(
        hex_x: participant.hex_x + dx,
        hex_y: participant.hex_y + dy
      )
    end
  end

  # Calculate a scatter position for a thrown-off player
  # Semi-random distance in a random direction
  # @param base_x [Integer] starting position (usually monster center)
  # @param base_y [Integer]
  # @return [Array<Integer>] [x, y] landing position
  def calculate_scatter_position(base_x = nil, base_y = nil)
    base_x ||= @monster.center_hex_x
    base_y ||= @monster.center_hex_y

    # Scatter distance: 2-4 hexes away from monster edge
    template = @monster.monster_template
    min_distance = [template.hex_width, template.hex_height].max / 2 + 2
    scatter_distance = min_distance + rand(0..2)

    # Random direction (0-5 for hex directions)
    direction = rand(0..5)

    # Calculate target position based on hex direction
    target_x, target_y = hex_in_direction(base_x, base_y, direction, scatter_distance)

    # Clamp to valid arena hex bounds
    target_x, target_y = clamp_to_arena_hex(target_x, target_y)

    # Avoid landing on the monster itself
    if @monster.occupies_hex?(target_x, target_y)
      # Move further out
      target_x, target_y = hex_in_direction(target_x, target_y, direction, 2)
      target_x, target_y = clamp_to_arena_hex(target_x, target_y)
    end

    [target_x, target_y]
  end

  # Check if a landing hex has a hazard
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [RoomHex, nil] the hazard hex or nil
  def check_hazard_at(hex_x, hex_y)
    return nil unless @room

    room_hex = RoomHex.first(room_id: @room.id, hex_x: hex_x, hex_y: hex_y)
    return nil unless room_hex&.dangerous?

    room_hex
  end

  # Find the closest hex to the monster that isn't occupied by it
  # @param from_x [Integer]
  # @param from_y [Integer]
  # @return [Array<Integer>] [x, y] closest non-occupied hex
  def closest_mounting_hex(from_x, from_y)
    # Get all hexes adjacent to monster's occupied hexes
    adjacent_hexes = []

    occupied_hexes.each do |mx, my|
      6.times do |dir|
        adj_x, adj_y = hex_in_direction(mx, my, dir, 1)
        next if @monster.occupies_hex?(adj_x, adj_y)
        max_x, max_y = arena_hex_bounds
        next if adj_x < 0 || adj_y < 0
        next if adj_x > max_x || adj_y > max_y

        adjacent_hexes << [adj_x, adj_y]
      end
    end

    # Find the closest one to the from position
    adjacent_hexes.uniq.min_by do |ax, ay|
      hex_distance(from_x, from_y, ax, ay)
    end
  end

  private

  # Rotate hex offset by steps (60-degree increments clockwise)
  # @param dx [Integer] x offset from center
  # @param dy [Integer] y offset from center
  # @param steps [Integer] number of 60-degree clockwise rotations
  # @return [Array<Integer>] rotated [dx, dy]
  def rotate_offset(dx, dy, steps)
    return [dx, dy] if steps.zero? || (dx.zero? && dy.zero?)

    steps.times do
      # Hex rotation: 60-degree clockwise step
      # new_x = -dy, new_y = dx + dy
      new_dx = -dy
      new_dy = dx + dy
      dx, dy = new_dx, new_dy
    end

    [dx, dy]
  end

  # Calculate hex distance using the proper offset coordinate formula
  def hex_distance(x1, y1, x2, y2)
    HexGrid.hex_distance(x1, y1, x2, y2)
  end

  # Get the hex position in a given direction and distance.
  # Steps through valid hex neighbors one at a time to maintain valid coordinates.
  # Direction: 0=N, 1=NE, 2=SE, 3=S, 4=SW, 5=NW (matches HexGrid neighbor order)
  def hex_in_direction(x, y, direction, distance)
    idx = direction % 6

    current_x, current_y = HexGrid.to_hex_coords(x, y)
    distance.times do
      neighbors = HexGrid.hex_neighbors(current_x, current_y)
      break if neighbors.empty? || idx >= neighbors.size

      current_x, current_y = neighbors[idx]
    end

    [current_x, current_y]
  end

  # Arena hex bounds using the proper hex coordinate system
  def arena_hex_bounds
    max_x = [@fight.arena_width - 1, 0].max
    max_y = [(@fight.arena_height - 1) * 4 + 2, 0].max
    [max_x, max_y]
  end

  def clamp_to_arena_hex(hex_x, hex_y)
    HexGrid.clamp_to_arena(hex_x, hex_y, @fight.arena_width, @fight.arena_height)
  end
end
