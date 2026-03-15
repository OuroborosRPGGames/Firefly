# frozen_string_literal: true

# Fast in-memory combat simulation for battle balancing.
# Uses pure Ruby structs (no Sequel models) for maximum performance.
# Target: 20 simulations in < 1 second.
#
# Supports:
# - Basic attacks with exploding dice
# - Abilities with damage, status effects, and AoE
# - Status effects (DOTs, buffs, CC)
# - Power-scaled damage for balance testing
#
# @example Basic combat
#   pcs = [SimParticipant.new(id: 1, name: 'Hero', is_pc: true, ...)]
#   npcs = [SimParticipant.new(id: 2, name: 'Goblin', is_pc: false, ...)]
#   sim = CombatSimulatorService.new(pcs: pcs, npcs: npcs, seed: 12345)
#   result = sim.simulate!
#   result.pc_victory  # => true/false
#
# @example With abilities
#   fireball = Ability.first(name: 'Fireball')
#   pc = SimParticipant.new(..., abilities: [fireball], ability_chance: 33)
#   sim = CombatSimulatorService.new(pcs: [pc], npcs: npcs)
#
class CombatSimulatorService
  # Reference centralized config for tunable values
  MAX_ROUNDS = GameConfig::Simulator::MAX_ROUNDS
  BASE_MOVEMENT = GameConfig::Simulator::BASE_MOVEMENT
  MOVEMENT_SEGMENT = GameConfig::Simulator::MOVEMENT_SEGMENT
  HAZARD_TYPES = GameConfig::Simulator::HAZARD_TYPES

  # Status effect definitions for simulation
  # Values reference GameConfig::Simulator for easy tuning
  STATUS_EFFECTS = {
    # CC effects - penalties from GameConfig::Simulator::STATUS_EFFECT_PENALTIES
    stunned: { skip_turn: true, duration: 1 },
    dazed: { attack_penalty: GameConfig::Simulator::STATUS_EFFECT_PENALTIES[:dazed_attack], duration: 1 },
    prone: { defense_penalty: GameConfig::Simulator::STATUS_EFFECT_PENALTIES[:prone_defense], duration: 1 },

    # Movement control
    immobilized: { duration: 2 },
    snared: { duration: 2 },
    slowed: { duration: 2 },

    # Damage modifiers - multiplier from GameConfig::Simulator::VULNERABLE_DAMAGE_MULT
    vulnerable: { damage_mult: GameConfig::Simulator::VULNERABLE_DAMAGE_MULT, duration: 2 },
    vulnerable_fire: { damage_mult: GameConfig::Simulator::VULNERABLE_DAMAGE_MULT, damage_type: :fire, duration: 2 },
    vulnerable_ice: { damage_mult: GameConfig::Simulator::VULNERABLE_DAMAGE_MULT, damage_type: :ice, duration: 2 },
    vulnerable_lightning: { damage_mult: GameConfig::Simulator::VULNERABLE_DAMAGE_MULT, damage_type: :lightning, duration: 2 },
    vulnerable_physical: { damage_mult: GameConfig::Simulator::VULNERABLE_DAMAGE_MULT, damage_type: :physical, duration: 2 },

    # Damage over time - values from GameConfig::Simulator::DOT_DAMAGE
    burning: { dot_damage: GameConfig::Simulator::DOT_DAMAGE[:burning], duration: 2 },
    poisoned: { dot_damage: GameConfig::Simulator::DOT_DAMAGE[:poisoned], duration: 3 },
    bleeding: { dot_damage: GameConfig::Simulator::DOT_DAMAGE[:bleeding], duration: 2 },
    freezing: { dot_damage: GameConfig::Simulator::DOT_DAMAGE[:freezing], duration: 2 },  # Cold DOT

    # Debuffs - penalty from GameConfig::Simulator::STATUS_EFFECT_PENALTIES
    frightened: { attack_penalty: GameConfig::Simulator::STATUS_EFFECT_PENALTIES[:frightened_attack], duration: 2 },
    taunted: { duration: 2 },  # Forced targeting (handled separately)

    # Buffs - values from GameConfig::Simulator::PROTECTION_VALUES
    empowered: { damage_bonus: GameConfig::Simulator::PROTECTION_VALUES[:empowered_bonus], duration: 2 },
    protected: { damage_reduction: GameConfig::Simulator::PROTECTION_VALUES[:protected_reduction], duration: 2 },
    armored: { damage_reduction: GameConfig::Simulator::PROTECTION_VALUES[:armored_reduction], duration: 2 },
    shielded: { shield_hp: GameConfig::Simulator::PROTECTION_VALUES[:shielded_hp], duration: 3 },
    regenerating: { hot_healing: GameConfig::Simulator::PROTECTION_VALUES[:regenerating_fraction], duration: 3 },

    # Special
    cleansed: { cleanse: true, duration: 0 }  # Removes negative effects
  }.freeze

  # Effects that are considered negative and can be cleansed
  NEGATIVE_EFFECTS = %i[
    stunned dazed prone immobilized snared slowed
    vulnerable vulnerable_fire vulnerable_ice vulnerable_lightning vulnerable_physical
    burning poisoned bleeding freezing frightened taunted
  ].freeze

  # Pure Ruby struct for participants (no DB overhead)
  SimParticipant = Struct.new(
    :id, :name, :is_pc, :team,
    :current_hp, :max_hp,
    :hex_x, :hex_y,
    :damage_bonus, :defense_bonus, :speed_modifier,
    :damage_dice_count, :damage_dice_sides,
    :stat_modifier,       # Attack stat (STR or DEX equivalent)
    :ai_profile,
    :is_knocked_out,
    :target_id,           # Current target's id
    :main_action,         # 'attack', 'defend', 'flee', 'ability'
    :pending_damage,      # Accumulated damage this round (legacy, kept for DOTs)
    :attack_count,        # Number of attacks received this round
    # Incremental damage tracking (new system)
    :cumulative_damage,   # Running total of damage this round for threshold checks
    :hp_lost_this_round,  # HP already lost this round from incremental checks
    # Ability support
    :abilities,           # Array of Ability models or configs
    :ability_chance,      # % chance to use ability (0-100)
    :selected_ability,    # Ability chosen for this round
    :damage_multiplier,   # Power scaling multiplier (for control team)
    :status_effects,      # Hash of effect_sym => remaining_rounds
    :shield_hp,           # Current shield absorption remaining
    :healing_accumulator, # Fractional healing accumulator for regen
    :willpower_dice,      # Willpower dice for ability bonus (PCs gain from damage, spend on abilities)
    keyword_init: true
  ) do
    # Calculate wound penalty (each HP lost = -1 to rolls)
    def wound_penalty
      max_hp - current_hp
    end

    # Damage thresholds adjusted for wounds - delegates to shared DamageCalculation module
    def damage_thresholds
      DamageCalculation.calculate_damage_thresholds(wound_penalty)
    end

    # Calculate HP loss from damage total - delegates to shared DamageCalculation module
    def calculate_hp_loss(damage)
      DamageCalculation.calculate_hp_from_raw_damage(damage, wound_penalty)
    end

    # Apply damage and check knockout (legacy - used for end-of-round DOT damage)
    def apply_damage!(avg_damage)
      hp_lost = calculate_hp_loss(avg_damage)
      self.current_hp = [current_hp - hp_lost, 0].max
      self.is_knocked_out = current_hp <= 0
      hp_lost
    end

    # === Incremental Damage System ===
    # Used during round resolution to apply damage incrementally as it accumulates

    # Check cumulative damage against thresholds and return HP that SHOULD be lost
    # Does NOT clear cumulative - damage continues accumulating throughout the round
    # @param damage [Integer] total damage accumulated so far this round
    # @return [Integer] HP lost based on current thresholds
    def hp_lost_from_cumulative(damage)
      calculate_hp_loss(damage)
    end

    # Apply HP loss from combat incrementally
    # Only applies the ADDITIONAL HP loss since last check
    # @param new_hp_lost [Integer] total HP that should now be lost this round
    # @param previously_lost [Integer] HP already lost earlier in this round
    # @return [Integer] additional HP lost this check (new_hp_lost - previously_lost)
    def apply_incremental_hp_loss!(new_hp_lost, previously_lost)
      additional_loss = new_hp_lost - previously_lost
      return 0 if additional_loss <= 0

      # Apply HP loss
      self.current_hp = [current_hp - additional_loss, 0].max

      # Check for knockout
      self.is_knocked_out = true if current_hp <= 0

      # PCs gain willpower from taking damage
      gain_willpower_from_damage!(additional_loss)

      additional_loss
    end

    # Add damage to cumulative total and check for threshold crossing
    # Returns HP lost if a new threshold was crossed, 0 otherwise
    # @param damage [Integer] damage to add
    # @return [Integer] additional HP lost from this damage (0 if no threshold crossed)
    def accumulate_and_check_damage!(damage)
      self.cumulative_damage = (cumulative_damage || 0) + damage

      new_hp_lost = hp_lost_from_cumulative(cumulative_damage)
      previously_lost = hp_lost_this_round || 0

      if new_hp_lost > previously_lost
        additional = apply_incremental_hp_loss!(new_hp_lost, previously_lost)
        self.hp_lost_this_round = new_hp_lost
        additional
      else
        0
      end
    end

    # Clear accumulated damage for new round
    def clear_pending_damage!
      self.pending_damage = 0
      self.attack_count = 0
      self.cumulative_damage = 0
      self.hp_lost_this_round = 0
    end

    # Accumulate incoming damage (legacy method - calls new system)
    def accumulate_damage!(damage)
      self.pending_damage = (pending_damage || 0) + damage
      self.attack_count = (attack_count || 0) + 1
    end

    # Calculate distance to another participant
    def distance_to(other)
      dx = hex_x - other.hex_x
      dy = hex_y - other.hex_y
      Math.sqrt(dx * dx + dy * dy).round
    end

    # HP as percentage (0.0 - 1.0)
    def hp_percent
      return 1.0 if max_hp.to_i <= 0

      current_hp.to_f / max_hp.to_f
    end

    # Get attacks per round based on speed
    def attacks_per_round
      base_speed = 3 # Default weapon speed
      modifier = speed_modifier || 0
      [base_speed + modifier, 1].max.clamp(1, 10)
    end

    # Calculate attack segments with variance
    # Uses GameConfig::Mechanics::SEGMENTS for consistency with FightParticipant
    def attack_segments(rng)
      speed = attacks_per_round
      segments_config = GameConfig::Mechanics::SEGMENTS
      interval = segments_config[:total].to_f / speed

      segments = []
      speed.times do |i|
        base_segment = ((i + 1) * interval).round
        variance = (base_segment * segments_config[:attack_randomization]).round
        randomized = base_segment + rng.rand(-variance..variance)
        segments << randomized.clamp(1, segments_config[:total])
      end
      segments.sort
    end

    # Calculate movement segments distributed evenly across the round
    # Uses same pattern as attack_segments for consistency
    def movement_segments(rng, movement_speed = nil)
      hexes = movement_speed || GameConfig::Simulator::BASE_MOVEMENT
      hexes = (hexes * 0.5).ceil if has_effect?(:slowed) || has_effect?(:snared)
      return [] if hexes <= 0

      segments_config = GameConfig::Mechanics::SEGMENTS
      interval = segments_config[:total].to_f / hexes

      segments = []
      hexes.times do |i|
        base_segment = ((i + 1) * interval).round
        variance = (base_segment * segments_config[:movement_randomization]).round
        randomized = base_segment + rng.rand(-variance..variance)
        segments << randomized.clamp(1, segments_config[:total])
      end
      segments.sort
    end

    # Check if participant has a status effect
    def has_effect?(effect_sym)
      return false unless status_effects&.key?(effect_sym)
      val = status_effects[effect_sym]
      val.is_a?(Hash) ? val[:duration] > 0 : val > 0
    end

    # Apply a status effect (supports extra data like damage_mult for vulnerability)
    def apply_effect!(effect_sym, duration, extra: nil)
      self.status_effects ||= {}

      # Special handling for cleanse - remove all negative effects
      if effect_sym == :cleansed
        NEGATIVE_EFFECTS.each { |neg| status_effects.delete(neg) }
        return
      end

      # For effects with extra data (like vulnerability multiplier), store as hash
      if extra
        current = status_effects[effect_sym]
        current_duration = current.is_a?(Hash) ? current[:duration] : (current || 0)
        status_effects[effect_sym] = extra.merge(duration: current_duration + duration)
      else
        # Simple duration-only effects
        current = status_effects[effect_sym]
        current_duration = current.is_a?(Hash) ? current[:duration] : (current || 0)
        status_effects[effect_sym] = current_duration + duration
      end
    end

    # Remove expired status effects and tick durations
    def tick_effects!
      return unless status_effects

      status_effects.each_key do |effect|
        val = status_effects[effect]
        if val.is_a?(Hash)
          val[:duration] -= 1
        else
          status_effects[effect] -= 1
        end
      end
      status_effects.delete_if do |_, v|
        v.is_a?(Hash) ? v[:duration] <= 0 : v <= 0
      end
    end

    # Check if stunned (skip turn)
    def stunned?
      has_effect?(:stunned)
    end

    # Get attack penalty multiplier from daze/frighten effects
    def daze_penalty
      penalty = 1.0
      penalty *= 0.5 if has_effect?(:dazed)
      penalty *= 0.75 if has_effect?(:frightened)
      penalty
    end

    # Get empowered damage bonus (supports variable bonus from effect data)
    def empowered_bonus
      return 0 unless has_effect?(:empowered)
      val = status_effects[:empowered]
      val.is_a?(Hash) ? (val[:damage_bonus] || 5) : 5
    end

    # Get protection damage reduction (supports variable reduction from effect data)
    # Unlike armored (per-hit), protected reduces TOTAL damage pool once per round
    def protection_reduction
      return 0 unless has_effect?(:protected)
      val = status_effects[:protected]
      val.is_a?(Hash) ? (val[:damage_reduction] || 5) : 5
    end

    # Get armored per-hit damage reduction (supports variable reduction from effect data)
    def armored_reduction
      return 0 unless has_effect?(:armored)
      val = status_effects[:armored]
      val.is_a?(Hash) ? (val[:damage_reduction] || 2) : 2
    end

    # Get current shield HP remaining (supports variable shield from effect data)
    def shield_hp_remaining
      return 0 unless has_effect?(:shielded)
      val = status_effects[:shielded]
      val.is_a?(Hash) ? (val[:shield_hp] || 0) : 0
    end

    # Absorb damage with shield, returns damage that got through
    def absorb_with_shield!(damage)
      return damage unless has_effect?(:shielded)
      val = status_effects[:shielded]
      return damage unless val.is_a?(Hash) && val[:shield_hp]

      absorbed = [damage, val[:shield_hp]].min
      val[:shield_hp] -= absorbed

      # Remove shield effect if HP depleted
      if val[:shield_hp] <= 0
        status_effects.delete(:shielded)
      end

      damage - absorbed
    end

    # Check vulnerability and return damage multiplier
    def vulnerability_multiplier(damage_type = :physical)
      # Check general vulnerability first
      if has_effect?(:vulnerable)
        val = status_effects[:vulnerable]
        return val.is_a?(Hash) ? (val[:damage_mult] || 2.0) : 2.0
      end

      # Check type-specific vulnerability
      type_vuln = "vulnerable_#{damage_type}".to_sym
      if has_effect?(type_vuln)
        val = status_effects[type_vuln]
        return val.is_a?(Hash) ? (val[:damage_mult] || 2.0) : 2.0
      end

      1.0
    end

    # Initialize status effects hash if nil
    def ensure_status_effects!
      self.status_effects ||= {}
      self.shield_hp ||= 0
    end

    # Has any abilities configured?
    def has_abilities?
      abilities && !abilities.empty?
    end

    # === Willpower System (for PCs using abilities) ===

    # Use a willpower die for ability (returns bonus damage from rolled d8)
    # Only PCs use willpower, and only if they have at least 1 whole die
    # Rolls 1d8 with explosion on 8 (same as the real combat system)
    # @return [Integer] bonus damage from the roll (0 if no willpower available)
    def use_willpower_for_ability!
      return 0 unless is_pc && (willpower_dice || 0) >= 1.0

      self.willpower_dice = willpower_dice - 1.0
      # Roll 1d8 with explosion on 8, return the total
      DiceRollService.roll(1, 8, explode_on: 8).total
    end

    # Track willpower gained from damage (PCs only)
    # Called when HP is lost to simulate gaining willpower from being hurt
    # @param hp_lost [Integer] HP lost from damage
    def gain_willpower_from_damage!(hp_lost)
      return unless is_pc && hp_lost > 0

      gain = hp_lost * GameConfig::Mechanics::WILLPOWER[:gain_per_hp_lost]
      max_dice = GameConfig::Mechanics::WILLPOWER[:max_dice]
      self.willpower_dice = [(willpower_dice || 0) + gain, max_dice].min
    end

    # Check if participant has available willpower dice
    # @return [Boolean]
    def has_willpower?
      (willpower_dice || 0) >= 1.0
    end
  end

  # Simulation result struct
  SimResult = Struct.new(
    :pc_victory,
    :rounds_taken,
    :surviving_pcs,
    :total_pc_hp_remaining,
    :total_npc_hp_remaining,
    :pc_ko_count,
    :npc_ko_count,
    :seed_used,
    # Monster combat results
    :monster_defeated,
    :monster_hp_remaining,
    keyword_init: true
  )

  # Monster struct for simulation (no DB overhead)
  SimMonster = Struct.new(
    :id, :name, :template_id,
    :current_hp, :max_hp,
    :center_x, :center_y,
    :segments,           # Array of SimSegment
    :mount_states,       # Array of SimMountState (participant_id => state)
    :status,             # :active, :collapsed, :defeated
    :shake_off_threshold,
    :climb_distance,
    :segment_attack_count_range, # [min, max] attacks per round
    keyword_init: true
  ) do
    def active_segments
      segments.select { |s| s.status != :destroyed }
    end

    def weak_point_segment
      segments.find(&:is_weak_point)
    end

    def defeated?
      status == :defeated || current_hp <= 0
    end

    def collapsed?
      status == :collapsed
    end

    # Check if mobility segments are destroyed (triggers collapse)
    def mobility_destroyed?
      mobility_segments = segments.select(&:required_for_mobility)
      return false if mobility_segments.empty?

      mobility_segments.all? { |s| s.status == :destroyed }
    end

    # Get mount state for a participant
    def mount_state_for(participant_id)
      mount_states.find { |ms| ms.participant_id == participant_id }
    end

    # Count mounted participants
    def mounted_count
      mount_states.count { |ms| ms.mount_status != :thrown && ms.mount_status != :dismounted }
    end

    # Check if shake-off should trigger
    def should_shake_off?
      # Urgent if anyone at weak point
      return true if mount_states.any? { |ms| ms.mount_status == :at_weak_point }

      # Check threshold adjusted for climbers
      climbing_count = mount_states.count { |ms| ms.mount_status == :climbing }
      adjusted_threshold = [shake_off_threshold - climbing_count, 1].max

      mounted_count >= adjusted_threshold
    end
  end

  # Monster segment struct for simulation
  SimSegment = Struct.new(
    :id, :name, :segment_type,
    :current_hp, :max_hp,
    :attacks_per_round, :attacks_remaining,
    :damage_dice, :damage_bonus,
    :reach,
    :is_weak_point, :required_for_mobility,
    :status,  # :healthy, :damaged, :broken, :destroyed
    :hex_x, :hex_y,
    keyword_init: true
  ) do
    def can_attack?
      status != :destroyed && attacks_remaining.to_i > 0
    end

    def hp_percent
      return 1.0 if max_hp.to_i <= 0
      current_hp.to_f / max_hp.to_f
    end

    def apply_damage!(damage)
      self.current_hp = [current_hp - damage, 0].max
      update_status!
      current_hp
    end

    def update_status!
      pct = hp_percent
      self.status = if pct <= 0
                      :destroyed
                    elsif pct <= 0.25
                      :broken
                    elsif pct <= 0.5
                      :damaged
                    else
                      :healthy
                    end
    end

    def reset_attacks!
      self.attacks_remaining = attacks_per_round
    end
  end

  # Mount state for participant on monster
  SimMountState = Struct.new(
    :participant_id,
    :segment_id,
    :mount_status,     # :mounted, :climbing, :at_weak_point, :thrown, :dismounted
    :climb_progress,   # 0-100, reaches weak point at 100
    keyword_init: true
  ) do
    def at_weak_point?
      mount_status == :at_weak_point
    end

    def climbing?
      mount_status == :climbing
    end

    def mounted?
      mount_status == :mounted || mount_status == :climbing || mount_status == :at_weak_point
    end
  end

  # AI profiles - reference centralized config
  AI_PROFILES = GameConfig::Simulator::AI_PROFILES

  attr_reader :pcs, :npcs, :participants, :monsters, :arena_width, :arena_height, :rng, :round

  # @param pcs [Array<SimParticipant>] Player characters
  # @param npcs [Array<SimParticipant>] Non-player characters
  # @param monsters [Array<SimMonster>] Large monsters with segments
  # @param arena_width [Integer] Arena width in hexes
  # @param arena_height [Integer] Arena height in hexes
  # @param seed [Integer, nil] RNG seed for reproducibility
  def initialize(pcs:, npcs:, monsters: [], arena_width: GameConfig::Simulator::ARENA_DEFAULTS[:width],
                 arena_height: GameConfig::Simulator::ARENA_DEFAULTS[:height], seed: nil, randomize_positions: false)
    @pcs = pcs
    @npcs = npcs
    @monsters = monsters
    @participants = @pcs + @npcs
    @arena_width = arena_width
    @arena_height = arena_height
    @rng = seed ? Random.new(seed) : Random.new
    @round = 0
    @randomize_positions = randomize_positions

    # Initialize participant state
    @participants.each do |p|
      p.is_knocked_out = false
      p.pending_damage = 0
      p.attack_count = 0
      p.ai_profile ||= 'balanced'
      p.ensure_status_effects!
      p.abilities ||= []
      p.ability_chance ||= 0
      p.damage_multiplier ||= 1.0

      # Initialize willpower: PCs start with initial dice, NPCs start with 0
      if p.is_pc
        p.willpower_dice ||= GameConfig::Mechanics::WILLPOWER[:initial_dice]
      else
        p.willpower_dice ||= 0
      end
    end

    # Initialize monster state
    @monsters.each do |m|
      m.status ||= :active
      m.mount_states ||= []
      m.segments.each do |s|
        s.status ||= :healthy
        s.reset_attacks!
      end
    end
  end

  # Run the combat simulation
  # @return [SimResult]
  def simulate!
    place_participants

    until fight_over? || @round >= MAX_ROUNDS
      @round += 1

      # Reset monster segment attacks for new round
      reset_monsters_for_round

      # Process DOT effects at start of round (accumulates damage)
      process_dot_effects

      # Generate AI decisions (including ability selection)
      # Stun check happens HERE - before we tick durations
      generate_decisions

      # Tick status effect durations AFTER decision check but BEFORE resolve
      # This ensures effects applied last round are checked, then decremented
      # A duration-1 stun applied in round N will:
      #   - Be present for round N+1's generate_decisions (target skips)
      #   - Get ticked to 0 here and removed
      tick_status_effects

      # Resolve combat actions (includes monster segment attacks)
      resolve_round

      # Apply all accumulated damage (threshold check here)
      apply_damage

      # Process healing effects after damage
      process_healing_effects

      # Check for knockouts and monster defeat
      check_knockouts
      check_monster_defeat
    end

    build_result
  end

  # Create SimParticipant from database Character
  # @param character [Character] Database character record
  # @param is_pc [Boolean] Whether this is a player character
  # @param team [String] Team identifier ('pc' or 'npc')
  # @return [SimParticipant]
  def self.from_character(character, is_pc:, team:)
    # Get combat stats from stat block
    stat_block = character.universe&.default_stat_block
    stat_modifier = 10 # Default

    if stat_block
      # Try to get STR or DEX from character stats via active instance
      char_instance = character.character_instances_dataset.where(online: true).first ||
                      character.character_instances_dataset.order(Sequel.desc(:updated_at)).first
      if char_instance
        str = StatAllocationService.get_stat_value(char_instance, 'STR') ||
              StatAllocationService.get_stat_value(char_instance, 'Strength') || 10
        stat_modifier = str
      end
    end

    # Estimate HP from stat block
    hp = stat_block ? (stat_block.total_points.to_i / 10 + 5) : 6
    hp = [hp, 3].max # Minimum 3 HP

    SimParticipant.new(
      id: character.id,
      name: character.full_name,
      is_pc: is_pc,
      team: team,
      current_hp: hp,
      max_hp: hp,
      hex_x: 0,
      hex_y: 0,
      damage_bonus: 0,
      defense_bonus: 0,
      speed_modifier: 0,
      damage_dice_count: 2,
      damage_dice_sides: 8,
      stat_modifier: stat_modifier,
      ai_profile: 'balanced'
    )
  end

  # Create SimParticipant from NpcArchetype
  # @param archetype [NpcArchetype] Database archetype record
  # @param id [Integer] Unique identifier for this instance
  # @return [SimParticipant]
  def self.from_archetype(archetype, id:)
    stats = archetype.combat_stats

    SimParticipant.new(
      id: id,
      name: archetype.name,
      is_pc: false,
      team: 'npc',
      current_hp: stats[:max_hp] || 6,
      max_hp: stats[:max_hp] || 6,
      hex_x: 0,
      hex_y: 0,
      damage_bonus: stats[:damage_bonus] || 0,
      defense_bonus: stats[:defense_bonus] || 0,
      speed_modifier: stats[:speed_modifier] || 0,
      damage_dice_count: stats[:damage_dice_count] || 2,
      damage_dice_sides: stats[:damage_dice_sides] || 6,
      stat_modifier: 10, # NPCs use base modifier
      ai_profile: archetype.ai_profile || 'balanced'
    )
  end

  # Create SimMonster from LargeMonsterInstance
  # @param monster_instance [LargeMonsterInstance] Database monster record
  # @return [SimMonster]
  def self.from_monster_instance(monster_instance)
    template = monster_instance.monster_template

    segments = monster_instance.monster_segment_instances.map do |seg_inst|
      seg_template = seg_inst.monster_segment_template
      SimSegment.new(
        id: seg_inst.id,
        name: seg_template.name,
        segment_type: seg_template.segment_type,
        current_hp: seg_inst.current_hp,
        max_hp: seg_inst.max_hp,
        attacks_per_round: seg_template.attacks_per_round || 1,
        attacks_remaining: seg_template.attacks_per_round || 1,
        damage_dice: seg_template.damage_dice || '2d8',
        damage_bonus: seg_template.damage_bonus || 0,
        reach: seg_template.reach || 2,
        is_weak_point: seg_template.is_weak_point || false,
        required_for_mobility: seg_template.required_for_mobility || false,
        status: (seg_inst.status || 'healthy').to_sym,
        hex_x: seg_inst.hex_position&.[](0) || 0,
        hex_y: seg_inst.hex_position&.[](1) || 0
      )
    end

    # Convert existing mount states
    mount_states = monster_instance.monster_mount_states.map do |ms|
      SimMountState.new(
        participant_id: ms.fight_participant_id,
        segment_id: ms.current_segment_id,
        mount_status: ms.mount_status&.to_sym || :dismounted,
        climb_progress: ms.climb_progress || 0
      )
    end

    SimMonster.new(
      id: monster_instance.id,
      name: template.name,
      template_id: template.id,
      current_hp: monster_instance.current_hp,
      max_hp: monster_instance.max_hp,
      center_x: monster_instance.center_hex_x || 10,
      center_y: monster_instance.center_hex_y || 5,
      segments: segments,
      mount_states: mount_states,
      status: :active,
      shake_off_threshold: template.shake_off_threshold || 3,
      climb_distance: template.climb_distance || 100,
      segment_attack_count_range: template.segment_attack_count_range || [1, 3]
    )
  end

  # Create SimMonster from MonsterTemplate (for balance testing)
  # @param template [MonsterTemplate] Database template record
  # @param id [Integer] Unique identifier for this instance
  # @return [SimMonster]
  def self.from_monster_template(template, id:)
    segments = template.monster_segment_templates.map.with_index do |seg_template, idx|
      hp_fraction = (seg_template.hp_fraction || 0.2) * (template.total_hp || 100)
      SimSegment.new(
        id: idx + 1,
        name: seg_template.name,
        segment_type: seg_template.segment_type,
        current_hp: hp_fraction.to_i,
        max_hp: hp_fraction.to_i,
        attacks_per_round: seg_template.attacks_per_round || 1,
        attacks_remaining: seg_template.attacks_per_round || 1,
        damage_dice: seg_template.damage_dice || '2d8',
        damage_bonus: seg_template.damage_bonus || 0,
        reach: seg_template.reach || 2,
        is_weak_point: seg_template.is_weak_point || false,
        required_for_mobility: seg_template.required_for_mobility || false,
        status: :healthy,
        hex_x: idx * 2,
        hex_y: 5
      )
    end

    SimMonster.new(
      id: id,
      name: template.name,
      template_id: template.id,
      current_hp: template.total_hp || 100,
      max_hp: template.total_hp || 100,
      center_x: 10,
      center_y: 5,
      segments: segments,
      mount_states: [],
      status: :active,
      shake_off_threshold: template.shake_off_threshold || 3,
      climb_distance: template.climb_distance || 100,
      segment_attack_count_range: template.segment_attack_count_range || [1, 3]
    )
  end

  private

  # Place participants randomly scattered across the arena
  # Each team gets a half of the arena but with random positions
  def place_participants
    used_positions = Set.new

    # Generate random obstacles (ratio from GameConfig)
    @obstacles = Set.new
    obstacle_ratio = GameConfig::Simulator::ARENA_DEFAULTS[:obstacle_ratio]
    obstacle_count = (@arena_width * @arena_height * obstacle_ratio).to_i
    obstacle_count.times do
      x = @rng.rand(@arena_width)
      y = @rng.rand(@arena_height)
      @obstacles << [x, y]
    end

    # Generate hazards
    @hazards = {}

    # Always place pit hazards at arena edges (strategic push targets)
    edge_pits = [
      [0, @arena_height / 2],
      [@arena_width - 1, @arena_height / 2],
      [@arena_width / 2, 0],
      [@arena_width / 2, @arena_height - 1]
    ]
    edge_pits.each do |pos|
      @hazards[pos] = :pit unless @obstacles.include?(pos)
    end

    # Add random hazards (ratio from GameConfig)
    hazard_ratio = GameConfig::Simulator::ARENA_DEFAULTS[:hazard_ratio]
    hazard_count = (@arena_width * @arena_height * hazard_ratio).to_i
    hazard_types = HAZARD_TYPES.keys
    hazard_count.times do
      x = @rng.rand(@arena_width)
      y = @rng.rand(@arena_height)
      pos = [x, y]
      next if @obstacles.include?(pos) || @hazards.key?(pos)

      @hazards[pos] = hazard_types.sample(random: @rng)
    end

    max_attempts = @arena_width * @arena_height

    if @randomize_positions
      # All participants placed randomly across entire arena
      @participants.each do |p|
        place_participant!(p, 0, @arena_width, 0, @arena_height, used_positions, max_attempts)
      end
    else
      half_width = @arena_width / 2

      # PCs scattered on left half
      @pcs.each do |pc|
        place_participant!(pc, 0, half_width, 0, @arena_height, used_positions, max_attempts)
      end

      # NPCs scattered on right half
      @npcs.each do |npc|
        place_participant!(npc, half_width, @arena_width, 0, @arena_height, used_positions, max_attempts)
      end
    end
  end

  # Check if fight is over
  # @return [Boolean]
  # Place a participant in a random open position within the given bounds.
  # Falls back to ignoring obstacles after max_attempts to avoid infinite loop.
  def place_participant!(participant, x_min, x_max, y_min, y_max, used_positions, max_attempts)
    arena_size = (x_max - x_min) * (y_max - y_min)
    hard_cap = max_attempts + arena_size
    attempts = 0
    loop do
      attempts += 1
      participant.hex_x = x_min + @rng.rand(x_max - x_min)
      participant.hex_y = y_min + @rng.rand(y_max - y_min)
      pos = [participant.hex_x, participant.hex_y]

      if attempts > hard_cap
        # Arena is full — force placement to avoid infinite loop
        used_positions << pos
        break
      elsif attempts > max_attempts
        # Fallback: accept any non-occupied position (ignore obstacles)
        unless used_positions.include?(pos)
          used_positions << pos
          break
        end
      else
        unless used_positions.include?(pos) || @obstacles.include?(pos)
          used_positions << pos
          break
        end
      end
    end
  end

  def fight_over?
    pcs_alive = @pcs.count { |p| !p.is_knocked_out }
    npcs_alive = @npcs.count { |p| !p.is_knocked_out }

    # PCs all knocked out = fight over (NPC victory)
    return true if pcs_alive == 0

    # All NPCs and monsters defeated = fight over (PC victory)
    npcs_defeated = npcs_alive == 0
    monsters_all_defeated = @monsters.empty? || @monsters.all?(&:defeated?)

    npcs_defeated && monsters_all_defeated
  end

  # Generate AI decisions for all participants
  def generate_decisions
    # Track enemies being targeted for CC this round to avoid double-stunning
    @pending_cc_targets = []
    # Track allies being targeted for shields this round to avoid double-shielding
    @pending_shield_targets = []

    # Shuffle to eliminate first-mover advantage in target selection
    active_participants.shuffle(random: @rng).each do |p|
      generate_decision(p)
    end

    @pending_cc_targets = nil
    @pending_shield_targets = nil
  end

  # Generate decision for a single participant
  def generate_decision(participant)
    # Skip if stunned
    if participant.stunned?
      participant.main_action = 'skip'
      return
    end

    profile = AI_PROFILES[participant.ai_profile] || AI_PROFILES['balanced']

    # Get enemies and allies
    enemies = enemies_of(participant)
    allies = allies_of(participant)
    return if enemies.empty?

    # Choose action based on HP and profile
    hp_pct = participant.hp_percent

    if hp_pct <= profile[:flee_threshold]
      participant.main_action = 'flee'
      participant.selected_ability = nil
      return
    elsif hp_pct <= 0.5 && @rng.rand < profile[:defend_weight]
      participant.main_action = 'defend'
      participant.selected_ability = nil
      return
    elsif participant.has_abilities? && @rng.rand(100) < participant.ability_chance
      # Smart ability selection
      ability, target = select_ability_and_target(participant, enemies, allies, profile)
      if ability
        participant.main_action = 'ability'
        participant.selected_ability = ability
        participant.target_id = target&.id
        return
      end
    end

    # Default to attack - prefer vulnerable targets
    participant.main_action = 'attack'
    participant.selected_ability = nil

    vulnerable_enemies = enemies.select { |e| e.has_effect?(:vulnerable) || e.status_effects&.keys&.any? { |k| k.to_s.start_with?('vulnerable') } }
    if vulnerable_enemies.any?
      participant.target_id = select_target(participant, vulnerable_enemies, profile)
    else
      participant.target_id = select_target(participant, enemies, profile)
    end
  end

  # Smart ability selection based on effective power
  # Uses simplified power calculation for simulator (no DB access)
  # Picks the ability+target combination with highest effective power
  def select_ability_and_target(participant, enemies, allies, profile)
    return [nil, nil] unless participant.has_abilities?

    # Build ranked list of (ability, target, power) options
    ranked_options = []

    participant.abilities.each do |ability|
      targets = sim_valid_targets_for_ability(ability, participant, allies, enemies)

      targets.each do |target|
        eff_power = calculate_effective_power_for_sim(ability, participant, target, enemies, allies)
        ranked_options << {
          ability: ability,
          target: target,
          effective_power: eff_power
        }
      end
    end

    # Sort by effective power (highest first)
    ranked_options.sort_by! { |opt| -opt[:effective_power] }

    # Return the best option (simulator is deterministic)
    if ranked_options.any?
      best = ranked_options.first
      [best[:ability], best[:target]]
    else
      [nil, nil]
    end
  end

  # Determine valid targets for an ability in the simulator
  # @param ability [Ability/SyntheticAbility] the ability
  # @param actor [SimParticipant] who's using it
  # @param allies [Array<SimParticipant>] available allies
  # @param enemies [Array<SimParticipant>] available enemies
  # @return [Array<SimParticipant>]
  def sim_valid_targets_for_ability(ability, actor, allies, enemies)
    target_type = sim_ability_target_type(ability)

    case target_type
    when :self
      [actor]
    when :ally
      allies + [actor]
    when :enemy
      enemies
    else
      enemies # Default to enemies
    end
  end

  # Determine ability target type from ability config
  def sim_ability_target_type(ability)
    # Check for explicit target_type field
    if ability.respond_to?(:target_type) && ability.target_type
      return ability.target_type.to_sym
    end

    # Infer from ability type
    return :ally if ability_is_healing?(ability)
    return :ally if ability_is_shield?(ability)
    return :ally if ability_is_protection?(ability)
    return :ally if ability_is_buff?(ability)

    :enemy # Default
  end

  # Calculate effective power for an ability+target in the simulator
  # Simplified version that doesn't need DB access
  def calculate_effective_power_for_sim(ability, actor, target, enemies, allies)
    base = sim_ability_power(ability)

    multiplier = 1.0

    # AoE cluster bonus - more targets in radius = higher power
    # For ally abilities (heals), count allies; for enemy abilities, count enemies
    # For friendly fire AoEs, calculate net value (enemies - allies*penalty)
    if ability.respond_to?(:has_aoe?) && ability.has_aoe?
      radius = aoe_radius(ability)
      has_friendly_fire = ability.respond_to?(:aoe_hits_allies) && ability.aoe_hits_allies

      if has_friendly_fire
        # Friendly fire: net targets = enemies - (allies * penalty)
        enemies_in_range = enemies.count { |e| e != target && distance_between(target, e) <= radius }
        allies_in_range = allies.count { |a| a != actor && distance_between(target, a) <= radius }

        penalty = GameConfig::EffectivePower::FRIENDLY_FIRE_ALLY_PENALTY
        net_targets = enemies_in_range - (allies_in_range * penalty)

        # If net is too low, heavily penalize
        min_net = GameConfig::EffectivePower::FRIENDLY_FIRE_MIN_NET_TARGETS
        if net_targets < min_net
          multiplier *= 0.1
        else
          expected = [radius * 1.5, 1].max
          actual = net_targets + 1
          multiplier *= [actual.to_f / expected, GameConfig::EffectivePower::AOE_CLUSTER_MAX_MULTIPLIER].min
        end
      else
        # Non-friendly-fire: count appropriate targets
        cluster_targets = sim_ability_target_type(ability) == :ally ? (allies + [actor]) : enemies
        targets_in_range = cluster_targets.count { |t| t != target && distance_between(target, t) <= radius }
        expected = [radius * 1.5, 1].max
        actual = targets_in_range + 1
        multiplier *= [actual.to_f / expected, GameConfig::EffectivePower::AOE_CLUSTER_MAX_MULTIPLIER].min
      end
    end

    # Execute bonus - target below execute threshold
    if ability.respond_to?(:has_execute?) && ability.has_execute? && ability.execute_threshold.to_i > 0
      threshold = ability.execute_threshold.to_i
      target_hp_pct = (target.hp_percent || 1.0) * 100
      if target_hp_pct <= threshold
        effect = ability.respond_to?(:parsed_execute_effect) ? ability.parsed_execute_effect : nil
        if effect && effect['instant_kill']
          multiplier *= GameConfig::EffectivePower::EXECUTE_INSTANT_KILL_MULTIPLIER
        else
          mult = effect&.dig('damage_multiplier')&.to_f || 2.0
          multiplier *= 1.0 + (mult - 1.0)
        end
      end
    end

    # Combo bonus - target has required status
    if ability.respond_to?(:has_combo?) && ability.has_combo?
      combo = ability.respond_to?(:parsed_combo_condition) ? ability.parsed_combo_condition : nil
      if combo && combo['requires_status']
        required = combo['requires_status'].to_sym
        if target.has_effect?(required)
          multiplier *= GameConfig::EffectivePower::COMBO_BONUS_MULTIPLIER
        end
      end
    end

    # Hazard knockback bonus
    if ability.respond_to?(:has_forced_movement?) && ability.has_forced_movement? && @hazards&.any?
      movement = ability.respond_to?(:parsed_forced_movement) ? ability.parsed_forced_movement : nil
      if movement && could_push_into_hazard?(actor, target, movement)
        multiplier *= GameConfig::EffectivePower::HAZARD_KNOCKBACK_MAX_MULTIPLIER
      end
    end

    # Vulnerability matching bonus - prefer abilities matching target's vulnerability type
    if ability_has_damage?(ability)
      damage_type = ability.respond_to?(:damage_type) ? ability.damage_type.to_s.downcase : 'physical'
      type_vuln = "vulnerable_#{damage_type}".to_sym

      if target.has_effect?(type_vuln)
        # Type-specific vulnerability match (e.g., fire ability vs vulnerable_fire)
        multiplier *= GameConfig::EffectivePower::VULNERABILITY_MATCH_MULTIPLIER
      elsif target.has_effect?(:vulnerable)
        # General vulnerability (applies to all damage types)
        multiplier *= GameConfig::EffectivePower::VULNERABILITY_MATCH_MULTIPLIER
      end
    end

    # Healing priority for injured allies
    if ability_is_healing?(ability) && target.hp_percent < 0.5
      multiplier *= 1.5 # Higher priority for critically injured
    end

    # Shield priority for unshielded low-HP allies
    if ability_is_shield?(ability) && !target.has_effect?(:shielded) && target.hp_percent < 0.5
      multiplier *= 1.3
    end

    base * multiplier
  end

  # Get base power for an ability in the simulator
  def sim_ability_power(ability)
    # Try to use the real power method if available
    return ability.power if ability.respond_to?(:power)

    # Fallback: estimate from damage dice
    base = 0
    if ability.respond_to?(:base_damage_dice) && ability.base_damage_dice
      base = DiceNotationService.new(ability.base_damage_dice).average rescue 10
    elsif ability.respond_to?(:average_damage)
      base = ability.average_damage rescue 10
    else
      base = 10 # Default
    end

    # Status effect power
    if ability.respond_to?(:parsed_status_effects) && ability.parsed_status_effects.any?
      ability.parsed_status_effects.each do |effect|
        name = (effect['effect'] || effect['effect_name'] || effect['name']).to_s.downcase
        duration = (effect['duration_rounds'] || effect['duration'] || 1).to_i

        # CC effects are valuable
        base += 10 * duration if %w[stunned stun].any? { |s| name.include?(s) }
        base += 5 * duration if %w[dazed daze prone].any? { |s| name.include?(s) }

        # DOTs
        base += 4 * duration if %w[burning burn fire poison bleed].any? { |s| name.include?(s) }

        # Buffs/debuffs
        base += 8 * duration if name.include?('vulnerable')
        base += 5 * duration if name.include?('shield')
      end
    end

    # Minimum power
    [base, 1].max
  end

  # Check if forced movement could push target into hazard
  def could_push_into_hazard?(actor, target, movement)
    return false unless @hazards&.any?

    distance = movement['distance'].to_i
    return false if distance <= 0

    direction = movement['direction'] || movement['type']
    case direction.to_s.downcase
    when 'push', 'away', 'away_from'
      # Check if any hazard is roughly in the push direction
      @hazards.any? do |h|
        dist_to_hazard = distance_between(target, h)
        dist_to_hazard <= distance + 1 && dist_to_hazard > 0
      end
    else
      false
    end
  end

  # Find the best target for an AoE ability (the one with most enemies within radius)
  def find_best_aoe_target(enemies, radius)
    return enemies.first if enemies.size <= 1

    enemies.max_by do |potential_center|
      # Count how many other enemies are within the AoE radius
      enemies.count { |e| e != potential_center && distance_between(potential_center, e) <= radius }
    end
  end

  # Find the best target for a friendly fire AoE ability
  # Returns [target, allies_hit, enemies_hit] - only returns target if enemies > allies
  def find_best_ff_aoe_target(actor, enemies, allies, ability)
    return [nil, 0, 0] if enemies.empty?

    radius = aoe_radius(ability)
    best_target = nil
    best_net_hits = 0
    best_ally_count = 0
    best_enemy_count = 0

    enemies.each do |potential_center|
      # Count enemies hit (including the center)
      enemies_hit = enemies.count { |e| distance_between(potential_center, e) <= radius }

      # Count allies hit (excluding actor - they're at a safe distance presumably)
      allies_hit = allies.count { |a| distance_between(potential_center, a) <= radius }

      net_hits = enemies_hit - allies_hit

      if net_hits > best_net_hits
        best_net_hits = net_hits
        best_target = potential_center
        best_ally_count = allies_hit
        best_enemy_count = enemies_hit
      end
    end

    [best_target, best_ally_count, best_enemy_count]
  end

  # Check if ability is a healing ability
  def ability_is_healing?(ability)
    return true if ability.respond_to?(:is_healing) && ability.is_healing

    # Check status effects for regenerating
    if ability.respond_to?(:parsed_status_effects)
      ability.parsed_status_effects.any? do |e|
        name = (e['effect'] || e['effect_name'] || e['name']).to_s.downcase
        name.include?('regen') || name.include?('heal')
      end
    else
      false
    end
  end

  # Check if ability grants shields (HP pool absorption)
  def ability_is_shield?(ability)
    if ability.respond_to?(:parsed_status_effects)
      ability.parsed_status_effects.any? do |e|
        name = (e['effect'] || e['effect_name'] || e['name']).to_s.downcase
        name.include?('shield')
      end
    else
      false
    end
  end

  # Check if ability grants protection (flat damage reduction to total pool)
  def ability_is_protection?(ability)
    if ability.respond_to?(:parsed_status_effects)
      ability.parsed_status_effects.any? do |e|
        name = (e['effect'] || e['effect_name'] || e['name']).to_s.downcase
        name.include?('protect')
      end
    else
      false
    end
  end

  # Check if ability is a buff (positive effect for allies)
  def ability_is_buff?(ability)
    if ability.respond_to?(:parsed_status_effects)
      ability.parsed_status_effects.any? do |e|
        name = (e['effect'] || e['effect_name'] || e['name']).to_s.downcase
        name.include?('empower') || name.include?('haste') || name.include?('fortif') ||
          name.include?('armor')  # Armored is a defensive buff for allies
      end
    else
      false
    end
  end

  # Check if ability has damage
  def ability_has_damage?(ability)
    ability.respond_to?(:base_damage_dice) && !ability.base_damage_dice.nil? && !ability.base_damage_dice.to_s.empty?
  end

  # Check if ability is a debuff (negative effect for enemies)
  def ability_is_debuff?(ability)
    return true if ability.respond_to?(:applies_prone) && ability.applies_prone

    if ability.respond_to?(:parsed_status_effects)
      ability.parsed_status_effects.any? do |e|
        name = (e['effect'] || e['effect_name'] || e['name']).to_s.downcase
        name.include?('vulnerable') || name.include?('stun') || name.include?('daze') ||
          name.include?('burn') || name.include?('poison') || name.include?('bleed') ||
          name.include?('slow') || name.include?('snare') || name.include?('immobil')
      end
    else
      false
    end
  end

  # Check if ability has forced movement (push/pull)
  def ability_has_forced_movement?(ability)
    return false unless ability.respond_to?(:has_forced_movement?)

    ability.has_forced_movement?
  end

  # Find the best enemy to push into a hazard
  # @return [Hash, nil] { ability: Ability, target: SimParticipant } or nil
  def find_best_hazard_push_target(actor, forced_movement_abilities, enemies)
    best_option = nil
    best_score = 0

    forced_movement_abilities.each do |ability|
      next unless ability.respond_to?(:parsed_forced_movement)

      movement_config = ability.parsed_forced_movement
      next unless movement_config

      direction = movement_config['direction'] || movement_config['type']
      distance = movement_config['distance'].to_i
      next if distance <= 0

      enemies.each do |enemy|
        # Calculate where enemy would land after push/pull
        landing = calculate_push_destination(actor, enemy, direction, distance)
        next unless landing

        # Check if landing position is a hazard
        landing_pos = [landing[:x], landing[:y]]
        hazard_type = @hazards[landing_pos]
        next unless hazard_type

        # Score based on hazard severity
        score = calculate_hazard_score(hazard_type, enemy)
        next if score <= 0

        if score > best_score
          best_score = score
          best_option = { ability: ability, target: enemy }
        end
      end
    end

    best_option
  end

  # Calculate where a target would land after forced movement
  # @return [Hash, nil] { x: Integer, y: Integer } or nil
  def calculate_push_destination(actor, target, direction, distance)
    return nil unless target.hex_x && target.hex_y
    return nil unless actor.hex_x && actor.hex_y

    # Calculate direction vector from actor to target
    dx = target.hex_x - actor.hex_x
    dy = target.hex_y - actor.hex_y

    # Normalize to unit direction
    length = Math.sqrt(dx * dx + dy * dy)
    return nil if length == 0

    unit_dx = dx / length
    unit_dy = dy / length

    # Push = move away from actor, Pull = move toward actor
    case direction.to_s.downcase
    when 'push', 'away', 'away_from'
      new_x = (target.hex_x + unit_dx * distance).round
      new_y = (target.hex_y + unit_dy * distance).round
    when 'pull', 'toward', 'towards'
      new_x = (target.hex_x - unit_dx * distance).round
      new_y = (target.hex_y - unit_dy * distance).round
    else
      # Default to push
      new_x = (target.hex_x + unit_dx * distance).round
      new_y = (target.hex_y + unit_dy * distance).round
    end

    # Check bounds
    new_x = new_x.clamp(0, @arena_width - 1)
    new_y = new_y.clamp(0, @arena_height - 1)

    { x: new_x, y: new_y }
  end

  # Score a hazard push opportunity (higher = better)
  def calculate_hazard_score(hazard_type, enemy)
    hazard = HAZARD_TYPES[hazard_type]
    return 0 unless hazard

    score = 0

    # Pit = instant kill, highest priority
    if hazard[:instant_kill]
      score += 50
    end

    # Damage per round
    if hazard[:damage_per_round]
      score += hazard[:damage_per_round] * 5
    end

    # General danger level
    score += (hazard[:danger_level] || 0) * 3

    # Wounded enemies are higher priority
    if enemy.hp_percent < 0.3
      score += 15
    elsif enemy.hp_percent < 0.5
      score += 5
    end

    score
  end

  # Check if enemy already has any debuff/CC effect
  def enemy_has_debuff?(enemy)
    return false unless enemy.status_effects&.any?

    debuff_effects = %i[stunned dazed prone immobilized snared slowed
                        vulnerable vulnerable_fire vulnerable_ice vulnerable_lightning vulnerable_physical
                        burning poisoned bleeding freezing frightened taunted]
    debuff_effects.any? { |e| enemy.has_effect?(e) }
  end

  # Check if enemy is already being targeted for CC this round
  def pending_cc_target?(enemy)
    @pending_cc_targets&.include?(enemy.id)
  end

  # Mark enemy as pending CC target for this round
  def mark_pending_cc_target(enemy)
    @pending_cc_targets << enemy.id if @pending_cc_targets
  end

  # Check if ally is already being targeted for shield this round
  def pending_shield_target?(ally)
    @pending_shield_targets&.include?(ally.id)
  end

  # Mark ally as pending shield target for this round
  def mark_pending_shield_target(ally)
    @pending_shield_targets << ally.id if @pending_shield_targets
  end

  # Select target based on strategy
  def select_target(participant, enemies, profile)
    case profile[:target_strategy]
    when :weakest
      enemies.min_by(&:current_hp)&.id
    when :closest
      enemies.min_by { |e| participant.distance_to(e) }&.id
    when :strongest
      enemies.max_by(&:current_hp)&.id
    when :threat
      # Prioritize enemies targeting us
      threats = enemies.select { |e| e.target_id == participant.id }
      (threats.first || enemies.min_by { |e| participant.distance_to(e) })&.id
    when :random
      enemies.sample&.id
    else
      enemies.min_by { |e| participant.distance_to(e) }&.id
    end
  end

  # Get enemies of a participant (using team/side if available)
  def enemies_of(participant)
    if participant.respond_to?(:team) && !participant.team.nil?
      # Use team-based logic (supports multi-side combat)
      @participants.reject do |p|
        p.is_knocked_out || p.team == participant.team
      end
    elsif participant.is_pc
      # Fallback to PC vs NPC logic
      @npcs.reject(&:is_knocked_out)
    else
      @pcs.reject(&:is_knocked_out)
    end
  end

  # Get allies of a participant (excluding self, using team/side if available)
  def allies_of(participant)
    if participant.respond_to?(:team) && !participant.team.nil?
      # Use team-based logic
      @participants.reject do |p|
        p.is_knocked_out || p.id == participant.id || p.team != participant.team
      end
    elsif participant.is_pc
      @pcs.reject { |p| p.is_knocked_out || p.id == participant.id }
    else
      @npcs.reject { |p| p.is_knocked_out || p.id == participant.id }
    end
  end

  # Get active (non-KO'd) participants
  def active_participants
    @participants.reject(&:is_knocked_out)
  end

  # Resolve a combat round using 100-segment timing
  def resolve_round
    # Build segment schedule
    segment_events = Array.new(101) { [] }

    # Shuffle to eliminate ordering bias in same-segment resolution
    active_participants.shuffle(random: @rng).each do |p|
      next if p.main_action == 'skip' || p.main_action == 'flee' || p.main_action == 'defend'

      target = find_participant(p.target_id)
      next unless target && !target.is_knocked_out

      if p.main_action == 'ability' && p.selected_ability
        # Schedule ability at activation segment
        ability = p.selected_ability
        segment = ability.respond_to?(:activation_segment) ? (ability.activation_segment || 50) : 50
        segment_events[segment] << { actor: p, target: target, ability: ability }
      else
        # Schedule attacks
        p.attack_segments(@rng).each do |segment|
          segment_events[segment] << { actor: p, target: target }
        end
      end

      # Schedule distributed movement (one step per segment)
      # Skip if immobilized
      unless p.has_effect?(:immobilized)
        movement_path = calculate_movement_path(p, target)
        move_segments = p.movement_segments(@rng)

        movement_path.each_with_index do |step, i|
          seg = move_segments[i] || move_segments.last || MOVEMENT_SEGMENT
          segment_events[seg] << {
            actor: p,
            movement_step: true,
            target_hex: step,
            step_index: i,
            total_steps: movement_path.length
          }
        end
      end
    end

    # Schedule monster segment attacks
    schedule_monster_attacks(segment_events)

    # Process segments in order (events within same segment already randomized)
    (1..100).each do |segment|
      segment_events[segment].each do |event|
        if event[:movement_step]
          process_movement_step(event)
        elsif event[:movement]
          # Legacy single-movement support (shouldn't be used anymore)
          process_movement(event[:actor])
        elsif event[:ability]
          process_ability(event[:actor], event[:target], event[:ability])
        elsif event[:monster_attack]
          process_monster_segment_attack(event[:monster], event[:segment], event[:target])
        elsif event[:shake_off]
          process_monster_shake_off(event[:monster])
        else
          process_attack(event[:actor], event[:target])
        end
      end
    end
  end

  # Process a single attack
  def process_attack(actor, target)
    return if actor.is_knocked_out || target.is_knocked_out

    # Range check disabled for balance testing - all attacks are ranged

    # Roll dice - use consistent rules for fair balance testing
    # Both teams use their configured dice (default 2d10) without explosion
    roll = roll_dice(actor.damage_dice_count, actor.damage_dice_sides)

    # Calculate total damage
    total = roll + actor.stat_modifier - actor.wound_penalty
    total += actor.damage_bonus
    total -= target.defense_bonus

    # Apply empowered bonus
    total += actor.empowered_bonus

    # Apply daze penalty
    total = (total * actor.daze_penalty).round

    # Apply damage multiplier (for power-scaled control team)
    total = (total * actor.damage_multiplier).round

    # Apply dodge penalty if target is defending
    total -= 5 if target.main_action == 'defend'

    # Apply protection reduction per-hit (previously was end-of-round)
    total -= target.protection_reduction
    total = [total, 0].max

    # Apply vulnerability multiplier
    total = (total * target.vulnerability_multiplier(:physical)).round

    total = [total, 0].max

    # Armored: per-hit damage reduction
    total -= target.armored_reduction
    total = [total, 0].max

    # Shield: absorb from HP pool (depletes shield)
    total = target.absorb_with_shield!(total)

    # Incremental damage: add to cumulative and check threshold
    # HP loss is applied immediately if a threshold is crossed
    # This means wound penalty affects subsequent attacks this round
    target.accumulate_and_check_damage!(total)

    # Also track in legacy pending_damage for compatibility
    target.accumulate_damage!(total)
  end

  # Process an ability use
  def process_ability(actor, target, ability)
    return if actor.is_knocked_out || target.is_knocked_out

    # Check if this is a healing ability
    is_healing = ability.respond_to?(:is_healing) && ability.is_healing

    # Check if this is an ally-support ability (shield, protection, buff)
    # These abilities apply effects to allies but should NOT deal damage to them
    is_ally_support = ability_is_shield?(ability) || ability_is_protection?(ability) || ability_is_buff?(ability)
    targets_ally = actor.team == target.team

    # Apply status effects from ability (to target - beneficial effects for heals, harmful for attacks)
    if ability.respond_to?(:parsed_status_effects)
      ability.parsed_status_effects.each do |effect|
        effect_name = (effect['effect'] || effect['effect_name'] || effect['name']).to_s
        chance = effect['chance']&.to_f || 1.0

        # Get base duration from effect config or ability defaults
        base_duration = effect['duration_rounds'] || effect['duration'] ||
                        (ability.respond_to?(:status_base_duration) ? ability.status_base_duration : nil) || 2

        # Apply duration scaling if ability has it (simpler than full roll-based scaling)
        # In simulator, we approximate with average roll bonus
        duration = base_duration
        if ability.respond_to?(:status_duration_scaling) && ability.status_duration_scaling.to_i > 0
          scaling = ability.status_duration_scaling.to_i
          # Approximate: average 2d8 roll = 9, so bonus = 9/scaling
          avg_bonus = (9.0 / scaling).to_i
          duration = base_duration + avg_bonus
        end

        next unless @rng.rand < chance

        effect_sym = normalize_effect_name(effect_name)
        next unless STATUS_EFFECTS[effect_sym]

        # For vulnerability effects, pass the damage multiplier as extra data
        if effect_sym.to_s.start_with?('vulnerable')
          damage_mult = effect['damage_mult']&.to_f || effect['multiplier']&.to_f || 2.0
          target.apply_effect!(effect_sym, duration.to_i, extra: { damage_mult: damage_mult })
        # For empowered effects, pass the damage bonus as extra data
        elsif effect_sym == :empowered
          damage_bonus = effect['damage_bonus']&.to_i || effect['bonus']&.to_i || 5
          target.apply_effect!(effect_sym, duration.to_i, extra: { damage_bonus: damage_bonus })
        # For armored effects, pass the damage reduction as extra data
        elsif effect_sym == :armored
          damage_reduction = effect['damage_reduction']&.to_i || effect['reduction']&.to_i || 2
          target.apply_effect!(effect_sym, duration.to_i, extra: { damage_reduction: damage_reduction })
        # For shielded effects, pass the shield HP as extra data
        elsif effect_sym == :shielded
          shield_hp = effect['shield_hp']&.to_i || effect['amount']&.to_i || 10
          target.apply_effect!(effect_sym, duration.to_i, extra: { shield_hp: shield_hp })
        # For protected effects, pass the damage reduction as extra data
        elsif effect_sym == :protected
          damage_reduction = effect['damage_reduction']&.to_i || effect['reduction']&.to_i || 5
          target.apply_effect!(effect_sym, duration.to_i, extra: { damage_reduction: damage_reduction })
        else
          target.apply_effect!(effect_sym, duration.to_i)
        end
      end
    end

    # Apply knockdown if ability has it (only for damaging abilities)
    if !is_healing && ability.respond_to?(:applies_prone) && ability.applies_prone
      target.apply_effect!(:prone, 1)
    end

    # Apply forced movement if ability has it
    if !is_healing && ability.respond_to?(:has_forced_movement?) && ability.has_forced_movement?
      apply_forced_movement(actor, target, ability)
    end

    # Calculate healing or damage if ability has dice
    if ability.respond_to?(:base_damage_dice) && ability.base_damage_dice
      if is_healing
        # Healing ability - restore HP to target
        heal_amount = DiceNotationService.new(ability.base_damage_dice).roll

        # Apply flat modifier
        heal_amount += ability.damage_modifier.to_i if ability.respond_to?(:damage_modifier)

        # Apply dice modifier
        if ability.respond_to?(:damage_modifier_dice) && !ability.damage_modifier_dice.to_s.strip.empty?
          heal_amount += ability.calculate_modifier_dice rescue 0
        end

        # Apply percentage multiplier
        if ability.respond_to?(:damage_multiplier)
          multiplier = ability.damage_multiplier.to_f
          heal_amount = (heal_amount * multiplier).round if multiplier > 0 && multiplier != 1.0
        end

        # Apply stat modifier (simulator uses generic stat_modifier for all stat-scaling abilities)
        if ability.respond_to?(:damage_stat) && ability.damage_stat
          heal_amount += actor.stat_modifier.to_i
        end

        heal_amount = [heal_amount, 0].max
        target.current_hp = [target.current_hp + heal_amount, target.max_hp].min
        return
      end

      # Ally-support abilities (shields, protection, buffs) don't damage allies
      # The effect was already applied above, so just return
      if is_ally_support && targets_ally
        return
      end
      damage = DiceNotationService.new(ability.base_damage_dice).roll

      # Apply PC willpower bonus for abilities (PCs use 1 willpower die if available)
      damage += actor.use_willpower_for_ability!

      # Apply flat damage modifier
      damage += ability.damage_modifier.to_i if ability.respond_to?(:damage_modifier)

      # Apply dice-based damage modifier (+1d6, -1d4, etc.)
      if ability.respond_to?(:damage_modifier_dice) && !ability.damage_modifier_dice.to_s.strip.empty?
        damage += ability.calculate_modifier_dice rescue 0
      end

      # Apply percentage damage multiplier (e.g., 1.5 = 150%)
      if ability.respond_to?(:damage_multiplier)
        multiplier = ability.damage_multiplier.to_f
        damage = (damage * multiplier).round if multiplier > 0 && multiplier != 1.0
      end

      # Apply stat-based damage modifier (simulator uses generic stat_modifier for all stats)
      if ability.respond_to?(:damage_stat) && ability.damage_stat
        damage += actor.stat_modifier.to_i
      end

      # Apply power scaling for abilities that have it (like EnergyBoltAbility)
      if ability.respond_to?(:power_scaled?) && ability.power_scaled? && ability.respond_to?(:power_multiplier)
        damage = (damage * ability.power_multiplier).round
      end

      # Apply conditional damage bonuses
      damage += calculate_conditional_damage(ability, target)

      # Apply empowered bonus
      damage += actor.empowered_bonus

      # Apply daze penalty
      damage = (damage * actor.daze_penalty).round

      # Determine damage type
      damage_type = ability.respond_to?(:damage_type) ? (ability.damage_type || 'physical').to_sym : :physical

      # Apply vulnerability
      damage = (damage * target.vulnerability_multiplier(damage_type)).round

      # Apply protection reduction per-hit (previously was end-of-round)
      damage -= target.protection_reduction
      damage = [damage, 0].max

      # Armored: per-hit damage reduction
      damage -= target.armored_reduction
      damage = [damage, 0].max

      # Shield: absorb from HP pool (depletes shield)
      damage = target.absorb_with_shield!(damage)

      # Incremental damage: add to cumulative and check threshold
      target.accumulate_and_check_damage!(damage)
      target.accumulate_damage!(damage)

      # Apply lifesteal - heal actor based on damage dealt
      if ability.respond_to?(:lifesteal_max) && ability.lifesteal_max.to_i > 0
        heal_amount = [damage, ability.lifesteal_max].min
        actor.current_hp = [actor.current_hp + heal_amount, actor.max_hp].min
      end

      # Handle Chain abilities - bounce to additional targets
      if ability.respond_to?(:has_chain?) && ability.has_chain?
        process_chain_damage(actor, target, ability, damage, damage_type)
      # Handle AoE - hit additional enemies
      elsif ability.respond_to?(:has_aoe?) && ability.has_aoe?
        process_aoe_damage(actor, target, ability, damage, damage_type)
      end
    end

    # Apply execute effect - instant kill if target below HP threshold
    apply_execute_effect(target, ability)
  end

  # Execute mechanic: instant kill targets below HP threshold
  def apply_execute_effect(target, ability)
    return unless ability.respond_to?(:has_execute?) && ability.has_execute?
    return if target.is_knocked_out

    threshold_pct = ability.execute_threshold.to_f / 100.0
    target_hp_pct = target.current_hp.to_f / target.max_hp.to_f

    return unless target_hp_pct <= threshold_pct

    effect = ability.respond_to?(:parsed_execute_effect) ? ability.parsed_execute_effect : {}
    if effect['instant_kill']
      target.current_hp = 0
      target.is_knocked_out = true
    end
  end

  # Calculate bonus damage from conditional effects
  def calculate_conditional_damage(ability, target)
    return 0 unless ability.respond_to?(:parsed_conditional_damage)

    conditions = ability.parsed_conditional_damage
    return 0 if conditions.nil? || conditions.empty?

    bonus = 0
    conditions.each do |cond|
      condition_type = cond['condition'].to_s

      triggered = case condition_type
                  when 'target_below_50_hp'
                    target.hp_percent < 0.5
                  when 'target_below_25_hp'
                    target.hp_percent < 0.25
                  when 'target_has_status'
                    status = cond['status'].to_s
                    effect_sym = normalize_effect_name(status)
                    target.has_effect?(effect_sym)
                  when 'target_full_hp'
                    target.hp_percent >= 1.0
                  else
                    false
                  end

      if triggered && cond['bonus_dice']
        bonus += DiceNotationService.new(cond['bonus_dice']).roll
      end
    end

    bonus
  end

  # Process chain/bounce damage to additional targets
  def process_chain_damage(actor, primary_target, ability, base_damage, damage_type)
    config = ability.parsed_chain_config
    return unless config

    max_targets = config['max_targets']&.to_i || 3
    falloff = config['damage_falloff']&.to_f || 0.5
    friendly_fire = config['friendly_fire'] == true

    # Get potential chain targets
    if friendly_fire
      potential_targets = @participants.reject { |p| p == primary_target || p.is_knocked_out }
    else
      potential_targets = enemies_of(actor).reject { |e| e == primary_target || e.is_knocked_out }
    end

    # Chain to additional targets
    current_damage = base_damage
    hits = [primary_target]

    (max_targets - 1).times do
      break if potential_targets.empty?

      # Find closest unchained target
      last_hit = hits.last
      next_target = potential_targets.min_by { |t| last_hit.distance_to(t) }
      break unless next_target

      potential_targets.delete(next_target)
      hits << next_target

      # Apply falloff
      current_damage = (current_damage * falloff).round

      # Apply vulnerability and protection
      chain_damage = (current_damage * next_target.vulnerability_multiplier(damage_type)).round
      chain_damage -= next_target.protection_reduction
      chain_damage = [chain_damage, 0].max

      # Incremental damage system
      next_target.accumulate_and_check_damage!(chain_damage)
      next_target.accumulate_damage!(chain_damage)
    end
  end

  # Process AoE damage to additional targets
  # Uses actual hex positions to find targets within the AoE radius
  def process_aoe_damage(actor, primary_target, ability, base_damage, damage_type)
    aoe_radius = aoe_radius(ability)

    # Get all potential targets within AoE radius of the primary target (the center)
    other_enemies = enemies_of(actor).reject { |e| e == primary_target || e.is_knocked_out }

    # Include allies if ability hits allies (friendly fire)
    if ability.respond_to?(:aoe_hits_allies) && ability.aoe_hits_allies
      other_allies = allies_of(actor).reject { |a| a == actor || a.is_knocked_out }
      other_enemies = other_enemies + other_allies
    end

    # Filter to targets actually within the AoE radius
    targets_in_range = other_enemies.select do |t|
      distance_between(primary_target, t) <= aoe_radius
    end

    targets_in_range.each do |aoe_target|
      aoe_damage = (base_damage * aoe_target.vulnerability_multiplier(damage_type)).round
      aoe_damage -= aoe_target.protection_reduction
      aoe_damage = [aoe_damage, 0].max
      # Incremental damage system
      aoe_target.accumulate_and_check_damage!(aoe_damage)
      aoe_target.accumulate_damage!(aoe_damage)
    end
  end

  # Get the effective radius of an AoE ability
  def aoe_radius(ability)
    return 1 unless ability.respond_to?(:aoe_shape)

    case ability.aoe_shape
    when 'circle'
      ability.aoe_radius.to_i.nonzero? || 1
    when 'cone'
      # Cone "radius" is roughly its length
      ability.aoe_length.to_i.nonzero? || 2
    when 'line'
      # Line has very narrow width, just treat as length
      ability.aoe_length.to_i.nonzero? || 3
    else
      1
    end
  end

  # Calculate hex distance between two participants
  def distance_between(a, b)
    dx = (a.hex_x - b.hex_x).abs
    dy = (a.hex_y - b.hex_y).abs
    # Hex distance (axial coordinates)
    [dx, dy, (dx + dy)].max / 2.0 + [dx, dy].min
  end

  # Estimate number of targets for AoE
  def estimate_aoe_targets(ability)
    return 1 unless ability.respond_to?(:aoe_shape)

    case ability.aoe_shape
    when 'circle'
      radius = ability.aoe_radius.to_i.nonzero? || 1
      case radius
      when 1 then 2
      when 2 then 3
      else [radius * 2, 5].min
      end
    when 'cone'
      length = ability.aoe_length.to_i.nonzero? || 2
      [length, 3].min
    when 'line'
      length = ability.aoe_length.to_i.nonzero? || 3
      [(length / 2.0).ceil, 2].min
    else
      1
    end
  end

  # Normalize status effect names to our symbols
  def normalize_effect_name(name)
    name = name.to_s.downcase.gsub(/[-\s]/, '_')

    case name
    when /vulnerable.*fire/ then :vulnerable_fire
    when /vulnerable.*ice/ then :vulnerable_ice
    when /vulnerable.*lightning/ then :vulnerable_lightning
    when /vulnerable.*physical/ then :vulnerable_physical
    when /vulnerable/ then :vulnerable
    when /stun/ then :stunned
    when /daze/ then :dazed
    when /burn/ then :burning
    when /poison/ then :poisoned
    when /bleed/ then :bleeding
    when /freez/ then :freezing
    when /fright|fear|terrif/ then :frightened
    when /taunt/ then :taunted
    when /empower/ then :empowered
    when /protect/ then :protected
    when /armor/ then :armored
    when /shield/ then :shielded
    when /regen/ then :regenerating
    when /prone/ then :prone
    when /immobil/ then :immobilized
    when /snare/ then :snared
    when /slow/ then :slowed
    else name.to_sym
    end
  end

  # Calculate movement path as array of [x, y] positions
  # Returns step-by-step path for distributed movement
  def calculate_movement_path(actor, target)
    return [] if actor.is_knocked_out
    return [] if actor.has_effect?(:immobilized)

    movement = BASE_MOVEMENT
    movement = (movement * 0.5).ceil if actor.has_effect?(:slowed) || actor.has_effect?(:snared)
    return [] if movement <= 0

    # Decide: tactical (towards target) or random movement
    use_tactical = target && !target.is_knocked_out &&
                   @rng.rand >= GameConfig::Simulator::MOVEMENT_BEHAVIOR[:random_chance]

    if use_tactical
      calculate_tactical_path(actor, target, movement)
    else
      calculate_random_path(actor, movement)
    end
  end

  # Calculate step-by-step path towards target
  def calculate_tactical_path(actor, target, movement)
    return [] if actor.distance_to(target) <= 1 # Already adjacent

    path = []
    current_x = actor.hex_x
    current_y = actor.hex_y

    movement.times do
      dx = target.hex_x - current_x
      dy = target.hex_y - current_y
      break if dx == 0 && dy == 0 # Reached target

      # Move one step towards target (prefer diagonal)
      if dx.abs > 0 && dy.abs > 0
        current_x += dx > 0 ? 1 : -1
        current_y += dy > 0 ? 1 : -1
      elsif dx.abs > 0
        current_x += dx > 0 ? 1 : -1
      elsif dy.abs > 0
        current_y += dy > 0 ? 1 : -1
      end

      # Clamp to arena and check obstacles
      current_x = current_x.clamp(0, @arena_width - 1)
      current_y = current_y.clamp(0, @arena_height - 1)

      break if @obstacles&.include?([current_x, current_y])
      path << [current_x, current_y]

      # Stop if reached adjacency
      new_dist = Math.sqrt((target.hex_x - current_x)**2 + (target.hex_y - current_y)**2).round
      break if new_dist <= 1
    end

    path
  end

  # Calculate step-by-step random path
  def calculate_random_path(actor, movement)
    # Pick a random direction
    directions = [
      [1, 0], [-1, 0], [0, 1], [0, -1],  # Cardinal
      [1, 1], [1, -1], [-1, 1], [-1, -1] # Diagonal
    ]
    dx, dy = directions[@rng.rand(directions.size)]

    # Use random subset of available movement
    actual_steps = @rng.rand(1..movement)

    path = []
    current_x = actor.hex_x
    current_y = actor.hex_y

    actual_steps.times do
      new_x = (current_x + dx).clamp(0, @arena_width - 1)
      new_y = (current_y + dy).clamp(0, @arena_height - 1)

      break if @obstacles&.include?([new_x, new_y])
      break if new_x == current_x && new_y == current_y # Hit boundary

      current_x = new_x
      current_y = new_y
      path << [current_x, current_y]
    end

    path
  end

  # Process a single movement step (for distributed movement)
  def process_movement_step(event)
    actor = event[:actor]
    return if actor.is_knocked_out

    target_hex = event[:target_hex]
    return unless target_hex

    new_x, new_y = target_hex

    # Check for obstacles (path may have become blocked)
    return if @obstacles&.include?([new_x, new_y])

    actor.hex_x = new_x
    actor.hex_y = new_y
  end

  # Process movement - mix of tactical and random movement (legacy, for backward compatibility)
  # 60% chance to move towards target, 40% chance to move randomly
  # This prevents predictable clustering that artificially inflates AoE effectiveness
  def process_movement(actor)
    return if actor.is_knocked_out

    # Check for movement-impairing effects
    return if actor.has_effect?(:immobilized)

    movement = BASE_MOVEMENT
    movement = (movement * 0.5).ceil if actor.has_effect?(:slowed) || actor.has_effect?(:snared)

    target = find_participant(actor.target_id)

    # Random vs tactical movement ratio from GameConfig (or 100% random if no target)
    if target.nil? || @rng.rand < GameConfig::Simulator::MOVEMENT_BEHAVIOR[:random_chance]
      # Random movement within arena bounds
      random_move(actor, movement)
    else
      # Move towards target
      tactical_move(actor, target, movement)
    end
  end

  # Move randomly within arena bounds
  def random_move(actor, movement)
    # Pick a random direction
    directions = [
      [1, 0], [-1, 0], [0, 1], [0, -1],  # Cardinal
      [1, 1], [1, -1], [-1, 1], [-1, -1] # Diagonal
    ]

    dx, dy = directions[@rng.rand(directions.size)]

    # Apply movement (partial based on speed)
    steps = @rng.rand(1..movement)
    new_x = (actor.hex_x + dx * steps).clamp(0, @arena_width - 1)
    new_y = (actor.hex_y + dy * steps).clamp(0, @arena_height - 1)

    # Check for obstacles
    pos = [new_x, new_y]
    unless @obstacles&.include?(pos)
      actor.hex_x = new_x
      actor.hex_y = new_y
    end
  end

  # Move towards a target
  def tactical_move(actor, target, movement)
    distance = actor.distance_to(target)
    return if distance <= 1 # Already adjacent

    dx = target.hex_x - actor.hex_x
    dy = target.hex_y - actor.hex_y

    # Move diagonally or cardinally towards target
    if dx.abs > 0 && dy.abs > 0
      # Diagonal movement
      step_x = dx > 0 ? 1 : -1
      step_y = dy > 0 ? 1 : -1
      steps = [movement, dx.abs, dy.abs].min

      actor.hex_x += step_x * steps
      actor.hex_y += step_y * steps
    elsif dx.abs > 0
      step = dx > 0 ? [movement, dx.abs].min : -[movement, dx.abs].min
      actor.hex_x += step
    elsif dy.abs > 0
      step = dy > 0 ? [movement, dy.abs].min : -[movement, dy.abs].min
      actor.hex_y += step
    end

    # Clamp to arena bounds
    actor.hex_x = actor.hex_x.clamp(0, @arena_width - 1)
    actor.hex_y = actor.hex_y.clamp(0, @arena_height - 1)
  end

  # Apply forced movement from an ability (push/pull)
  def apply_forced_movement(actor, target, ability)
    return unless ability.respond_to?(:parsed_forced_movement)

    movement_config = ability.parsed_forced_movement
    return unless movement_config

    direction = movement_config['direction'] || movement_config['type']
    distance = movement_config['distance'].to_i
    return if distance <= 0

    destination = calculate_push_destination(actor, target, direction, distance)
    return unless destination

    # Move target to new position
    target.hex_x = destination[:x]
    target.hex_y = destination[:y]

    # If pushed into hazard, process hazard damage immediately with push bonus
    landing_pos = [target.hex_x, target.hex_y]
    if @hazards[landing_pos]
      process_hazard_damage(target, was_pushed: true)
    end
  end

  # Clear accumulated damage state at end of round
  # HP loss is now applied incrementally during the round via accumulate_and_check_damage!
  # This method just cleans up for the next round
  def apply_damage
    @participants.each do |p|
      p.clear_pending_damage!
    end
  end

  # Process DOT effects at start of round (applies damage incrementally)
  def process_dot_effects
    @participants.each do |p|
      next if p.is_knocked_out

      # Status effect DOTs - apply incrementally
      %i[burning poisoned bleeding freezing].each do |dot|
        next unless p.has_effect?(dot)

        dot_damage = STATUS_EFFECTS[dot][:dot_damage]
        # Use incremental damage system for DOTs too
        p.accumulate_and_check_damage!(dot_damage)
        p.accumulate_damage!(dot_damage)
      end

      # Hazard damage
      process_hazard_damage(p)
    end
  end

  # Process hazard damage for a participant standing on a hazard
  # @param participant [SimParticipant] The target standing on hazard
  # @param was_pushed [Boolean] Whether they were pushed into it (higher damage)
  def process_hazard_damage(participant, was_pushed: false)
    pos = [participant.hex_x, participant.hex_y]
    hazard_type = @hazards[pos]
    return unless hazard_type

    hazard = HAZARD_TYPES[hazard_type]

    if hazard[:instant_kill]
      # Pit = instant death
      participant.current_hp = 0
      participant.is_knocked_out = true
    elsif was_pushed
      # Pushed into hazard: deal standard attack damage (2d10 avg = 11)
      # If prone, double the damage (landed hard)
      base_damage = roll_dice(2, 10)
      base_damage *= 2 if participant.has_effect?(:prone)
      # Use incremental damage system
      participant.accumulate_and_check_damage!(base_damage)
      participant.accumulate_damage!(base_damage)
    elsif hazard[:damage_per_round]
      # Standing in hazard (start of round): use hazard's normal damage
      hazard_damage = hazard[:damage_per_round]
      # Use incremental damage system
      participant.accumulate_and_check_damage!(hazard_damage)
      participant.accumulate_damage!(hazard_damage)
    end
  end

  # Tick status effect durations (reduce by 1, remove expired)
  def tick_status_effects
    @participants.each(&:tick_effects!)
  end

  # Process healing effects after damage
  def process_healing_effects
    @participants.each do |p|
      next if p.is_knocked_out

      # Regeneration with fractional accumulation
      if p.has_effect?(:regenerating)
        heal_rate = STATUS_EFFECTS[:regenerating][:hot_healing]
        p.healing_accumulator ||= 0.0
        p.healing_accumulator += heal_rate

        # Only heal when crossing integer threshold
        if p.healing_accumulator >= 1.0
          heal_amount = p.healing_accumulator.to_i
          p.healing_accumulator -= heal_amount
          p.current_hp = [p.current_hp + heal_amount, p.max_hp].min
        end
      end

      # Note: Shields now use per-hit absorption, no pool to refresh
    end
  end

  # Check for knockouts
  def check_knockouts
    @participants.each do |p|
      p.is_knocked_out = true if p.current_hp <= 0
    end
  end

  # Roll dice with exploding
  def roll_exploding(count, sides, explode_on, max_explosions: 10)
    total = 0
    count.times do
      result = @rng.rand(1..sides)
      total += result

      # Handle explosions
      explosion_count = 0
      while result == explode_on && explosion_count < max_explosions
        result = @rng.rand(1..sides)
        total += result
        explosion_count += 1
      end
    end
    total
  end

  # Roll dice without exploding
  def roll_dice(count, sides)
    total = 0
    count.times { total += @rng.rand(1..sides) }
    total
  end

  # Find participant by ID
  def find_participant(id)
    return nil unless id

    @participants.find { |p| p.id == id }
  end

  # Build simulation result
  def build_result
    pcs_alive = @pcs.reject(&:is_knocked_out)
    npcs_alive = @npcs.reject(&:is_knocked_out)

    # Check monster status
    monster_defeated = @monsters.any? ? @monsters.all?(&:defeated?) : nil
    monster_hp = @monsters.any? ? @monsters.sum(&:current_hp) : nil

    # PC victory if all NPCs and monsters defeated
    npc_side_defeated = npcs_alive.empty? && (@monsters.empty? || monster_defeated)

    SimResult.new(
      pc_victory: npc_side_defeated && pcs_alive.any?,
      rounds_taken: @round,
      surviving_pcs: pcs_alive.count,
      total_pc_hp_remaining: pcs_alive.sum(&:current_hp),
      total_npc_hp_remaining: npcs_alive.sum(&:current_hp),
      pc_ko_count: @pcs.count(&:is_knocked_out),
      npc_ko_count: @npcs.count(&:is_knocked_out),
      seed_used: @rng.seed,
      monster_defeated: monster_defeated,
      monster_hp_remaining: monster_hp
    )
  end

  # ============================================================================
  # Monster Combat Methods
  # ============================================================================

  # Reset monster segments for new round
  def reset_monsters_for_round
    @monsters.each do |monster|
      next if monster.defeated?

      monster.segments.each(&:reset_attacks!)
    end
  end

  # Schedule monster segment attacks in the event timeline
  # @param segment_events [Array<Array>] The 100-segment event schedule
  def schedule_monster_attacks(segment_events)
    @monsters.each do |monster|
      next if monster.defeated?

      # Select which segments attack this round
      attacking_segments = select_monster_attacking_segments(monster)

      attacking_segments.each do |seg|
        # Select target for this segment
        target = select_monster_target(monster, seg)
        next unless target

        # Schedule attacks at random segments (spread across round)
        seg.attacks_per_round.times do
          attack_segment = @rng.rand(20..80) # Spread attacks mid-round
          segment_events[attack_segment] << {
            monster_attack: true,
            monster: monster,
            segment: seg,
            target: target
          }
        end
      end

      # Check for shake-off
      if monster.should_shake_off?
        # Urgent shake-off (weak point threatened) happens early
        shake_segment = if monster.mount_states.any?(&:at_weak_point?)
                          @rng.rand(15..25)
                        else
                          @rng.rand(45..55)
                        end
        segment_events[shake_segment] << {
          shake_off: true,
          monster: monster
        }
      end
    end
  end

  # Select which segments will attack this round
  # @param monster [SimMonster]
  # @return [Array<SimSegment>]
  def select_monster_attacking_segments(monster)
    available = monster.active_segments.select(&:can_attack?)
    return [] if available.empty?

    # Don't attack with segments that have mounted players
    mounted_segment_ids = monster.mount_states.map(&:segment_id).compact
    available = available.reject { |s| mounted_segment_ids.include?(s.id) }

    return [] if available.empty?

    # Determine attack count based on template range
    range = monster.segment_attack_count_range || [1, 3]
    count = @rng.rand(range[0]..range[1])
    count = [count, available.count].min

    # Prioritize based on threat assessment
    threats = assess_monster_threats(monster)

    if threats[:at_weak_point].any?
      # Emergency: all available segments attack
      available
    elsif threats[:climbing].any?
      # Prioritize segments that can reach climbers
      score_segments_for_climbers(available, threats[:climbing], monster).take(count)
    else
      # Normal: random selection
      available.sample(count, random: @rng)
    end
  end

  # Score segments by ability to hit climbers
  def score_segments_for_climbers(segments, climbers, monster)
    climber_participants = climbers.map { |ms| find_participant(ms.participant_id) }.compact

    scored = segments.map do |seg|
      score = climber_participants.count { |cp| monster_segment_can_hit?(seg, cp, monster) }
      [seg, score]
    end

    scored.sort_by { |_s, score| -score }.map(&:first)
  end

  # Assess threats to the monster from mounted participants
  def assess_monster_threats(monster)
    at_weak_point = []
    climbing = []
    mounted = []

    monster.mount_states.each do |ms|
      case ms.mount_status
      when :at_weak_point
        at_weak_point << ms
      when :climbing
        climbing << ms
      when :mounted
        mounted << ms
      end
    end

    {
      at_weak_point: at_weak_point,
      climbing: climbing,
      mounted: mounted,
      total_mounted: monster.mounted_count
    }
  end

  # Select target for a monster segment
  # @param monster [SimMonster]
  # @param segment [SimSegment]
  # @return [SimParticipant, nil]
  def select_monster_target(monster, segment)
    # Priority 1: Anyone at weak point
    target = find_weak_point_attacker(monster, segment)
    return target if target

    # Priority 2: Active climbers
    target = find_closest_climber(monster, segment)
    return target if target

    # Priority 3: Anyone mounted on this segment
    target = find_mounted_on_segment(monster, segment)
    return target if target

    # Priority 4: Ground targets
    select_ground_target_for_monster(monster, segment)
  end

  # Find participant at weak point that segment can hit
  def find_weak_point_attacker(monster, segment)
    monster.mount_states.each do |ms|
      next unless ms.at_weak_point?

      participant = find_participant(ms.participant_id)
      next unless participant && !participant.is_knocked_out

      return participant if monster_segment_can_hit?(segment, participant, monster)
    end
    nil
  end

  # Find closest active climber
  def find_closest_climber(monster, segment)
    climbers = monster.mount_states.select(&:climbing?)
    return nil if climbers.empty?

    # Sort by climb progress (highest = closest to weak point)
    climbers.sort_by { |ms| -(ms.climb_progress || 0) }.each do |ms|
      participant = find_participant(ms.participant_id)
      next unless participant && !participant.is_knocked_out

      return participant if monster_segment_can_hit?(segment, participant, monster)
    end
    nil
  end

  # Find anyone mounted on this segment
  def find_mounted_on_segment(monster, segment)
    monster.mount_states.each do |ms|
      next unless ms.segment_id == segment.id
      next unless ms.mounted?

      participant = find_participant(ms.participant_id)
      return participant if participant && !participant.is_knocked_out
    end
    nil
  end

  # Select ground target for monster segment
  def select_ground_target_for_monster(monster, segment)
    valid_targets = @pcs.select do |p|
      next false if p.is_knocked_out

      # Skip mounted participants (handled above)
      mount_state = monster.mount_state_for(p.id)
      next false if mount_state&.mounted?

      monster_segment_can_hit?(segment, p, monster)
    end

    return nil if valid_targets.empty?

    # Target closest
    valid_targets.min_by do |t|
      dx = t.hex_x - segment.hex_x
      dy = t.hex_y - segment.hex_y
      Math.sqrt(dx * dx + dy * dy)
    end
  end

  # Check if segment can hit a target
  def monster_segment_can_hit?(segment, target, monster)
    # Mounted targets are always in range
    mount_state = monster.mount_state_for(target.id)
    return true if mount_state&.mounted?

    # Calculate distance
    dx = (target.hex_x - segment.hex_x).abs
    dy = (target.hex_y - segment.hex_y).abs
    distance = [dx, dy].max + [dx, dy].min / 2  # Approximate hex distance

    distance <= segment.reach
  end

  # Process a monster segment attack
  def process_monster_segment_attack(monster, segment, target)
    return if monster.defeated? || segment.status == :destroyed
    return if target.is_knocked_out

    # Roll damage dice
    damage = 0
    if segment.damage_dice
      damage = DiceNotationService.new(segment.damage_dice).roll rescue roll_dice(2, 8)
    else
      damage = roll_dice(2, 8)
    end

    damage += segment.damage_bonus.to_i
    damage = [damage, 0].max

    # Accumulate damage on target
    target.accumulate_damage!(damage)
  end

  # Process monster shake-off attempt
  def process_monster_shake_off(monster)
    return if monster.defeated?

    monster.mount_states.each do |ms|
      next unless ms.mounted?

      participant = find_participant(ms.participant_id)
      next unless participant

      # Participants can make a check to cling
      # Simulate with 50% base cling chance
      cling_chance = 0.5

      # Better climbers have higher chance
      cling_chance += 0.1 if ms.mount_status == :climbing

      # At weak point = very determined to stay
      cling_chance += 0.2 if ms.at_weak_point?

      if @rng.rand < cling_chance
        # Success - stay mounted (but reset climb progress)
        if ms.climbing?
          ms.climb_progress = [ms.climb_progress.to_i - 25, 0].max
        end
      else
        # Failed - thrown off
        ms.mount_status = :thrown

        # Take fall damage
        fall_damage = @rng.rand(5..15)
        participant.accumulate_damage!(fall_damage)
      end
    end
  end

  # Check for monster defeat/collapse
  def check_monster_defeat
    @monsters.each do |monster|
      next if monster.defeated?

      # Check HP threshold
      if monster.current_hp <= 0
        monster.status = :defeated
        next
      end

      # Check mobility collapse
      if monster.mobility_destroyed? && !monster.collapsed?
        monster.status = :collapsed

        # All mounted participants are thrown
        monster.mount_states.each do |ms|
          next unless ms.mounted?

          ms.mount_status = :thrown
          participant = find_participant(ms.participant_id)
          next unless participant

          # Fall damage
          fall_damage = @rng.rand(10..20)
          participant.accumulate_damage!(fall_damage)
        end
      end
    end
  end

  # Check if fight is over (updated to include monsters)
  def monsters_defeated?
    return true if @monsters.empty?

    @monsters.all?(&:defeated?)
  end

  # Process a participant attack on a monster segment
  # @param actor [SimParticipant] The attacker
  # @param monster [SimMonster] The monster being attacked
  # @param segment [SimSegment] The segment being targeted (or nil for auto-select)
  def process_attack_on_monster(actor, monster, segment = nil)
    return if actor.is_knocked_out || monster.defeated?

    # Auto-select segment if not specified
    segment ||= select_segment_to_attack(actor, monster)
    return unless segment && segment.status != :destroyed

    # Roll damage
    roll = roll_dice(actor.damage_dice_count, actor.damage_dice_sides)
    total = roll + actor.stat_modifier - actor.wound_penalty
    total += actor.damage_bonus
    total += actor.empowered_bonus
    total = (total * actor.daze_penalty).round
    total = (total * actor.damage_multiplier).round
    total = [total, 0].max

    # Check if attacker is at weak point (3x damage distributed)
    mount_state = monster.mount_state_for(actor.id)
    if mount_state&.at_weak_point?
      # Triple damage distributed to all segments
      apply_weak_point_damage(monster, total * 3)

      # Attacker is thrown from weak point after attacking
      mount_state.mount_status = :thrown
      fall_damage = @rng.rand(5..10)
      actor.accumulate_damage!(fall_damage)
    else
      # Normal segment damage
      segment.apply_damage!(total)

      # Update monster total HP based on segment damage
      update_monster_hp_from_segments(monster)
    end
  end

  # Select which segment to attack based on strategy
  def select_segment_to_attack(actor, monster)
    available = monster.active_segments.select { |s| s.status != :destroyed }
    return nil if available.empty?

    # Mount state affects targeting
    mount_state = monster.mount_state_for(actor.id)

    if mount_state&.at_weak_point?
      # At weak point - attack weak point segment
      return monster.weak_point_segment || available.first
    end

    if mount_state&.mounted?
      # Mounted - attack segment we're on
      target = available.find { |s| s.id == mount_state.segment_id }
      return target if target
    end

    # Priority: damaged segments (finish them), then mobility segments
    damaged = available.select { |s| s.status == :damaged || s.status == :broken }
    return damaged.min_by(&:hp_percent) if damaged.any?

    mobility = available.select(&:required_for_mobility)
    return mobility.first if mobility.any?

    # Default: random segment
    available.sample(random: @rng)
  end

  # Apply weak point damage (distributed to all segments)
  def apply_weak_point_damage(monster, total_damage)
    active = monster.active_segments
    return if active.empty?

    # Distribute damage equally
    damage_per_segment = total_damage / active.count

    active.each do |seg|
      seg.apply_damage!(damage_per_segment)
    end

    # Update monster total HP
    update_monster_hp_from_segments(monster)
  end

  # Update monster HP based on segment HP totals
  def update_monster_hp_from_segments(monster)
    total_segment_hp = monster.segments.sum(&:current_hp)
    total_max_hp = monster.segments.sum(&:max_hp)

    # Monster HP is proportional to segment HP
    if total_max_hp > 0
      hp_fraction = total_segment_hp.to_f / total_max_hp
      monster.current_hp = (monster.max_hp * hp_fraction).to_i
    end

    # Check for defeat
    if monster.current_hp <= 0
      monster.status = :defeated
    end
  end

  # Simulate climb progress for mounted participants
  def simulate_climbing(monster)
    monster.mount_states.each do |ms|
      next unless ms.climbing?

      participant = find_participant(ms.participant_id)
      next unless participant && !participant.is_knocked_out

      # Progress climbing (approximately 20-30% per round)
      progress = @rng.rand(20..30)
      ms.climb_progress = (ms.climb_progress || 0) + progress

      # Check if reached weak point
      if ms.climb_progress >= 100
        ms.mount_status = :at_weak_point
        ms.climb_progress = 100
      end
    end
  end

  # Helper: Find first active monster (for simple monster fights)
  def active_monster
    @monsters.find { |m| !m.defeated? }
  end
end
