# frozen_string_literal: true

# Calculates the "effective power" of an ability in a specific combat context.
# Wraps AbilityPowerCalculator's base power and applies environmental bonuses
# based on the battlefield situation.
#
# Environmental bonuses include:
# - AoE cluster bonus (more enemies in radius = higher effective power)
# - Hazard knockback bonus (push into hazard = higher priority)
# - Execute bonus (target below execute threshold = higher priority)
# - Combo bonus (target has required status = higher priority)
#
# Used by:
# - CombatAIService for NPC and idle PC ability selection
# - CombatSimulatorService for balance testing
#
# @example
#   eff_power = AbilityEffectivePowerCalculator.calculate(
#     ability: fireball,
#     actor: caster,
#     target: enemy1,
#     fight: fight,
#     enemies: [enemy1, enemy2, enemy3],
#     allies: [ally1, ally2]  # needed for friendly fire calculation
#   )
#   # => 180.0 (base 100 * 1.8 AoE cluster bonus)
#
class AbilityEffectivePowerCalculator
  # Calculate effective power for an ability used on a specific target
  # @param ability [Ability] the ability
  # @param actor [FightParticipant] who's using it
  # @param target [FightParticipant] potential target
  # @param fight [Fight] the fight context
  # @param enemies [Array<FightParticipant>] enemy participants
  # @param allies [Array<FightParticipant>] allied participants (excluding actor)
  # @return [Float] effective power score
  def self.calculate(ability:, actor:, target:, fight:, enemies:, allies:)
    new(ability, actor, target, fight, enemies, allies).effective_power
  end

  def initialize(ability, actor, target, fight, enemies, allies)
    @ability = ability
    @actor = actor
    @target = target
    @fight = fight
    @enemies = enemies || []
    @allies = allies || []
  end

  # Calculate effective power including all environmental bonuses
  # @return [Float] effective power score
  def effective_power
    base = @ability.power # From AbilityPowerCalculator

    # Environmental bonuses (multiplicative)
    multiplier = 1.0
    multiplier *= aoe_cluster_multiplier
    multiplier *= hazard_knockback_multiplier
    multiplier *= execute_bonus_multiplier
    multiplier *= combo_bonus_multiplier
    multiplier *= vulnerability_bonus_multiplier

    base * multiplier
  end

  private

  # Calculate AoE cluster bonus based on targets in radius around center
  # Uses AbilityPowerWeights expected targets vs actual targets
  #
  # For enemy abilities without friendly fire: counts enemies clustered together
  # For ally abilities (heals): counts allies clustered together
  # For friendly fire AoEs: counts enemies minus (allies * penalty)
  #
  # @return [Float] multiplier (0.0 - AOE_CLUSTER_MAX_MULTIPLIER)
  def aoe_cluster_multiplier
    return 1.0 unless @ability.has_aoe?

    radius = @ability.aoe_radius.to_i.nonzero? || 1

    # Check if this is a friendly fire AoE (hits allies too)
    has_friendly_fire = @ability.respond_to?(:aoe_hits_allies) && @ability.aoe_hits_allies

    if has_friendly_fire
      # Friendly fire AoE: calculate net value (enemies - allies*penalty)
      enemies_in_range = count_in_radius(@enemies, radius)
      allies_in_range = count_in_radius(@allies, radius)

      penalty = GameConfig::EffectivePower::FRIENDLY_FIRE_ALLY_PENALTY
      net_targets = enemies_in_range - (allies_in_range * penalty)

      # If net targets is below minimum, heavily penalize this ability
      min_net = GameConfig::EffectivePower::FRIENDLY_FIRE_MIN_NET_TARGETS
      return 0.1 if net_targets < min_net # Near-zero multiplier, AI will avoid

      # Use net targets for the cluster bonus calculation
      expected = AbilityPowerWeights.aoe_circle_targets(radius)
      return 1.0 if expected <= 0

      # +1 for primary target (which is an enemy for damage abilities)
      actual = net_targets + 1
      ratio = actual.to_f / expected
      [ratio, GameConfig::EffectivePower::AOE_CLUSTER_MAX_MULTIPLIER].min
    else
      # Non-friendly-fire AoE: use appropriate targets based on ability type
      cluster_targets = @ability.target_type == 'ally' ? @allies : @enemies
      targets_in_range = count_in_radius(cluster_targets, radius)

      expected = AbilityPowerWeights.aoe_circle_targets(radius)
      return 1.0 if expected <= 0

      actual = targets_in_range + 1 # +1 for primary target

      ratio = actual.to_f / expected
      [ratio, GameConfig::EffectivePower::AOE_CLUSTER_MAX_MULTIPLIER].min
    end
  end

  # Count targets within radius of @target (excluding @target itself)
  # @param targets [Array<FightParticipant>] list of participants to check
  # @param radius [Integer] AoE radius in hexes
  # @return [Integer] count of targets in range
  def count_in_radius(targets, radius)
    targets.count do |t|
      next false if t == @target
      distance_between(@target, t) <= radius
    end
  end

  # Calculate bonus if knockback would push target into hazard
  # @return [Float] multiplier (1.0 - HAZARD_KNOCKBACK_MAX_MULTIPLIER)
  def hazard_knockback_multiplier
    return 1.0 unless @ability.has_forced_movement?
    return 1.0 unless battle_map_active?

    movement = @ability.parsed_forced_movement
    return 1.0 unless movement

    distance = movement['distance'].to_i
    return 1.0 if distance <= 0

    landing = calculate_landing_position(@target, movement)
    return 1.0 unless landing

    hazard_hex = find_hex_at(landing[:x], landing[:y])
    return 1.0 unless hazard_hex

    # Check for hazard or impassable terrain
    return 1.0 unless hazard_hex.respond_to?(:is_hazard?) && (hazard_hex.is_hazard? || !hazard_hex.traversable)

    # Normalize hazard score to multiplier
    # pit = 100 score -> 2.0x multiplier
    score = hazard_score(hazard_hex)
    bonus = score / 100.0
    1.0 + [bonus, GameConfig::EffectivePower::HAZARD_KNOCKBACK_MAX_MULTIPLIER - 1.0].min
  end

  # Calculate bonus if target is below execute threshold
  # @return [Float] multiplier (1.0 - EXECUTE_INSTANT_KILL_MULTIPLIER)
  def execute_bonus_multiplier
    return 1.0 unless @ability.has_execute?

    threshold = @ability.execute_threshold.to_i
    return 1.0 if threshold <= 0

    max_hp = [@target.max_hp.to_f, 1].max
    target_hp_pct = (@target.current_hp.to_f / max_hp) * 100

    if target_hp_pct <= threshold
      # Target is within execute range
      effect = @ability.parsed_execute_effect || {}
      if effect['instant_kill']
        GameConfig::EffectivePower::EXECUTE_INSTANT_KILL_MULTIPLIER
      else
        # Bonus based on damage multiplier
        mult = effect['damage_multiplier']&.to_f || 2.0
        1.0 + (mult - 1.0)
      end
    else
      1.0
    end
  end

  # Calculate bonus if target has status required for combo
  # @return [Float] multiplier (1.0 or COMBO_BONUS_MULTIPLIER)
  def combo_bonus_multiplier
    return 1.0 unless @ability.has_combo?

    combo = @ability.parsed_combo_condition
    return 1.0 unless combo

    required_status = combo['requires_status']
    return 1.0 unless required_status

    if @target.respond_to?(:has_status_effect?) && @target.has_status_effect?(required_status)
      GameConfig::EffectivePower::COMBO_BONUS_MULTIPLIER
    else
      1.0
    end
  end

  # Calculate bonus if target is vulnerable to this ability's damage type
  # e.g., target has vulnerable_fire and ability does fire damage -> bonus
  # @return [Float] multiplier (1.0 or VULNERABILITY_MATCH_MULTIPLIER)
  def vulnerability_bonus_multiplier
    return 1.0 unless @ability.respond_to?(:damage_type) && @ability.damage_type

    damage_type = @ability.damage_type.to_s.downcase

    # Check for type-specific vulnerability (vulnerable_fire, vulnerable_ice, etc.)
    type_vuln_effect = "vulnerable_#{damage_type}"
    if @target.respond_to?(:has_status_effect?) && @target.has_status_effect?(type_vuln_effect)
      return GameConfig::EffectivePower::VULNERABILITY_MATCH_MULTIPLIER
    end

    # Also check for general vulnerability (applies to all damage types)
    if @target.respond_to?(:has_status_effect?) && @target.has_status_effect?('vulnerable')
      return GameConfig::EffectivePower::VULNERABILITY_MATCH_MULTIPLIER
    end

    1.0
  end

  # Calculate hex distance between two participants
  # @param a [FightParticipant] first participant
  # @param b [FightParticipant] second participant
  # @return [Integer] hex distance (999 if positions unknown)
  def distance_between(a, b)
    return 999 unless a.hex_x && a.hex_y && b.hex_x && b.hex_y

    HexGrid.hex_distance(a.hex_x, a.hex_y, b.hex_x, b.hex_y)
  end

  # Check if battle map features are active
  # @return [Boolean]
  def battle_map_active?
    @fight&.uses_battle_map && @fight&.room&.has_battle_map
  end

  # Calculate where target would land after forced movement
  # @param target [FightParticipant] the target being moved
  # @param movement [Hash] forced movement config { 'direction' => ..., 'distance' => ... }
  # @return [Hash, nil] { x: Integer, y: Integer } or nil if can't calculate
  def calculate_landing_position(target, movement)
    return nil unless target.hex_x && target.hex_y
    return nil unless @actor.hex_x && @actor.hex_y

    dx = target.hex_x - @actor.hex_x
    dy = target.hex_y - @actor.hex_y
    length = Math.sqrt(dx * dx + dy * dy)
    return nil if length == 0

    unit_dx = dx / length
    unit_dy = dy / length
    distance = movement['distance'].to_i

    direction = movement['direction'] || movement['type']
    case direction.to_s.downcase
    when 'push', 'away', 'away_from'
      { x: (target.hex_x + unit_dx * distance).round, y: (target.hex_y + unit_dy * distance).round }
    when 'pull', 'toward', 'towards'
      { x: (target.hex_x - unit_dx * distance).round, y: (target.hex_y - unit_dy * distance).round }
    else
      # Default to push
      { x: (target.hex_x + unit_dx * distance).round, y: (target.hex_y + unit_dy * distance).round }
    end
  end

  # Find hex at specific coordinates
  # @param x [Integer] hex x coordinate
  # @param y [Integer] hex y coordinate
  # @return [RoomHex, nil]
  def find_hex_at(x, y)
    return nil unless @fight&.room

    RoomHex.where(room: @fight.room, hex_x: x, hex_y: y).first
  end

  # Score a hazard hex based on severity
  # Higher score = more dangerous hazard
  # @param hex [RoomHex] the hazard hex
  # @return [Integer] hazard score
  def hazard_score(hex)
    return 0 unless hex

    score = 0

    # Pit = instant removal, highest priority
    if hex.respond_to?(:hex_type) && hex.hex_type == 'pit'
      score += 100
    elsif hex.respond_to?(:traversable) && !hex.traversable
      score += 100
    end

    # Hazard damage per round
    if hex.respond_to?(:hazard_damage_per_round)
      score += hex.hazard_damage_per_round.to_i * 5
    end

    # Danger level
    if hex.respond_to?(:danger_level)
      score += hex.danger_level.to_i * 3
    end

    # Fire hazards are extra damaging
    if hex.respond_to?(:hazard_type) && hex.hazard_type == 'fire'
      score += 20
    end

    # Explosives can chain react
    if hex.respond_to?(:is_explosive) && hex.is_explosive
      score += 30
    end

    score
  end
end
