# frozen_string_literal: true

# Resolves a combat round using the 100-segment system.
# Handles attack scheduling, damage calculation, movement, and knockouts.
# Integrates with battle map features (cover, elevation, hazards) when active.
class CombatResolutionService
  attr_reader :fight, :events, :roll_results, :battle_map_service, :resolution_errors, :logger

  # Movement happens once per round at this base segment (with variance from config)
  # Movement budget is now total per round (from GameConfig::Mechanics::MOVEMENT)
  MOVEMENT_SEGMENT = GameConfig::Mechanics::SEGMENTS[:movement_base]
  OBSERVER_EXPOSE_TARGETS_BONUS = 2
  OBSERVER_BLOCK_DAMAGE_MULT = 0.75
  OBSERVER_AGGRO_DAMAGE_MULT = 1.25

  def initialize(fight, logger: nil)
    @fight = fight
    @events = []
    @roll_results = []  # Collect all dice rolls for display
    @resolution_errors = []
    @segment_events = Array.new(GameConfig::Mechanics::SEGMENTS[:total] + 1) { [] }  # Segments 0-100
    @battle_map_service = BattleMapCombatService.new(fight)
    @monster_combat_service = MonsterCombatService.new(fight) if fight.has_active_large_monster?
    @logger = logger || CombatRoundLogger.new(fight)

    # Identity map: one Ruby object per participant, shared across all events.
    # Prevents stale position data when scheduling creates separate objects via associations.
    @participants = {}

    # In-memory state for round resolution - tracks cumulative damage and knockouts
    # This avoids DB refreshes during segment processing
    @round_state = {}
  end

  # Look up the canonical participant object by ID.
  # All scheduling and processing should use this instead of Sequel associations
  # to ensure position updates from movement are visible to attack distance checks.
  def participant(id)
    return nil unless id

    @participants[id] ||= FightParticipant[id]
  end

  # All active participants from the identity map, falling back to DB if map not yet populated
  def active_participants
    @participants.any? ? @participants.each_value : fight.active_participants
  end

  # Initialize round state for all participants at start of resolution
  # Tracks cumulative damage, HP lost this round, knockout status, and initial distance (for reach)
  #
  # Damage tracking breakdown:
  # - cumulative_damage: Total raw damage for display
  # - raw_by_attacker: Hash of attacker_id => raw damage (Armor applies per-attacker, not per-hit)
  # - raw_by_attacker_type: Hash of [attacker_id, damage_type] => raw damage (for type-specific armor)
  # - dot_cumulative: DOT damage (bypasses Armor and Protection, but not Shields)
  # - shield_absorbed_total: Track total absorbed by shields for display
  #
  # Defense application order:
  # 1. Shields absorb per-hit (before tracking)
  # 2. Armor (damage_reduction) applies per-attacker cumulative
  # 3. Protection applies to overall cumulative (attacks only, not DOTs)
  def initialize_round_state
    # Build identity map so all references to the same participant share one Ruby object
    fight.active_participants.each { |p| @participants[p.id] = p }

    @participants.each_value do |p|
      target = participant(p.target_participant_id)
      distance = target ? p.hex_distance_to(target) : nil

      # Pre-roll willpower defense once per round (not per-attack)
      # This single roll reduces cumulative damage before threshold calculation
      wp_defense_roll = p.willpower_defense_roll
      wp_defense_total = wp_defense_roll&.total || 0

      # Pre-roll willpower ability once per round (not per-cast)
      wp_ability_roll = p.willpower_ability_roll
      wp_ability_total = wp_ability_roll&.total || 0

      # Pre-roll base ability roll once per round for PCs/non-custom NPCs.
      # All abilities for the participant scale from this single roll.
      ability_base_roll = if p.npc_with_custom_dice?
                            nil
                          else
                            DiceRollService.roll(2, 8, explode_on: 8, modifier: 0)
                          end
      ability_all_roll_penalty = p.all_roll_penalty
      ability_round_total = if ability_base_roll
                              [ability_base_roll.total + wp_ability_total + ability_all_roll_penalty, 0].max
                            end

      # Pre-roll willpower movement once per round (not per-step)
      wp_movement_data = p.willpower_movement_roll
      wp_movement_roll = wp_movement_data&.dig(:roll_result)
      wp_movement_bonus = wp_movement_data&.dig(:bonus_hexes) || 0

      # Catch participants who entered with 0 HP but were never flagged as knocked out
      if p.current_hp <= 0 && !p.is_knocked_out
        p.update(is_knocked_out: true)
      end

      @round_state[p.id] = {
        cumulative_damage: 0,
        raw_by_attacker: Hash.new(0),
        raw_by_attacker_type: Hash.new(0),
        dot_cumulative: 0,
        ability_cumulative: 0,  # Ability damage (already processed by AbilityProcessorService modifiers)
        shield_absorbed_total: 0,
        hp_lost_this_round: 0,
        is_knocked_out: p.is_knocked_out,
        current_hp: p.current_hp,
        # Capture initial distance at round start for reach calculations
        initial_distance_to_target: distance,
        initial_adjacent: distance.nil? ? false : distance <= 1,
        # Willpower defense: one roll per round, reduces cumulative damage
        willpower_defense_roll: wp_defense_roll,
        willpower_defense_total: wp_defense_total,
        willpower_defense_applied: 0,
        # Willpower ability: one roll per round, adds to ability effectiveness
        willpower_ability_roll: wp_ability_roll,
        willpower_ability_total: wp_ability_total,
        ability_base_roll: ability_base_roll,
        ability_all_roll_penalty: ability_all_roll_penalty,
        ability_round_total: ability_round_total,
        # Willpower movement: one roll per round, adds bonus movement budget
        willpower_movement_roll: wp_movement_roll,
        willpower_movement_bonus: wp_movement_bonus
      }
    end
  end

  # Check if participant is knocked out (uses in-memory state for speed)
  # @param participant_id [Integer] the participant ID to check
  # @return [Boolean] true if knocked out
  def knocked_out?(participant_id)
    @round_state.dig(participant_id, :is_knocked_out) || false
  end

  # Mark participant as knocked out in round state
  # @param participant_id [Integer] the participant ID to mark
  def mark_knocked_out!(participant_id)
    return unless @round_state[participant_id]

    @round_state[participant_id][:is_knocked_out] = true
  end

  # Calculate effective cumulative damage for threshold checks
  # Applies defenses in order: Armor (per-attacker) → Protection (overall) → add DOTs
  #
  # @param target [FightParticipant] the target participant
  # @param state [Hash] the round state for this target
  # @param damage_type [String] damage type for type-specific defenses
  # @return [Hash] { effective: Integer, armor_reduced: Integer, protection_reduced: Integer }
  def calculate_effective_cumulative(target, state, damage_type)
    # Step 1: Apply Armor (damage_reduction) per-attacker and per-damage-type when available.
    # This preserves type-specific mitigation for mixed-type rounds.
    attack_after_armor = 0
    total_armor_reduced = 0
    attack_after_armor_by_type = Hash.new(0)
    raw_by_attacker = state[:raw_by_attacker] || {}
    raw_by_attacker_type = state[:raw_by_attacker_type] || {}
    fallback_type = damage_type.to_s

    if raw_by_attacker_type.any?
      accounted_by_attacker = Hash.new(0)

      raw_by_attacker_type.each do |(attacker_id, typed_damage), raw_damage|
        typed = typed_damage.to_s
        armor = StatusEffectService.flat_damage_reduction(target, typed)
        reduced = [raw_damage - armor, 0].max
        accounted_by_attacker[attacker_id] += raw_damage
        attack_after_armor += reduced
        attack_after_armor_by_type[typed] += reduced
        total_armor_reduced += (raw_damage - reduced)
      end

      # Legacy compatibility: if raw_by_attacker has extra damage not typed, treat it as fallback type.
      raw_by_attacker.each do |attacker_id, raw_damage|
        untyped_damage = raw_damage - accounted_by_attacker[attacker_id]
        next if untyped_damage <= 0

        armor = StatusEffectService.flat_damage_reduction(target, fallback_type)
        reduced = [untyped_damage - armor, 0].max
        attack_after_armor += reduced
        attack_after_armor_by_type[fallback_type] += reduced
        total_armor_reduced += (untyped_damage - reduced)
      end
    else
      raw_by_attacker.each_value do |raw_damage|
        armor = StatusEffectService.flat_damage_reduction(target, fallback_type)
        reduced = [raw_damage - armor, 0].max
        attack_after_armor += reduced
        attack_after_armor_by_type[fallback_type] += reduced
        total_armor_reduced += (raw_damage - reduced)
      end
    end

    # Step 2: Apply Protection (overall cumulative reduction for attacks)
    if attack_after_armor_by_type.keys.length <= 1
      protection = StatusEffectService.overall_protection(target, fallback_type)
      attack_after_protection = [attack_after_armor - protection, 0].max
      protection_applied = attack_after_armor - attack_after_protection
    else
      # Separate universal ("all") protection from type-specific protection so
      # universal protection is only applied once across mixed damage types.
      all_only_probe_type = '__all_only_probe__'
      all_protection = StatusEffectService.overall_protection(target, all_only_probe_type)

      specific_protection_applied = 0
      attack_after_armor_by_type.each do |typed, typed_damage|
        total_for_type = StatusEffectService.overall_protection(target, typed)
        specific_for_type = [total_for_type - all_protection, 0].max
        specific_protection_applied += [specific_for_type, typed_damage].min
      end

      after_specific = [attack_after_armor - specific_protection_applied, 0].max
      all_protection_applied = [all_protection, after_specific].min
      protection_applied = specific_protection_applied + all_protection_applied
      attack_after_protection = [attack_after_armor - protection_applied, 0].max
    end

    # Step 2.5: Add ability damage (already processed by AbilityProcessorService modifiers,
    # bypasses armor/protection but goes through willpower defense)
    combined = attack_after_protection + (state[:ability_cumulative] || 0)

    # Step 3: Apply willpower defense (pre-rolled once per round, reduces combined attack+ability damage)
    wp_defense = state[:willpower_defense_total] || 0
    after_wp = [combined - wp_defense, 0].max
    wp_applied = combined - after_wp
    state[:willpower_defense_applied] = wp_applied

    # Step 4: Add DOT damage (bypasses Armor, Protection, and willpower defense)
    effective = after_wp + (state[:dot_cumulative] || 0)

    {
      effective: effective,
      armor_reduced: total_armor_reduced,
      protection_reduced: protection_applied,
      willpower_defense_reduced: wp_applied
    }
  end

  # Resolve the entire round
  # @return [Hash] containing :events and :roll_display
  def resolve!
    # Lock round to prevent choice changes during resolution
    fight.lock_round!

    # Initialize in-memory state for tracking damage and knockouts during resolution
    initialize_round_state

    # Log round start with all participant inputs and states
    @logger.log_round_start(@participants, @round_state)
    @logger.log_status_effects(@participants)

    # Safety check: move anyone on a non-traversable hex to nearest valid hex
    safe_execute('validate_participant_positions') { validate_participant_positions }

    # Check if all conscious participants chose 'pass' - end fight peacefully
    if all_conscious_passed?
      end_fight_peacefully
      @logger.log_narrative('(fight ended peacefully - mutual pass)')
      @logger.flush!
      return { events: @events, roll_display: [], fight_ended: true, end_reason: 'mutual_pass', errors: [] }
    end

    # Each step is wrapped in error handling so one failure doesn't block the whole round
    safe_execute('schedule_all_events') { schedule_all_events }
    @logger.log_scheduled_events(@segment_events)
    safe_execute('schedule_tick_events') { schedule_tick_events }
    safe_execute('pre_roll_combat_dice') { pre_roll_combat_dice }
    @logger.log_pre_rolls(@combat_pre_rolls, @participants)
    safe_execute('process_segments') { process_segments }
    safe_execute('process_end_of_round_effects') { process_end_of_round_effects }
    safe_execute('apply_accumulated_damage') { apply_accumulated_damage }
    safe_execute('process_flee_attempts') { process_flee_attempts }
    safe_execute('process_surrenders') { process_surrenders }
    safe_execute('process_battle_map_hazards') { process_battle_map_hazards }
    safe_execute('check_knockouts') { check_knockouts }
    safe_execute('save_events_to_db') { save_events_to_db }
    safe_execute('generate_roll_display') { generate_roll_display }
    safe_execute('generate_damage_summary') { generate_round_damage_summary }

    # Log round end with final states (flush deferred until after narrative is logged)
    @logger.log_round_end(@participants, @round_state, @resolution_errors)
    @logger.log_damage_summary(@damage_summary)

    { events: @events, roll_display: @roll_display || [], damage_summary: @damage_summary, errors: @resolution_errors }
  end

  # Log narrative and flush - called by FightService after narrative generation
  def log_narrative_and_flush(narrative_text)
    @logger.log_narrative(narrative_text)
    @logger.flush!
  end

  # Execute a step with error handling, logging failures but not blocking resolution
  # @param step_name [String] name of the step for logging
  # @yield the block to execute
  def safe_execute(step_name)
    yield
  rescue StandardError => e
    @resolution_errors << {
      step: step_name,
      error_class: e.class.to_s,
      message: e.message
    }
    warn "[COMBAT_RESOLUTION] Error in #{step_name}: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n") if e.backtrace
    # Don't re-raise - allow round to continue/complete
  end

  # Check if all conscious participants chose 'pass'
  def all_conscious_passed?
    conscious = active_participants.reject(&:is_knocked_out)
    return false if conscious.empty?

    conscious.all? { |p| p.main_action == 'pass' }
  end

  # End fight peacefully when all participants chose to pass
  def end_fight_peacefully
    @events << create_event(0, nil, nil, 'fight_ended_peacefully',
                            reason: 'All participants chose not to attack')

    fight.update(
      status: 'complete',
      combat_ended_at: Time.now
    )

    save_events_to_db
  end

  private

  # Auto-equip the active weapon and unequip the other if needed
  def ensure_weapon_equipped(active_weapon, other_weapon)
    return unless active_weapon

    other_weapon&.unequip if other_weapon&.equipped? && other_weapon&.id != active_weapon.id
    active_weapon.equip unless active_weapon.equipped?
  end

  # Re-evaluate weapon choice at attack time based on current distance.
  # If attacker moved into melee range since scheduling, switch to melee weapon.
  # If attacker moved out of melee range, switch to ranged weapon.
  def reevaluate_weapon_for_distance(actor, target, weapon, weapon_type)
    distance = actor.hex_distance_to(target)
    melee_weapon = actor.melee_weapon
    ranged_weapon = actor.ranged_weapon
    normalized_type = if weapon_type.is_a?(Symbol)
                        weapon_type
                      elsif weapon_type.nil?
                        nil
                      else
                        text = weapon_type.to_s.strip
                        text.empty? ? nil : text.downcase.to_sym
                      end

    new_weapon, new_type = if distance && distance <= 1 && melee_weapon
                              ensure_weapon_equipped(melee_weapon, ranged_weapon)
                              [melee_weapon, :melee]
                            elsif distance && distance <= 1 && !melee_weapon && ranged_weapon
                              ranged_weapon.unequip if ranged_weapon.equipped?
                              [nil, :unarmed]
                            elsif distance && distance > 1 && ranged_weapon
                              ensure_weapon_equipped(ranged_weapon, melee_weapon)
                              [ranged_weapon, :ranged]
                            else
                              [weapon, normalized_type]
                            end

    if new_type != normalized_type
      @logger.log_weapon_switch(actor, target, distance, normalized_type, new_type, new_weapon&.respond_to?(:name) ? new_weapon.name : nil)
    end

    [new_weapon, new_type]
  end

  # Re-evaluate natural attack at attack time based on current distance.
  # If an NPC has both melee and ranged attacks, pick the best for current range.
  # E.g., Spider switches from Spit (ranged) to Bite (melee) when in melee range.
  def reevaluate_natural_attack_for_distance(actor, target, natural_attack, weapon_type)
    archetype = actor.npc_archetype
    return [natural_attack, weapon_type] unless archetype&.has_natural_attacks?

    distance = actor.hex_distance_to(target)
    better_attack = archetype.best_attack_for_range(distance)
    return [natural_attack, weapon_type] unless better_attack

    new_type = better_attack.melee? ? :natural_melee : :natural_ranged
    if better_attack.name != natural_attack.name
      @logger.log_weapon_switch(actor, target, distance, weapon_type, new_type, better_attack.name)
    end

    [better_attack, new_type]
  end

  def activity_instance_for_observer_effects
    return @activity_instance_for_observer_effects if defined?(@activity_instance_for_observer_effects)

    activity_instance_id = fight.respond_to?(:activity_instance_id) ? fight.activity_instance_id : nil
    @activity_instance_for_observer_effects = activity_instance_id ? ActivityInstance[activity_instance_id] : nil
  end

  def activity_observer_effects
    return @activity_observer_effects if defined?(@activity_observer_effects)

    instance = activity_instance_for_observer_effects
    @activity_observer_effects = instance ? ObserverEffectService.effects_for_combat(instance) : {}
  end

  def activity_participants_by_char_id
    return @activity_participants_by_char_id if defined?(@activity_participants_by_char_id)

    instance = activity_instance_for_observer_effects
    @activity_participants_by_char_id = {}
    return @activity_participants_by_char_id unless instance

    instance.active_participants.each do |participant|
      @activity_participants_by_char_id[participant.char_id] = participant
    end

    @activity_participants_by_char_id
  end

  def activity_participant_for_combatant(combatant)
    return nil unless combatant

    char_id = combatant.character_instance&.character_id
    return nil unless char_id

    activity_participants_by_char_id[char_id]
  end

  def observer_effects_for_combatant(combatant)
    activity_participant = activity_participant_for_combatant(combatant)
    return {} unless activity_participant

    activity_observer_effects[activity_participant.id] || {}
  end

  def activity_combatant_for_activity_participant(activity_participant_id)
    return nil unless activity_participant_id

    active_participants.find do |combatant|
      participant = activity_participant_for_combatant(combatant)
      participant&.id == activity_participant_id
    end
  end

  def resolve_observer_forced_target(actor)
    return nil unless actor&.is_npc

    forced_candidates = []
    aggro_candidates = []

    activity_observer_effects.each do |activity_participant_id, effects|
      candidate = activity_combatant_for_activity_participant(activity_participant_id)
      next unless candidate
      next if knocked_out?(candidate.id)
      next if candidate.side == actor.side

      if effects.key?(:forced_target)
        forced_candidates << candidate
      elsif effects[:aggro_boost]
        aggro_candidates << candidate
      end
    end

    return forced_candidates.first if forced_candidates.any?
    return nil if aggro_candidates.empty?

    aggro_candidates.min_by do |candidate|
      actor.hex_distance_to(candidate)
    rescue StandardError => e
      warn "[CombatResolution] hex_distance_to failed for candidate #{candidate.inspect}: #{e.message}"
      999
    end
  end

  def halve_damage_applies_from_actor?(target_effects, actor)
    sources = Array(target_effects[:halve_damage_from])
    return false if sources.empty?
    return true if sources.any?(&:nil?)

    actor_activity_participant_id = activity_participant_for_combatant(actor)&.id
    return false unless actor_activity_participant_id

    sources.include?(actor_activity_participant_id)
  end

  def apply_observer_combat_modifiers(actor, target, total)
    actor_effects = observer_effects_for_combatant(actor)
    target_effects = observer_effects_for_combatant(target)

    flat_bonus = 0
    multiplier = 1.0
    applied_effects = []

    if actor_effects[:expose_targets]
      flat_bonus += OBSERVER_EXPOSE_TARGETS_BONUS
      applied_effects << 'expose_targets'
    end

    if actor_effects[:damage_dealt_mult]
      dealt_mult = actor_effects[:damage_dealt_mult].to_f
      if dealt_mult.positive?
        multiplier *= dealt_mult
        applied_effects << 'damage_dealt_mult'
      end
    end

    if target_effects[:damage_dealt_mult] && actor&.is_npc
      npc_dealt_mult = target_effects[:damage_dealt_mult].to_f
      if npc_dealt_mult.positive?
        multiplier *= npc_dealt_mult
        applied_effects << 'npc_damage_boost'
      end
    end

    if target_effects[:damage_taken_mult]
      taken_mult = target_effects[:damage_taken_mult].to_f
      if taken_mult.positive?
        multiplier *= taken_mult
        applied_effects << 'damage_taken_mult'
      end
    end

    if target_effects[:block_damage]
      multiplier *= OBSERVER_BLOCK_DAMAGE_MULT
      applied_effects << 'block_damage'
    end

    if target_effects[:aggro_boost] && actor&.is_npc
      multiplier *= OBSERVER_AGGRO_DAMAGE_MULT
      applied_effects << 'aggro_boost'
    end

    if halve_damage_applies_from_actor?(target_effects, actor)
      multiplier *= 0.5
      applied_effects << 'halve_damage'
    end

    modified_total = ((total + flat_bonus) * multiplier).round
    modified_total = [modified_total, 0].max

    {
      total: modified_total,
      effects: applied_effects,
      multiplier: multiplier,
      flat_bonus: flat_bonus
    }
  end

  # Schedule all attacks, abilities, and movement for the round
  def schedule_all_events
    @participants.each_value do |participant|
      # For stand_still, protection tactics are active from segment 0
      if participant.movement_action == 'stand_still'
        participant.update(movement_completed_segment: 0)
      end

      schedule_attacks(participant)
      schedule_abilities(participant)
      schedule_tactical_abilities(participant)
      schedule_movement(participant)
    end

    # Schedule monster attacks if fight has monsters
    schedule_monster_attacks if @monster_combat_service
  end

  # Schedule status effect tick events - DOTs distributed across segments, healing at mid-round
  def schedule_tick_events
    # Reset DOT tracking at start of new round
    StatusEffectService.reset_dot_tracking(@fight)

    # Schedule distributed DOT ticks across the round
    schedule_dot_tick_events

    # Schedule healing tick processing at mid-round (still single tick)
    @segment_events[MOVEMENT_SEGMENT] ||= []
    @segment_events[MOVEMENT_SEGMENT] << { type: :process_healing_ticks }
  end

  # Schedule distributed DOT tick events across the round.
  # Each damage tick effect has its ticks spread across segments based on total damage.
  # Example: 10 damage = ticks at segments 10, 20, 30, 40, 50, 60, 70, 80, 90, 100
  def schedule_dot_tick_events
    @participants.each_value do |participant|
      StatusEffectService.active_effects(participant).each do |pse|
        next unless pse.status_effect&.effect_type == 'damage_tick'

        # Get tick schedule (rolls and caches damage if not yet done)
        tick_segments = StatusEffectService.dot_tick_schedule_for(pse)

        # Schedule individual tick events at each segment
        tick_segments.each_with_index do |segment, idx|
          @segment_events[segment] ||= []
          @segment_events[segment] << {
            type: :dot_tick,
            participant_status_effect_id: pse.id,
            participant: participant,
            tick_index: idx,
            segment: segment
          }
        end
      end
    end
  end

  # Pre-roll one set of combat dice per attacker for the entire round.
  # Instead of rolling 2d8 per attack segment, we roll once and distribute
  # the total evenly across all attacks. This makes combat display cleaner:
  # one visible dice animation per combatant instead of many.
  def pre_roll_combat_dice
    @combat_pre_rolls = {}

    @participants.each_value do |participant|
      next unless participant.main_action == 'attack'
      build_pre_roll_for_actor(participant)
    end
  end

  # Build and cache a participant's per-round attack pre-roll.
  # Returns the cached pre-roll if it already exists.
  # @param participant [FightParticipant]
  # @return [Hash, nil]
  def build_pre_roll_for_actor(participant)
    @combat_pre_rolls ||= {}
    return @combat_pre_rolls[participant.id] if @combat_pre_rolls[participant.id]

    attack_count = count_scheduled_attacks(participant.id)
    return nil if attack_count <= 0

    # Sum stat modifiers across all scheduled attacks (different weapon types use different stats)
    # e.g. 2 melee (STR 2) + 1 ranged (DEX 4) = total_stat 8, per-attack = 8/3
    total_stat_modifier = sum_attack_stat_modifiers(participant)
    stat_per_attack = total_stat_modifier.to_f / attack_count

    # ONE roll per round - natural attacks use natural dice, other NPCs use custom dice, PCs use 2d8 exploding
    natural_attack = natural_attack_for_pre_roll(participant)
    base_roll = roll_base_attack_dice(participant, natural_attack)

    # Willpower dice (only if allocated to attack/main action)
    wp_roll = participant.willpower_attack_roll
    wp_bonus = wp_roll&.total || 0

    roll_total = base_roll.total + wp_bonus
    all_roll_penalty = participant.all_roll_penalty

    @combat_pre_rolls[participant.id] = {
      base_roll: base_roll,
      willpower_roll: wp_roll,
      total_stat_modifier: total_stat_modifier,
      # Backward-compatible alias used in some tests/debug helpers.
      stat_modifier: total_stat_modifier,
      stat_per_attack: stat_per_attack,
      roll_total: roll_total,
      all_roll_penalty: all_roll_penalty,
      attack_count: attack_count,
      is_pc: !participant.is_npc
    }
  end

  # Find the natural attack used by this participant's scheduled attack events.
  # @param participant [FightParticipant]
  # @return [NpcAttack, nil]
  def natural_attack_for_pre_roll(participant)
    @segment_events.each do |segment_events|
      segment_events.each do |event|
        next unless event[:type] == :attack
        next unless event[:actor]&.id == participant.id
        next unless event[:natural_attack]

        return event[:natural_attack]
      end
    end
    nil
  end

  # Build the base attack roll for a participant, respecting natural attack dice.
  # @param participant [FightParticipant]
  # @param natural_attack [NpcAttack, nil]
  # @return [DiceRollService::RollResult]
  def roll_base_attack_dice(participant, natural_attack = nil)
    if natural_attack
      DiceRollService.roll(natural_attack.dice_count, natural_attack.dice_sides,
                           explode_on: nil, modifier: 0)
    elsif participant.npc_with_custom_dice?
      DiceRollService.roll(participant.npc_damage_dice_count,
                           participant.npc_damage_dice_sides,
                           explode_on: nil, modifier: 0)
    else
      DiceRollService.roll(2, 8, explode_on: 8, modifier: 0)
    end
  end

  # Count scheduled :attack events for a participant across all segments
  # @param participant_id [Integer] the participant ID
  # @return [Integer] number of attack events
  def count_scheduled_attacks(participant_id)
    @segment_events.sum do |segment_events|
      segment_events.count { |e| e[:type] == :attack && e[:actor]&.id == participant_id }
    end
  end

  # Get the stat modifier for the round. The stat is added ONCE to the round
  # total, then the total is apportioned across attacks.
  # For mixed weapon types (melee + ranged), uses a weighted average of STR/DEX.
  def sum_attack_stat_modifiers(participant)
    weapon_type_counts = Hash.new(0)

    @segment_events.each do |segment_events|
      segment_events.each do |e|
        next unless e[:type] == :attack && e[:actor]&.id == participant.id

        wt = e[:weapon_type] || :melee
        weapon_type_counts[wt] += 1
      end
    end

    return 0 if weapon_type_counts.empty?

    # If all attacks use the same weapon type, just return that stat
    if weapon_type_counts.size == 1
      return get_attack_stat(participant, weapon_type_counts.keys.first)
    end

    # Mixed weapon types: weighted average of stats
    total_attacks = weapon_type_counts.values.sum.to_f
    weapon_type_counts.sum do |wt, count|
      get_attack_stat(participant, wt) * (count / total_attacks)
    end
  end

  # Process end-of-round effects like burning spread
  def process_end_of_round_effects
    StatusEffectService.process_burning_spread(@fight) do |event|
      @events << create_event(100, event[:from], event[:to], 'burning_spread',
                              from_name: event[:from].character_name,
                              to_name: event[:to].character_name)
    end
  end

  # Schedule all monster segment attacks for the round
  def schedule_monster_attacks
    LargeMonsterInstance.where(fight_id: fight.id, status: 'active').each do |monster|
      monster_events = @monster_combat_service.schedule_monster_attacks(monster)

      monster_events.each do |segment_num, events|
        events.each do |event|
          @segment_events[segment_num] << event
        end
      end
    end
  end

  # Schedule ability activation based on ability's activation_segment
  def schedule_abilities(participant)
    return unless participant.main_action == 'ability'

    # Support both new ability_id and legacy ability_choice
    ability = participant.selected_ability || find_ability_by_choice(participant.ability_choice)
    return unless ability
    return unless ability_available_for_participant?(participant, ability, :main)

    target = self.participant(participant.ability_target_participant_id) || self.participant(participant.target_participant_id)

    # Use ability's configured activation segment with variance
    segment = ability.calculate_activation_segment
    segment = segment.clamp(1, 100)

    @segment_events[segment] << {
      type: :ability,
      actor: participant,
      target: target,
      ability: ability,
      segment: segment
    }
  end

  # Find ability by legacy string choice (backward compatibility)
  def find_ability_by_choice(ability_choice)
    choice = ability_choice.to_s.strip
    return nil if choice.empty?

    # Get universe from room's location hierarchy: room -> location -> zone -> world -> universe
    universe = fight.room&.location&.zone&.world&.universe
    return nil unless universe

    candidates = [choice, choice.tr('_', ' ')].uniq
    candidates.each do |candidate|
      match = Ability.where(universe_id: [universe.id, nil]).where(Sequel.ilike(:name, candidate)).first
      return match if match
    end

    nil
  end

  # Schedule tactical ability activation (healing spells, buffs, etc.)
  def schedule_tactical_abilities(participant)
    return unless participant.tactical_ability_id

    ability = participant.tactical_ability
    return unless ability
    return unless ability_available_for_participant?(participant, ability, :tactical)

    target = if ability.target_type == 'self'
               participant
             else
               self.participant(participant.tactic_target_participant_id) || self.participant(participant.target_participant_id)
             end
    return unless target

    # Tactical abilities typically activate early in the round (before main actions)
    # Use ability's configured activation segment if available, otherwise early segment
    segment = ability.calculate_activation_segment rescue GameConfig::Mechanics::SEGMENTS[:tactical_fallback]
    segment = segment.clamp(1, GameConfig::Mechanics::SEGMENTS[:total])

    @segment_events[segment] << {
      type: :ability,
      actor: participant,
      target: target,
      ability: ability,
      segment: segment,
      is_tactical: true
    }
  end

  # Check whether an ability is usable for a participant.
  # If no availability list is present (legacy/test contexts), allow by fallback.
  def ability_available_for_participant?(participant, ability, slot)
    available = case slot
                when :tactical
                  participant.available_tactical_abilities
                else
                  participant.available_main_abilities
                end
    available_list = available.respond_to?(:to_a) ? available.to_a : Array(available)
    return true if available_list.empty?

    available_list.any? { |candidate| candidate&.id == ability.id }
  end

  # Schedule attack events based on weapon speed
  def schedule_attacks(participant)
    return unless participant.main_action == 'attack'

    # Check if targeting a monster
    if participant.targeting_monster_id
      schedule_player_attacks_on_monster(participant)
      return
    end

    target = participant(participant.target_participant_id)
    return unless target&.can_act?

    # Determine which weapon to use based on current distance
    distance = participant.hex_distance_to(target)
    melee_weapon = participant.melee_weapon
    ranged_weapon = participant.ranged_weapon

    # Choose appropriate weapon and auto-equip if needed
    if distance <= 1 && melee_weapon
      ensure_weapon_equipped(melee_weapon, ranged_weapon)
      schedule_weapon_attacks(participant, melee_weapon, :melee, target)
    elsif distance > 1 && ranged_weapon
      ensure_weapon_equipped(ranged_weapon, melee_weapon)
      schedule_weapon_attacks(participant, ranged_weapon, :ranged, target)
    elsif melee_weapon
      # Have melee weapon but out of range - will need to close
      ensure_weapon_equipped(melee_weapon, ranged_weapon)
      schedule_weapon_attacks(participant, melee_weapon, :melee, target)
    elsif ranged_weapon && distance > 1
      # Only have ranged and at range
      ensure_weapon_equipped(ranged_weapon, melee_weapon)
      schedule_weapon_attacks(participant, ranged_weapon, :ranged, target)
    elsif participant.using_natural_attacks?
      # NPC with natural attacks from archetype
      schedule_natural_attacks(participant, target, distance)
    else
      # Unarmed - treat as speed 5 melee
      schedule_unarmed_attacks(participant, target)
    end
  end

  # Schedule natural attacks from NPC archetype
  # Applies reach-based segment compression for melee natural attacks
  # @param participant [FightParticipant] the NPC attacker
  # @param target [FightParticipant] the target
  # @param distance [Integer] distance in hexes
  def schedule_natural_attacks(participant, target, distance)
    archetype = participant.npc_archetype
    return unless archetype&.has_natural_attacks?

    # Get the best attack for the current distance
    attack = archetype.best_attack_for_range(distance)
    return unless attack

    # Calculate attack segments using the attack's speed
    base_segments = participant.natural_attack_segments(attack)
    weapon_type = attack.melee? ? :natural_melee : :natural_ranged

    # Apply reach compression for melee natural attacks
    compressed_segments = if attack.melee?
                            segment_range = calculate_natural_reach_segment_range(participant, attack, target)
                            ReachSegmentService.compress_segments(base_segments, segment_range)
                          else
                            base_segments # Ranged attacks don't compress
                          end

    compressed_segments.each do |segment|
      @segment_events[segment] << {
        type: :attack,
        actor: participant,
        target: target,
        weapon: nil,
        natural_attack: attack,
        weapon_type: weapon_type,
        segment: segment
      }
    end
  end

  # Calculate segment range for natural attacks based on reach
  # @param participant [FightParticipant] the NPC attacker
  # @param attack [NpcAttack] the natural attack
  # @param target [FightParticipant] the defender
  # @return [Hash] { start: Integer, end: Integer }
  def calculate_natural_reach_segment_range(participant, attack, target)
    return { start: 1, end: 100 } unless target

    # Get initial adjacency from round state
    state = @round_state[participant.id]
    is_adjacent = state&.dig(:initial_adjacent) || false

    attacker_reach = ReachSegmentService.effective_reach(:natural_melee, nil, attack)
    defender_reach = ReachSegmentService.defender_reach(target)

    return { start: 1, end: 100 } unless attacker_reach && defender_reach

    ReachSegmentService.calculate_segment_range(
      attacker_reach: attacker_reach,
      defender_reach: defender_reach,
      is_adjacent: is_adjacent
    )
  end

  # Schedule attacks for a specific weapon
  # Applies reach-based segment compression for melee weapons
  def schedule_weapon_attacks(participant, weapon, weapon_type, target)
    base_segments = participant.attack_segments(weapon)

    # Apply reach compression for melee attacks
    compressed_segments = if weapon_type == :melee
                            segment_range = calculate_reach_segment_range(participant, weapon, weapon_type, target)
                            ReachSegmentService.compress_segments(base_segments, segment_range)
                          else
                            base_segments # Ranged attacks don't compress
                          end

    compressed_segments.each do |segment|
      @segment_events[segment] << {
        type: :attack,
        actor: participant,
        target: target,
        weapon: weapon,
        weapon_type: weapon_type,
        segment: segment
      }
    end
  end

  # Calculate segment range based on reach advantage
  # @param participant [FightParticipant] the attacker
  # @param weapon [Item] the weapon being used
  # @param weapon_type [Symbol] :melee, :ranged, etc.
  # @param target [FightParticipant] the defender
  # @return [Hash] { start: Integer, end: Integer }
  def calculate_reach_segment_range(participant, weapon, weapon_type, target)
    return { start: 1, end: 100 } unless target

    # Get initial adjacency from round state
    state = @round_state[participant.id]
    is_adjacent = state&.dig(:initial_adjacent) || false

    attacker_reach = ReachSegmentService.effective_reach(weapon_type, weapon, nil)
    defender_reach = ReachSegmentService.defender_reach(target)

    return { start: 1, end: 100 } unless attacker_reach && defender_reach

    ReachSegmentService.calculate_segment_range(
      attacker_reach: attacker_reach,
      defender_reach: defender_reach,
      is_adjacent: is_adjacent
    )
  end

  # Schedule unarmed attacks (default speed 5)
  # Applies reach-based segment compression
  def schedule_unarmed_attacks(participant, target)
    # Unarmed: speed 5, melee range only (from config)
    segments_config = GameConfig::Mechanics::SEGMENTS
    base_segments = GameConfig::Mechanics::UNARMED_SEGMENTS.map do |base|
      variance = (base * segments_config[:attack_randomization]).round
      (base + rand(-variance..variance)).clamp(1, segments_config[:total])
    end.sort

    # Apply reach compression for unarmed (melee) attacks
    segment_range = calculate_reach_segment_range(participant, nil, :unarmed, target)
    compressed_segments = ReachSegmentService.compress_segments(base_segments, segment_range)

    compressed_segments.each do |segment|
      @segment_events[segment] << {
        type: :attack,
        actor: participant,
        target: target,
        weapon: nil,
        weapon_type: :unarmed,
        segment: segment
      }
    end
  end

  # Schedule player attacks against a monster
  def schedule_player_attacks_on_monster(participant)
    monster = LargeMonsterInstance.where(
      id: participant.targeting_monster_id,
      fight_id: fight.id,
      status: 'active'
    ).first
    return unless monster && monster.status == 'active'

    melee_weapon = participant.melee_weapon
    ranged_weapon = participant.ranged_weapon

    # Calculate distance to monster center (hex steps, not Euclidean)
    distance = HexGrid.hex_distance(
      participant.hex_x, participant.hex_y,
      monster.center_hex_x, monster.center_hex_y
    )

    # Choose appropriate weapon based on distance and auto-equip
    if distance <= 2 && melee_weapon
      weapon = melee_weapon
      weapon_type = :melee
      ensure_weapon_equipped(melee_weapon, ranged_weapon)
    elsif distance > 2 && ranged_weapon
      weapon = ranged_weapon
      weapon_type = :ranged
      ensure_weapon_equipped(ranged_weapon, melee_weapon)
    elsif melee_weapon
      weapon = melee_weapon
      weapon_type = :melee
      ensure_weapon_equipped(melee_weapon, ranged_weapon)
    elsif ranged_weapon
      weapon = ranged_weapon
      weapon_type = :ranged
      ensure_weapon_equipped(ranged_weapon, melee_weapon)
    else
      weapon = nil
      weapon_type = :unarmed
    end

    # Get attack segments
    if weapon
      segments = participant.attack_segments(weapon)
    else
      # Unarmed: speed 5 (from config)
      segments_config = GameConfig::Mechanics::SEGMENTS
      segments = GameConfig::Mechanics::UNARMED_SEGMENTS.map do |base|
        variance = (base * segments_config[:attack_randomization]).round
        (base + rand(-variance..variance)).clamp(1, segments_config[:total])
      end.sort
    end

    segments.each do |segment|
      @segment_events[segment] << {
        type: :attack,
        actor: participant,
        target: nil, # No participant target
        weapon: weapon,
        weapon_type: weapon_type,
        segment: segment,
        targeting_monster: true
      }
    end
  end

  # Schedule movement events distributed across the round (one per hex moved)
  # Movement is now spread evenly like attacks, allowing fluid melee/ranged transitions
  def schedule_movement(participant)
    # stand_still is handled in schedule_all_events (sets movement_completed_segment: 0)
    if participant.movement_action == 'stand_still'
      @logger.log_movement_planning(participant, 'stand_still', 0, [], 'none')
      return
    end

    # Calculate the full path at scheduling time
    path = calculate_movement_path(participant)
    if path.empty?
      # If already engaged in melee and using "towards_person", keep movement segments available
      # so the actor can immediately follow if the target retreats later in the round.
      shadow = build_towards_person_shadow_steps(participant)
      if !shadow.empty?
        @logger.log_movement_fallback(participant, participant.movement_action, 'shadow_steps', 'primary path empty, melee follow-up')
        path = shadow
      else
        @logger.log_movement_planning(participant, participant.movement_action, movement_budget_for(participant), [], 'empty_path')
        return
      end
    end
    return if path.empty?

    # Get segments distributed evenly based on movement budget.
    # Keep participant.movement_segments as the base source for compatibility with existing tests.
    movement_budget = movement_budget_for(participant)
    segments = participant.movement_segments
    if movement_budget > segments.length
      expanded = movement_segments_for_budget(movement_budget)
      segments += expanded.drop(segments.length)
      segments = segments.sort
    end
    segments = segments.first(path.length)

    if segments.empty?
      @logger.log_movement_planning(participant, participant.movement_action, movement_budget, path, 'no_segments')
      return
    end

    @logger.log_movement_planning(participant, participant.movement_action, movement_budget, path, 'scheduled')

    # Schedule one movement step event per hex in the path
    path.each_with_index do |step, i|
      segment = segments[i] || segments.last
      @segment_events[segment] << {
        type: :movement_step,
        actor: participant,
        target_hex: step,
        step_index: i,
        total_steps: path.length,
        segment: segment
      }
    end
  end

  # Calculate the movement path based on movement action type
  # @param participant [FightParticipant]
  # @return [Array<Array<Integer>>] Array of [x, y] positions
  def calculate_movement_path(participant)
    case participant.movement_action
    when 'towards_person'
      calculate_towards_path(participant)
    when 'away_from'
      calculate_away_path(participant)
    when 'maintain_distance'
      calculate_maintain_distance_path(participant)
    when 'move_to_hex'
      calculate_hex_target_path(participant)
    else
      []
    end
  end

  # Total movement budget for this round (base movement + willpower movement bonus).
  def movement_budget_for(participant)
    base = participant.movement_speed
    bonus = @round_state.dig(participant.id, :willpower_movement_bonus) || 0
    base + bonus
  end

  # Build evenly distributed movement segments for an arbitrary movement budget.
  # Mirrors FightParticipant#movement_segments, but allows dynamic budget adjustments.
  def movement_segments_for_budget(hexes)
    return [] if hexes <= 0

    segments_config = GameConfig::Mechanics::SEGMENTS
    interval = segments_config[:total].to_f / hexes

    segments = []
    hexes.times do |i|
      base_segment = ((i + 1) * interval).round
      variance = (base_segment * segments_config[:movement_randomization]).round
      randomized = base_segment + rand(-variance..variance)
      segments << randomized.clamp(1, segments_config[:total])
    end
    segments.sort
  end

  # Calculate path towards a target participant
  def calculate_towards_path(participant)
    target = participant(participant.movement_target_participant_id)
    return [] unless target
    movement_budget = movement_budget_for(participant)
    return [] if movement_budget <= 0

    # Already in melee at schedule time: don't pre-plan lateral movement.
    # process_movement_step will dynamically chase later this round if the target retreats.
    distance = participant.hex_distance_to(target)
    if distance && distance <= 1
      @logger.log_movement_skipped(participant, "towards_person_already_adjacent(dist=#{distance})", step_index: 0)
      return []
    end

    if battle_map_service.battle_map_active?
      path = best_adjacent_path_to_target(participant, target, movement_budget)
      return path if path.any?

      path = CombatPathfindingService.next_steps(
        fight: fight,
        participant: participant,
        target_x: target.hex_x,
        target_y: target.hex_y,
        movement_budget: movement_budget
      )
      if path.empty?
        reason = CombatPathfindingService.last_failure_reason || 'unknown'
        @logger.log_pathfinding_failure(participant, participant.hex_x, participant.hex_y, target.hex_x, target.hex_y, "towards_person: #{reason}")
      end
      path
    else
      # Fallback: simple path calculation without battle map
      calculate_simple_towards_path(participant, target.hex_x, target.hex_y, movement_budget)
    end
  end

  # Calculate path away from a target participant
  def calculate_away_path(participant)
    target = participant(participant.movement_target_participant_id)
    return [] unless target
    movement_budget = movement_budget_for(participant)

    dx = participant.hex_x - target.hex_x
    dy = participant.hex_y - target.hex_y
    distance = Math.sqrt(dx * dx + dy * dy)
    return [] if distance == 0

    # Target a point 2x movement distance away from the threat
    flee_distance = movement_budget * 2
    flee_x = (participant.hex_x + (dx / distance * flee_distance)).round
    flee_y = (participant.hex_y + (dy / distance * flee_distance)).round

    # Clamp to valid arena hex bounds
    flee_x, flee_y = clamp_to_arena_hex(flee_x, flee_y)

    if battle_map_service.battle_map_active?
      CombatPathfindingService.next_steps(
        fight: fight,
        participant: participant,
        target_x: flee_x,
        target_y: flee_y,
        movement_budget: movement_budget
      )
    else
      calculate_simple_away_path(participant, target, movement_budget)
    end
  end

  # Calculate path to maintain distance from target
  def calculate_maintain_distance_path(participant)
    target = participant(participant.movement_target_participant_id)
    return [] unless target

    current_dist = participant.hex_distance_to(target)
    desired_dist = participant.maintain_distance_range

    if current_dist < desired_dist
      calculate_away_path(participant)
    elsif current_dist > desired_dist + 1
      calculate_towards_path(participant)
    else
      [] # Within range, no movement needed
    end
  end

  # Calculate path to a specific hex
  def calculate_hex_target_path(participant)
    # Snap to valid hex coordinates (safety net)
    raw_x = participant.target_hex_x || 0
    raw_y = participant.target_hex_y || 0
    target_x, target_y = HexGrid.to_hex_coords(raw_x, raw_y)

    if target_x != raw_x || target_y != raw_y
      @logger.log_movement_fallback(participant, "raw_target(#{raw_x},#{raw_y})", "snapped(#{target_x},#{target_y})", 'hex coord snapping')
    end

    movement_budget = movement_budget_for(participant)
    return [] if movement_budget <= 0

    if battle_map_service.battle_map_active?
      path = CombatPathfindingService.next_steps(
        fight: fight,
        participant: participant,
        target_x: target_x,
        target_y: target_y,
        movement_budget: movement_budget
      )
      if path.any?
        @logger.log_pathfinding_detail(participant, path.length, path.length, movement_budget)
        return path
      end

      reason = CombatPathfindingService.last_failure_reason || 'unknown'
      @logger.log_pathfinding_failure(participant, participant.hex_x, participant.hex_y, target_x, target_y, "move_to_hex: #{reason}")
      @logger.log_movement_fallback(participant, 'A*_next_steps', 'nearest_reachable', reason)
      nearest_reachable_steps(participant, target_x, target_y, movement_budget)
    else
      calculate_simple_towards_path(participant, target_x, target_y, movement_budget)
    end
  end

  # Simple path calculation without battle map (fallback)
  # Uses hex neighbors to ensure valid hex coordinates
  def calculate_simple_towards_path(participant, target_x, target_y, movement_budget = nil)
    steps = []
    current_x = participant.hex_x
    current_y = participant.hex_y
    remaining = movement_budget || participant.movement_speed
    arena_w = fight.arena_width || 10
    arena_h = fight.arena_height || 10
    max_x = [arena_w - 1, 0].max
    max_y = [(arena_h - 1) * 4 + 2, 0].max

    while remaining > 0
      break if current_x == target_x && current_y == target_y

      current_distance = HexGrid.hex_distance(current_x, current_y, target_x, target_y)
      # Stop if adjacent to target (within melee range)
      break if current_distance <= 1

      # Find the neighbor hex closest to the target, within arena bounds
      neighbors = HexGrid.hex_neighbors(current_x, current_y)
      neighbors.select! { |nx, ny| nx >= 0 && ny >= 0 && nx <= max_x && ny <= max_y }
      break if neighbors.empty?

      best = neighbors.min_by { |nx, ny| HexGrid.hex_distance(nx, ny, target_x, target_y) }
      break unless best

      # Don't move if it would increase distance (prevents oscillation)
      best_distance = HexGrid.hex_distance(best[0], best[1], target_x, target_y)
      break if best_distance >= current_distance

      current_x, current_y = best
      steps << [current_x, current_y]
      remaining -= 1
    end

    steps
  end

  # Simple path away from target without battle map (fallback)
  # Uses hex neighbors to ensure valid hex coordinates
  def calculate_simple_away_path(participant, target, movement_budget = nil)
    steps = []
    current_x = participant.hex_x
    current_y = participant.hex_y
    remaining = movement_budget || participant.movement_speed
    arena_w = fight.arena_width || 10
    arena_h = fight.arena_height || 10
    max_x = [arena_w - 1, 0].max
    max_y = [(arena_h - 1) * 4 + 2, 0].max

    while remaining > 0
      # Find the neighbor hex that maximizes distance from target
      neighbors = HexGrid.hex_neighbors(current_x, current_y)
      # Filter to valid arena bounds
      neighbors.select! { |nx, ny| nx >= 0 && ny >= 0 && nx <= max_x && ny <= max_y }
      break if neighbors.empty?

      best = neighbors.max_by { |nx, ny| HexGrid.hex_distance(nx, ny, target.hex_x, target.hex_y) }
      current_dist = HexGrid.hex_distance(current_x, current_y, target.hex_x, target.hex_y)
      break if HexGrid.hex_distance(best[0], best[1], target.hex_x, target.hex_y) <= current_dist # Can't get further

      current_x, current_y = best
      steps << [current_x, current_y]
      remaining -= 1
    end

    steps
  end

  # Process all segments in order
  # Movement events are processed before attacks within each segment so that
  # position updates happen before range checks
  def process_segments
    (1..GameConfig::Mechanics::SEGMENTS[:total]).each do |segment|
      sorted = @segment_events[segment].sort_by { |event| segment_event_sort_key(event) }
      sorted.each do |event|
        case event[:type]
        when :attack
          process_attack(event, segment)
        when :ability
          process_ability(event, segment)
        when :movement_step
          process_movement_step(event, segment)
        when :monster_attack
          process_monster_attack(event, segment)
        when :monster_turn
          process_monster_turn_event(event, segment)
        when :monster_move
          process_monster_move_event(event, segment)
        when :monster_shake_off
          process_monster_shake_off(event, segment)
        when :dot_tick
          process_dot_tick_event(event, segment)
        when :process_healing_ticks
          process_healing_ticks(segment)
        # :process_ticks removed — superseded by distributed DOT/healing tick events
        end
      end
    end
  end

  # Process a single movement step (one hex at a time)
  # This allows attacks to check position dynamically as movement occurs
  def process_movement_step(event, segment)
    actor = event[:actor]
    if knocked_out?(actor.id)
      @logger.log_movement_skipped(actor, 'knocked_out', step_index: event[:step_index], segment: segment)
      return
    end

    # Refresh actor to get latest state (position, movement_completed_segment)
    actor.refresh

    # Skip if movement already marked complete this round
    # This happens when we've reached our goal early (e.g., became adjacent to target)
    if actor.movement_completed_segment && actor.movement_completed_segment > 0
      @logger.log_movement_skipped(actor, "movement_already_complete(seg=#{actor.movement_completed_segment})", step_index: event[:step_index], segment: segment)
      return
    end

    # Check if snared (can't move)
    unless actor.can_move?
      @logger.log_movement_skipped(actor, 'snared', step_index: event[:step_index], segment: segment)
      # Only emit blocked message on first step
      if event[:step_index] == 0
        @events << create_event(segment, actor, nil, 'movement_blocked',
                                reason: 'snared',
                                status_effect: 'snared')
      end
      # Mark movement complete even when blocked (for protection timing)
      if event[:step_index] == event[:total_steps] - 1
        actor.update(movement_completed_segment: segment)
      end
      return
    end

    movement_target = nil
    if %w[towards_person away_from].include?(actor.movement_action)
      movement_target = participant(actor.movement_target_participant_id)
      unless movement_target
        @logger.log_movement_skipped(actor, 'movement_target_not_found', step_index: event[:step_index], segment: segment)
        actor.update(movement_completed_segment: segment) if event[:step_index] == event[:total_steps] - 1
        return
      end
    end

    if actor.movement_action == 'towards_person'
      current_distance = actor.hex_distance_to(movement_target)
      if current_distance && current_distance <= 1
        @logger.log_movement_skipped(actor, "already_adjacent(dist=#{current_distance})", step_index: event[:step_index], segment: segment)
        unless target_has_future_movement_steps?(movement_target.id, segment)
          actor.update(movement_completed_segment: segment)
        end
        return
      end
    end

    target_hex = case actor.movement_action
                 when 'towards_person'
                   dynamic_towards_step(actor, movement_target)
                 when 'away_from'
                   dynamic_away_step(actor, movement_target)
                 else
                   event[:target_hex]
                 end

    unless target_hex
      @logger.log_movement_skipped(actor, 'no_target_hex_resolved', step_index: event[:step_index], segment: segment)
      actor.update(movement_completed_segment: segment)
      return
    end

    new_x, new_y = target_hex

    # Capture old position for animation
    old_x = actor.hex_x
    old_y = actor.hex_y

    # Log the movement step
    @logger.log_movement_step(actor, event[:step_index], event[:total_steps], old_x, old_y, new_x, new_y)

    # Update position to this hex
    actor.update(
      hex_x: new_x,
      hex_y: new_y,
      moved_this_round: true
    )

    # Sync elevation and swimming state with battle map
    battle_map_service.sync_participant_elevation(actor)
    battle_map_service.update_swimming_state(actor)
    actor.sync_position_to_character!

    # Determine movement direction for event
    direction = case actor.movement_action
                when 'towards_person' then 'towards'
                when 'away_from' then 'away'
                when 'maintain_distance' then 'maintain'
                when 'move_to_hex' then 'hex'
                else 'move'
                end

    # Get target name if applicable
    target_name = participant(actor.movement_target_participant_id)&.character_name

    # Look up hex terrain data for narrative enrichment
    dest_hex = fight.room&.hex_details(new_x, new_y)
    origin_hex = fight.room&.hex_details(old_x, old_y)

    # Create movement step event (includes old position for client animation)
    @events << create_event(segment, actor, nil, 'movement_step',
                            direction: direction,
                            target_name: target_name,
                            old_x: old_x,
                            old_y: old_y,
                            new_x: new_x,
                            new_y: new_y,
                            step: event[:step_index] + 1,
                            total_steps: event[:total_steps],
                            hex_type: dest_hex&.hex_type,
                            cover_object: dest_hex&.cover_object,
                            has_cover: dest_hex&.has_cover,
                            elevation_level: dest_hex&.elevation_level.to_i,
                            old_elevation_level: origin_hex&.elevation_level.to_i,
                            difficult_terrain: dest_hex&.difficult_terrain,
                            water_type: dest_hex&.water_type,
                            surface_type: dest_hex&.surface_type,
                            is_stairs: dest_hex&.is_stairs,
                            is_ladder: dest_hex&.is_ladder,
                            is_ramp: dest_hex&.is_ramp)

    # For 'towards_person' movement, check if we've now reached adjacency
    # Mark complete early to skip remaining steps (prevents overshooting)
    if actor.movement_action == 'towards_person' && movement_target
      current_distance = actor.hex_distance_to(movement_target)
      if current_distance && current_distance <= 1
        unless target_has_future_movement_steps?(movement_target.id, segment)
          actor.update(movement_completed_segment: segment)
          return
        end
      end
    end

    # Mark movement complete on final step (for guard/back-to-back protection timing)
    if event[:step_index] == event[:total_steps] - 1
      actor.update(movement_completed_segment: segment)
    end
  end

  # Build placeholder movement steps so a melee-engaged pursuer can chase if the target retreats.
  def build_towards_person_shadow_steps(participant)
    return [] unless participant.movement_action == 'towards_person'

    movement_target = self.participant(participant.movement_target_participant_id)
    return [] unless movement_target

    distance = participant.hex_distance_to(movement_target)
    return [] unless distance && distance <= 1

    budget = movement_budget_for(participant)
    return [] if budget <= 0

    Array.new(budget, nil)
  end

  # Best path to any hex adjacent to the target participant.
  # Avoids no-op pathing toward an occupied target hex.
  def best_adjacent_path_to_target(participant, target, movement_budget)
    return [] unless target
    return [] if movement_budget <= 0
    return [] unless participant.hex_x && participant.hex_y
    return [] unless target.hex_x && target.hex_y

    candidates = HexGrid.hex_neighbors(target.hex_x, target.hex_y)
    candidates.select! { |x, y| within_arena_bounds?(x, y) }
    candidates.sort_by! do |x, y|
      HexGrid.hex_distance(participant.hex_x, participant.hex_y, x, y)
    end

    last_reason = nil
    candidates.each do |x, y|
      path = CombatPathfindingService.next_steps(
        fight: fight,
        participant: participant,
        target_x: x,
        target_y: y,
        movement_budget: movement_budget
      )
      return path if path.any?

      last_reason = CombatPathfindingService.last_failure_reason
    end

    # Store the last failure reason so callers can diagnose
    CombatPathfindingService.instance_variable_set(:@last_failure_reason,
      last_reason || "all_#{candidates.size}_adjacent_hexes_unreachable")

    []
  end

  # If direct path to a clicked hex is blocked/unreachable, move toward the nearest reachable
  # hex around the requested destination instead of silently doing nothing.
  def nearest_reachable_steps(participant, target_x, target_y, movement_budget)
    return [] unless participant.hex_x && participant.hex_y
    return [] if movement_budget <= 0

    max_x, max_y = arena_hex_bounds
    search_radius = [movement_budget + 4, 10].min
    candidates = []

    y = 0
    while y <= max_y
      x = (y / 2).even? ? 0 : 1
      while x <= max_x
        if HexGrid.valid_hex_coords?(x, y)
          distance_to_target = HexGrid.hex_distance(x, y, target_x, target_y)
          if distance_to_target.positive? && distance_to_target <= search_radius
            distance_from_actor = HexGrid.hex_distance(participant.hex_x, participant.hex_y, x, y)
            candidates << [x, y, distance_to_target, distance_from_actor]
          end
        end
        x += 2
      end
      y += 2
    end

    candidates.sort_by! { |_x, _y, dist_target, dist_actor| [dist_target, dist_actor] }
    candidates.each do |x, y, *_rest|
      path = CombatPathfindingService.next_steps(
        fight: fight,
        participant: participant,
        target_x: x,
        target_y: y,
        movement_budget: movement_budget
      )
      return path if path.any?
    end

    greedy_reachable_step_toward_target(participant, target_x, target_y)
  end

  def greedy_reachable_step_toward_target(participant, target_x, target_y)
    neighbors = HexGrid.hex_neighbors(participant.hex_x, participant.hex_y)
    neighbors.select! { |x, y| within_arena_bounds?(x, y) }
    neighbors.sort_by! { |x, y| HexGrid.hex_distance(x, y, target_x, target_y) }

    neighbors.each do |x, y|
      path = CombatPathfindingService.next_steps(
        fight: fight,
        participant: participant,
        target_x: x,
        target_y: y,
        movement_budget: 1
      )
      return path if path.any?
    end

    []
  end

  def dynamic_towards_step(actor, movement_target)
    return nil unless movement_target

    if battle_map_service.battle_map_active?
      # Use full movement budget so a single costly step (difficult terrain,
      # elevation change) doesn't consume the entire 1-step allocation.
      budget = actor.movement_speed.to_i.clamp(1, 6)
      path = best_adjacent_path_to_target(actor, movement_target, budget)
      return path.first if path.any?

      direct = CombatPathfindingService.next_steps(
        fight: fight,
        participant: actor,
        target_x: movement_target.hex_x,
        target_y: movement_target.hex_y,
        movement_budget: budget
      )
      return direct.first if direct.any?

      reason = CombatPathfindingService.last_failure_reason || 'budget_exceeded_first_step'
      @logger.log_dynamic_step_failure(actor, 'towards_person', actor.hex_x, actor.hex_y, movement_target.character_name, reason)
      nil
    else
      calculate_simple_towards_path(actor, movement_target.hex_x, movement_target.hex_y, 1).first
    end
  end

  # Recalculate a single "away from target" step from the actor's current position.
  # Chooses the reachable adjacent hex that maximizes distance from the current target position.
  def dynamic_away_step(actor, movement_target)
    return nil unless movement_target
    return nil unless actor.hex_x && actor.hex_y
    return nil unless movement_target.hex_x && movement_target.hex_y

    if battle_map_service.battle_map_active?
      current_distance = HexGrid.hex_distance(actor.hex_x, actor.hex_y, movement_target.hex_x, movement_target.hex_y)
      best_step = nil
      best_distance = current_distance

      HexGrid.hex_neighbors(actor.hex_x, actor.hex_y).each do |nx, ny|
        next unless within_arena_bounds?(nx, ny)

        path = CombatPathfindingService.next_steps(
          fight: fight,
          participant: actor,
          target_x: nx,
          target_y: ny,
          movement_budget: 1
        )
        next if path.empty?

        step = path.first
        distance = HexGrid.hex_distance(step[0], step[1], movement_target.hex_x, movement_target.hex_y)
        next unless distance > best_distance

        best_distance = distance
        best_step = step
      end

      return best_step if best_step
      nil
    else
      calculate_simple_away_path(actor, movement_target, 1).first
    end
  end

  def target_has_future_movement_steps?(target_id, segment)
    return false unless target_id

    # Include the current segment — the target's movement step may be
    # in the same segment but processed after this actor's step.
    (segment..GameConfig::Mechanics::SEGMENTS[:total]).any? do |s|
      @segment_events[s]&.any? do |e|
        e[:type] == :movement_step && e[:actor]&.id == target_id
      end
    end
  end

  def segment_event_sort_key(event)
    return [1, 0] unless event[:type] == :movement_step

    action = event[:actor]&.movement_action
    movement_priority = case action
                        when 'away_from', 'maintain_distance', 'move_to_hex'
                          0
                        when 'towards_person'
                          1
                        else
                          0
                        end
    [0, movement_priority]
  end

  def arena_hex_bounds
    arena_w = fight.arena_width || 10
    arena_h = fight.arena_height || 10
    [[arena_w - 1, 0].max, [(arena_h - 1) * 4 + 2, 0].max]
  end

  def within_arena_bounds?(x, y)
    max_x, max_y = arena_hex_bounds
    x >= 0 && x <= max_x && y >= 0 && y <= max_y && HexGrid.valid_hex_coords?(x, y)
  end

  # Process a single distributed DOT tick event.
  # DOTs bypass Armored (damage_reduction) and Protected, but can be absorbed by Shields.
  # Applies damage, updates cumulative tracking, and checks for knockout.
  def process_dot_tick_event(event, segment)
    pse = ParticipantStatusEffect[event[:participant_status_effect_id]]
    return unless pse

    participant = event[:participant]
    return if knocked_out?(participant.id)

    StatusEffectService.process_dot_tick(pse, segment) do |tick_event|
      dot_damage = tick_event[:damage]
      damage_type = tick_event[:damage_type] || 'physical'

      # DOTs BYPASS Armored (damage_reduction) - no flat_damage_reduction applied

      # Track damage before shield absorption for absorbed total calculation
      damage_before_shield = dot_damage

      # DOTs CAN be absorbed by Shields
      dot_damage = StatusEffectService.absorb_damage_with_shields(participant, dot_damage, damage_type)

      # Create the tick event for logging
      @events << create_event(
        segment,
        nil,
        tick_event[:participant],
        'damage_tick',
        damage: dot_damage,
        damage_before_shield: damage_before_shield,
        shield_absorbed: damage_before_shield - dot_damage,
        tick_number: tick_event[:tick_number],
        total_ticks: tick_event[:total_ticks],
        effect: tick_event[:effect],
        damage_type: damage_type
      )

      # Apply incremental damage tracking
      # DOTs bypass Armor and Protection - only add to dot_cumulative
      state = @round_state[participant.id]
      if state
        # Track shield absorption for display
        shield_absorbed = damage_before_shield - dot_damage
        state[:shield_absorbed_total] += shield_absorbed if shield_absorbed > 0

        # DOTs bypass Armor and Protection - add to dot_cumulative only
        state[:dot_cumulative] += dot_damage
        state[:cumulative_damage] += dot_damage

        # Calculate effective cumulative (DOTs bypass defenses, handled in calculate_effective_cumulative)
        effective_result = calculate_effective_cumulative(participant, state, damage_type)
        effective_cumulative = effective_result[:effective]

        # Check if cumulative damage crosses a new threshold
        new_hp_lost = participant.hp_lost_from_cumulative(effective_cumulative)
        previously_lost = state[:hp_lost_this_round]

        if new_hp_lost > previously_lost
          # Apply the additional HP loss to DB
          additional_loss = participant.apply_incremental_hp_loss!(new_hp_lost, previously_lost)

          # Update in-memory state
          state[:hp_lost_this_round] = new_hp_lost
          state[:current_hp] = participant.current_hp

          @events << create_event(segment, nil, participant, 'damage_applied',
                                  damage_this_attack: dot_damage,
                                  cumulative_damage: state[:cumulative_damage],
                                  effective_cumulative: effective_cumulative,
                                  armor_reduced: effective_result[:armor_reduced],
                                  protection_reduced: effective_result[:protection_reduced],
                                  hp_lost_now: additional_loss,
                                  hp_lost_total: new_hp_lost,
                                  remaining_hp: participant.current_hp,
                                  new_wound_penalty: participant.wound_penalty,
                                  source: 'dot_tick')

          # Check for knockout
          if participant.current_hp <= 0
            mark_knocked_out!(participant.id)

            @events << create_event(segment, nil, participant, 'knockout',
                                    final_hp: participant.current_hp,
                                    knockout_segment: segment,
                                    total_damage_taken: state[:cumulative_damage],
                                    source: 'dot_tick')

            if participant.character_instance
              PrisonerService.process_knockout!(participant.character_instance)
            end
          end
        end
      end
    end
  end

  # Process healing ticks from status effects (called at MOVEMENT_SEGMENT)
  def process_healing_ticks(segment)
    StatusEffectService.process_healing_ticks(@fight, @fight.round_number) do |event|
      @events << create_event(segment, nil, event[:participant], 'healing_tick',
                              amount: event[:amount],
                              effect: event[:effect])
    end
  end

  # Process a monster segment attack event
  def process_monster_attack(event, segment)
    return unless @monster_combat_service

    result = @monster_combat_service.process_monster_attack(event, segment)
    return unless result

    @events << create_event(
      segment,
      nil,
      FightParticipant[event[:target_id]],
      result[:type],
      monster_name: result[:monster_name],
      segment_name: result[:segment_name],
      damage: result[:damage],
      reason: result[:reason]
    )
  end

  # Process a monster turn event
  def process_monster_turn_event(event, segment)
    return unless @monster_combat_service

    result = @monster_combat_service.process_monster_turn(event)
    return unless result

    @events << create_event(
      segment,
      nil,
      nil,
      'monster_turn',
      monster_name: result[:monster_name],
      old_direction: result[:old_direction],
      new_direction: result[:new_direction]
    )
  end

  # Process a monster move event
  def process_monster_move_event(event, segment)
    return unless @monster_combat_service

    result = @monster_combat_service.process_monster_move(event)
    return unless result

    @events << create_event(
      segment,
      nil,
      nil,
      'monster_move',
      monster_name: result[:monster_name],
      from_x: result[:from_x],
      from_y: result[:from_y],
      to_x: result[:to_x],
      to_y: result[:to_y]
    )
  end

  # Process a monster shake-off event
  def process_monster_shake_off(event, segment)
    return unless @monster_combat_service

    result = @monster_combat_service.process_shake_off(event)
    return unless result

    # Log the shake-off itself
    @events << create_event(
      segment,
      nil,
      nil,
      'monster_shake_off',
      monster_name: result[:monster_name],
      thrown_count: result[:thrown_count]
    )

    # Log each thrown player
    result[:results].each do |thrown|
      next unless thrown[:thrown]

      @events << create_event(
        segment,
        nil,
        nil,
        'player_thrown_off',
        participant_name: thrown[:participant_name],
        landing_x: thrown[:landing_x],
        landing_y: thrown[:landing_y],
        landed_in_hazard: thrown[:landed_in_hazard],
        hazard_type: thrown[:hazard_type]
      )
    end
  end

  # Process a player attack on a monster
  def process_attack_on_monster(actor, segment, weapon, weapon_type)
    monster = LargeMonsterInstance.where(
      id: actor.targeting_monster_id,
      fight_id: fight.id,
      status: 'active'
    ).first
    return unless monster && monster.status == 'active'

    # Use pre-rolled dice if available
    pre_roll = @combat_pre_rolls&.dig(actor.id) || build_pre_roll_for_actor(actor)
    stat_modifier = nil
    if pre_roll
      n = pre_roll[:attack_count]
      round_stat_modifier = pre_roll[:total_stat_modifier] || pre_roll[:stat_modifier] || 0
      # Round total includes all flat modifiers, divided evenly across attacks
      round_total = pre_roll[:roll_total] + round_stat_modifier -
                    actor.wound_penalty + pre_roll[:all_roll_penalty] +
                    actor.tactic_outgoing_damage_modifier +
                    actor.outgoing_damage_modifier
      damage = (round_total.to_f / n).round
      attack_roll = pre_roll[:base_roll]
      stat_modifier = pre_roll[:stat_per_attack] || (round_stat_modifier.to_f / n)
    else
      stat_modifier = get_attack_stat(actor, weapon_type)
      attack_roll = if actor.npc_with_custom_dice?
                      DiceRollService.roll(actor.npc_damage_dice_count, actor.npc_damage_dice_sides,
                                           explode_on: nil, modifier: 0)
                    else
                      DiceRollService.roll(2, 8, explode_on: 8, modifier: 0)
                    end
      damage = attack_roll.total + stat_modifier - actor.wound_penalty +
               actor.tactic_outgoing_damage_modifier +
               actor.outgoing_damage_modifier

      @roll_results << { participant: actor, roll_result: attack_roll, purpose: 'attack', target: nil }
    end

    actor_observer_effects = observer_effects_for_combatant(actor)
    if actor_observer_effects[:expose_targets]
      damage += OBSERVER_EXPOSE_TARGETS_BONUS
    end
    if actor_observer_effects[:damage_dealt_mult]
      damage = (damage * actor_observer_effects[:damage_dealt_mult].to_f).round
    end

    damage = [damage, 0].max

    # Process attack through monster combat service
    result = @monster_combat_service.process_attack_on_monster(actor, monster, damage)

    if result[:success]
      # Log the attack result
      @events << create_event(
        segment,
        actor,
        nil,
        result[:events]&.any? { |e| e[:type] == 'weak_point_attack' } ? 'monster_weak_point_attack' : 'monster_segment_attack',
        monster_name: monster.display_name,
        segment_name: result[:segment_name],
        damage: result[:segment_damage],
        roll: attack_roll.total,
        roll_dice: attack_roll.dice,
        stat_mod: stat_modifier,
        stat_mod_round_total: pre_roll ? (pre_roll[:total_stat_modifier] || pre_roll[:stat_modifier]) : stat_modifier,
        monster_hp_percent: result[:monster_hp_percent]
      )

      # Log any additional events (segment destroyed, monster collapsed, etc.)
      result[:events]&.each do |event|
        @events << create_event(
          segment,
          actor,
          nil,
          event[:type],
          **event.except(:type)
        )
      end
    else
      @events << create_event(
        segment,
        actor,
        nil,
        'monster_attack_failed',
        reason: result[:reason]
      )
    end
  end

  # Process ability activation using AbilityProcessorService
  def process_ability(event, segment)
    actor = event[:actor]
    target = event[:target]
    ability = event[:ability]

    return if knocked_out?(actor.id)

    # Handle legacy string ability choices
    if ability.is_a?(String)
      ability = find_ability_by_choice(ability)
      return unless ability
    end

    # Roll effectiveness: PCs use 2d8 + willpower (same as attacks), NPCs use custom dice
    roll_data = roll_ability_effectiveness(actor, ability)

    # Track roll for display (uses original RollResult for animation)
    track_ability_roll(actor, ability, target, roll_data[:roll_result])

    @logger.log_ability(segment, actor, target, ability.respond_to?(:name) ? ability.name : ability.to_s,
                        roll_data[:total])

    # Use AbilityProcessorService for data-driven ability execution
    # Pass the modified total with willpower and penalties applied
    processor = AbilityProcessorService.new(
      actor: actor,
      ability: ability,
      primary_target: target,
      base_roll: roll_data
    )

    ability_events = processor.process!(segment)

    # Process ability events - use incremental damage system
    ability_events.each do |ae|
      @events << ae

      # Execute mechanics can knockout immediately via AbilityProcessorService.
      # Keep in-memory round state in sync so the target can't act later this round.
      if ae[:event_type] == 'ability_execute' && ae[:details][:instant_kill]
        target_id = ae[:details][:target_id]
        ability_target = participant(target_id) if target_id

        if ability_target
          mark_knocked_out!(ability_target.id)
          state = @round_state[ability_target.id]
          state[:current_hp] = ability_target.current_hp if state
        end
      end

      # For ability hits, apply incremental damage on the target
      if ae[:event_type] == 'ability_hit'
        target_id = ae[:details][:target_id]
        damage = ae[:details][:effective_damage] || 0

        if target_id && damage > 0
          ability_target = participant(target_id)
          next unless ability_target

          # Skip if target already knocked out
          next if knocked_out?(ability_target.id)

          # Use incremental damage system - track ability damage separately
          # Abilities bypass armor/protection (handled in processor) but go through willpower defense
          state = @round_state[ability_target.id]
          next unless state

          state[:ability_cumulative] += damage
          state[:cumulative_damage] += damage

          # Route through calculate_effective_cumulative for willpower defense
          damage_type = ae[:details][:damage_type] || 'physical'
          effective_result = calculate_effective_cumulative(ability_target, state, damage_type)
          effective_cumulative = effective_result[:effective]

          new_hp_lost = ability_target.hp_lost_from_cumulative(effective_cumulative)
          previously_lost = state[:hp_lost_this_round]

          if new_hp_lost > previously_lost
            additional_loss = ability_target.apply_incremental_hp_loss!(new_hp_lost, previously_lost)
            state[:hp_lost_this_round] = new_hp_lost
            state[:current_hp] = ability_target.current_hp

            @events << create_event(segment, actor, ability_target, 'damage_applied',
                                    damage_this_attack: damage,
                                    cumulative_damage: state[:cumulative_damage],
                                    hp_lost_now: additional_loss,
                                    hp_lost_total: new_hp_lost,
                                    remaining_hp: ability_target.current_hp,
                                    new_wound_penalty: ability_target.wound_penalty,
                                    source: 'ability')

            if ability_target.current_hp <= 0
              mark_knocked_out!(ability_target.id)

              @events << create_event(segment, actor, ability_target, 'knockout',
                                      final_hp: ability_target.current_hp,
                                      knockout_segment: segment,
                                      total_damage_taken: state[:cumulative_damage])

              if ability_target.character_instance
                PrisonerService.process_knockout!(ability_target.character_instance)
              end
            end
          end
        end
      end
    end
  end

  # Roll ability effectiveness - same roll as attacks for PCs
  # PCs roll 2d8 exploding + willpower bonus (same formula as attacks)
  # @param actor [FightParticipant] who is using the ability
  # @param ability [Ability] the ability being used
  # @return [Hash] containing :roll_result (for animation), :total (final modified total), and other components
  def roll_ability_effectiveness(actor, ability)
    if actor.npc_with_custom_dice?
      # NPCs can use ability-specific dice or their custom NPC dice
      if ability.base_damage_dice
        parsed = DiceNotationService.parse(ability.base_damage_dice)
        if parsed[:valid] && parsed[:count].to_i > 0
          roll_result = DiceRollService.roll(
            parsed[:count].to_i,
            parsed[:sides].to_i,
            explode_on: nil,
            modifier: parsed[:modifier].to_i
          )
          all_roll_penalty = actor.all_roll_penalty
          return {
            roll_result: roll_result,
            total: [roll_result.total + all_roll_penalty, 0].max,
            all_roll_penalty: all_roll_penalty,
            willpower_bonus: 0
          }
        end
      end
      # Fall back to NPC custom dice
      roll_result = DiceRollService.roll(
        actor.npc_damage_dice_count,
        actor.npc_damage_dice_sides,
        explode_on: nil,
        modifier: 0
      )
      all_roll_penalty = actor.all_roll_penalty
      {
        roll_result: roll_result,
        total: [roll_result.total + all_roll_penalty, 0].max,
        all_roll_penalty: all_roll_penalty,
        willpower_bonus: 0
      }
    else
      # PCs use a single top-of-round 2d8 roll for all abilities this round.
      # Willpower ability dice are also pre-rolled once per round.
      actor_state = @round_state[actor.id]
      roll_result = actor_state&.dig(:ability_base_roll) || DiceRollService.roll(2, 8, explode_on: 8, modifier: 0)
      willpower_roll = actor_state&.dig(:willpower_ability_roll)
      willpower_bonus = actor_state&.dig(:willpower_ability_total) || 0

      # all-roll penalty is captured at round start when available.
      all_roll_penalty = actor_state&.dig(:ability_all_roll_penalty)
      all_roll_penalty = actor.all_roll_penalty if all_roll_penalty.nil?
      final_total = actor_state&.dig(:ability_round_total)
      final_total = roll_result.total + willpower_bonus + all_roll_penalty if final_total.nil?

      # Return both the original RollResult (for animation) and the modified total
      {
        roll_result: roll_result,
        base_total: roll_result.total,
        willpower_bonus: willpower_bonus,
        willpower_roll: willpower_roll,
        all_roll_penalty: all_roll_penalty,
        total: [final_total, 0].max
      }
    end
  end

  # Track ability roll for display in roll_display
  # @param actor [FightParticipant] who used the ability
  # @param ability [Ability] the ability used
  # @param target [FightParticipant] primary target
  # @param roll_result [DiceRollService::RollResult] the roll
  def track_ability_roll(actor, ability, target, roll_result)
    @roll_results << {
      participant: actor,
      roll_result: roll_result,
      purpose: 'ability',
      ability_name: ability.name,
      target: target
    }
  end


  # Check if attacker will close the melee gap within the catch-up window
  # This allows melee attacks to "catch up" when chasing a retreating target
  # @param actor [FightParticipant] the attacker
  # @param target [FightParticipant] the target
  # @param current_segment [Integer] the current segment
  # @return [Boolean] true if attacker will be in melee range within the window
  def will_close_melee_gap?(actor, target, current_segment)
    catchup_window = GameConfig::Mechanics::SEGMENTS[:melee_catchup_window]
    max_segment = [current_segment + catchup_window, GameConfig::Mechanics::SEGMENTS[:total]].min

    # Collect actor's upcoming positions by segment
    actor_positions = {}
    ((current_segment + 1)..max_segment).each do |seg|
      @segment_events[seg]&.each do |event|
        next unless event[:type] == :movement_step && event[:actor]&.id == actor.id
        actor_positions[seg] = event[:target_hex]
      end
    end

    return false if actor_positions.empty?

    # Collect target's upcoming positions by segment (target may also be moving)
    target_positions = {}
    ((current_segment + 1)..max_segment).each do |seg|
      @segment_events[seg]&.each do |event|
        next unless event[:type] == :movement_step && event[:actor]&.id == target.id
        target_positions[seg] = event[:target_hex]
      end
    end

    # Track target's position through time (start from current DB position)
    last_target_x = target.hex_x
    last_target_y = target.hex_y

    # Check actor positions in segment order — compare against target's position at same time
    actor_positions.keys.sort.any? do |seg|
      actor_pos = actor_positions[seg]
      next false unless actor_pos

      # Update target position for any movement at or before this segment
      target_positions.each do |tseg, tpos|
        if tseg <= seg && tpos
          last_target_x, last_target_y = tpos
        end
      end

      HexGrid.hex_distance(actor_pos[0], actor_pos[1], last_target_x, last_target_y) <= 1
    end
  end

  # Find all participants within hex range of center
  def find_aoe_targets(center, radius)
    active_participants.select do |p|
      center.hex_distance_to(p) <= radius
    end
  end

  # Check if attack should be redirected by Guard or Back-to-Back tactics
  # @return [Array] [new_target, redirect_type, damage_modifier] or nil if no redirect
  def check_attack_redirection(target, attacker, segment)
    return nil if target.nil?

    # Find guards protecting target
    guards = active_participants.select do |p|
      next false if knocked_out?(p.id)
      next false unless p.guarding?(target)
      next false unless p.protection_active_at_segment?(segment)

      # Check adjacency (within 1 hex)
      p.hex_distance_to(target) <= 1
    end

    protection = GameConfig::Tactics::PROTECTION

    if guards.any?
      # Chance per guard from config, max 100%
      chance = [guards.length * protection[:guard_redirect_chance], 100].min
      if rand(100) < chance
        redirected_guard = guards.sample
        # Damage bonus to guard when redirecting (from config)
        return [redirected_guard, :guard, protection[:guard_damage_bonus]]
      end
    end

    # Check back-to-back
    btb_partner = active_participants.find do |p|
      next false if knocked_out?(p.id)
      next false unless p.back_to_back_with?(target)
      next false unless p.protection_active_at_segment?(segment)

      # Check adjacency (within 1 hex)
      p.hex_distance_to(target) <= 1
    end

    if btb_partner
      is_mutual = target.mutual_back_to_back_with?(btb_partner)
      chance = is_mutual ? protection[:btb_mutual_chance] : protection[:btb_single_chance]
      if rand(100) < chance
        # Damage mod if mutual back-to-back (from config)
        damage_mod = is_mutual ? protection[:btb_mutual_damage_mod] : 0
        return [btb_partner, :back_to_back, damage_mod]
      end
    end

    nil
  end

  # Process a single attack event
  def process_attack(event, segment)
    actor = event[:actor]
    target = event[:target]
    weapon = event[:weapon]
    weapon_type = event[:weapon_type]
    natural_attack = event[:natural_attack]

    return if knocked_out?(actor.id)

    # Route monster attacks separately
    if (event[:targeting_monster] || actor.targeting_monster_id) && @monster_combat_service
      process_attack_on_monster(actor, segment, weapon, weapon_type)
      return
    end

    # Validate and resolve the attack target (redirections, observer effects)
    target, redirect_type, redirect_damage_mod = resolve_attack_target(actor, target, segment)
    return unless target

    # Re-evaluate weapon/attack for current distance (post-movement)
    if natural_attack
      natural_attack, weapon_type = reevaluate_natural_attack_for_distance(actor, target, natural_attack, weapon_type)
    else
      weapon, weapon_type = reevaluate_weapon_for_distance(actor, target, weapon, weapon_type)
    end

    # Check range
    return unless attack_in_range?(actor, target, weapon, weapon_type, natural_attack, segment)

    # Calculate base damage from dice + modifiers
    roll_data = calculate_attack_damage(actor, target, natural_attack, weapon_type, redirect_damage_mod)
    total = roll_data[:total]

    # Apply battle map modifiers — divide flat bonuses/penalties by attack count
    # so that a weapon with 5 attacks/round doesn't eat 5x the penalty
    attack_count = roll_data.dig(:pre_roll, :attack_count) || 1
    map_mods = apply_battle_map_modifiers(actor, target, weapon_type, total, segment, attack_count: attack_count)
    if map_mods[:blocked]
      @logger.log_attack_blocked(segment, actor, target, 'full_cover')
      return
    end
    total = map_mods[:total]

    # Mark that actor attacked this round (for cover blocking calculation)
    actor.update(acted_this_round: true)

    # Apply remaining modifiers (NPC bonuses, status effects, observer effects)
    total = apply_final_attack_modifiers(actor, target, natural_attack, total, roll_data)

    # Apply shields and track cumulative damage
    damage_type = natural_attack ? natural_attack.damage_type : 'physical'
    damage_result = apply_attack_damage_tracking(actor, target, total, damage_type, segment)

    # Log full attack breakdown
    distance = actor.hex_distance_to(target)
    state = @round_state[target.id]
    @logger.log_attack(segment, actor, target, weapon_type || natural_attack&.name,
                       roll_data, map_mods, total, state&.dig(:cumulative_damage) || 0, distance,
                       damage_result)

    # Emit hit/miss event
    emit_attack_event(segment, actor, target, weapon_type, natural_attack, damage_type,
                      roll_data, map_mods, damage_result, redirect_type, redirect_damage_mod)
  end

  # Validate target and apply redirections (observer effects, guard, back-to-back)
  # @return [Array] [resolved_target, redirect_type, redirect_damage_mod] or [nil] if invalid
  def resolve_attack_target(actor, target, segment)
    return [nil, nil, 0] unless target
    return [nil, nil, 0] if knocked_out?(target.id)

    if actor.same_side?(target)
      @events << create_event(segment, actor, target, 'action', reason: 'invalid_target_same_side')
      return [nil, nil, 0]
    end
    if StatusEffectService.cannot_target_ids(actor).include?(target.id)
      @events << create_event(segment, actor, target, 'action', reason: 'invalid_target_protected')
      return [nil, nil, 0]
    end

    # Activity observer forced target redirect
    observer_forced_target = resolve_observer_forced_target(actor)
    if observer_forced_target && observer_forced_target.id != target.id
      original_target = target
      target = observer_forced_target
      return [nil, nil, 0] if knocked_out?(target.id)

      @events << create_event(segment, actor, original_target, 'attack_redirected',
                              new_target_name: target.character_name,
                              redirect_type: 'observer_forced_target',
                              protector_tactic: 'observer')
    end

    # Guard / Back-to-Back redirection
    redirect_type = nil
    redirect_damage_mod = 0
    redirect_result = check_attack_redirection(target, actor, segment)
    if redirect_result
      original_target = target
      target = redirect_result[0]
      redirect_type = redirect_result[1]
      redirect_damage_mod = redirect_result[2]

      @logger.log_attack_redirect(segment, actor, original_target, target, redirect_type)
      @events << create_event(segment, actor, original_target, 'attack_redirected',
                              new_target_name: target.character_name,
                              redirect_type: redirect_type.to_s,
                              protector_tactic: redirect_type == :guard ? 'guard' : 'back_to_back')
    end

    [target, redirect_type, redirect_damage_mod]
  end

  # Check if attack is within range, considering melee catchup
  # @return [Boolean] true if in range
  def attack_in_range?(actor, target, weapon, weapon_type, natural_attack, segment)
    distance = actor.hex_distance_to(target)
    max_range = if natural_attack
                  natural_attack.range_hexes
                elsif weapon&.pattern
                  weapon.pattern.range_in_hexes
                else
                  1
                end

    return true if distance <= max_range

    # Melee catchup: allow if attacker was initially close and will close the gap
    initial_dist = @round_state[actor.id]&.dig(:initial_distance_to_target)
    can_catchup = max_range == 1 &&
                  initial_dist && initial_dist <= 2 &&
                  will_close_melee_gap?(actor, target, segment)

    unless can_catchup
      @logger.log_attack_out_of_range(segment, actor, target, distance, max_range)
      @events << create_event(segment, actor, target, 'out_of_range',
                              weapon_type: weapon_type.to_s,
                              distance: distance,
                              max_range: max_range)
      return false
    end

    true
  end

  # Calculate base attack damage from dice rolls and flat modifiers
  # @return [Hash] with :total, :attack_roll, :stat_modifier, :round_stat_modifier,
  #   :willpower_attack_roll_result, :willpower_attack_mod, :all_roll_penalty,
  #   :dodge_penalty, :pre_roll
  def calculate_attack_damage(actor, target, natural_attack, weapon_type, redirect_damage_mod)
    pre_roll = @combat_pre_rolls&.dig(actor.id) || build_pre_roll_for_actor(actor)
    dodge_penalty = target.main_action == 'dodge' ? GameConfig::Tactics::DODGE_PENALTY : 0

    if pre_roll
      n = pre_roll[:attack_count]
      round_stat_modifier = pre_roll[:total_stat_modifier] || pre_roll[:stat_modifier] || 0

      round_total = pre_roll[:roll_total] + round_stat_modifier -
                    actor.wound_penalty + pre_roll[:all_roll_penalty]
      round_total += actor.tactic_outgoing_damage_modifier
      round_total += target.tactic_incoming_damage_modifier
      round_total += redirect_damage_mod
      round_total -= dodge_penalty
      round_total += (actor.npc_damage_bonus || 0)
      round_total -= (target.npc_defense_bonus || 0)
      round_total += actor.outgoing_damage_modifier

      {
        total: [(round_total.to_f / n).round, 0].max,
        attack_roll: pre_roll[:base_roll],
        stat_modifier: pre_roll[:stat_per_attack] || (round_stat_modifier.to_f / n),
        round_stat_modifier: round_stat_modifier,
        willpower_attack_roll_result: pre_roll[:willpower_roll],
        willpower_attack_mod: pre_roll[:willpower_roll]&.total || 0,
        all_roll_penalty: pre_roll[:all_roll_penalty],
        dodge_penalty: dodge_penalty,
        pre_roll: pre_roll
      }
    else
      attack_count = [count_scheduled_attacks(actor.id), 1].max
      round_stat_modifier = sum_attack_stat_modifiers(actor)
      stat_mod = round_stat_modifier.to_f / attack_count
      attack_roll = roll_base_attack_dice(actor, natural_attack)

      wp_roll = actor.willpower_attack_roll
      wp_mod = (wp_roll&.total || 0).to_f / attack_count
      all_penalty = actor.all_roll_penalty.to_f / attack_count
      wound_share = actor.wound_penalty.to_f / attack_count
      total = attack_roll.total + stat_mod - wound_share + wp_mod + all_penalty
      total += actor.tactic_outgoing_damage_modifier
      total += target.tactic_incoming_damage_modifier
      total += redirect_damage_mod
      total -= dodge_penalty

      @roll_results << { participant: actor, roll_result: attack_roll, purpose: 'attack', target: target }
      if wp_roll
        @roll_results << { participant: actor, roll_result: wp_roll,
                           purpose: 'willpower_attack', target: target }
      end

      {
        total: [total, 0].max,
        attack_roll: attack_roll,
        stat_modifier: stat_mod,
        round_stat_modifier: round_stat_modifier,
        willpower_attack_roll_result: wp_roll,
        willpower_attack_mod: wp_mod,
        all_roll_penalty: all_penalty,
        dodge_penalty: dodge_penalty,
        pre_roll: nil
      }
    end
  end

  # Apply battle map modifiers (elevation, cover, LoS, concealment)
  # @return [Hash] with :total, :blocked, :elevation_mod, :los_penalty,
  #   :elevation_damage_bonus, :cover_damage_multiplier
  def apply_battle_map_modifiers(actor, target, weapon_type, total, segment, attack_count: 1)
    result = { total: total, blocked: false, elevation_mod: 0,
               los_penalty: 0, elevation_damage_bonus: 0, cover_damage_multiplier: 1.0 }

    return result unless battle_map_service.battle_map_active?

    # Flat modifiers are divided by attack_count so they apply proportionally
    # to each attack's share of the round total (matching how dice are divided).
    n = [attack_count, 1].max.to_f

    result[:elevation_mod] = battle_map_service.elevation_modifier(actor, target)
    total += (result[:elevation_mod] / n).round

    result[:los_penalty] = battle_map_service.line_of_sight_penalty(actor, target)
    total += (result[:los_penalty] / n).round

    prone_mod = battle_map_service.prone_modifier(actor, target)
    total += (prone_mod / n).round

    ranged_attack = %i[ranged natural_ranged].include?(weapon_type)
    if ranged_attack
      result[:elevation_damage_bonus] = battle_map_service.elevation_damage_bonus(actor, target)
      total += (result[:elevation_damage_bonus] / n).round

      blocked, cover_mult, total, cover_obj = apply_ranged_cover_and_concealment(actor, target, total, segment, weapon_type)
      if blocked
        result[:blocked] = true
        return result
      end
      result[:cover_damage_multiplier] = cover_mult
      result[:cover_object] = cover_obj if cover_obj
    end

    result[:total] = total
    result
  end

  # Apply ranged cover LoS blocking and concealment.
  # Cover hexes between attacker and target that aren't adjacent to the attacker
  # block or reduce damage. Attacker's own adjacent cover is ignored (shooting FROM cover).
  # @return [Array] [blocked, cover_damage_multiplier, total, cover_object]
  def apply_ranged_cover_and_concealment(actor, target, total, segment, weapon_type = :ranged)
    hexes_between = battle_map_service.send(:hexes_in_line,
                                             actor.hex_x, actor.hex_y,
                                             target.hex_x, target.hex_y)

    cover_room_hexes = hexes_between.filter_map do |hex_x, hex_y|
      battle_map_service.cached_hex(hex_x, hex_y)
    end

    blocking_hex = CoverLosService.blocking_cover_hex(
      attacker_pos: [actor.hex_x, actor.hex_y],
      hexes_in_path: cover_room_hexes
    )

    cover_damage_multiplier = 1.0
    if blocking_hex
      target_stationary = !target.moved_this_round && !target.acted_this_round

      if target_stationary
        actor.update(acted_this_round: true)
        @events << create_event(segment, actor, target, 'shot_blocked',
                                weapon_type: weapon_type.to_s, reason: 'full_cover',
                                cover_object: blocking_hex.cover_object)
        return [true, 0.0, total]
      else
        cover_damage_multiplier = 0.5
        total = (total * 0.5).floor
      end
    end

    target_hex = fight.room.room_hexes_dataset.first(
      hex_x: target.hex_x, hex_y: target.hex_y
    )
    if ConcealmentService.applies_to_attack?(target_hex, weapon_type.to_s.sub('natural_', ''))
      distance = HexGrid.hex_distance(actor.hex_x, actor.hex_y, target.hex_x, target.hex_y)
      total += ConcealmentService.ranged_penalty(distance)
    end

    [false, cover_damage_multiplier, total, blocking_hex&.cover_object]
  end

  # Apply remaining modifiers: NPC bonuses, status effects, observer effects, damage types, shields
  # @return [Integer] final damage total before shield absorption
  def apply_final_attack_modifiers(actor, target, natural_attack, total, roll_data)
    unless roll_data[:pre_roll]
      total += (actor.npc_damage_bonus || 0)
      total -= (target.npc_defense_bonus || 0)
    end
    total = [total, 0].max

    outgoing_mod = roll_data[:pre_roll] ? 0 : actor.outgoing_damage_modifier
    total += outgoing_mod
    roll_data[:outgoing_mod] = outgoing_mod

    incoming_mod = target.incoming_damage_modifier
    attack_n = roll_data.dig(:pre_roll, :attack_count) || 1
    total = [total + (incoming_mod.to_f / attack_n).round, 0].max
    roll_data[:incoming_mod] = incoming_mod

    observer_mods = apply_observer_combat_modifiers(actor, target, total)
    total = observer_mods[:total]
    roll_data[:observer_mods] = observer_mods

    damage_type = natural_attack ? natural_attack.damage_type : 'physical'
    total = (total * StatusEffectService.damage_type_multiplier(target, damage_type)).round

    # Willpower defense info for event display (applied at cumulative level, not per-hit)
    target_state = @round_state[target.id]
    roll_data[:willpower_defense_roll_result] = target_state&.dig(:willpower_defense_roll)
    roll_data[:willpower_defense_reduction] = target_state&.dig(:willpower_defense_total) || 0

    total
  end

  # Apply shield absorption and track cumulative damage for threshold checks
  # @return [Hash] with :threshold_crossed, :hp_lost_this_attack, :total (post-shield)
  def apply_attack_damage_tracking(actor, target, total, damage_type, segment)
    damage_before_shield = total
    total = StatusEffectService.absorb_damage_with_shields(target, total, damage_type)

    threshold_crossed = false
    hp_lost_this_attack = 0
    state = @round_state[target.id]

    if state
      shield_absorbed = damage_before_shield - total
      state[:shield_absorbed_total] += shield_absorbed if shield_absorbed > 0

      state[:raw_by_attacker][actor.id] += total
      state[:raw_by_attacker_type][[actor.id, damage_type]] += total
      state[:cumulative_damage] += total

      effective_result = calculate_effective_cumulative(target, state, damage_type)
      effective_cumulative = effective_result[:effective]

      new_hp_lost = target.hp_lost_from_cumulative(effective_cumulative)
      previously_lost = state[:hp_lost_this_round]

      if new_hp_lost > previously_lost
        threshold_crossed = true
        additional_loss = target.apply_incremental_hp_loss!(new_hp_lost, previously_lost)
        hp_lost_this_attack = additional_loss
        state[:hp_lost_this_round] = new_hp_lost
        state[:current_hp] = target.current_hp

        @logger.log_damage_threshold(target, state[:cumulative_damage], effective_cumulative,
                                     additional_loss, new_hp_lost, target.current_hp,
                                     armor: effective_result[:armor_reduced],
                                     protection: effective_result[:protection_reduced],
                                     wp_defense: effective_result[:willpower_defense_reduced])

        if fight.spar_mode?
          @logger.log_spar_touch(target, target.touch_count, target.max_hp)
        end

        @events << create_event(segment, actor, target, 'damage_applied',
                                damage_this_attack: total,
                                cumulative_damage: state[:cumulative_damage],
                                effective_cumulative: effective_cumulative,
                                shield_absorbed: shield_absorbed,
                                armor_reduced: effective_result[:armor_reduced],
                                protection_reduced: effective_result[:protection_reduced],
                                hp_lost_now: additional_loss,
                                hp_lost_total: new_hp_lost,
                                remaining_hp: target.current_hp,
                                new_wound_penalty: target.wound_penalty)

        if target.current_hp <= 0
          mark_knocked_out!(target.id)
          @logger.log_knockout(target, segment, state[:cumulative_damage])
          @events << create_event(segment, actor, target, 'knockout',
                                  final_hp: target.current_hp,
                                  knockout_segment: segment,
                                  total_damage_taken: state[:cumulative_damage])
          PrisonerService.process_knockout!(target.character_instance) if target.character_instance
        end
      end
    end

    { threshold_crossed: threshold_crossed, hp_lost_this_attack: hp_lost_this_attack, total: total }
  end

  # Emit the final hit/miss event with all combat details
  def emit_attack_event(segment, actor, target, weapon_type, natural_attack, damage_type,
                        roll_data, map_mods, damage_result, redirect_type, redirect_damage_mod)
    total = damage_result[:total]
    threshold_crossed = damage_result[:threshold_crossed]
    base_hit_threshold = 10 - target.wound_penalty
    event_type = (total > base_hit_threshold || threshold_crossed) ? 'hit' : 'miss'

    # Ranged misses that went through cover → emit as shot_blocked for narrative
    ranged_type = %w[ranged natural_ranged].include?(weapon_type.to_s)
    if event_type == 'miss' && ranged_type && map_mods[:cover_damage_multiplier] < 1.0
      @events << create_event(segment, actor, target, 'shot_blocked',
                              weapon_type: weapon_type.to_s, reason: 'partial_cover',
                              cover_object: map_mods[:cover_object])
      return
    end

    observer_mods = roll_data[:observer_mods] || { effects: [], multiplier: 1.0, flat_bonus: 0 }
    dodge_penalty = roll_data[:dodge_penalty] || 0
    wp_attack_mod = roll_data[:willpower_attack_mod] || 0
    wp_attack_roll = roll_data[:willpower_attack_roll_result]
    wp_defense_reduction = roll_data[:willpower_defense_reduction] || 0
    wp_defense_roll = roll_data[:willpower_defense_roll_result]
    outgoing_mod = roll_data[:outgoing_mod] || 0
    incoming_mod = roll_data[:incoming_mod] || 0

    @events << create_event(segment, actor, target, event_type,
                            threshold_crossed: threshold_crossed,
                            hp_lost_this_attack: damage_result[:hp_lost_this_attack],
                            weapon_type: weapon_type.to_s,
                            natural_attack_name: natural_attack&.name,
                            damage_type: damage_type,
                            roll: roll_data[:attack_roll].total,
                            roll_dice: roll_data[:attack_roll].dice,
                            roll_exploded: roll_data[:attack_roll].explosions.any?,
                            stat_mod: roll_data[:stat_modifier],
                            stat_mod_round_total: roll_data[:round_stat_modifier],
                            wound_penalty: actor.wound_penalty,
                            all_roll_penalty: roll_data[:all_roll_penalty],
                            tactic_outgoing_mod: actor.tactic_outgoing_damage_modifier != 0 ? actor.tactic_outgoing_damage_modifier : nil,
                            tactic_incoming_mod: target.tactic_incoming_damage_modifier != 0 ? target.tactic_incoming_damage_modifier : nil,
                            redirect_type: redirect_type,
                            redirect_damage_mod: redirect_damage_mod != 0 ? redirect_damage_mod : nil,
                            dodge_penalty: dodge_penalty > 0 ? -dodge_penalty : nil,
                            willpower_attack_bonus: wp_attack_mod > 0 ? wp_attack_mod : nil,
                            willpower_attack_dice: wp_attack_roll&.dice,
                            willpower_attack_exploded: wp_attack_roll&.explosions&.any?,
                            willpower_defense_roll: wp_defense_reduction > 0 ? wp_defense_reduction : nil,
                            willpower_defense_dice: wp_defense_roll&.dice,
                            willpower_defense_exploded: wp_defense_roll&.explosions&.any?,
                            outgoing_modifier: outgoing_mod != 0 ? outgoing_mod : nil,
                            incoming_modifier: incoming_mod != 0 ? incoming_mod : nil,
                            observer_effects: observer_mods[:effects].any? ? observer_mods[:effects] : nil,
                            observer_multiplier: observer_mods[:multiplier] != 1.0 ? observer_mods[:multiplier].round(2) : nil,
                            observer_flat_bonus: observer_mods[:flat_bonus].positive? ? observer_mods[:flat_bonus] : nil,
                            elevation_modifier: map_mods[:elevation_mod] != 0 ? map_mods[:elevation_mod] : nil,
                            los_penalty: map_mods[:los_penalty] != 0 ? map_mods[:los_penalty] : nil,
                            elevation_damage_bonus: map_mods[:elevation_damage_bonus] > 0 ? map_mods[:elevation_damage_bonus] : nil,
                            cover_damage_reduction: map_mods[:cover_damage_multiplier] < 1.0 ? "#{((1 - map_mods[:cover_damage_multiplier]) * 100).round}%" : nil,
                            cover_object: map_mods[:cover_object],
                            total: total)
  end

  # Get the relevant attack stat for a weapon type.
  # The raw stat value IS the damage modifier (Strength 5 = +5 to the round).
  def get_attack_stat(participant, weapon_type)
    char_instance = participant.character_instance
    # NPCs without a character_instance use their damage bonus directly
    return participant.npc_damage_bonus || 0 unless char_instance

    # Use Dexterity for ranged/natural_ranged, Strength for melee/natural_melee/unarmed
    stat_name = %i[ranged natural_ranged].include?(weapon_type) ? 'Dexterity' : 'Strength'

    # Try to get from CharacterStat
    char_stat = CharacterStat
                .eager(:stat)
                .where(character_instance_id: char_instance.id)
                .all
                .find { |cs| cs.stat&.name == stat_name }

    char_stat&.current_value || GameConfig::Mechanics::DEFAULT_STAT
  end

  # Log round damage summaries for all participants
  # HP loss is now applied incrementally during the round via apply_incremental_hp_loss!
  # This method just creates summary events for any damage taken
  def apply_accumulated_damage
    @round_state.each do |participant_id, state|
      next if state[:cumulative_damage] <= 0

      participant = fight.fight_participants_dataset.first(id: participant_id)
      next unless participant

      # Log the total damage taken this round (even if some didn't cause HP loss)
      @events << create_event(100, nil, participant, 'round_damage_summary',
                              total_damage_taken: state[:cumulative_damage],
                              hp_lost_this_round: state[:hp_lost_this_round],
                              remaining_hp: participant.current_hp,
                              wound_penalty: participant.wound_penalty)
    end

    # Clear the legacy pending_damage fields on participants (no longer used)
    fight.fight_participants.each do |p|
      p.clear_accumulated_damage! if p.respond_to?(:clear_accumulated_damage!)
    end
  end

  # Process battle map hazard damage for all participants
  def process_battle_map_hazards
    return unless battle_map_service.battle_map_active?

    hazard_events = battle_map_service.process_all_hazard_damage

    hazard_events.each do |event|
      participant = event[:participant]
      next if event[:damage] <= 0

      @logger.log_hazard_damage(participant, event[:hazard_type], event[:damage], event[:hex_x], event[:hex_y])
      @events << create_event(100, nil, participant, 'hazard_damage',
                              damage: event[:damage],
                              damage_type: event[:damage_type],
                              hazard_type: event[:hazard_type],
                              hex_x: event[:hex_x],
                              hex_y: event[:hex_y],
                              remaining_hp: participant.current_hp)
    end
  end

  # ============================================
  # Flee Processing
  # ============================================

  # Process flee attempts at end of round
  # Participants who selected flee and took no damage escape the fight
  def process_flee_attempts
    fight.active_participants.where(is_fleeing: true).each do |participant|
      state = @round_state[participant.id]
      damage_taken = state ? state[:cumulative_damage] : 0

      if damage_taken.zero?
        @logger.log_flee(participant, true, direction: participant.flee_direction)
        process_successful_flee(participant)
      else
        @logger.log_flee(participant, false, direction: participant.flee_direction, damage_taken: damage_taken)
        process_failed_flee(participant, damage_taken)
      end
    end
  end

  # Process a successful flee - move character to adjacent room
  def process_successful_flee(participant)
    # Get destination from flee direction via spatial adjacency
    destination = RoomAdjacencyService.resolve_direction_movement(
      fight.room, participant.flee_direction.to_sym
    )
    destination_name = destination&.name || 'an adjacent room'

    participant.process_successful_flee!

    @events << create_event(
      GameConfig::Mechanics::SEGMENTS[:total],
      participant, nil, 'flee_success',
      direction: participant.flee_direction,
      destination: destination_name
    )

    BroadcastService.to_room(
      fight.room_id,
      "#{participant.character_name} escapes the fight, fleeing #{participant.flee_direction}!",
      type: :combat
    )

    # Log flee to character stories
    IcActivityService.record(
      room_id: fight.room_id,
      content: "#{participant.character_name} escapes the fight, fleeing #{participant.flee_direction}!",
      sender: participant.character_instance, type: :combat
    )
  end

  # Process a failed flee - character was hit while trying to escape
  def process_failed_flee(participant, damage_taken)
    @events << create_event(
      GameConfig::Mechanics::SEGMENTS[:total],
      participant, nil, 'flee_failed',
      direction: participant.flee_direction,
      damage_taken: damage_taken
    )

    participant.cancel_flee!

    BroadcastService.to_character(
      participant.character_instance,
      'Your escape attempt was interrupted by incoming attacks!',
      type: :combat
    )

    # Log escape interruption to character story
    IcActivityService.record_for(
      recipients: [participant.character_instance],
      content: 'Your escape attempt was interrupted by incoming attacks!',
      sender: nil, type: :combat
    )
  end

  # ============================================
  # Surrender Processing
  # ============================================

  # Process all surrenders at end of round
  def process_surrenders
    fight.fight_participants_dataset.where(is_surrendering: true).each do |participant|
      process_surrender(participant)
    end
  end

  # Process a single surrender - make character helpless and remove from fight
  def process_surrender(participant)
    participant.process_surrender!

    @events << create_event(
      GameConfig::Mechanics::SEGMENTS[:total],
      participant, nil, 'surrender',
      character_name: participant.character_name
    )

    BroadcastService.to_room(
      fight.room_id,
      "#{participant.character_name} surrenders!",
      type: :combat
    )

    # Log surrender to character stories
    IcActivityService.record(
      room_id: fight.room_id,
      content: "#{participant.character_name} surrenders!",
      sender: participant.character_instance, type: :combat
    )
  end

  # Check for and record knockouts (or deaths for hostile NPCs)
  # Also catches participants at 0 HP that were never flagged as knocked out
  def check_knockouts
    fight.fight_participants.each do |participant|
      next unless participant.current_hp <= 0

      # Check if this participant already had a knockout/death event in a previous round
      already_announced_prev_round = FightEvent.where(
        fight_id: fight.id,
        target_participant_id: participant.id,
        event_type: %w[knockout death]
      ).where(Sequel.lit('round_number < ?', fight.round_number)).any?

      if already_announced_prev_round
        # Already knocked out in a previous round — just ensure internal state, don't re-announce
        participant.update(is_knocked_out: true) unless participant.is_knocked_out
        mark_knocked_out!(participant.id) unless knocked_out?(participant.id)
        next
      end

      # First time reaching 0 HP — flag as knocked out
      unless participant.is_knocked_out
        participant.update(is_knocked_out: true)
      end
      mark_knocked_out!(participant.id)

      # Only log if not already logged this round (check both knockout and death)
      already_logged = @events.any? do |e|
        %w[knockout death].include?(e[:event_type]) && e[:target_id] == participant.id
      end

      next if already_logged

      character = participant.character_instance&.character

      if character&.hostile?
        # Hostile NPCs die and despawn instead of being knocked out
        @events << create_event(100, nil, participant, 'death',
                                final_hp: participant.current_hp)
        NpcSpawnService.kill_npc!(participant.character_instance)
      else
        # Players and non-hostile NPCs get knocked out
        @events << create_event(100, nil, participant, 'knockout',
                                final_hp: participant.current_hp)

        # Transition character instance to unconscious state for prisoner mechanics
        if participant.character_instance
          PrisonerService.process_knockout!(participant.character_instance)
        end
      end
    end
  end

  # Create an event hash
  def create_event(segment, actor, target, event_type, **details)
    # Validate event_type - use safe fallback if invalid
    safe_type = validate_event_type(event_type)

    {
      segment: segment,
      actor_id: actor&.id,
      actor_name: actor&.character_name,
      target_id: target&.id,
      target_name: target&.character_name,
      event_type: safe_type,
      round: fight.round_number,
      details: details
    }
  end

  # Validate event type, returning a safe fallback if invalid
  # @param event_type [String] the event type to validate
  # @return [String] validated event type or 'action' as fallback
  def validate_event_type(event_type)
    return 'action' if event_type.nil?

    type_str = event_type.to_s
    if FightEvent::EVENT_TYPES.include?(type_str)
      type_str
    else
      warn "[COMBAT_RESOLUTION] Unknown event type '#{type_str}', using 'action' fallback"
      'action'
    end
  end

  # Save events to database
  def save_events_to_db
    @events.each do |e|
      puts "[DEBUG] Saving event: #{e[:event_type].inspect}" if ENV['DEBUG']
      begin
        FightEvent.create(
          fight_id: fight.id,
          round_number: fight.round_number,
          segment: e[:segment],
          actor_participant_id: e[:actor_id],
          target_participant_id: e[:target_id],
          event_type: e[:event_type],
          weapon_type: e.dig(:details, :weapon_type),
          damage_dealt: e.dig(:details, :total),
          roll_result: e.dig(:details, :roll),
          details: e[:details].to_json
        )
      rescue Sequel::ValidationFailed => ve
        warn "[COMBAT_RESOLUTION] Failed to save event #{e[:event_type]}: #{ve.message}"
        # Skip this event but continue with others
      end
    end
  end

  # Generate a compact damage summary for the round.
  # Aggregates damage per attacker->target pair. Also collects status effects and knockouts.
  # Format: (Lin dmg Rob for 20[2HP]; Rob dmg Lin for 10[0HP]; Rob knocked down)
  def generate_round_damage_summary
    # Use character_name (full name) so the personalization service can match
    # and replace names per-viewer (e.g., "a short lady" for unknown characters).
    # Short names like "Lin" won't match after the full name is already matched
    # in the narrative due to matched_char_ids in the personalization pipeline.

    # Sum raw damage from ALL hit and miss events (per-attack damage totals)
    # This gives the true cumulative raw damage, not just threshold-crossing amounts
    damage_data = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = { raw: 0, hp_lost: 0 } } }
    status_effects = []

    @events.each do |event|
      case event[:event_type]
      when 'hit', 'miss'
        d = event[:details] || {}
        actor_name = event[:actor_name]
        target_name = event[:target_name]
        next unless actor_name && target_name

        damage_data[actor_name][target_name][:raw] += (d[:total] || 0)
      when 'damage_applied'
        d = event[:details] || {}
        actor_name = event[:actor_name]
        target_name = event[:target_name]
        next unless actor_name && target_name

        damage_data[actor_name][target_name][:hp_lost] += (d[:hp_lost_now] || 0)
      when 'status_applied'
        d = event[:details] || {}
        target_name = d[:target_name] || event[:target_name]
        effect_name = d[:effect_name]
        status_effects << "#{target_name} #{effect_name&.tr('_', ' ')}" if effect_name && target_name
      when 'knockout'
        target_name = event[:details]&.dig(:target_name) || event[:target_name]
        status_effects << "#{target_name} KO'd" if target_name
      end
    end

    parts = damage_data.flat_map do |attacker, targets|
      targets.map { |target, d| "#{attacker} dmg #{target} for #{d[:raw]}[#{d[:hp_lost]}HP]" }
    end
    parts.concat(status_effects)

    @damage_summary = parts.any? ? "(#{parts.join('; ')})" : nil
  end

  # Generate roll display data for broadcasting before narrative.
  # One animated roll per PC combatant (not NPCs). Willpower dice shown in yellow.
  # Also includes willpower defense rolls (per-attack, cyan).
  def generate_roll_display
    @roll_display = []

    # Pre-rolled attack dice: one display per PC attacker
    (@combat_pre_rolls || {}).each do |participant_id, pre_roll|
      next unless pre_roll[:is_pc] # NPCs don't display rolls

      participant = fight.fight_participants.find { |p| p.id == participant_id }
      next unless participant

      # Base roll animation (white)
      # Use empty name in animation data - the character name is set via
      # dataset.characterName on the container div (avoids double name display)
      base_anim = DiceRollService.generate_animation_data(
        pre_roll[:base_roll],
        character_name: '',
        color: 'w'
      )

      # Merge willpower dice into base animation so they appear on the same line in blue
      if pre_roll[:willpower_roll]
        wp_roll = pre_roll[:willpower_roll]
        # Count all non-explosion dice (base + WP) for explosion delay offset
        base_explosion_count = pre_roll[:base_roll].dice.length - pre_roll[:base_roll].count
        wp_dice_parts = wp_roll.dice.each_with_index.map do |die_result, idx|
          # dtype 4 = willpower (blue) - all willpower dice use this type
          # Base WP dice bounce simultaneously with attack dice (delay 0)
          # Only WP explosions are delayed (after all base explosions)
          delay = if idx < wp_roll.count
                    0
                  else
                    ((base_explosion_count + idx - wp_roll.count + 1) * 2)
                  end
          roll_sequence = DiceRollService.generate_roll_sequence(die_result, wp_roll.sides)
          "4||#{delay}||#{die_result}||#{roll_sequence.join('|')}"
        end
        # Append willpower dice to the base animation's dice data
        base_anim = "#{base_anim}(())#{wp_dice_parts.join('(())')}"
      end

      @roll_display << {
        character_id: participant.character_instance_id,
        character_name: participant.character_name,
        animations: [base_anim],
        total: pre_roll[:roll_total]
      }
    end

    # Willpower defense and ability rolls: one pre-rolled display per participant from round_state
    # Use empty name in animation data to avoid double name display (container div has the name)
    (@round_state || {}).each do |participant_id, state|
      participant = fight.fight_participants.find { |p| p.id == participant_id }
      next unless participant

      # Willpower defense roll
      wp_defense = state[:willpower_defense_roll]
      if wp_defense
        defense_anim = DiceRollService.generate_animation_data(
          wp_defense,
          character_name: '',
          color: 'c'
        )

        @roll_display << {
          character_id: participant.character_instance_id,
          character_name: participant.character_name,
          animations: [defense_anim],
          total: wp_defense.total
        }
      end

      # Willpower ability roll (only if participant used an ability)
      wp_ability = state[:willpower_ability_roll]
      if wp_ability
        # Only show if participant actually used an ability this round
        used_ability = @events.any? { |e| e[:event_type] == 'ability_start' && e[:actor_id] == participant.id }
        if used_ability
          ability_anim = DiceRollService.generate_animation_data(
            wp_ability,
            character_name: '',
            color: 'b'  # blue for ability willpower
          )

          @roll_display << {
            character_id: participant.character_instance_id,
            character_name: participant.character_name,
            animations: [ability_anim],
            total: wp_ability.total
          }
        end
      end
    end
  end

  # Validate all participant positions at start of round.
  # Moves anyone on a non-traversable hex to nearest valid hex.
  # Catches edge cases like terrain changing mid-fight.
  def validate_participant_positions
    room = fight.room
    return unless room

    fight_service = FightService.new(fight)

    active_participants.each do |p|
      next if p.is_knocked_out
      next if RoomHex.playable_at?(room, p.hex_x, p.hex_y)

      new_x, new_y = fight_service.find_unoccupied_hex(p.hex_x, p.hex_y)
      next if new_x == p.hex_x && new_y == p.hex_y

      warn "[CombatResolution] Round #{fight.round_number}: repositioned #{p.character_name} " \
           "from (#{p.hex_x},#{p.hex_y}) to (#{new_x},#{new_y}) — non-traversable hex"
      p.update(hex_x: new_x, hex_y: new_y)
      p.sync_position_to_character!
    end
  end

  def clamp_to_arena_hex(hex_x, hex_y)
    HexGrid.clamp_to_arena(hex_x, hex_y, fight.arena_width, fight.arena_height)
  end
end
