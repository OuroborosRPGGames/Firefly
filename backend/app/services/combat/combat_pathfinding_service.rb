# frozen_string_literal: true
require_relative '../concerns/pathfinding_helper'

# A* pathfinding service for tactical combat movement
# Handles terrain costs, obstacle avoidance, elevation, and hazards
class CombatPathfindingService
  include PathfindingHelper
  MAX_PATH_LENGTH = 200  # Must support large arenas with offset hex coordinates

  # Hazard avoidance costs by profile (higher = more avoidance during path planning)
  HAZARD_AVOIDANCE_COSTS = {
    ignore: 1.0,      # berserker - treat hazards as normal terrain
    low: 5.0,         # aggressive, guardian - will path through if needed
    moderate: 15.0,   # balanced - prefer to avoid
    high: 50.0        # defensive, coward - strongly avoid
  }.freeze

  # Fixed hazard movement cost (applied during budget counting)
  # Hazardous terrain costs double movement regardless of personality
  HAZARD_MOVEMENT_COST = 2.0

  # Find optimal path from start to goal using A*
  # @param fight [Fight] the current fight
  # @param start_x [Integer] starting hex X
  # @param start_y [Integer] starting hex Y
  # @param goal_x [Integer] destination hex X
  # @param goal_y [Integer] destination hex Y
  # @param participant [FightParticipant] for hazard avoidance checks
  # @return [Array<Array<Integer>>] path as [[x,y], [x,y], ...] excluding start, including goal
  def self.find_path(fight:, start_x:, start_y:, goal_x:, goal_y:, participant: nil)
    new(fight, participant).find_path(start_x, start_y, goal_x, goal_y)
  end

  # Get next step(s) toward a target (up to movement budget)
  # @param fight [Fight]
  # @param participant [FightParticipant] moving participant
  # @param target_x [Integer] destination X
  # @param target_y [Integer] destination Y
  # @param movement_budget [Integer] how many hexes can move
  # @return [Array<Array<Integer>>] hexes to move through this step
  def self.next_steps(fight:, participant:, target_x:, target_y:, movement_budget:)
    @last_failure_reason = nil
    instance = new(fight, participant)
    path = instance.find_path(participant.hex_x, participant.hex_y, target_x, target_y)

    if path.empty?
      @last_failure_reason = instance.last_failure_reason
      return []
    end

    # Take up to movement_budget steps, but respect terrain costs
    instance.steps_within_budget(path, movement_budget, participant.hex_x, participant.hex_y)
  end

  # Last failure reason from the most recent find_path or next_steps call
  def self.last_failure_reason
    @last_failure_reason
  end

  attr_reader :last_failure_reason, :last_budget_truncation

  # Calculate total movement cost for a path
  # @param fight [Fight]
  # @param path [Array<Array<Integer>>] path of [x, y] coordinates
  # @param participant [FightParticipant] for cost calculations
  # @return [Float] total cost
  def self.path_cost(fight:, path:, participant: nil)
    return 0.0 if path.empty?

    new(fight, participant).calculate_path_cost(path)
  end

  # =========================================
  # Instance Methods
  # =========================================

  # High cost for pathing through occupied hexes (prefer to go around)
  OCCUPIED_HEX_COST = 10.0

  def initialize(fight, participant = nil)
    @fight = fight
    @room = fight&.room
    @participant = participant
    @hex_cache = {}
    @occupied_hexes = nil
    @wall_mask = :not_loaded  # lazy sentinel
  end

  # A* pathfinding implementation
  def find_path(start_x, start_y, goal_x, goal_y)
    @last_failure_reason = nil

    unless @room
      @last_failure_reason = 'no_room'
      return []
    end

    # Already at goal
    if start_x == goal_x && start_y == goal_y
      @last_failure_reason = 'already_at_goal'
      return []
    end

    # Check if goal is reachable
    goal_hex = hex_at(goal_x, goal_y)
    if goal_hex&.blocks_movement?
      @last_failure_reason = "goal_blocked(#{goal_x},#{goal_y} type=#{goal_hex.hex_type})"
      return []
    end

    # Check start hex neighbors for any passable exit
    start_neighbors = HexGrid.hex_neighbors(start_x, start_y)
    start_blocked_reasons = diagnose_blocked_neighbors(start_x, start_y, start_neighbors) if start_neighbors.any?

    # A* data structures
    open_set = PriorityQueue.new
    open_set.push([start_x, start_y], 0)

    came_from = {}
    g_score = Hash.new(Float::INFINITY)
    g_score[[start_x, start_y]] = 0

    f_score = Hash.new(Float::INFINITY)
    f_score[[start_x, start_y]] = heuristic(start_x, start_y, goal_x, goal_y)

    visited = Set.new

    while open_set.any?
      current = open_set.pop
      current_pos = [current[0], current[1]]

      # Found the goal
      if current_pos == [goal_x, goal_y]
        @last_failure_reason = nil
        return reconstruct_path(came_from, current_pos, skip_start: true)
      end

      next if visited.include?(current_pos)

      visited.add(current_pos)

      # Expand neighbors
      neighbors = HexGrid.hex_neighbors(current_pos[0], current_pos[1])
      neighbors.each do |neighbor_x, neighbor_y|
        neighbor_pos = [neighbor_x, neighbor_y]
        next if visited.include?(neighbor_pos)

        # Check arena bounds
        next unless within_arena?(neighbor_x, neighbor_y)

        # Calculate movement cost
        from_hex = hex_at(current_pos[0], current_pos[1])
        to_hex = hex_at(neighbor_x, neighbor_y)
        move_cost = movement_cost_between(from_hex, to_hex)

        next if move_cost == Float::INFINITY

        tentative_g = g_score[current_pos] + move_cost

        if tentative_g < g_score[neighbor_pos]
          came_from[neighbor_pos] = current_pos
          g_score[neighbor_pos] = tentative_g
          f_score[neighbor_pos] = tentative_g + heuristic(neighbor_x, neighbor_y, goal_x, goal_y)
          open_set.push(neighbor_pos, f_score[neighbor_pos])
        end
      end

      # Safety limit
      if visited.size > MAX_PATH_LENGTH * 4
        @last_failure_reason = "safety_limit(visited=#{visited.size})"
        return []
      end
    end

    # No path found - build diagnostic
    if start_blocked_reasons && start_blocked_reasons.values.all? { |r| r != 'ok' }
      @last_failure_reason = "start_hex_trapped(#{start_x},#{start_y}) neighbors: #{start_blocked_reasons.map { |k, v| "#{k}=#{v}" }.join(', ')}"
    else
      @last_failure_reason = "no_route(visited=#{visited.size} start=(#{start_x},#{start_y}) goal=(#{goal_x},#{goal_y}))"
    end
    []
  end

  # Diagnostic: why is each neighbor of a hex blocked?
  def diagnose_blocked_neighbors(from_x, from_y, neighbors)
    from_hex = hex_at(from_x, from_y)
    reasons = {}
    neighbors.each do |nx, ny|
      key = "(#{nx},#{ny})"
      unless within_arena?(nx, ny)
        reasons[key] = 'out_of_arena'
        next
      end
      to_hex = hex_at(nx, ny)
      reasons[key] = movement_block_reason(from_hex, to_hex)
    end
    reasons
  end

  # Return a human-readable reason why movement to a hex is blocked, or 'ok'
  def movement_block_reason(from_hex, to_hex)
    return 'no_hex' unless to_hex

    return "blocks_movement(type=#{to_hex.hex_type})" if to_hex.blocks_movement?

    if wall_mask_service && !to_hex.passable_edges.nil? && from_hex
      dir = direction_between(from_hex, to_hex)
      return "wall_mask(dir=#{dir})" unless to_hex.passable_from?(dir)
    end

    # Cover objects provide defensive bonuses but don't block movement.
    # Characters can stand on/behind cover hexes.

    if to_hex.dangerous?
      return 'hazard_blocked' unless can_path_through_hazard?
    end

    if from_hex && !from_hex.can_transition_to?(to_hex)
      return "elevation_blocked(from=#{from_hex.elevation_level} to=#{to_hex.elevation_level})"
    end

    'ok'
  end

  # Get steps within movement budget
  def steps_within_budget(path, budget, start_x, start_y)
    return [] if path.empty?

    steps = []
    step_costs = []
    remaining_budget = budget.to_f
    current_x, current_y = start_x, start_y

    path.each do |next_x, next_y|
      from_hex = hex_at(current_x, current_y)
      to_hex = hex_at(next_x, next_y)
      cost = movement_cost_between(from_hex, to_hex, include_hazard_cost: false)

      if cost > remaining_budget
        step_costs << { to: [next_x, next_y], cost: cost, reason: 'over_budget' }
        break
      end

      steps << [next_x, next_y]
      step_costs << { to: [next_x, next_y], cost: cost }
      remaining_budget -= cost
      current_x, current_y = next_x, next_y

      # At least one step guaranteed if possible
      if remaining_budget < 1.0 && steps.any?
        step_costs << { reason: "budget_exhausted(remaining=#{remaining_budget.round(1)})" }
        break
      end
    end

    # Store truncation info for the combat round logger to pick up
    if steps.length < path.length && steps.length < budget
      @last_budget_truncation = {
        steps_taken: steps.length,
        path_length: path.length,
        budget: budget,
        step_costs: step_costs
      }
    else
      @last_budget_truncation = nil
    end

    steps
  end

  # Calculate total path cost
  def calculate_path_cost(path)
    return 0.0 if path.empty?

    total = 0.0
    prev_pos = nil

    path.each do |pos|
      if prev_pos
        from_hex = hex_at(prev_pos[0], prev_pos[1])
        to_hex = hex_at(pos[0], pos[1])
        cost = movement_cost_between(from_hex, to_hex)
        return Float::INFINITY if cost == Float::INFINITY

        total += cost
      end
      prev_pos = pos
    end

    total
  end

  private

  # Heuristic: hex distance to goal
  def heuristic(x, y, goal_x, goal_y)
    HexGrid.hex_distance(x, y, goal_x, goal_y)
  end

  # Get hex at position (cached)
  def hex_at(x, y)
    key = [x, y]
    return @hex_cache[key] if @hex_cache.key?(key)

    @hex_cache[key] = if @room
                        RoomHex.hex_details(@room, x, y)
                      else
                        nil
                      end
  end

  # Check if a hex is occupied by another participant or monster (not self)
  def occupied_by_other?(hex_x, hex_y)
    return false unless @fight

    occupied = occupied_hexes
    occupied.include?([hex_x, hex_y])
  end

  # Build set of hexes occupied by other participants and monsters (cached per pathfind)
  def occupied_hexes
    return @occupied_hexes if @occupied_hexes

    @occupied_hexes = Set.new

    @fight.fight_participants.each do |p|
      next if @participant && p.id == @participant.id
      next unless p.hex_x && p.hex_y
      next if p.is_knocked_out

      @occupied_hexes.add([p.hex_x, p.hex_y])
    end

    @fight.large_monster_instances_dataset.where(status: 'active').each do |monster|
      monster.occupied_hexes.each { |h| @occupied_hexes.add(h) }
    end

    @occupied_hexes
  end

  # Check if position is within arena
  def within_arena?(x, y)
    return true unless @fight

    max_x = [@fight.arena_width - 1, 0].max
    max_y = [(@fight.arena_height - 1) * 4 + 2, 0].max
    x >= 0 && x <= max_x &&
      y >= 0 && y <= max_y
  end

  # Lazy-loaded wall mask service for the current room.
  def wall_mask_service
    return @wall_mask unless @wall_mask == :not_loaded
    @wall_mask = WallMaskService.for_room(@room)
  end

  # Calculate movement cost between two hexes
  def movement_cost_between(from_hex, to_hex, include_hazard_cost: true)
    return Float::INFINITY unless to_hex

    # Always check if the hex fundamentally blocks movement (wall type, pit,
    # or majority wall coverage from pixel data)
    return Float::INFINITY if to_hex.blocks_movement?

    # Pixel data adds directional edge checks on top of the base check.
    # A hex might be occupiable (majority floor) but blocked from certain
    # directions by a wall cutting through it.
    if wall_mask_service && !to_hex.passable_edges.nil? && from_hex
      dir = direction_between(from_hex, to_hex)
      return Float::INFINITY unless to_hex.passable_from?(dir)
    end

    # Cover objects provide defensive bonuses but don't block movement.

    # Check for hazards
    if to_hex.dangerous?
      if include_hazard_cost
        # A* path planning: use personality-based avoidance cost
        return Float::INFINITY unless can_path_through_hazard?
        return hazard_cost
      end
      # Budget counting: hazards cost extra movement (fixed penalty)
      return HAZARD_MOVEMENT_COST
    end

    # Base terrain cost from hex
    cost = to_hex.calculated_movement_cost

    # Participant collision avoidance - prefer to path around occupied hexes
    if occupied_by_other?(to_hex.hex_x, to_hex.hex_y)
      cost += OCCUPIED_HEX_COST
    end

    # Elevation transition cost
    if from_hex && to_hex
      cost *= elevation_transition_cost(from_hex, to_hex)
    end

    # Check if elevation is passable
    if from_hex && !from_hex.can_transition_to?(to_hex)
      return Float::INFINITY
    end

    cost
  end

  # Calculate elevation transition multiplier
  # Elevation comes in bands of ~4, so diff 0-5 is essentially one level.
  # Characters can climb/descend freely within one level band.
  # Ramps/stairs/ladders remove the cost penalty entirely.
  def elevation_transition_cost(from_hex, to_hex)
    from_elev = from_hex.elevation_level.to_i
    to_elev = to_hex.elevation_level.to_i
    diff = (to_elev - from_elev).abs

    return 1.0 if diff == 0

    has_aid = from_hex.is_ramp || from_hex.is_stairs || from_hex.is_ladder ||
              to_hex.is_ramp || to_hex.is_stairs || to_hex.is_ladder
    return 1.0 if has_aid

    # Elevation bands are ~4, so diff 1-5 is within one level
    if diff <= 5
      1.5
    else
      # 6+ requires special terrain (blocked by can_transition_to? anyway)
      Float::INFINITY
    end
  end

  # Check if participant can/should path through hazards
  def can_path_through_hazard?
    return true unless @participant

    # Check explicit override
    return true if @participant.ignore_hazard_avoidance

    # Check AI profile if NPC
    hazard_profile = hazard_avoidance_profile
    hazard_profile == :ignore
  end

  # Get hazard cost based on avoidance profile
  def hazard_cost
    profile = hazard_avoidance_profile
    HAZARD_AVOIDANCE_COSTS[profile] || HAZARD_AVOIDANCE_COSTS[:moderate]
  end

  # Determine hazard avoidance profile for participant
  def hazard_avoidance_profile
    return :moderate unless @participant

    # Check if ignore flag is set
    return :ignore if @participant.ignore_hazard_avoidance

    # For NPCs, check AI profile
    character = @participant.character_instance&.character
    if character&.npc?
      archetype = character.npc_archetype
      ai_profile = archetype&.ai_profile || 'balanced'
      return map_ai_profile_to_hazard_avoidance(ai_profile)
    end

    # Default for players
    :moderate
  end

  DIRECTION_NAMES = ['N', 'NE', 'SE', 'S', 'SW', 'NW'].freeze
  PATH_HEX_OFFSETS = [[0, 4], [1, 2], [1, -2], [0, -4], [-1, -2], [-1, 2]].freeze

  # Get the named direction from from_hex to to_hex, or nil if not a neighbor.
  def direction_between(from_hex, to_hex)
    dx = to_hex.hex_x - from_hex.hex_x
    dy = to_hex.hex_y - from_hex.hex_y
    idx = PATH_HEX_OFFSETS.index([dx, dy])
    idx ? DIRECTION_NAMES[idx] : nil
  end

  # Map AI profile to hazard avoidance level
  def map_ai_profile_to_hazard_avoidance(ai_profile)
    case ai_profile.to_s
    when 'berserker'
      :ignore
    when 'aggressive', 'guardian'
      :low
    when 'balanced'
      :moderate
    when 'defensive', 'coward'
      :high
    else
      :moderate
    end
  end

  # =========================================
  # Simple Priority Queue (min-heap)
  # =========================================
  class PriorityQueue
    def initialize
      @elements = []
    end

    def push(item, priority)
      @elements << [priority, item]
      bubble_up(@elements.size - 1)
    end

    def pop
      return nil if @elements.empty?

      min = @elements.first[1]
      last = @elements.pop
      if @elements.any?
        @elements[0] = last
        bubble_down(0)
      end
      min
    end

    def any?
      @elements.any?
    end

    private

    def bubble_up(index)
      parent = (index - 1) / 2
      return if index == 0 || @elements[parent][0] <= @elements[index][0]

      @elements[parent], @elements[index] = @elements[index], @elements[parent]
      bubble_up(parent)
    end

    def bubble_down(index)
      child = 2 * index + 1
      return if child >= @elements.size

      # Find smaller child
      if child + 1 < @elements.size && @elements[child + 1][0] < @elements[child][0]
        child += 1
      end

      return if @elements[index][0] <= @elements[child][0]

      @elements[index], @elements[child] = @elements[child], @elements[index]
      bubble_down(child)
    end
  end
end
