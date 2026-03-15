# frozen_string_literal: true

# Logic-based combat AI for NPCs and idle PCs.
# Makes sensible decisions without LLM calls.
#
# Used by:
# - FightService.apply_defaults! for AFK players on timeout
# - FightService.add_participant for immediate NPC decisions
#
# Supports:
# - Regular PvP/PvE combat with other participants
# - Monster combat with mounting/climbing mechanics
#
# @example
#   ai = CombatAIService.new(participant)
#   ai.apply_decisions!  # Updates participant and marks input complete
#
class CombatAIService
  # AI Profiles define decision weights for different behavior types
  # Keys: attack_weight, defend_weight, ability_weight, flee_threshold, hazard_avoidance, terrain_caution
  # hazard_avoidance: :ignore (charge through), :low (will if needed), :moderate (prefer around), :high (avoid always)
  # terrain_caution: 0.0-1.0 (willingness to traverse difficult terrain)
  AI_PROFILES = {
    'aggressive' => {
      attack_weight: 0.8,
      defend_weight: 0.1,
      ability_weight: 0.4,
      flee_threshold: 0.1,
      target_strategy: :weakest,
      hazard_avoidance: :low,
      terrain_caution: 0.2
    },
    'defensive' => {
      attack_weight: 0.4,
      defend_weight: 0.5,
      ability_weight: 0.3,
      flee_threshold: 0.3,
      target_strategy: :threat,
      hazard_avoidance: :high,
      terrain_caution: 0.7
    },
    'balanced' => {
      attack_weight: 0.6,
      defend_weight: 0.3,
      ability_weight: 0.3,
      flee_threshold: 0.2,
      target_strategy: :closest,
      hazard_avoidance: :moderate,
      terrain_caution: 0.4
    },
    'berserker' => {
      attack_weight: 0.95,
      defend_weight: 0.0,
      ability_weight: 0.2,
      flee_threshold: 0.0,
      target_strategy: :weakest,
      hazard_avoidance: :ignore,
      terrain_caution: 0.0
    },
    'coward' => {
      attack_weight: 0.3,
      defend_weight: 0.4,
      ability_weight: 0.2,
      flee_threshold: 0.5,
      target_strategy: :random,
      hazard_avoidance: :high,
      terrain_caution: 0.8
    },
    'guardian' => {
      attack_weight: 0.5,
      defend_weight: 0.6,
      ability_weight: 0.4,
      flee_threshold: 0.15,
      target_strategy: :threat,
      hazard_avoidance: :low,
      terrain_caution: 0.3
    }
  }.freeze

  # Map NpcArchetype.behavior_pattern to AI profile
  BEHAVIOR_TO_PROFILE = {
    'aggressive' => 'aggressive',
    'hostile' => 'aggressive',
    'passive' => 'defensive',
    'friendly' => 'coward',
    'guard' => 'guardian',
    'neutral' => 'balanced',
    'merchant' => 'coward'
  }.freeze

  attr_reader :participant, :fight, :profile, :archetype

  def initialize(participant)
    @participant = participant
    @fight = participant.fight
    @archetype = determine_archetype
    @profile = determine_profile
  end

  # Generate all combat decisions for this participant
  # Routes to monster combat if fight has an active monster
  # @return [Hash] decisions hash with all combat choices
  def decide!
    # Check for monster combat - completely different decision tree
    if fight_has_active_monster?
      return decide_monster_combat!
    end

    # Standard PvP/PvE combat
    decide_standard_combat!
  end

  # Standard participant vs participant combat decisions
  # @return [Hash] decisions hash
  def decide_standard_combat!
    decisions = {}

    # 1. Select primary target (for attacks)
    decisions[:target_participant_id] = select_target

    # 2. Choose main action (includes ability target selection)
    main_result = choose_main_action
    decisions[:main_action] = main_result[:action]
    decisions[:ability_id] = main_result[:ability_id]
    # For abilities, use ability-specific target; for attacks, use primary target
    decisions[:ability_target_participant_id] = main_result[:ability_target_id]

    # 3. Choose movement
    movement_result = choose_movement(decisions[:target_participant_id])
    decisions[:movement_action] = movement_result[:action]
    if movement_result[:action] == 'move_to_hex'
      decisions[:movement_target_participant_id] = nil
      decisions[:target_hex_x] = movement_result[:hex_x]
      decisions[:target_hex_y] = movement_result[:hex_y]
    else
      decisions[:movement_target_participant_id] = movement_result[:target_id]
      decisions[:target_hex_x] = nil
      decisions[:target_hex_y] = nil
    end
    decisions[:maintain_distance_range] = movement_result[:distance]

    # NPCs don't use tactical actions
    decisions[:tactical_action] = nil
    decisions[:tactical_ability_id] = nil

    # Don't allocate willpower (simpler AI)
    decisions[:willpower_attack] = 0
    decisions[:willpower_defense] = 0
    decisions[:willpower_ability] = 0

    decisions
  end

  # Apply decisions to the participant and mark input complete
  # @return [Hash] the applied decisions
  def apply_decisions!
    decisions = decide!

    # Filter out nil values to avoid overwriting with nils
    update_hash = decisions.compact

    participant.update(update_hash)
    participant.complete_input!

    decisions
  end

  private

  # Determine the NPC archetype (if any)
  # @return [NpcArchetype, nil]
  def determine_archetype
    char = participant.character_instance&.character
    return nil unless char&.npc?

    char.npc_archetype
  end

  # Determine the AI profile to use
  # Merges archetype-specific thresholds into the base profile
  # @return [Hash] profile configuration
  def determine_profile
    base_profile = if @archetype
                     profile_name = @archetype.ai_profile
                     AI_PROFILES[profile_name] || AI_PROFILES['balanced']
                   else
                     # Default for PCs (idle/AFK players) - defensive to prioritize survival
                     AI_PROFILES['defensive']
                   end

    # Merge archetype-specific thresholds (converted from percent to decimal)
    return base_profile unless @archetype

    profile = base_profile.dup
    if @archetype.flee_health_percent
      profile[:flee_threshold] = @archetype.flee_health_percent / 100.0
    end
    if @archetype.defensive_health_percent
      profile[:defensive_threshold] = @archetype.defensive_health_percent / 100.0
    end
    profile
  end

  # ============================================
  # Target Selection
  # ============================================

  # Select the best target based on strategy
  # Uses cover-aware ranged selection when participant has ranged capability
  # @return [Integer, nil] target participant ID
  def select_target
    enemies = available_enemies
    return nil if enemies.empty?

    # If we have ranged capability, use terrain/cover-aware selection
    # This ensures we factor in cover penalties even if we also have melee
    if participant.ranged_weapon && battle_map_active?
      target = select_best_ranged_target(enemies)
      return target&.id if target
    end

    target = case @profile[:target_strategy]
             when :weakest then select_weakest(enemies)
             when :closest then select_closest(enemies)
             when :strongest then select_strongest(enemies)
             when :threat then select_highest_threat(enemies)
             when :random then enemies.sample
             else select_closest(enemies)
             end

    target&.id
  end

  # Get all valid enemy targets (on different sides)
  # @return [Array<FightParticipant>]
  def available_enemies
    fight.active_participants
         .where(is_knocked_out: false)
         .exclude(side: participant.side)
         .all
  end

  # Get all allies (on same side, excluding self)
  # @return [Array<FightParticipant>]
  def available_allies
    fight.active_participants
         .where(is_knocked_out: false)
         .where(side: participant.side)
         .exclude(id: participant.id)
         .all
  end

  # Select the enemy with lowest HP (finish off weak targets)
  def select_weakest(enemies)
    enemies.min_by(&:current_hp)
  end

  # Select the nearest enemy
  def select_closest(enemies)
    enemies.min_by { |e| participant.hex_distance_to(e) }
  end

  # Select the enemy with highest HP (challenge seeker)
  def select_strongest(enemies)
    enemies.max_by(&:current_hp)
  end

  # Select the most threatening enemy
  # Threat = targeting us + proximity + desperation
  def select_highest_threat(enemies)
    weights = GameConfig::Combat::THREAT_WEIGHTS
    enemies.max_by do |enemy|
      threat = 0
      # Bonus if they're targeting us
      threat += weights[:targeted_by_enemy] if enemy.target_participant_id == participant.id
      # +points for proximity (max_bonus - distance, so closer = higher)
      threat += [weights[:max_proximity_bonus] - participant.hex_distance_to(enemy), 0].max
      # +points for how wounded they are (desperate enemies are dangerous)
      threat += (enemy.max_hp - enemy.current_hp)
      threat
    end
  end

  # Select the best target for ranged attacks considering cover and elevation
  # Prioritizes: exposed targets, lower elevation, wounded, not in cover
  # Heavily penalizes targets behind cover to encourage attacking exposed enemies
  # @param enemies [Array<FightParticipant>]
  # @return [FightParticipant, nil]
  def select_best_ranged_target(enemies)
    return nil if enemies.empty?

    battle_map = BattleMapCombatService.new(fight)
    my_elevation = battle_map.participant_elevation(participant)

    weights = GameConfig::Combat::THREAT_WEIGHTS
    enemies.max_by do |enemy|
      score = base_target_score(enemy)

      # Bonus if shot has clear line (no cover blocking path)
      unless battle_map.shot_passes_through_cover?(participant, enemy)
        score += weights[:no_cover_bonus]
      end

      # Penalty for targeting enemies in concealed hexes (fog, smoke, darkness)
      target_hex = RoomHex.hex_details(fight.room, enemy.hex_x, enemy.hex_y)
      distance = participant.hex_distance_to(enemy)
      if ConcealmentService.applies_to_attack?(target_hex, 'ranged')
        concealment_penalty = ConcealmentService.ranged_penalty(distance)
        # Convert penalty to positive score reduction (penalty is negative)
        score += concealment_penalty * 2  # Multiply to amplify impact on target selection
      end

      # Bonus if we have elevation advantage
      enemy_elevation = battle_map.participant_elevation(enemy)
      score += weights[:elevation_advantage] if my_elevation > enemy_elevation

      # Bonus for significant elevation advantage (ranged damage bonus applies)
      score += weights[:elevation_advantage] if (my_elevation - enemy_elevation) >= weights[:significant_elevation]

      # Heavy penalty if shot would pass through cover - encourages targeting exposed enemies
      if battle_map.shot_passes_through_cover?(participant, enemy)
        score -= weights[:cover_penalty]
        score -= weights[:ranged_vs_cover_penalty] # Additional penalty for ranged vs covered
      end

      # Stationary targets behind cover are immune — heavy penalty
      if !enemy.moved_this_round && !enemy.acted_this_round && battle_map.shot_passes_through_cover?(participant, enemy)
        score -= weights[:inactive_penalty] * 2
      end

      score
    end
  end

  # Base targeting score (shared between strategies)
  # @param enemy [FightParticipant]
  # @return [Integer]
  def base_target_score(enemy)
    scoring = GameConfig::Combat::TARGET_SCORING
    thresholds = GameConfig::Combat::HP_THRESHOLDS
    score = 0
    # Bonus for wounded targets (finish them off)
    hp_percent = enemy.current_hp.to_f / [enemy.max_hp.to_f, 1].max
    score += scoring[:wounded_bonus] if hp_percent < thresholds[:wounded]
    score += scoring[:critical_bonus] if hp_percent < thresholds[:critically_wounded]
    # Bonus for being in weapon range
    distance = participant.hex_distance_to(enemy)
    score += scoring[:in_range_bonus] if distance <= effective_weapon_range
    score
  end

  # ============================================
  # Main Action Selection
  # ============================================

  # Choose main action based on health and profile
  # @return [Hash] { action: String, ability_id: Integer|nil, ability_target_id: Integer|nil }
  def choose_main_action
    hp_percent = current_hp_percent

    # If critically wounded, defend (flee behavior)
    if hp_percent <= @profile[:flee_threshold]
      return { action: 'defend', ability_id: nil, ability_target_id: nil }
    end

    # Try smart ability selection (picks ability AND appropriate target)
    ability_result = select_ability_with_target
    if ability_result
      return {
        action: 'ability',
        ability_id: ability_result[:ability].id,
        ability_target_id: ability_result[:target_id]
      }
    end

    # If wounded and defensive profile, consider defending
    if hp_percent <= GameConfig::Combat::HP_THRESHOLDS[:wounded] && rand < @profile[:defend_weight]
      return { action: 'defend', ability_id: nil, ability_target_id: nil }
    end

    # Default: attack (fallback when no ability chosen)
    { action: 'attack', ability_id: nil, ability_target_id: nil }
  end

  # Smart ability selection - picks ability AND appropriate target based on effective power
  # Uses AbilityEffectivePowerCalculator to rank abilities by situational effectiveness.
  # Abilities are sorted by effective power and tried in order (NPCs use chance to skip).
  # @return [Hash, nil] { ability: Ability, target_id: Integer } or nil
  def select_ability_with_target
    # Check global cooldown first - blocks ALL abilities
    return nil if participant.global_ability_cooldown.to_i > 0

    allies = available_allies
    enemies = available_enemies

    # Get abilities with use chances - different for NPCs vs idle PCs
    abilities_config = if @archetype
                         # NPCs: use archetype abilities with configured use% chances
                         @archetype.combat_abilities_with_chances
                       else
                         # Idle PCs: use learned abilities with 100% chance (always pick best)
                         participant.all_combat_abilities.map { |a| { ability: a, chance: 100 } }
                       end

    return nil if abilities_config.empty?

    # Build ranked list of (ability, target, power, chance) options
    ranked_options = []

    abilities_config.each do |ac|
      ability = ac[:ability]

      # Skip if on cooldown (specific or global)
      next unless participant.ability_available?(ability)

      targets = valid_targets_for_ability(ability, allies, enemies)

      targets.each do |target|
        eff_power = AbilityEffectivePowerCalculator.calculate(
          ability: ability,
          actor: participant,
          target: target,
          fight: fight,
          enemies: enemies,
          allies: allies
        )

        ranked_options << {
          ability: ability,
          target: target,
          effective_power: eff_power,
          use_chance: ac[:chance]
        }
      end
    end

    # Sort by effective power (highest first)
    ranked_options.sort_by! { |opt| -opt[:effective_power] }

    # Try abilities in order
    # NPCs: apply use% chance (can skip to next best)
    # PCs: 100% chance (always use best available)
    ranked_options.each do |opt|
      next unless rand(100) < opt[:use_chance]

      return { ability: opt[:ability], target_id: opt[:target].id }
    end

    nil
  end

  # Determine valid targets based on ability's target type
  # @param ability [Ability] the ability to use
  # @param allies [Array<FightParticipant>] available allies
  # @param enemies [Array<FightParticipant>] available enemies
  # @return [Array<FightParticipant>]
  def valid_targets_for_ability(ability, allies, enemies)
    case ability.target_type
    when 'self'
      [participant]
    when 'ally'
      allies + [participant]
    when 'enemy'
      enemies
    else
      enemies # Default to enemies
    end
  end

  # Select appropriate target based on ability type
  # @param ability [Ability] the ability to use
  # @param allies [Array<FightParticipant>] available allies
  # @param enemies [Array<FightParticipant>] available enemies
  # @return [FightParticipant, nil]
  def select_target_for_ability(ability, allies, enemies)
    case ability.target_type
    when 'self'
      participant
    when 'ally'
      # For heals, pick most wounded; otherwise pick any ally or self
      if ability.healing_ability?
        (allies + [participant]).min_by { |p| hp_percent_for(p) }
      else
        allies.sample || participant
      end
    when 'enemy'
      select_target_by_strategy(enemies)
    else
      enemies.sample
    end
  end

  # Select target using profile strategy
  def select_target_by_strategy(enemies)
    return nil if enemies.empty?

    case @profile[:target_strategy]
    when :weakest then enemies.min_by(&:current_hp)
    when :closest then enemies.min_by { |e| participant.hex_distance_to(e) }
    when :strongest then enemies.max_by(&:current_hp)
    when :threat then select_highest_threat(enemies)
    when :random then enemies.sample
    else enemies.min_by { |e| participant.hex_distance_to(e) }
    end
  end

  # Check if ability is a shield/protection ability
  # @param ability [Ability] the ability to check
  # @return [Boolean]
  def ability_is_shield?(ability)
    return false unless ability.respond_to?(:parsed_status_effects)

    ability.parsed_status_effects.any? do |effect|
      effect_name = effect['name'] || effect['effect_name'] || ''
      effect_name.to_s.downcase.include?('shield') ||
        effect_name.to_s.downcase.include?('protect') ||
        effect_name.to_s.downcase.include?('barrier')
    end
  end

  # Get HP percent for a participant
  def hp_percent_for(p)
    return 1.0 if p.max_hp.to_i <= 0

    p.current_hp.to_f / p.max_hp.to_f
  end

  # Get abilities from NPC archetype
  # @return [Array<Ability>]
  def npc_abilities
    return [] unless @archetype

    @archetype.combat_abilities
  end

  # ============================================
  # Movement Selection
  # ============================================

  # Choose movement action based on combat role, weapon range, health, terrain, and cover
  # @param target_id [Integer, nil] current target
  # @return [Hash] { action: String, target_id: Integer|nil, distance: Integer|nil, hex_x: Integer|nil, hex_y: Integer|nil }
  def choose_movement(target_id)
    return no_movement unless target_id

    target = FightParticipant[target_id]
    return no_movement unless target

    distance = participant.hex_distance_to(target)
    hp_percent = current_hp_percent

    # Flee behavior - retreat when critically wounded
    if hp_percent <= @profile[:flee_threshold]
      return { action: 'away_from', target_id: target_id, distance: nil }
    end

    # Determine combat role and choose appropriate movement strategy
    role = assess_combat_role

    case role
    when :melee
      choose_melee_movement(target, distance)
    when :ranged
      choose_ranged_movement(target, distance)
    else
      choose_flexible_movement(target, distance)
    end
  end

  # Movement strategy for melee-focused combatants
  # Rush directly toward target to close distance
  # @param target [FightParticipant]
  # @param distance [Integer] current distance to target
  # @return [Hash]
  def choose_melee_movement(target, distance)
    melee_range = participant.melee_weapon&.pattern&.range_in_hexes || 1

    # Aggressive melee NPCs should keep "towards" active in melee so they can
    # immediately follow retreating targets within the same round.
    if distance <= melee_range
      return { action: 'towards_person', target_id: target.id, distance: nil } if npc_should_shadow_chase_in_melee?

      return no_movement
    end

    # Melee combatants must always close distance — standing still out of
    # melee range accomplishes nothing.  Terrain avoidance only applies when
    # there is a ranged fallback (handled by choose_flexible_movement).
    { action: 'towards_person', target_id: target.id, distance: nil }
  end

  # Movement strategy for ranged-focused combatants
  # Maintain optimal distance, seek cover, get clear line of sight
  # @param target [FightParticipant]
  # @param distance [Integer] current distance to target
  # @return [Hash]
  def choose_ranged_movement(target, distance)
    config = GameConfig::Combat::AI_POSITIONING
    weapon_range = effective_weapon_range

    # Too close - back off
    if distance < config[:min_ranged_distance]
      return { action: 'maintain_distance', target_id: target.id, distance: config[:optimal_ranged_distance] }
    end

    # Out of weapon range - must advance (standing still while unable to hit is useless)
    if distance > weapon_range
      return { action: 'towards_person', target_id: target.id, distance: config[:optimal_ranged_distance] }
    end

    # In weapon range - consider repositioning for better position
    return no_movement unless battle_map_active?

    enemies = available_enemies
    battle_map = BattleMapCombatService.new(fight)

    # Score current position
    current_score = battle_map.score_ranged_position(
      participant.hex_x, participant.hex_y,
      participant, target, enemies
    )

    # Find best reposition hex
    best_hex = find_best_reposition(target, enemies, battle_map, current_score)

    if best_hex
      { action: 'move_to_hex', target_id: nil, distance: nil, hex_x: best_hex[:x], hex_y: best_hex[:y] }
    else
      no_movement
    end
  end

  # Movement strategy for flexible combatants (good at both ranged and melee)
  # Adapt based on situation - use melee if target is behind cover, else ranged tactics
  # @param target [FightParticipant]
  # @param distance [Integer] current distance to target
  # @return [Hash]
  def choose_flexible_movement(target, distance)
    # If target is behind cover and we can reach them, prefer melee
    if should_prefer_melee?(target)
      return choose_melee_movement(target, distance)
    end

    # Otherwise use ranged tactics
    choose_ranged_movement(target, distance)
  end

  # Find the best hex to reposition to for improved ranged combat effectiveness
  # @param target [FightParticipant] primary target
  # @param enemies [Array<FightParticipant>] all enemies
  # @param battle_map [BattleMapCombatService]
  # @param current_score [Integer] score of current position
  # @return [Hash, nil] { x: Integer, y: Integer } or nil if no good reposition found
  def find_best_reposition(target, enemies, battle_map, current_score)
    config = GameConfig::Combat::AI_POSITIONING
    max_dist = config[:max_reposition_hexes]
    threshold = config[:reposition_threshold]

    best = nil
    best_score = current_score

    # Check hexes within movement range
    (-max_dist..max_dist).each do |dx|
      (-max_dist..max_dist).each do |dy|
        hx = participant.hex_x + dx
        hy = participant.hex_y + dy
        next if dx == 0 && dy == 0
        next if HexGrid.hex_distance(participant.hex_x, participant.hex_y, hx, hy) > max_dist

        hex = fight.room.room_hexes_dataset.first(hex_x: hx, hex_y: hy)
        next unless hex&.traversable && !hex.blocks_movement?

        score = battle_map.score_ranged_position(hx, hy, participant, target, enemies)

        # Only consider if score improvement exceeds threshold
        if score > best_score + threshold
          best_score = score
          best = { x: hx, y: hy }
        end
      end
    end

    best
  end

  # Check if we should avoid approaching due to difficult terrain
  # @param target [FightParticipant]
  # @return [Boolean]
  def should_avoid_approach?(target)
    terrain_caution = @profile[:terrain_caution] || 0.4

    # Low caution profiles don't care about terrain
    return false if terrain_caution < GameConfig::Combat::HP_THRESHOLDS[:terrain_caution]

    # Calculate path cost to target
    path_cost = CombatPathfindingService.path_cost(
      fight: fight,
      path: CombatPathfindingService.find_path(
        fight: fight,
        start_x: participant.hex_x,
        start_y: participant.hex_y,
        goal_x: target.hex_x,
        goal_y: target.hex_y,
        participant: participant
      ),
      participant: participant
    )

    # Compare to straight-line distance - if path is much costlier, consider avoiding
    direct_distance = participant.hex_distance_to(target)
    terrain_penalty_ratio = path_cost / [direct_distance.to_f, 1.0].max

    # High caution profiles avoid if path is 50%+ costlier than direct
    # Low caution profiles only avoid if path is 100%+ costlier
    terrain_config = GameConfig::Combat::TERRAIN
    cost_threshold = terrain_config[:cost_threshold_base] + (terrain_config[:cost_threshold_bonus] - terrain_caution)
    terrain_penalty_ratio > cost_threshold
  end

  # Default no-movement response
  def no_movement
    { action: 'stand_still', target_id: nil, distance: nil }
  end

  def npc_should_shadow_chase_in_melee?
    is_npc_actor = participant.is_npc || participant.character_instance&.character&.npc?
    return false unless is_npc_actor

    ai_profile = @archetype&.ai_profile.to_s
    %w[aggressive berserker].include?(ai_profile)
  end

  # Get effective weapon range
  # @return [Integer]
  def effective_weapon_range
    # Check ranged first, then melee
    if participant.ranged_weapon&.pattern
      return participant.ranged_weapon.pattern.range_in_hexes || 5
    end

    if participant.melee_weapon&.pattern
      return participant.melee_weapon.pattern.range_in_hexes || 1
    end

    # Default melee range
    1
  end

  # Check if participant only has ranged weapon
  # @return [Boolean]
  def ranged_only?
    participant.ranged_weapon && !participant.melee_weapon
  end

  # Check if participant has both melee and ranged weapons
  # @return [Boolean]
  def has_both_weapons?
    participant.ranged_weapon && participant.melee_weapon
  end

  # Check if target is behind cover (shot would pass through cover)
  # @param target [FightParticipant]
  # @return [Boolean]
  def target_is_behind_cover?(target)
    return false unless battle_map_active?

    battle_map = BattleMapCombatService.new(fight)
    battle_map.shot_passes_through_cover?(participant, target)
  end

  # Check if we should prefer melee attack over ranged
  # True when: target is behind cover AND we have melee weapon AND target is reachable
  # @param target [FightParticipant]
  # @return [Boolean]
  def should_prefer_melee?(target)
    return false unless has_both_weapons?
    return false unless target_is_behind_cover?(target)

    # Check if we can reach target with melee (within movement + melee range)
    distance = participant.hex_distance_to(target)
    melee_range = participant.melee_weapon&.pattern&.range_in_hexes || 1
    movement = GameConfig::Mechanics::MOVEMENT[:base]

    distance <= (movement + melee_range)
  end

  # ============================================
  # Combat Role Assessment
  # ============================================

  # Determine combat role: :ranged, :melee, or :flexible
  # Based on weapon availability and damage comparison
  # @return [Symbol] :ranged, :melee, or :flexible
  def assess_combat_role
    ranged = participant.ranged_weapon
    melee = participant.melee_weapon

    return :melee unless ranged
    return :ranged unless melee

    # Both weapons - compare expected damage output
    # Pattern doesn't have base_damage, so default to flexible if both weapons exist
    ranged_damage = ranged.respond_to?(:base_damage) ? ranged.base_damage.to_i : 0
    melee_damage = melee.respond_to?(:base_damage) ? melee.base_damage.to_i : 0
    total = ranged_damage + melee_damage
    return :flexible if total == 0

    thresholds = GameConfig::Combat::AI_POSITIONING
    ranged_ratio = ranged_damage.to_f / total

    if ranged_ratio >= thresholds[:ranged_focus_threshold]
      :ranged
    elsif ranged_ratio <= (1 - thresholds[:melee_focus_threshold])
      :melee
    else
      :flexible
    end
  end

  # ============================================
  # Helpers
  # ============================================

  # Current HP as percentage (0.0 - 1.0)
  # @return [Float]
  def current_hp_percent
    max = participant.max_hp.to_i
    return 1.0 if max <= 0

    participant.current_hp.to_f / max.to_f
  end

  # Check if battle map features are active for this fight
  # @return [Boolean]
  def battle_map_active?
    return false unless fight

    fight.uses_battle_map && fight.room&.has_battle_map
  end

  # ============================================
  # Hazard-Aware Forced Movement
  # ============================================

  # Find the best target to push/pull into a hazard
  # @param forced_movement_abilities [Array] abilities with forced movement
  # @param enemies [Array<FightParticipant>]
  # @return [Hash, nil] { ability: Ability, target_id: Integer } or nil
  def find_best_hazard_push(forced_movement_abilities, enemies)
    room = fight.room
    return nil unless room

    best_option = nil
    best_score = 0

    forced_movement_abilities.each do |ac|
      ability = ac[:ability]
      movement_config = ability.parsed_forced_movement
      next unless movement_config

      direction = movement_config['direction'] || movement_config['type']
      distance = movement_config['distance'].to_i
      next if distance <= 0

      enemies.each do |enemy|
        # Calculate where enemy would land after push/pull
        landing_hex = calculate_forced_movement_destination(enemy, direction, distance)
        next unless landing_hex

        # Check if landing position is a hazard
        hazard_hex = RoomHex.where(room: room, hex_x: landing_hex[:x], hex_y: landing_hex[:y]).first
        next unless hazard_hex&.is_hazard? || hazard_hex&.blocks_movement?

        # Score based on hazard severity
        score = calculate_hazard_push_score(hazard_hex, enemy)

        # Roll for ability use (chance-based)
        next unless rand(100) < ac[:chance]

        if score > best_score
          best_score = score
          best_option = { ability: ability, target_id: enemy.id }
        end
      end
    end

    best_option
  end

  # Calculate where a target would land after forced movement
  # @param target [FightParticipant] the target being moved
  # @param direction [String] 'push'/'away' or 'pull'/'toward'
  # @param distance [Integer] number of hexes
  # @return [Hash, nil] { x: Integer, y: Integer } or nil
  def calculate_forced_movement_destination(target, direction, distance)
    return nil unless target.hex_x && target.hex_y
    return nil unless participant.hex_x && participant.hex_y

    # Calculate direction vector from participant to target
    dx = target.hex_x - participant.hex_x
    dy = target.hex_y - participant.hex_y

    # Normalize to unit direction
    length = Math.sqrt(dx * dx + dy * dy)
    return nil if length == 0

    unit_dx = dx / length
    unit_dy = dy / length

    # Push = move away from participant, Pull = move toward participant
    case direction.to_s.downcase
    when 'push', 'away', 'away_from'
      # Move target away from us
      new_x = (target.hex_x + unit_dx * distance).round
      new_y = (target.hex_y + unit_dy * distance).round
    when 'pull', 'toward', 'towards'
      # Move target toward us
      new_x = (target.hex_x - unit_dx * distance).round
      new_y = (target.hex_y - unit_dy * distance).round
    else
      # Default: treat as push
      new_x = (target.hex_x + unit_dx * distance).round
      new_y = (target.hex_y + unit_dy * distance).round
    end

    { x: new_x, y: new_y }
  end

  # Score a hazard push opportunity
  # Higher score = better opportunity
  # @param hazard_hex [RoomHex] the hazard hex
  # @param enemy [FightParticipant] the target
  # @return [Integer] score (0+ for hazards, 0 for non-hazards)
  def calculate_hazard_push_score(hazard_hex, enemy)
    return 0 unless hazard_hex

    scoring = GameConfig::Combat::HAZARD_SCORING
    score = 0

    # Pit = instant kill/removal, highest priority
    if hazard_hex.hex_type == 'pit' || !hazard_hex.traversable
      score += scoring[:pit_bonus]
    end

    # Hazard damage per round
    if hazard_hex.hazard_damage_per_round.to_i > 0
      score += hazard_hex.hazard_damage_per_round * scoring[:damage_per_round_mult]
    end

    # General danger level
    score += hazard_hex.danger_level.to_i * scoring[:danger_level_mult]

    # Fire hazards are very damaging
    if hazard_hex.hazard_type == 'fire'
      score += scoring[:fire_bonus]
    end

    # Explosives can chain react
    if hazard_hex.is_explosive
      score += scoring[:explosive_bonus]
    end

    # Wounded enemies are higher priority targets
    hp_percent = hp_percent_for(enemy)
    thresholds = GameConfig::Combat::HP_THRESHOLDS
    if hp_percent < thresholds[:critically_wounded] + 0.05  # ~0.3
      score += scoring[:wounded_target_bonus]
    elsif hp_percent < thresholds[:wounded]
      score += scoring[:hurt_target_bonus]
    end

    score
  end

  # ============================================
  # Monster Combat - Large Multi-Segment Enemies
  # ============================================

  # Check if fight has an active monster to fight
  # @return [Boolean]
  def fight_has_active_monster?
    !!(active_monster && active_monster.active?)
  end

  # Get the active monster in the fight
  # @return [LargeMonsterInstance, nil]
  def active_monster
    @active_monster ||= if fight.respond_to?(:active_large_monster)
                          fight.active_large_monster
                        else
                          LargeMonsterInstance.first(fight_id: fight.id, status: 'active')
                        end
  end

  # Make combat decisions when fighting a monster
  # Handles mounting, climbing, segment targeting, and ground attacks
  # @return [Hash] decisions hash
  def decide_monster_combat!
    monster = active_monster
    return decide_standard_combat! unless monster

    hp_percent = current_hp_percent

    # Critically wounded: dismount if mounted, defend if not
    if hp_percent <= @profile[:flee_threshold]
      return handle_critical_hp_monster_combat(monster)
    end

    # Already mounted: decide climb/cling/attack/dismount
    if participant_is_mounted?
      return plan_mounted_actions(monster)
    end

    # Not mounted: decide whether to mount or attack from ground
    if should_attempt_mount?(monster)
      return plan_mounting_strategy(monster)
    end

    # Fight from ground - target segments
    plan_ground_attack(monster)
  end

  # Handle combat when critically wounded (flee behavior)
  # @param monster [LargeMonsterInstance]
  # @return [Hash] decisions
  def handle_critical_hp_monster_combat(monster)
    if participant_is_mounted?
      # Dismount to safety
      return build_monster_decisions(
        main_action: 'defend',
        mount_action: 'dismount',
        movement_action: 'away_from_monster',
        monster: monster
      )
    end

    # Just defend and stay away
    build_monster_decisions(
      main_action: 'defend',
      movement_action: 'away_from_monster',
      monster: monster
    )
  end

  # Check if participant is currently mounted on the monster
  # @return [Boolean]
  def participant_is_mounted?
    participant.is_mounted
  end

  # Get mount state for participant
  # @return [MonsterMountState, nil]
  def mount_state_for_participant
    monster = active_monster
    return nil unless monster

    MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
  end

  # Decide whether to attempt mounting the monster
  # Based on AI profile, HP, and distance
  # @param monster [LargeMonsterInstance]
  # @return [Boolean]
  def should_attempt_mount?(monster)
    hp_percent = current_hp_percent

    # Profile-based mounting thresholds
    mount_likelihood = case @profile[:target_strategy]
                       when :weakest  # Aggressive - very likely to mount
                         0.8
                       when :closest  # Balanced - moderate mount chance
                         0.5
                       when :threat   # Defensive/Guardian - moderate mount chance
                         0.4
                       when :random   # Coward - unlikely to mount
                         0.2
                       else
                         0.5
                       end

    # Berserkers always want to mount (go for weak point)
    if @profile[:flee_threshold] == 0.0  # Berserker profile
      mount_likelihood = 0.95
    end

    # Reduce mounting likelihood based on HP
    mount_likelihood *= hp_percent if hp_percent < 0.7

    # Must be adjacent to monster to mount
    return false unless adjacent_to_monster?(monster)

    # Roll against likelihood
    rand < mount_likelihood
  end

  # Check if participant is adjacent to the monster
  # @param monster [LargeMonsterInstance]
  # @return [Boolean]
  def adjacent_to_monster?(monster)
    return false unless participant.hex_x && participant.hex_y

    # Check if any segment is within 1 hex
    monster.monster_segment_instances.any? do |segment|
      pos = segment.hex_position
      next false unless pos

      dx = (participant.hex_x - pos[0]).abs
      dy = (participant.hex_y - pos[1]).abs
      [dx, dy].max <= 1
    end
  end

  # Plan mounting strategy - attempt to mount the monster
  # @param monster [LargeMonsterInstance]
  # @return [Hash] decisions
  def plan_mounting_strategy(monster)
    # Find closest segment to mount on
    closest_segment = find_closest_segment(monster)

    build_monster_decisions(
      main_action: 'attack',
      mount_action: 'mount',
      targeting_monster_id: monster.id,
      targeting_segment_id: closest_segment&.id,
      movement_action: 'towards_monster',
      monster: monster
    )
  end

  # Plan actions while mounted on the monster
  # @param monster [LargeMonsterInstance]
  # @return [Hash] decisions
  def plan_mounted_actions(monster)
    mount_state = mount_state_for_participant
    return plan_ground_attack(monster) unless mount_state

    hp_percent = current_hp_percent

    case mount_state.mount_status
    when 'at_weak_point'
      # Always attack when at weak point - massive damage opportunity!
      plan_weak_point_attack(monster)

    when 'climbing'
      # Continue climbing or cling if danger sensed
      if should_cling?(monster, mount_state)
        plan_cling_action(monster)
      else
        plan_continue_climb(monster, mount_state)
      end

    when 'mounted'
      # Initial mount - decide to climb or stay
      if hp_percent < 0.5
        # Hurt - cling for safety
        plan_cling_action(monster)
      else
        # Start climbing toward weak point
        plan_start_climb(monster)
      end

    else
      # Fallback - dismount
      plan_dismount(monster)
    end
  end

  # Decide whether to cling (defensive) vs climb (offensive)
  # @param monster [LargeMonsterInstance]
  # @param mount_state [MonsterMountState]
  # @return [Boolean]
  def should_cling?(monster, mount_state)
    hp_percent = current_hp_percent

    # Cling if low HP
    return true if hp_percent < 0.4

    # Check if monster is likely to shake off
    # Defensive profiles cling more often
    if @profile[:defend_weight].to_f > 0.4
      mounted_count = monster.monster_mount_states.count do |ms|
        %w[mounted climbing at_weak_point].include?(ms.mount_status)
      end

      # If many climbers, monster likely to shake off
      return true if mounted_count >= monster.monster_template.shake_off_threshold
    end

    false
  end

  # Decide whether to dismount voluntarily
  # @param monster [LargeMonsterInstance]
  # @param mount_state [MonsterMountState]
  # @return [Boolean]
  def should_dismount?(monster, mount_state)
    hp_percent = current_hp_percent

    # Dismount if critically wounded
    return true if hp_percent <= @profile[:flee_threshold]

    # Cowardly profiles dismount when hurt
    return true if @profile[:flee_threshold] >= 0.4 && hp_percent < 0.5

    false
  end

  # Plan attack on weak point
  # @param monster [LargeMonsterInstance]
  # @return [Hash]
  def plan_weak_point_attack(monster)
    weak_segment = monster.weak_point_segment

    build_monster_decisions(
      main_action: 'attack',
      mount_action: 'attack',
      targeting_monster_id: monster.id,
      targeting_segment_id: weak_segment&.id
    )
  end

  # Plan cling action (safe from shake-off)
  # @param monster [LargeMonsterInstance]
  # @return [Hash]
  def plan_cling_action(monster)
    build_monster_decisions(
      main_action: 'defend',  # Clinging = defensive
      mount_action: 'cling'
    )
  end

  # Plan continue climbing
  # @param monster [LargeMonsterInstance]
  # @param mount_state [MonsterMountState]
  # @return [Hash]
  def plan_continue_climb(monster, mount_state)
    build_monster_decisions(
      main_action: 'attack',  # Can attack segment while climbing
      mount_action: 'climb',
      targeting_monster_id: monster.id,
      targeting_segment_id: mount_state.current_segment_id
    )
  end

  # Plan starting to climb
  # @param monster [LargeMonsterInstance]
  # @return [Hash]
  def plan_start_climb(monster)
    build_monster_decisions(
      main_action: 'attack',
      mount_action: 'climb',
      targeting_monster_id: monster.id
    )
  end

  # Plan dismount action
  # @param monster [LargeMonsterInstance]
  # @return [Hash]
  def plan_dismount(monster)
    build_monster_decisions(
      main_action: 'defend',
      mount_action: 'dismount',
      movement_action: 'away_from_monster',
      monster: monster
    )
  end

  # Plan ground attack - target segments without mounting
  # @param monster [LargeMonsterInstance]
  # @return [Hash]
  def plan_ground_attack(monster)
    target_segment = select_target_segment(monster)

    # Determine movement - approach if ranged only, otherwise get adjacent
    movement = if ranged_only?
                 'maintain_distance'
               else
                 'towards_monster'
               end

    build_monster_decisions(
      main_action: 'attack',
      targeting_monster_id: monster.id,
      targeting_segment_id: target_segment&.id,
      movement_action: movement,
      monster: monster
    )
  end

  # Select best segment to attack
  # Priorities: weak point > damaged > mobility > closest
  # @param monster [LargeMonsterInstance]
  # @return [MonsterSegmentInstance, nil]
  def select_target_segment(monster)
    segments = monster.monster_segment_instances.reject { |s| s.status == 'destroyed' }
    return nil if segments.empty?

    # If at weak point, always target it
    weak_point = segments.find(&:weak_point?)
    if weak_point && participant_is_mounted?
      mount_state = mount_state_for_participant
      return weak_point if mount_state&.at_weak_point?
    end

    # Aggressive profiles target damaged segments (finish them off)
    if @profile[:target_strategy] == :weakest
      damaged = segments.select { |s| %w[damaged broken].include?(s.status) }
      return damaged.min_by { |s| s.current_hp } if damaged.any?
    end

    # Target mobility segments to trigger collapse (high-value targets)
    mobility_segments = segments.select(&:required_for_mobility?)
    if mobility_segments.any?
      # Pick most damaged mobility segment
      return mobility_segments.min_by { |s| s.current_hp }
    end

    # Default: closest reachable segment
    find_closest_segment(monster)
  end

  # Find the closest segment to the participant
  # @param monster [LargeMonsterInstance]
  # @return [MonsterSegmentInstance, nil]
  def find_closest_segment(monster)
    segments = monster.monster_segment_instances.reject { |s| s.status == 'destroyed' }
    return nil if segments.empty?

    return segments.first unless participant.hex_x && participant.hex_y

    segments.min_by do |segment|
      pos = segment.hex_position
      next Float::INFINITY unless pos

      dx = (participant.hex_x - pos[0]).abs
      dy = (participant.hex_y - pos[1]).abs
      Math.sqrt(dx * dx + dy * dy)
    end
  end

  # Build decisions hash for monster combat
  # Sets appropriate defaults for unused fields
  # @param options [Hash]
  # @return [Hash]
  def build_monster_decisions(options = {})
    movement = translate_monster_movement(
      options[:movement_action],
      options[:targeting_monster_id],
      options[:monster]
    )

    {
      # Main action
      main_action: options[:main_action] || 'attack',
      ability_id: options[:ability_id],
      ability_target_participant_id: options[:ability_target_participant_id],

      # Monster targeting
      targeting_monster_id: options[:targeting_monster_id],
      targeting_segment_id: options[:targeting_segment_id],

      # Mount action
      mount_action: options[:mount_action],
      is_mounted: %w[mount climb cling attack].include?(options[:mount_action]) ? true : nil,

      # Movement (interpret monster-specific movements)
      movement_action: movement[:action],
      movement_target_participant_id: movement[:target_participant_id],
      target_hex_x: movement[:hex_x],
      target_hex_y: movement[:hex_y],
      maintain_distance_range: movement[:distance],

      # Unused for monster combat
      target_participant_id: nil,
      tactical_action: nil,
      tactical_ability_id: nil,
      willpower_attack: 0,
      willpower_defense: 0,
      willpower_ability: 0
    }.compact
  end

  # Translate monster-specific movement actions to standard actions
  # @param action [String, nil]
  # @param monster_id [Integer, nil]
  # @return [Hash]
  def translate_monster_movement(action, monster_id = nil, monster_override = nil)
    monster = monster_override || (monster_id ? LargeMonsterInstance[monster_id] : nil) || active_monster

    case action
    when 'towards_monster'
      target = target_hex_towards_monster(monster)
      target ? { action: 'move_to_hex', hex_x: target[0], hex_y: target[1] } : { action: 'stand_still' }
    when 'away_from_monster'
      target = target_hex_away_from_monster(monster)
      target ? { action: 'move_to_hex', hex_x: target[0], hex_y: target[1] } : { action: 'stand_still' }
    when 'maintain_distance'
      { action: 'stand_still' }
    else
      { action: 'stand_still' }
    end
  end

  def target_hex_towards_monster(monster)
    return nil unless monster && participant.hex_x && participant.hex_y

    if monster.is_a?(LargeMonsterInstance)
      target = MonsterHexService.new(monster).closest_mounting_hex(participant.hex_x, participant.hex_y)
      return target if target
    end

    closest_segment = monster.monster_segment_instances
                            .filter_map(&:hex_position)
                            .min_by { |hx, hy| HexGrid.hex_distance(participant.hex_x, participant.hex_y, hx, hy) }
    closest_segment
  rescue StandardError => e
    warn "[CombatAIService] Failed to calculate move-towards-monster target: #{e.message}"
    nil
  end

  def target_hex_away_from_monster(monster)
    return nil unless monster && participant.hex_x && participant.hex_y

    center_x = monster.respond_to?(:center_hex_x) ? monster.center_hex_x : participant.hex_x
    center_y = monster.respond_to?(:center_hex_y) ? monster.center_hex_y : participant.hex_y

    dx = participant.hex_x - center_x
    dy = participant.hex_y - center_y
    dx = 1 if dx.zero? && dy.zero?

    steps = [participant.movement_speed.to_i, 1].max
    raw_x = participant.hex_x + (dx <=> 0) * steps
    raw_y = participant.hex_y + (dy <=> 0) * steps * 2
    hex_x, hex_y = HexGrid.to_hex_coords(raw_x, raw_y)
    HexGrid.clamp_to_arena(hex_x, hex_y, fight.arena_width, fight.arena_height)
  rescue StandardError => e
    warn "[CombatAIService] Failed to calculate move-away-from-monster target: #{e.message}"
    nil
  end
end
