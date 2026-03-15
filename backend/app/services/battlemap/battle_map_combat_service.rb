# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

# Provides battle map integration for combat resolution.
# Handles cover, elevation, line of sight, hazards, and terrain effects.
class BattleMapCombatService
  REDIS_HEX_CACHE_TTL = 3600  # 1 hour
  REDIS_HEX_CACHE_PREFIX = 'bmhex:'

  attr_reader :fight, :room

  # Initialize with a fight that uses battle maps
  # @param fight [Fight] the fight to process
  def initialize(fight)
    @fight = fight
    @room = fight.room
    @hex_cache = nil
  end

  # Check if battle map features should be applied
  # @return [Boolean]
  def battle_map_active?
    fight.uses_battle_map && room&.has_battle_map
  end

  # Retrieve a hex from the in-memory cache (built on first access).
  # Falls back to DB query if hex not found in cache.
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [RoomHex, nil]
  def cached_hex(hex_x, hex_y)
    build_hex_cache unless @hex_cache
    @hex_cache[[hex_x, hex_y]]
  end

  # Force-rebuild the hex cache (call after hex mutations like destroy_cover).
  def invalidate_hex_cache!
    @hex_cache = nil
    invalidate_redis_hex_cache!
  end

  # ========================================
  # Cover System
  # ========================================

  # Destroy a cover hex (convert to debris)
  # @param hex [RoomHex]
  # @return [Boolean] success
  def destroy_cover(hex)
    return false unless hex.destroyable

    result = hex.destroy_cover!
    invalidate_hex_cache! if result
    result
  end

  # Damage a cover hex
  # @param hex [RoomHex]
  # @param damage [Integer]
  # @return [Boolean] true if cover was destroyed
  def damage_cover(hex, damage)
    return false unless hex.destroyable && hex.hit_points.to_i > 0

    new_hp = hex.hit_points - damage
    if new_hp <= 0
      hex.destroy_cover!
      invalidate_hex_cache!
      true
    else
      hex.update(hit_points: new_hp)
      invalidate_hex_cache!
      false
    end
  end

  # ========================================
  # Elevation System
  # ========================================

  # Calculate elevation modifier for combat
  # Higher ground gives attack bonus, lower ground gives penalty
  # @param attacker [FightParticipant]
  # @param defender [FightParticipant]
  # @return [Integer] modifier (-2 to +2)
  def elevation_modifier(attacker, defender)
    return 0 unless battle_map_active?

    attacker_z = attacker.hex_z.to_i
    defender_z = defender.hex_z.to_i

    # Also consider hex elevation if participant doesn't have explicit elevation
    if attacker_z == 0
      attacker_hex = room.hex_details(attacker.hex_x, attacker.hex_y)
      attacker_z = attacker_hex&.elevation_level.to_i
    end

    if defender_z == 0
      defender_hex = room.hex_details(defender.hex_x, defender.hex_y)
      defender_z = defender_hex&.elevation_level.to_i
    end

    RoomHex.elevation_modifier_for_combat(attacker_z, defender_z)
  end

  # Update participant's elevation based on hex
  # @param participant [FightParticipant]
  def sync_participant_elevation(participant)
    return unless battle_map_active?

    hex = room.hex_details(participant.hex_x, participant.hex_y)
    participant.update(hex_z: hex&.elevation_level.to_i)
  end

  # ========================================
  # Line of Sight
  # ========================================

  # Check if viewer has line of sight to target
  # Uses hex-level check (only blocked by hexes with blocks_line_of_sight flag).
  # Pixel-level wall mask checking was too aggressive — interior cover objects
  # in the mask were incorrectly blocking LoS across open rooms.
  # @param viewer [FightParticipant]
  # @param target [FightParticipant]
  # @return [Boolean]
  def has_line_of_sight?(viewer, target)
    return true unless battle_map_active?

    # Try pixel-level wall mask ray cast first (more accurate)
    wall_mask = WallMaskService.for_room(fight.room)
    if wall_mask
      p1 = wall_mask.hex_to_pixel(viewer.hex_x, viewer.hex_y)
      p2 = wall_mask.hex_to_pixel(target.hex_x, target.hex_y)
      return wall_mask.ray_los_clear?(p1[0], p1[1], p2[0], p2[1])
    end

    # Fall back to hex-level LOS
    hex_line_of_sight?(viewer, target)
  end

  # Get line of sight penalty if LoS is blocked
  # @param viewer [FightParticipant]
  # @param target [FightParticipant]
  # @return [Integer] penalty (0 or -4)
  def line_of_sight_penalty(viewer, target)
    has_line_of_sight?(viewer, target) ? 0 : -4
  end

  # Check if a wall edge blocks melee between two adjacent hexes.
  # Uses the same passable_edges check as movement — if you can't walk there,
  # you can't punch through it either (walls AND windows block melee).
  # @param attacker [FightParticipant]
  # @param target [FightParticipant]
  # @return [Boolean] true if wall blocks the melee attack
  def wall_blocks_melee?(attacker, target)
    return false unless battle_map_active?

    room = fight.room
    return false unless room

    to_hex = RoomHex.where(room_id: room.id, hex_x: target.hex_x, hex_y: target.hex_y).first
    return false unless to_hex && !to_hex.passable_edges.nil?

    dx = target.hex_x - attacker.hex_x
    dy = target.hex_y - attacker.hex_y
    dir_idx = CombatPathfindingService::PATH_HEX_OFFSETS.index([dx, dy])
    return false unless dir_idx  # not adjacent or unrecognized offset

    direction = CombatPathfindingService::DIRECTION_NAMES[dir_idx]
    !to_hex.passable_from?(direction)
  end

  # Check if a wall blocks ranged attacks between two participants.
  # Walls fully block; windows and doors do NOT block ranged attacks (you can
  # shoot through a window or an open doorway).
  # @param attacker [FightParticipant]
  # @param target [FightParticipant]
  # @return [Boolean] true if wall blocks the ranged attack
  def wall_blocks_ranged?(attacker, target)
    return false unless battle_map_active?
    !has_line_of_sight?(attacker, target)
  end

  # ========================================
  # Hazard System
  # ========================================

  # Process hazard damage for all participants at end of round
  # @return [Array<Hash>] damage events
  def process_all_hazard_damage
    return [] unless battle_map_active?

    events = []
    fight.active_participants.each do |participant|
      event = process_hazard_damage(participant)
      events << event if event
    end
    events
  end

  # Process hazard damage for a single participant
  # @param participant [FightParticipant]
  # @return [Hash, nil] damage event or nil if no hazard
  def process_hazard_damage(participant)
    return nil unless battle_map_active?

    hex = cached_hex(participant.hex_x, participant.hex_y)
    return nil unless hex&.is_hazard?
    return nil unless hex.hazard_damage_per_round.to_i > 0

    damage = hex.hazard_damage_per_round

    # Apply damage — hazards always hit (no save)
    hp_lost = participant.take_damage(damage)

    {
      participant: participant,
      damage: hp_lost,
      damage_type: hex.hazard_damage_type,
      hazard_type: hex.hazard_type,
      hex_x: hex.hex_x,
      hex_y: hex.hex_y
    }
  end

  # Trigger a potential hazard
  # @param hex [RoomHex]
  # @param trigger_type [String]
  # @return [Boolean] true if hazard was triggered
  def trigger_hazard(hex, trigger_type)
    hex.trigger_potential_hazard!(trigger_type)
  end

  # ========================================
  # Explosive System
  # ========================================

  # Trigger an explosion at a hex
  # @param hex [RoomHex]
  # @return [Array<Hash>] damage events for affected participants
  def trigger_explosion(hex)
    return [] unless battle_map_active?

    explosion_data = hex.trigger_explosion!(fight)
    return [] unless explosion_data

    # Track this explosion in fight state
    track_explosion(explosion_data)

    # Find affected participants
    events = []
    radius = explosion_data[:radius]
    damage = explosion_data[:damage]

    fight.active_participants.each do |participant|
      distance = HexGrid.hex_distance(
        explosion_data[:center_x], explosion_data[:center_y],
        participant.hex_x, participant.hex_y
      )

      next if distance > radius

      # Damage decreases with distance
      effective_damage = damage - (distance * 2)
      effective_damage = [effective_damage, 1].max

      hp_lost = participant.take_damage(effective_damage)

      events << {
        participant: participant,
        damage: hp_lost,
        damage_type: 'explosion',
        distance: distance,
        center_x: explosion_data[:center_x],
        center_y: explosion_data[:center_y]
      }
    end

    # Check for chain reactions (nearby explosives)
    check_chain_explosions(explosion_data[:center_x], explosion_data[:center_y], radius, events)

    events
  end

  # Check for chain explosions from nearby explosives
  def check_chain_explosions(center_x, center_y, radius, events)
    nearby_explosives = room.explosive_hexes.select do |hex|
      distance = HexGrid.hex_distance(center_x, center_y, hex.hex_x, hex.hex_y)
      distance <= radius && hex.should_explode?('fire')
    end

    nearby_explosives.each do |hex|
      chain_events = trigger_explosion(hex)
      events.concat(chain_events)
    end
  end

  # Track explosion in fight state
  def track_explosion(explosion_data)
    return unless fight.respond_to?(:triggered_hazards)

    hazards = fight.triggered_hazards || []
    hazards << {
      type: 'explosion',
      x: explosion_data[:center_x],
      y: explosion_data[:center_y],
      radius: explosion_data[:radius],
      round: fight.round_number
    }
    fight.update(triggered_hazards: Sequel.pg_jsonb_wrap(hazards))
  end

  # ========================================
  # Movement System
  # ========================================

  # Calculate movement cost from one hex to another
  # @param from_x [Integer]
  # @param from_y [Integer]
  # @param to_x [Integer]
  # @param to_y [Integer]
  # @param participant [FightParticipant]
  # @return [Float] movement cost (1.0 = normal, Infinity = impassable)
  def movement_cost(from_x, from_y, to_x, to_y, participant = nil)
    return Float::INFINITY unless battle_map_active?

    from_hex = room.hex_details(from_x, from_y)
    to_hex = room.hex_details(to_x, to_y)

    return Float::INFINITY unless to_hex.traversable

    # Base cost from target hex
    cost = to_hex.calculated_movement_cost

    # Check elevation transition
    unless from_hex.can_transition_to?(to_hex)
      return Float::INFINITY
    end

    # Swimming check - non-swimmers can't enter deep water
    if to_hex.requires_swim_check?
      if participant && !participant.is_swimming
        return Float::INFINITY if to_hex.water_type == 'deep'
      end
    end

    cost
  end

  # Check if participant can move through a hex
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @param participant [FightParticipant]
  # @return [Boolean]
  def can_move_through?(hex_x, hex_y, participant = nil)
    return true unless battle_map_active?

    hex = room.hex_details(hex_x, hex_y)
    return false unless hex.traversable

    # Check for swimming requirement
    if hex.requires_swim_check?
      return false if hex.water_type == 'deep' && !(participant&.is_swimming)
    end

    true
  end

  # Update participant swimming state based on hex
  # @param participant [FightParticipant]
  def update_swimming_state(participant)
    return unless battle_map_active?

    hex = room.hex_details(participant.hex_x, participant.hex_y)
    should_swim = hex&.requires_swim_check? || false
    participant.update(is_swimming: should_swim) if participant.is_swimming != should_swim
  end

  # ========================================
  # Prone System
  # ========================================

  # Set participant as prone
  # @param participant [FightParticipant]
  def go_prone(participant)
    participant.update(is_prone: true)
  end

  # Stand participant up
  # @param participant [FightParticipant]
  def stand_up(participant)
    participant.update(is_prone: false)
  end

  # Get attack modifier for prone target
  # @param attacker [FightParticipant]
  # @param defender [FightParticipant]
  # @return [Integer] modifier
  def prone_modifier(attacker, defender)
    return 0 unless defender.is_prone

    distance = HexGrid.hex_distance(
      attacker.hex_x, attacker.hex_y,
      defender.hex_x, defender.hex_y
    )

    # Melee attacks get +2 against prone, ranged get -2
    distance <= 1 ? 2 : -2
  end

  # ========================================
  # Ranged Combat Modifiers
  # ========================================

  # Calculate damage bonus for elevation advantage on ranged attacks
  # +2 damage when attacker is 2 or more levels above the target
  # @param attacker [FightParticipant]
  # @param defender [FightParticipant]
  # @return [Integer] bonus damage (0 or 2)
  def elevation_damage_bonus(attacker, defender)
    return 0 unless battle_map_active?

    attacker_z = participant_elevation(attacker)
    defender_z = participant_elevation(defender)

    (attacker_z - defender_z) >= 2 ? 2 : 0
  end

  # Check if a ranged shot passes through any cover-providing hex
  # Note: Cover adjacent to the attacker doesn't count - if you're behind a rock,
  # you can shoot out without penalty. Only obstacles you're shooting THROUGH matter.
  # Uses contiguous block grouping for proper cover detection.
  # @param attacker [FightParticipant]
  # @param defender [FightParticipant]
  # @return [Boolean]
  def shot_passes_through_cover?(attacker, defender)
    return false unless battle_map_active?
    return false unless attacker&.hex_x && attacker&.hex_y
    return false unless defender&.hex_x && defender&.hex_y

    hexes_coords = hexes_in_line(
      attacker.hex_x, attacker.hex_y,
      defender.hex_x, defender.hex_y
    )

    hexes_in_path = hexes_coords.filter_map do |hex_x, hex_y|
      cached_hex(hex_x, hex_y)
    end

    attacker_pos = [attacker.hex_x, attacker.hex_y]
    CoverLosService.cover_applies?(attacker_pos: attacker_pos, hexes_in_path: hexes_in_path)
  end

  # Get effective elevation for a participant
  # @param participant [FightParticipant]
  # @return [Integer]
  def participant_elevation(participant)
    z = participant.hex_z.to_i
    return z if z > 0

    hex = room.hex_details(participant.hex_x, participant.hex_y)
    hex&.elevation_level.to_i
  end

  # ========================================
  # AI Position Evaluation
  # ========================================

  # Find hexes within range that provide cover from enemies
  # @param participant [FightParticipant]
  # @param enemies [Array<FightParticipant>]
  # @param max_distance [Integer] max hexes to search
  # @return [Array<Hash>] hexes with cover: [{x:, y:, cover_directions:}]
  def find_cover_hexes(participant, enemies, max_distance: 3)
    return [] unless battle_map_active?

    candidates = []
    center_x, center_y = participant.hex_x, participant.hex_y

    (-max_distance..max_distance).each do |dx|
      (-max_distance..max_distance).each do |dy|
        hx, hy = center_x + dx, center_y + dy
        next if HexGrid.hex_distance(center_x, center_y, hx, hy) > max_distance

        hex = cached_hex(hx, hy)
        next unless hex&.traversable && !hex.blocks_movement?

        cover_directions = find_adjacent_cover_directions(hx, hy, enemies)
        next if cover_directions.empty?

        candidates << { x: hx, y: hy, cover_directions: cover_directions }
      end
    end

    candidates
  end

  # Find directions from which this hex has adjacent cover against enemies
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @param enemies [Array<FightParticipant>]
  # @return [Array<String>] directions with useful cover
  def find_adjacent_cover_directions(hex_x, hex_y, enemies)
    return [] unless battle_map_active?

    directions = []
    %w[N NE SE S SW NW].each do |dir|
      neighbor = HexGrid.hex_neighbor_by_direction(hex_x, hex_y, dir)
      next unless neighbor

      cover_hex = cached_hex(neighbor[0], neighbor[1])
      next unless cover_hex&.provides_cover?

      # Check if this cover blocks any enemy
      opposite = opposite_direction(dir)
      enemies.each do |enemy|
        enemy_dir = direction_from_coords(hex_x, hex_y, enemy.hex_x, enemy.hex_y)
        if enemy_dir == opposite || adjacent_direction?(enemy_dir, opposite)
          directions << dir
          break
        end
      end
    end
    directions.uniq
  end

  # Find hexes with clear line of sight to target
  # @param participant [FightParticipant]
  # @param target [FightParticipant]
  # @param max_distance [Integer] max hexes to search
  # @return [Array<Hash>] hexes with clear LoS: [{x:, y:, distance:}]
  def find_clear_los_hexes(participant, target, max_distance: 3)
    return [] unless battle_map_active?

    candidates = []
    center_x, center_y = participant.hex_x, participant.hex_y

    (-max_distance..max_distance).each do |dx|
      (-max_distance..max_distance).each do |dy|
        hx, hy = center_x + dx, center_y + dy
        next if HexGrid.hex_distance(center_x, center_y, hx, hy) > max_distance

        hex = cached_hex(hx, hy)
        next unless hex&.traversable && !hex.blocks_movement?

        # Create mock position for LoS check
        mock = OpenStruct.new(hex_x: hx, hex_y: hy, hex_z: participant.hex_z)
        next if shot_passes_through_cover?(mock, target)

        candidates << {
          x: hx,
          y: hy,
          distance: HexGrid.hex_distance(hx, hy, target.hex_x, target.hex_y)
        }
      end
    end

    candidates
  end

  # Score a potential position for ranged combat
  # Higher scores are better positions
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @param participant [FightParticipant]
  # @param target [FightParticipant]
  # @param enemies [Array<FightParticipant>]
  # @return [Integer] position score
  def score_ranged_position(hex_x, hex_y, participant, target, enemies)
    return -100 unless battle_map_active?

    config = GameConfig::Combat::AI_POSITIONING
    score = 0

    # Distance score - prefer optimal range (penalty for being too close or too far)
    dist = HexGrid.hex_distance(hex_x, hex_y, target.hex_x, target.hex_y)
    optimal = config[:optimal_ranged_distance]
    distance_penalty = (dist - optimal).abs
    score -= distance_penalty

    # Clear LoS bonus - can hit target without cover penalty
    mock = OpenStruct.new(hex_x: hex_x, hex_y: hex_y, hex_z: participant.hex_z)
    score += config[:los_clear_priority] unless shot_passes_through_cover?(mock, target)

    # NEW HEX SYSTEM: Penalty if target is in concealed hex (fog, smoke, darkness)
    if fight.uses_new_hex_system?
      target_hex = RoomHex.hex_details(room, target.hex_x, target.hex_y)
      if ConcealmentService.applies_to_attack?(target_hex, 'ranged')
        concealment_penalty = ConcealmentService.ranged_penalty(dist)
        score += concealment_penalty  # Penalty is negative, so this reduces score
      end
    end

    # Cover bonus - protected from enemy attacks
    cover_dirs = find_adjacent_cover_directions(hex_x, hex_y, enemies)
    score += config[:cover_seek_priority] unless cover_dirs.empty?

    score
  end

  private

  # Pixel-level LOS using wall mask ray casting.
  # Doors and windows are always transparent; only wall pixels block LOS.
  def pixel_line_of_sight?(viewer, target, wall_mask)
    vp = wall_mask.hex_to_pixel(viewer.hex_x, viewer.hex_y)
    tp = wall_mask.hex_to_pixel(target.hex_x, target.hex_y)
    wall_mask.ray_los_clear?(*vp, *tp)
  end

  # Hex-level LOS fallback (used when no wall mask exists).
  def hex_line_of_sight?(viewer, target)
    hexes_between = hexes_in_line(
      viewer.hex_x, viewer.hex_y,
      target.hex_x, target.hex_y
    )

    viewer_elevation = viewer.hex_z.to_i

    hexes_between.none? do |hex_x, hex_y|
      hex = cached_hex(hex_x, hex_y)
      hex&.blocks_los_at_elevation?(viewer_elevation)
    end
  end

  # Calculate direction from coordinates to coordinates.
  # Returns one of the 6 hex directions: N, NE, SE, S, SW, NW.
  # Pure E/W (dy==0) is mapped to NE/NW or SE/SW since hex grids
  # don't have east/west neighbors.
  # @return [String] direction (N, NE, SE, S, SW, NW)
  def direction_from_coords(from_x, from_y, to_x, to_y)
    dx = to_x - from_x
    dy = to_y - from_y

    if dy > 0
      dx > 0 ? 'NE' : (dx < 0 ? 'NW' : 'N')
    elsif dy < 0
      dx > 0 ? 'SE' : (dx < 0 ? 'SW' : 'S')
    else
      # dy == 0: no pure E/W in hex grid — map to nearest hex direction
      dx > 0 ? 'NE' : 'NW'
    end
  end

  # Calculate direction from one participant to another.
  # Returns one of the 6 hex directions: N, NE, SE, S, SW, NW.
  # @return [String] direction (N, NE, SE, S, SW, NW)
  def direction_from(from, to)
    direction_from_coords(from.hex_x, from.hex_y, to.hex_x, to.hex_y)
  end

  # Get opposite direction (uppercase for hex combat grid)
  # @param direction [String]
  # @return [String]
  def opposite_direction(direction)
    CanvasHelper.opposite_direction(direction.to_s.downcase, fallback: direction.to_s).upcase
  end

  # Check if two hex directions are adjacent (one step apart on the hex ring).
  # Hex directions: N, NE, SE, S, SW, NW (6 directions, no E/W).
  # @param dir1 [String]
  # @param dir2 [String]
  # @return [Boolean]
  def adjacent_direction?(dir1, dir2)
    directions = %w[N NE SE S SW NW]
    idx1 = directions.index(dir1)
    idx2 = directions.index(dir2)

    return false unless idx1 && idx2

    diff = (idx1 - idx2).abs
    diff == 1 || diff == 5
  end

  # Get hexes in a line between two points (Bresenham's algorithm adapted for hex)
  # @return [Array<Array<Integer, Integer>>] hex coordinates
  def hexes_in_line(x1, y1, x2, y2)
    hexes = []

    # Simple linear interpolation between hex centers
    steps = HexGrid.hex_distance(x1, y1, x2, y2)
    return hexes if steps <= 1

    (1...steps).each do |step|
      t = step.to_f / steps
      x = (x1 + (x2 - x1) * t).round
      y = (y1 + (y2 - y1) * t).round

      # Snap to valid hex coords
      hex_x, hex_y = HexGrid.to_hex_coords(x, y)
      hexes << [hex_x, hex_y]
    end

    hexes.uniq
  end

  # Build in-memory hex cache from Redis (if available) or DB.
  # Eliminates N+1 queries during combat resolution.
  def build_hex_cache
    @hex_cache = {}
    return unless room

    # Try Redis first
    cached = load_hex_cache_from_redis
    if cached
      cached.each { |h| @hex_cache[[h.hex_x, h.hex_y]] = h }
      return
    end

    # Fall back to DB and populate Redis
    hexes = room.room_hexes_dataset.all
    hexes.each { |h| @hex_cache[[h.hex_x, h.hex_y]] = h }
    save_hex_cache_to_redis(hexes)
  end

  def redis_hex_cache_key
    "#{REDIS_HEX_CACHE_PREFIX}#{room.id}"
  end

  def load_hex_cache_from_redis
    REDIS_POOL.with do |redis|
      raw = redis.get(redis_hex_cache_key)
      return nil unless raw

      data = JSON.parse(raw)
      data.map do |h|
        hex = RoomHex.new
        hex.set_fields(h, h.keys.map(&:to_sym), missing: :skip)
        hex
      end
    end
  rescue StandardError => e
    warn "[BattleMapCombat] Redis hex cache load failed: #{e.message}"
    nil
  end

  def save_hex_cache_to_redis(hexes)
    return if hexes.empty?

    # Serialize only the columns needed for combat lookups
    cols = %i[hex_x hex_y hex_type traversable has_cover cover_object cover_value
              cover_height elevation_level difficult_terrain danger_level hazard_type
              hazard_damage_per_round water_type blocks_line_of_sight is_explosive
              explosion_radius explosion_damage explosion_trigger passable_edges
              wall_feature room_id hit_points is_potential_hazard]

    data = hexes.map do |h|
      cols.each_with_object({}) do |col, hash|
        val = h.respond_to?(col) ? h.send(col) : nil
        hash[col.to_s] = val unless val.nil?
      end
    end

    REDIS_POOL.with do |redis|
      redis.setex(redis_hex_cache_key, REDIS_HEX_CACHE_TTL, data.to_json)
    end
  rescue StandardError => e
    warn "[BattleMapCombat] Redis hex cache save failed: #{e.message}"
  end

  def invalidate_redis_hex_cache!
    REDIS_POOL.with do |redis|
      redis.del(redis_hex_cache_key)
    end
  rescue StandardError => e
    warn "[BattleMapCombat] Redis hex cache invalidation failed: #{e.message}"
  end
end
