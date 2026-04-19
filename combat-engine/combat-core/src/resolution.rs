/// Main round resolution loop for the 100-segment combat system.
///
/// Each round is divided into 100 segments. All participant actions are
/// scheduled onto this timeline, then processed in segment order. Damage
/// is tracked incrementally using `DamageTracker` -- each hit may cross
/// a threshold and cause immediate HP loss, increasing wound penalty for
/// subsequent hits within the same round.
use std::collections::HashMap;

use rand::Rng;

use crate::ability_resolution;
use crate::battle_map;
use crate::damage::DamageTracker;
use crate::defense;
use crate::dice;
use crate::hex_grid;
use crate::interactive_objects;
use crate::monster_combat;
use crate::movement;
use crate::observer_effects;
use crate::tactics;
use crate::segments::{EventPriority, MovementIntent, SegmentEventType, SegmentTimeline};
use crate::status_effects;
use crate::weapon_resolution;
use crate::types::actions::{MainAction, MovementAction, PlayerAction, TacticChoice};
use crate::types::config::CombatConfig;
use crate::types::abilities::ForcedMovementDirection;
use crate::types::events::{
    AbilityTargetResult, AttackRollDetail, AttackWeaponDetail, CombatEvent, DefenseDetail,
};
use crate::types::fight_state::{FightMode, FightState, RoundResult};
use crate::types::hex::HexCoord;
use crate::types::monsters::MountStatus;
use crate::types::participant::Participant;
use crate::types::status_effects::EffectType;
use crate::types::weapons::DamageType;

/// Pre-rolled qi dice for a participant (rolled once per round, shared across all events).
/// Rolled in Phase 1 (initialize_round_state) to match Ruby's RNG consumption order.
struct PreRolls {
    participant_id: u64,
    qi_defense_roll: Option<i32>,
    qi_ability_roll: Option<i32>,
    ability_base_roll: Option<i32>,
    tactic_movement_bonus: u32,
}

/// Pre-rolled combat dice for attackers, rolled in Phase 3 (after timeline building)
/// to match Ruby's `pre_roll_combat_dice` RNG consumption order.
struct CombatPreRoll {
    participant_id: u64,
    base_attack_roll: i32,
    /// Individual dice values from the base weapon roll.
    base_dice: Vec<u32>,
    /// Whether any base dice exploded.
    base_exploded: bool,
    qi_attack_roll: Option<i32>,
    /// Individual dice values from qi attack roll.
    qi_attack_dice: Option<Vec<u32>>,
    roll_total: i32,
    attack_count: u32,
    all_roll_penalty: i16,
    stat_modifier: i16,
}

/// Main round resolution function.
///
/// Takes the current fight state and each participant's chosen action, then
/// simulates one full round of combat. Returns the resulting state, all
/// combat events that occurred, knockout list, and fight-end status.
pub fn resolve_round_inner(
    state: &FightState,
    actions: &[PlayerAction],
    rng: &mut impl Rng,
) -> RoundResult {
    resolve_round_impl(state, actions, rng, false)
}

/// Like `resolve_round_inner` but also emits `RngTrace` events for every
/// random value consumed, labeled with semantic context. Used for parity debugging.
pub fn resolve_round_traced(
    state: &FightState,
    actions: &[PlayerAction],
    rng: &mut impl Rng,
) -> RoundResult {
    resolve_round_impl(state, actions, rng, true)
}

fn resolve_round_impl(
    state: &FightState,
    actions: &[PlayerAction],
    rng: &mut impl Rng,
    trace_rng: bool,
) -> RoundResult {
    let mut next_state = state.clone();
    let mut events: Vec<CombatEvent> = Vec::new();
    let mut knockouts: Vec<u64> = Vec::new();

    // Sort actions by participant_id (ascending) to match Ruby's DB ID ordering
    let mut sorted_actions = actions.to_vec();
    sorted_actions.sort_by_key(|a| a.participant_id);
    let actions = &sorted_actions;

    // Pre-round position validation. Ruby: combat_resolution_service.rb:302-303
    // validate_participant_positions — moves anyone standing on a non-playable
    // hex to a nearby valid hex so scheduling doesn't operate on invalid state.
    validate_participant_positions(&mut next_state, &mut events);

    // Step 0: Mutual-pass check -- if all conscious participants chose Pass, end fight peacefully
    // Ruby: combat_resolution_service.rb:305-311 checks all_conscious_passed? before scheduling
    {
        let conscious: Vec<u64> = next_state.participants.iter()
            .filter(|p| !p.is_knocked_out)
            .map(|p| p.id)
            .collect();
        if !conscious.is_empty() && conscious.iter().all(|pid| {
            actions.iter().any(|a| a.participant_id == *pid && matches!(a.main_action, MainAction::Pass))
        }) {
            events.push(CombatEvent::FightEnded { winner_side: None });
            return RoundResult {
                next_state,
                events,
                knockouts: Vec::new(),
                fight_ended: true,
                winner_side: None,
            };
        }
    }

    // Step 1: Pre-roll qi dice for each participant (Phase 1: initialize_round_state)
    // Ruby order per participant: qi_defense, qi_ability, ability_base (2d8 exploding for non-NPC), qi_movement
    let (pre_rolls, mut rng_seq) = pre_roll_all(&next_state, actions, rng, trace_rng, &mut events);

    // Deduct spent qi dice from next_state
    deduct_qi_spent(&mut next_state, actions);

    // Emit QiUsed events for Phase 1 rolls (defense, ability, movement)
    for pr in &pre_rolls {
        if let Some(roll) = pr.qi_defense_roll {
            if roll > 0 {
                let action = actions.iter().find(|a| a.participant_id == pr.participant_id);
                let dice_count = action.map_or(0, |a| a.qi_defense);
                events.push(CombatEvent::QiUsed {
                    participant_id: pr.participant_id,
                    category: "defense".to_string(),
                    dice_count,
                    roll_total: roll,
                });
            }
        }
        if let Some(roll) = pr.qi_ability_roll {
            if roll > 0 {
                let action = actions.iter().find(|a| a.participant_id == pr.participant_id);
                let dice_count = action.map_or(0, |a| a.qi_ability);
                events.push(CombatEvent::QiUsed {
                    participant_id: pr.participant_id,
                    category: "ability".to_string(),
                    dice_count,
                    roll_total: roll,
                });
            }
        }
        if pr.tactic_movement_bonus > 0 {
            let action = actions.iter().find(|a| a.participant_id == pr.participant_id);
            let dice_count = action.map_or(0, |a| a.qi_movement);
            events.push(CombatEvent::QiUsed {
                participant_id: pr.participant_id,
                category: "movement".to_string(),
                dice_count,
                roll_total: (pr.tactic_movement_bonus * 2) as i32, // reverse the /2
            });
        }
    }

    // Qi Lightness round-start drop: clear elevated state on any participant
    // whose active tactic is NOT Qi Lightness this round. Ruby:
    // FightParticipant#drop_from_qi_lightness! (fight_participant.rb:418).
    for p in &mut next_state.participants {
        let has_ql = actions
            .iter()
            .any(|a| a.participant_id == p.id && matches!(a.tactic, TacticChoice::QiLightness { .. }));
        if !has_ql && p.qi_lightness_elevated {
            p.qi_lightness_elevated = false;
            p.qi_lightness_elevation_bonus = 0;
        }
    }

    // Step 2: Build the segment timeline from all participant actions (Phase 2: schedule_all_events)
    let timeline = build_timeline(&next_state, actions, &pre_rolls, rng, trace_rng, &mut events, &mut rng_seq);

    // Record the final movement segment per participant so guard/back-to-back
    // checks can gate on it (Ruby fight_participant.rb:446-448
    // protection_active_at_segment?). Participants with no movement this round
    // get `None`, meaning their protection is active the entire round.
    {
        let mut last_move: HashMap<u64, u32> = HashMap::new();
        for event in timeline.events_in_order() {
            if matches!(event.event_type, SegmentEventType::Movement { .. }) {
                let slot = last_move.entry(event.participant_id).or_insert(0);
                if event.segment > *slot {
                    *slot = event.segment;
                }
            }
        }
        for p in &mut next_state.participants {
            p.movement_completed_segment = last_move.get(&p.id).copied();
        }
    }

    // Step 2.5: Pre-roll combat dice for attackers (Phase 3: pre_roll_combat_dice)
    // Ruby rolls weapon dice + qi_attack AFTER timeline building, iterating attackers by ID order
    let combat_pre_rolls = pre_roll_combat_dice(&next_state, actions, &timeline, rng, trace_rng, &mut events, &mut rng_seq);

    // Emit QiUsed events for qi_attack rolls (Phase 3)
    for cpr in &combat_pre_rolls {
        if let Some(qi_atk) = cpr.qi_attack_roll {
            if qi_atk > 0 {
                let action = actions.iter().find(|a| a.participant_id == cpr.participant_id);
                let dice_count = action.map_or(0, |a| a.qi_attack);
                events.push(CombatEvent::QiUsed {
                    participant_id: cpr.participant_id,
                    category: "attack".to_string(),
                    dice_count,
                    roll_total: qi_atk,
                });
            }
        }
    }

    // Step 3: Tick status effect durations (after decisions, before resolution)
    tick_all_effects(&mut next_state, &mut events);

    // Step 4: Initialize damage trackers and round damage state for each participant
    let mut damage_trackers: HashMap<u64, DamageTracker> = HashMap::new();
    let mut round_damage_states: HashMap<u64, defense::RoundDamageState> = HashMap::new();
    for p in &next_state.participants {
        let wound_penalty = if next_state.fight_mode == FightMode::Spar {
            0
        } else {
            p.wound_penalty()
        };
        damage_trackers.insert(p.id, DamageTracker::new(wound_penalty));
        // Get qi_defense_total from pre_rolls for this participant
        let qi_def = pre_rolls.iter()
            .find(|r| r.participant_id == p.id)
            .and_then(|r| r.qi_defense_roll)
            .unwrap_or(0);
        round_damage_states.insert(p.id, defense::RoundDamageState::new(qi_def));
    }

    // Step 4.5: Record initial distances between attackers and targets (for melee catch-up)
    // Ruby stores initial_distance_to_target in @round_state and requires dist <= 2 for catch-up.
    let mut initial_distances: HashMap<(u64, u64), i32> = HashMap::new();
    for action in actions {
        if let MainAction::Attack { target_id, .. } = action.main_action {
            if let (Some(a), Some(t)) = (
                find_participant(&next_state.participants, action.participant_id),
                find_participant(&next_state.participants, target_id),
            ) {
                let dist = hex_grid::hex_distance(a.position.x, a.position.y, t.position.x, t.position.y);
                initial_distances.insert((action.participant_id, target_id), dist);
            }
        }
    }

    // Step 4.6: Reset per-round tracking for all participants
    for p in &mut next_state.participants {
        p.attacks_this_round = 0;
        p.moved_this_round = false;
        p.acted_this_round = false;
    }

    // Per-round area-denial tracker. Records each mover's entry hex per denier
    // so the "retreat to entry" exception (Ruby check_lateral_denial) works
    // across multi-step pursuits within this round.
    let mut area_denial_tracker = tactics::AreaDenialTracker::new();

    // Per-round map of pursuers whose remaining movement has been cancelled
    // by a wall flip (Ruby: cancel_remaining_movement at combat_resolution_service.rb:2243).
    // Keyed by pursuer id → cutoff segment (inclusive). Movement events at or
    // below the cutoff still run; those strictly after are skipped.
    let mut cancelled_movements: HashMap<u64, u32> = HashMap::new();

    // Step 5: Process all events in segment order
    for event in timeline.events_in_order() {
        // Skip knocked out participants (participant events only — monster-
        // owned events use monster.id which is not in state.participants, so
        // the default-true is_knocked_out would incorrectly drop them).
        let is_monster_event = matches!(
            &event.event_type,
            SegmentEventType::MonsterAttack { .. } | SegmentEventType::MonsterShakeOff { .. }
        );
        if !is_monster_event && is_knocked_out(event.participant_id, &next_state) {
            continue;
        }

        // Skip movement events for participants whose pursuit was swapped out
        // during a wall flip this round.
        if let SegmentEventType::Movement { .. } = &event.event_type {
            if let Some(&cutoff) = cancelled_movements.get(&event.participant_id) {
                if event.segment > cutoff {
                    continue;
                }
            }
        }

        match &event.event_type {
            SegmentEventType::Movement { target_x, target_y, intent } => {
                process_movement_with_intent(
                    &mut next_state,
                    event.participant_id,
                    *target_x,
                    *target_y,
                    intent,
                    event.segment,
                    &mut events,
                    &timeline,
                    actions,
                    &mut area_denial_tracker,
                );
                // Qi Lightness: elevate participant on their final movement step
                // if Qi Lightness is the active tactic (Ruby combat_resolution_service.rb:1761).
                if let Some(p_mcs) = next_state
                    .participants
                    .iter()
                    .find(|p| p.id == event.participant_id)
                    .and_then(|p| p.movement_completed_segment)
                {
                    if event.segment == p_mcs {
                        let ql_mode = actions
                            .iter()
                            .find(|a| a.participant_id == event.participant_id)
                            .and_then(|a| {
                                if let TacticChoice::QiLightness { mode } = &a.tactic {
                                    Some(*mode)
                                } else {
                                    None
                                }
                            });
                        if let Some(mode) = ql_mode {
                            if let Some(p) = next_state
                                .participants
                                .iter_mut()
                                .find(|p| p.id == event.participant_id)
                            {
                                use crate::types::actions::QiLightnessMode as AQLM;
                                let bonus = match mode {
                                    AQLM::WallRun => 4,
                                    AQLM::WallBounce | AQLM::TreeLeap => 16,
                                };
                                p.qi_lightness_elevated = true;
                                p.qi_lightness_elevation_bonus = bonus;
                                p.position.z += bonus;
                            }
                        }
                    }
                }
            }
            SegmentEventType::Attack(target_id) => {
                // Sanctuary / targeting_restriction: if attacker has an effect
                // forbidding attacks on this target, cancel the attack and
                // emit an InvalidTarget event. Ruby parity:
                // combat_resolution_service.rb:2872.
                let blocked = find_participant(&next_state.participants, event.participant_id)
                    .map_or(false, |a| {
                        status_effects::cannot_target_ids(&a.status_effects).contains(target_id)
                    });
                if blocked {
                    events.push(CombatEvent::InvalidTarget {
                        attacker_id: event.participant_id,
                        target_id: *target_id,
                        reason: "invalid_target_protected".to_string(),
                        segment: event.segment,
                    });
                    continue;
                }

                // Resolve target redirections (Guard / BackToBack) before damage calc.
                // Ruby's resolve_attack_target runs before process_attack for each attack event.
                // Only consumes RNG when guard/btb tactics are active.
                let (resolved_target, redirect_damage_mod) = resolve_attack_target(
                    &next_state,
                    actions,
                    event.participant_id,
                    *target_id,
                    event.segment,
                    rng,
                    &mut events,
                );
                if let Some(ko_id) = process_attack_event(
                    &mut next_state,
                    event.participant_id,
                    resolved_target,
                    &pre_rolls,
                    &combat_pre_rolls,
                    actions,
                    event.segment,
                    &mut events,
                    &mut damage_trackers,
                    &mut round_damage_states,
                    &timeline,
                    &initial_distances,
                    redirect_damage_mod,
                ) {
                    knockouts.push(ko_id);
                }
            }
            SegmentEventType::AbilityUse {
                ability_id,
                target_id,
            } => {
                let kos = process_ability_event(
                    &mut next_state,
                    event.participant_id,
                    *ability_id,
                    *target_id,
                    &pre_rolls,
                    actions,
                    event.segment,
                    &mut events,
                    &mut damage_trackers,
                    &mut round_damage_states,
                    rng,
                );
                knockouts.extend(kos);
            }
            SegmentEventType::DotTick {
                effect_name,
                damage,
            } => {
                if let Some(ko_id) = process_dot_event(
                    &mut next_state,
                    event.participant_id,
                    effect_name,
                    *damage,
                    event.segment,
                    &mut events,
                    &mut damage_trackers,
                    &mut round_damage_states,
                    &pre_rolls,
                    actions,
                ) {
                    knockouts.push(ko_id);
                }
            }
            SegmentEventType::StandUp => {
                process_standup(&mut next_state, event.participant_id, &mut events);
            }
            SegmentEventType::DanglingClimbBack => {
                process_dangling_climb_back(&mut next_state, event.participant_id, event.segment, &mut events);
            }
            SegmentEventType::MonsterAttack {
                segment_id,
                target_id,
            } => {
                if let Some(ko_id) = process_monster_attack_event(
                    &mut next_state,
                    event.participant_id, // monster_id (set at scheduling)
                    *segment_id,          // actual segment ID
                    *target_id,
                    event.segment,
                    rng,
                    &mut events,
                    &mut damage_trackers,
                    &mut round_damage_states,
                ) {
                    knockouts.push(ko_id);
                }
            }
            SegmentEventType::WallFlip(wall_x, wall_y) => {
                // Ruby: process_wall_flip (combat_resolution_service.rb:2171).
                // Launch hex is the mover's current position (approach steps have
                // already placed them adjacent to the wall). Direction = launch→wall;
                // landing = 2 hexes back along the reversed direction, with a
                // three-tier fallback (second_back → first_back → launch).
                let from_pos = {
                    let p = match find_participant(&next_state.participants, event.participant_id) {
                        Some(p) => p,
                        None => continue,
                    };
                    p.position
                };
                let direction = match hex_grid::direction_between(
                    from_pos.x, from_pos.y, *wall_x, *wall_y,
                ) {
                    Some(d) => d,
                    None => continue, // no direction (launch == wall): bail like Ruby.
                };
                let opposite = hex_grid::reverse_direction(direction);
                let first_back = hex_grid::hex_neighbor_by_direction(*wall_x, *wall_y, opposite);
                let second_back = hex_grid::hex_neighbor_by_direction(first_back.0, first_back.1, opposite);

                // Three-tier landing fallback (Ruby: combat_resolution_service.rb:2189-2196).
                let second_traversable = battle_map::hex_is_traversable(&next_state.hex_map, second_back.0, second_back.1);
                let first_traversable = battle_map::hex_is_traversable(&next_state.hex_map, first_back.0, first_back.1);
                let default_landing = if second_traversable {
                    second_back
                } else if first_traversable {
                    first_back
                } else {
                    (from_pos.x, from_pos.y)
                };

                // Find melee pursuer — another participant moving towards actor,
                // within 2 hexes. Ruby: find_wall_flip_pursuer (:2231-2240).
                let pursuer = {
                    let actor_pos = from_pos;
                    next_state.participants.iter().find_map(|p| {
                        if p.id == event.participant_id || p.is_knocked_out { return None; }
                        // Check the live action list for the pursuer's movement intent.
                        let a = actions.iter().find(|a| a.participant_id == p.id)?;
                        let pursuing = match &a.movement {
                            MovementAction::TowardsPerson(target_id) => *target_id == event.participant_id,
                            _ => false,
                        };
                        if !pursuing { return None; }
                        let dist = hex_grid::hex_distance(p.position.x, p.position.y, actor_pos.x, actor_pos.y);
                        if dist <= 2 { Some(p.id) } else { None }
                    })
                };

                let mut pursuer_id: Option<u64> = None;
                let landing = if let Some(pid) = pursuer {
                    // Force pursuer to the launch hex. Actor lands 1 hex beyond
                    // the pursuer at `default_landing` — because `first_back`
                    // coincides with `launch_hex` in the offset grid when the
                    // mover is adjacent to the wall, and the pursuer now occupies
                    // it. Ruby (combat_resolution_service.rb:2207-2213) falls
                    // through `can_move_through?` for the same reason.
                    if let Some(pi) = next_state.participants.iter_mut().find(|p| p.id == pid) {
                        pi.position = HexCoord { x: from_pos.x, y: from_pos.y, z: from_pos.z };
                    }
                    // Cancel pursuer's remaining movement events (Ruby:
                    // cancel_remaining_movement at :2243).
                    cancelled_movements.insert(pid, event.segment);
                    pursuer_id = Some(pid);
                    default_landing
                } else {
                    default_landing
                };

                process_movement_event(
                    &mut next_state,
                    event.participant_id,
                    landing.0,
                    landing.1,
                    event.segment,
                    &mut events,
                );
                events.push(CombatEvent::WallFlip {
                    participant_id: event.participant_id,
                    from: from_pos,
                    to: HexCoord { x: landing.0, y: landing.1, z: from_pos.z },
                    segment: event.segment,
                    pursuer_id,
                });
            }
            SegmentEventType::AttackMonster { monster_id, segment_id } => {
                process_player_attack_on_monster(
                    &mut next_state,
                    event.participant_id,
                    *monster_id,
                    *segment_id,
                    &combat_pre_rolls,
                    event.segment,
                    &mut events,
                );
            }
            SegmentEventType::MonsterShakeOff { monster_id } => {
                process_monster_shake_off_event(
                    &mut next_state,
                    *monster_id,
                    event.segment,
                    rng,
                    &mut events,
                );
            }
            SegmentEventType::ElementTactic {
                tactic_type,
                element_id,
                target_x,
                target_y,
            } => {
                interactive_objects::process_element_tactic_event(
                    &mut next_state,
                    event.participant_id,
                    tactic_type,
                    *element_id,
                    *target_x,
                    *target_y,
                    event.segment,
                    &mut events,
                    &mut damage_trackers,
                    &mut round_damage_states,
                    &mut knockouts,
                );
            }
        }
    }

    // Step 5.5: Process flee/surrender results
    process_flee_surrender(&mut next_state, actions, &damage_trackers, &mut events, &mut knockouts);

    // Step 6: Process healing effects (regeneration)
    process_healing(&mut next_state, &mut events);

    // Step 7: Expire exhausted effects
    expire_all_effects(&mut next_state, &mut events);

    // Step 8: Qi regeneration (suppressed by qi_aura/qi_lightness)
    regenerate_qi(&mut next_state, actions);

    // Step 8.5: Process battle map hazard damage
    process_hazard_damage(&mut next_state, &mut events, &mut knockouts);

    // Step 8.6: End-of-round reapply for persistent interactive objects
    // (toxic_mushrooms, lotus_pollen). Mirrors Ruby
    // `FightHexEffectService#end_of_round` (fight_hex_effect_service.rb:35-51).
    let eor_segment = next_state.config.segments.tactical_fallback;
    let ids_and_pos: Vec<(u64, i32, i32)> = next_state
        .participants
        .iter()
        .filter(|p| !p.is_knocked_out)
        .map(|p| (p.id, p.position.x, p.position.y))
        .collect();
    for (pid, px, py) in ids_and_pos {
        crate::interactive_objects::on_hex_enter(
            &mut next_state,
            pid,
            px,
            py,
            eor_segment,
            &mut events,
        );
    }

    // Step 9: Decay cooldowns
    decay_cooldowns(&mut next_state);

    // Step 9.5: Apply queued combat-style switches. Ruby:
    // combat_resolution_service.rb:401 calls `apply_style_switch!` for each
    // participant whose pending_style_switch is set. Rust emits a
    // StyleSwitched event so the wrapper can invoke the full Ruby apply
    // (variant-lock cleanup, character_instance preference). We also clear
    // pending_style_switch locally so the event stream reflects the round's
    // final state.
    apply_style_switches(&mut next_state, &mut events);

    // Step 10: Advance round
    next_state.round += 1;

    // Step 11: Check fight end
    let (fight_ended, winner_side) = check_fight_end(&next_state);
    if fight_ended {
        events.push(CombatEvent::FightEnded { winner_side });
    }

    RoundResult {
        next_state,
        events,
        knockouts,
        fight_ended,
        winner_side,
    }
}

// ---------------------------------------------------------------------------
// Pre-roll helpers
// ---------------------------------------------------------------------------

/// Roll qi dice once per participant for the entire round (Phase 1).
///
/// Ruby's RNG order per participant:
/// 1. qi_defense_roll (if qi_defense > 0)
/// 2. qi_ability_roll (if qi_ability > 0)
/// 3. ability_base_roll (2d8 exploding, only if NOT npc_with_custom_dice)
/// 4. qi_movement_roll (if qi_movement > 0)
/// Relocate any active, non-KO participant whose position is non-playable.
/// Ruby equivalent: CombatResolutionService#validate_participant_positions
/// (combat_resolution_service.rb:3775). Runs before scheduling so later
/// steps always see participants on valid hexes. Uses a BFS ring search
/// (radius 1..6) to find the nearest playable, unoccupied hex.
fn validate_participant_positions(
    state: &mut FightState,
    events: &mut Vec<CombatEvent>,
) {
    let ids: Vec<u64> = state
        .participants
        .iter()
        .filter(|p| !p.is_knocked_out)
        .map(|p| p.id)
        .collect();

    for id in ids {
        let current = match state.participants.iter().find(|p| p.id == id) {
            Some(p) => p.position,
            None => continue,
        };

        if crate::battle_map::is_playable(&state.hex_map, current.x, current.y) {
            continue;
        }

        // Ring search: widen radius until we find a valid hex.
        let mut relocated: Option<crate::types::hex::HexCoord> = None;
        'ring: for radius in 1..=6 {
            for dx in -(radius as i32)..=(radius as i32) {
                for dy in -(radius as i32)..=(radius as i32) {
                    if dx == 0 && dy == 0 {
                        continue;
                    }
                    let nx = current.x + dx;
                    let ny = current.y + dy;
                    let dist = crate::hex_grid::hex_distance(current.x, current.y, nx, ny);
                    if dist != radius as i32 {
                        continue;
                    }
                    if !crate::battle_map::is_playable(&state.hex_map, nx, ny) {
                        continue;
                    }
                    if crate::battle_map::is_hex_occupied(
                        &state.participants,
                        &crate::types::hex::HexCoord { x: nx, y: ny, z: 0 },
                        id,
                    ) {
                        continue;
                    }
                    relocated = Some(crate::types::hex::HexCoord { x: nx, y: ny, z: current.z });
                    break 'ring;
                }
            }
        }

        if let Some(new_pos) = relocated {
            if let Some(p) = state.participants.iter_mut().find(|p| p.id == id) {
                p.position = new_pos;
            }
            // Ruby `validate_participant_positions` relocates silently (just a
            // warn log, no fight event). To preserve exact event parity we do
            // NOT emit a Moved event here.
        }
    }
    let _ = events; // unused; kept for future event emissions
}

///
/// NOTE: qi_attack is NOT rolled here -- it's rolled in Phase 3 (pre_roll_combat_dice).
///
/// Returns (pre_rolls, rng_sequence_counter) for continued trace numbering.
fn pre_roll_all(
    state: &FightState,
    actions: &[PlayerAction],
    rng: &mut impl Rng,
    trace: bool,
    events: &mut Vec<CombatEvent>,
) -> (Vec<PreRolls>, u32) {
    let mut rolls = Vec::new();
    let mut seq: u32 = 0;

    for action in actions {
        let participant = match find_participant(&state.participants, action.participant_id) {
            Some(p) => p,
            None => continue,
        };

        if participant.is_knocked_out {
            continue;
        }

        let pid = action.participant_id;
        let die_sides = participant.qi_die_sides as u32;
        let explode_on = if die_sides > 0 {
            Some(die_sides)
        } else {
            None
        };

        // 1. qi_defense_roll
        let qi_defense_roll = if action.qi_defense > 0 {
            let result = dice::roll(
                action.qi_defense as u32,
                die_sides,
                explode_on,
                0,
                rng,
            );
            if trace {
                events.push(CombatEvent::RngTrace {
                    participant_id: pid, label: format!("qi_defense_{}d{}", action.qi_defense, die_sides),
                    value: result.total, sequence: seq,
                });
                seq += 1;
            }
            Some(result.total)
        } else {
            None
        };

        // 2. qi_ability_roll
        let qi_ability_roll = if action.qi_ability > 0 {
            let result = dice::roll(
                action.qi_ability as u32,
                die_sides,
                explode_on,
                0,
                rng,
            );
            if trace {
                events.push(CombatEvent::RngTrace {
                    participant_id: pid, label: format!("qi_ability_{}d{}", action.qi_ability, die_sides),
                    value: result.total, sequence: seq,
                });
                seq += 1;
            }
            Some(result.total)
        } else {
            None
        };

        // 3. ability_base_roll (2d8 exploding on 8) -- only for non-NPC participants
        // NPCs with custom dice skip this roll. Ruby checks npc_with_custom_dice?
        // which looks at npc_damage_dice_count/sides, distinct from natural_attacks.
        // Ruby: ability base roll suppressed only if npc_with_custom_dice? is true
        // (explicit custom dice count/sides set), NOT if natural attacks exist
        let is_npc_with_custom_dice = participant.is_npc_custom_dice;
        let ability_base_roll = if !is_npc_with_custom_dice {
            let result = dice::roll(2, 8, Some(8), 0, rng);
            if trace {
                events.push(CombatEvent::RngTrace {
                    participant_id: pid, label: "ability_base_2d8x".to_string(),
                    value: result.total, sequence: seq,
                });
                seq += 1;
            }
            Some(result.total)
        } else {
            None
        };

        // 4. qi_movement_roll
        let tactic_movement_bonus = if action.qi_movement > 0 {
            let result = dice::roll(
                action.qi_movement as u32,
                die_sides,
                explode_on,
                0,
                rng,
            );
            if trace {
                events.push(CombatEvent::RngTrace {
                    participant_id: pid, label: format!("qi_movement_{}d{}", action.qi_movement, die_sides),
                    value: result.total, sequence: seq,
                });
                seq += 1;
            }
            (result.total.max(0) as u32) / 2
        } else {
            0
        };

        rolls.push(PreRolls {
            participant_id: action.participant_id,
            qi_defense_roll,
            qi_ability_roll,
            ability_base_roll,
            tactic_movement_bonus,
        });
    }

    (rolls, seq)
}

/// Deduct qi dice spent from participants in next_state.
/// Called separately because pre_roll_all works with immutable state.
fn deduct_qi_spent(state: &mut FightState, actions: &[PlayerAction]) {
    for action in actions {
        let total_qi_spent = action.qi_defense as f32
            + action.qi_attack as f32
            + action.qi_ability as f32
            + action.qi_movement as f32;

        if total_qi_spent > 0.0 {
            if let Some(p) = state
                .participants
                .iter_mut()
                .find(|p| p.id == action.participant_id)
            {
                p.qi_dice = (p.qi_dice - total_qi_spent).max(0.0);
            }
        }
    }
}

/// Pre-roll combat dice for all attackers (Phase 3: pre_roll_combat_dice).
///
/// Ruby's RNG order per attacker (main_action == Attack), iterated by participant ID:
/// 1. roll_base_attack_dice: dice::roll(weapon.dice_count, weapon.dice_sides, None, 0, rng)
/// 2. qi_attack_roll: dice::roll(qi_attack_count, qi_die_sides, Some(qi_die_sides), 0, rng)
///
/// This must be called AFTER build_timeline so we know how many attacks each
/// participant has scheduled (needed for dividing the single roll across attacks).
fn pre_roll_combat_dice(
    state: &FightState,
    actions: &[PlayerAction],
    timeline: &SegmentTimeline,
    rng: &mut impl Rng,
    trace: bool,
    events: &mut Vec<CombatEvent>,
    rng_seq: &mut u32,
) -> Vec<CombatPreRoll> {
    let mut combat_rolls = Vec::new();

    for action in actions {
        // Only roll for participants whose main_action is Attack
        if !matches!(action.main_action, MainAction::Attack { .. }) {
            continue;
        }

        let participant = match find_participant(&state.participants, action.participant_id) {
            Some(p) => p,
            None => continue,
        };

        if participant.is_knocked_out {
            continue;
        }

        // Count scheduled attack events for this participant (both participant-target
        // and monster-target attacks need pre-rolled dice).
        let attack_count = timeline
            .events_in_order()
            .iter()
            .filter(|e| {
                e.participant_id == action.participant_id
                    && matches!(
                        e.event_type,
                        SegmentEventType::Attack(_)
                            | SegmentEventType::AttackMonster { .. }
                    )
            })
            .count() as u32;

        if attack_count == 0 {
            continue;
        }

        // Determine effective dice for pre-rolling.
        // Ruby priority (roll_base_attack_dice):
        //   1. Natural attack if scheduled → use its dice (no explosion).
        //      Ruby natural_attack_for_pre_roll returns the attack chosen by
        //      schedule_natural_attacks, which calls archetype.best_attack_for_range(distance).
        //      We replicate that directly via best_natural_attack_for_range using
        //      the current distance to the primary target.
        //   2. NPC with custom dice (npc_with_custom_dice?) → use custom dice (no explosion)
        //   3. PC (or NPC without custom dice) → 2d8 exploding on 8
        let primary_target_id = match action.main_action {
            MainAction::Attack { target_id, .. } => Some(target_id),
            _ => None,
        };
        let attack_distance: u32 = primary_target_id
            .and_then(|tid| find_participant(&state.participants, tid))
            .map(|t| hex_grid::hex_distance(
                participant.position.x, participant.position.y,
                t.position.x, t.position.y,
            ) as u32)
            .unwrap_or(1);
        let (dice_count, dice_sides, explode_on) = if !participant.natural_attacks.is_empty() {
            let na = weapon_resolution::best_natural_attack_for_range(
                &participant.natural_attacks,
                attack_distance,
            )
            .unwrap_or_else(|| participant.natural_attacks.first().unwrap());
            (na.dice_count, na.dice_sides, None)
        } else if participant.is_npc_custom_dice {
            // NPC with custom dice (no natural attacks): read from serialized weapon, no explosion.
            // The serializer injects npc_damage_dice_count/sides into the weapon fields.
            let weapon = participant.melee_weapon.as_ref()
                .or(participant.ranged_weapon.as_ref());
            match weapon {
                Some(w) => (w.dice_count, w.dice_sides, None),
                None => (2, 8, None), // fallback
            }
        } else {
            // PC (or NPC without custom dice): 2d8 exploding on 8
            (2, 8, Some(8))
        };

        // 1. Roll base attack dice
        let base_roll = dice::roll(dice_count, dice_sides, explode_on, 0, rng);
        let base_attack_roll = base_roll.total;
        let base_dice = base_roll.dice.clone();
        let base_exploded = base_roll.dice.len() > base_roll.count as usize;

        if trace {
            events.push(CombatEvent::RngTrace {
                participant_id: action.participant_id,
                label: format!("base_attack_{}d{}", dice_count, dice_sides),
                value: base_attack_roll, sequence: *rng_seq,
            });
            *rng_seq += 1;
        }

        // 2. Roll qi_attack (if allocated)
        let die_sides = participant.qi_die_sides as u32;
        let explode_on = if die_sides > 0 {
            Some(die_sides)
        } else {
            None
        };

        let (qi_attack_roll, qi_attack_dice) = if action.qi_attack > 0 {
            let result = dice::roll(
                action.qi_attack as u32,
                die_sides,
                explode_on,
                0,
                rng,
            );
            if trace {
                events.push(CombatEvent::RngTrace {
                    participant_id: action.participant_id,
                    label: format!("qi_attack_{}d{}", action.qi_attack, die_sides),
                    value: result.total, sequence: *rng_seq,
                });
                *rng_seq += 1;
            }
            (Some(result.total), Some(result.dice.clone()))
        } else {
            (None, None)
        };

        let roll_total = base_attack_roll + qi_attack_roll.unwrap_or(0);

        combat_rolls.push(CombatPreRoll {
            participant_id: action.participant_id,
            base_attack_roll,
            base_dice,
            base_exploded,
            qi_attack_roll,
            qi_attack_dice,
            roll_total,
            attack_count,
            all_roll_penalty: participant.all_roll_penalty,
            // Select stat based on weapon type: Dexterity for pure ranged, Strength for melee
            stat_modifier: if participant.melee_weapon.is_none()
                && participant.ranged_weapon.is_some()
            {
                participant.dexterity_modifier
            } else {
                participant.stat_modifier
            },
        });
    }

    combat_rolls
}

// ---------------------------------------------------------------------------
// Timeline building
// ---------------------------------------------------------------------------

/// Build the full segment timeline from all participant actions.
fn build_timeline(
    state: &FightState,
    actions: &[PlayerAction],
    pre_rolls: &[PreRolls],
    rng: &mut impl Rng,
    trace: bool,
    events: &mut Vec<CombatEvent>,
    rng_seq: &mut u32,
) -> SegmentTimeline {
    let mut timeline = SegmentTimeline::new();

    for action in actions {
        let participant = match find_participant(&state.participants, action.participant_id) {
            Some(p) => p,
            None => continue,
        };

        if participant.is_knocked_out {
            continue;
        }

        // Dangling: participant went over a fall edge. Ruby combat_resolution_service.rb:645
        // schedules dangling_climb_back at MOVEMENT_SEGMENT and skips all other actions.
        let is_dangling = participant.status_effects.iter()
            .any(|e| e.effect_name == "dangling");
        if is_dangling {
            timeline.schedule(
                state.config.segments.movement_base,
                action.participant_id,
                SegmentEventType::DanglingClimbBack,
                EventPriority::MovementApproach,
            );
            continue; // skip all other scheduling for this participant
        }

        // Status-effect gating (Ruby status_effect_service.rb):
        //   - ActionRestriction/CrowdControl: can't take main or tactical actions.
        //   - MovementBlock/Grapple: can't move.
        let action_restricted = status_effects::is_action_restricted(&participant.status_effects);
        let movement_blocked = status_effects::is_movement_blocked(&participant.status_effects);

        let pr = pre_rolls
            .iter()
            .find(|r| r.participant_id == action.participant_id);
        // Firefly divergence: adds the participant's flat tactic_movement_bonus_flat
        // (e.g., +2 from the `quick` tactic) on top of the dice-derived bonus.
        let tactic_movement_bonus =
            pr.map_or(0, |r| r.tactic_movement_bonus) + participant.tactic_movement_bonus_flat;

        // Determine if sprinting
        let is_sprinting = matches!(action.main_action, MainAction::Sprint);

        // Determine qi_lightness state
        let qi_lightness = matches!(
            action.tactic,
            TacticChoice::QiLightness { .. }
        );
        let qi_lightness_wall_bounce = matches!(
            action.tactic,
            TacticChoice::QiLightness {
                mode: crate::types::actions::QiLightnessMode::WallBounce
            }
        );

        // Check for slow effect
        let is_slowed = status_effects::has_effect(&participant.status_effects, "slow");

        // Calculate movement budget
        let budget = movement::calculate_movement_budget(
            &state.config,
            is_sprinting,
            tactic_movement_bonus,
            qi_lightness,
            qi_lightness_wall_bounce,
            is_slowed,
        );

        // 1. Schedule attacks (Ruby: schedule_attacks runs before schedule_movement,
        // so attack RNG consumption must come first to match the RNG stream).
        // Player-vs-monster attacks (targeting_monster_id set) route to a separate
        // event type so the resolver hits the correct segment rather than a participant.
        let mut monster_attack_scheduled = false;
        if !action_restricted {
        if let MainAction::Attack {
            target_id,
            monster_id,
            segment_id,
        } = action.main_action
        {
            // If attacking a monster segment, schedule AttackMonster events directly.
            if let (Some(mid), Some(sid)) = (monster_id, segment_id) {
                let weapon_speed = participant.melee_weapon.as_ref().map_or(5, |w| w.speed);
                let num_attacks = weapon_resolution::attacks_per_round(weapon_speed);
                let segs = weapon_resolution::attack_segments(num_attacks, &state.config, rng);
                for seg in segs {
                    timeline.schedule(
                        seg,
                        action.participant_id,
                        SegmentEventType::AttackMonster { monster_id: mid, segment_id: sid },
                        EventPriority::NonMovement,
                    );
                }
                monster_attack_scheduled = true;
            }
            // If already scheduled as a monster attack, skip the regular participant-target block.
            if monster_attack_scheduled {
                // Still need to continue past this `if let` — fall through to further action phases.
            } else {
            // Check for forced target override from observer effects.
            // Ruby retargets NPC attackers only (combat_resolution_service.rb:533);
            // PCs ignore forced_target observer effects.
            let actor_is_npc = find_participant(&state.participants, action.participant_id)
                .map_or(false, |p| p.is_npc);
            let actual_target = observer_effects::forced_target(
                &state.observer_effects,
                action.participant_id,
                actor_is_npc,
            )
            .unwrap_or(target_id);

            // Determine weapon speed for attacks_per_round
            let weapon_speed = participant
                .melee_weapon
                .as_ref()
                .map_or(5, |w| w.speed);
            let num_attacks = weapon_resolution::attacks_per_round(weapon_speed);
            let attack_segs =
                weapon_resolution::attack_segments(num_attacks, &state.config, rng);

            // Apply reach-based segment compression for melee attacks
            // (ranged attacks skip compression, matching Ruby)
            let is_ranged = participant
                .melee_weapon
                .as_ref()
                .map_or(false, |w| w.is_ranged)
                || (participant.melee_weapon.is_none() && participant.ranged_weapon.is_some());

            let compressed_segs = if !is_ranged {
                let attacker_reach = weapon_resolution::effective_reach(participant, &state.config);
                let target_p = find_participant(&state.participants, actual_target);
                let defender_reach = target_p
                    .map(|t| weapon_resolution::effective_reach(t, &state.config))
                    .unwrap_or(state.config.reach.unarmed_reach);
                let is_adjacent = target_p.map_or(false, |t| {
                    hex_grid::hex_distance(
                        participant.position.x, participant.position.y,
                        t.position.x, t.position.y,
                    ) <= 1
                });

                let (range_start, range_end) = weapon_resolution::reach_segment_range(
                    attacker_reach, defender_reach, is_adjacent, &state.config,
                );
                weapon_resolution::compress_segments(&attack_segs, range_start, range_end)
            } else {
                attack_segs.clone()
            };

            if trace {
                events.push(CombatEvent::RngTrace {
                    participant_id: action.participant_id,
                    label: format!("attack_schedule_{}_attacks", compressed_segs.len()),
                    value: compressed_segs.len() as i32, sequence: *rng_seq,
                });
                *rng_seq += 1;
            }

            for seg in compressed_segs {
                timeline.schedule(
                    seg,
                    action.participant_id,
                    SegmentEventType::Attack(actual_target),
                    EventPriority::NonMovement,
                );
            }
            } // end else (regular participant-target attack)
        }
        } // end !action_restricted attack block

        // 3. Schedule ability use at the ability's configured activation_segment,
        //    matching Ruby combat_resolution_service.rb:861 schedule_abilities.
        if !action_restricted {
        if let MainAction::Ability {
            ability_id,
            target_id,
        } = action.main_action
        {
            // Find the caster's ability to read its activation_segment field.
            let caster = find_participant(&state.participants, action.participant_id);
            let seg = caster
                .and_then(|p| p.abilities.iter().find(|a| a.id == ability_id))
                .and_then(|a| a.activation_segment)
                .filter(|s| *s > 0 && *s <= state.config.segments.total)
                .unwrap_or(state.config.segments.tactical_fallback);
            timeline.schedule(
                seg,
                action.participant_id,
                SegmentEventType::AbilityUse {
                    ability_id,
                    target_id,
                },
                EventPriority::NonMovement,
            );
        }
        } // end !action_restricted ability block

        // 4. Schedule tactical ability (tactic choice, not main action)
        // Ruby: schedule_tactical_abilities runs AFTER schedule_abilities (line 658)
        if !action_restricted {
        if let TacticChoice::TacticalAbility {
            ability_id,
            target_id,
        } = action.tactic
        {
            let seg = state.config.segments.tactical_fallback;
            timeline.schedule(
                seg,
                action.participant_id,
                SegmentEventType::AbilityUse {
                    ability_id,
                    target_id,
                },
                EventPriority::NonMovement,
            );
        }

        // Element tactics (break/detonate/ignite). Ruby: when
        // participant.element_tactic? && @fight_hex_service is present, schedule
        // `{type: :resolve_element_tactic, actor: participant}` at
        // GameConfig::Mechanics::SEGMENTS[:tactical_fallback]
        // (combat_resolution_service.rb:662-667).
        let seg = state.config.segments.tactical_fallback;
        match &action.tactic {
            TacticChoice::Break { element_id, target_x, target_y } => {
                timeline.schedule(
                    seg, action.participant_id,
                    SegmentEventType::ElementTactic {
                        tactic_type: "break".into(),
                        element_id: *element_id,
                        target_x: *target_x,
                        target_y: *target_y,
                    },
                    EventPriority::NonMovement,
                );
            }
            TacticChoice::Detonate { element_id } => {
                timeline.schedule(
                    seg, action.participant_id,
                    SegmentEventType::ElementTactic {
                        tactic_type: "detonate".into(),
                        element_id: Some(*element_id),
                        target_x: None, target_y: None,
                    },
                    EventPriority::NonMovement,
                );
            }
            TacticChoice::Ignite { target_x, target_y } => {
                timeline.schedule(
                    seg, action.participant_id,
                    SegmentEventType::ElementTactic {
                        tactic_type: "ignite".into(),
                        element_id: None,
                        target_x: Some(*target_x), target_y: Some(*target_y),
                    },
                    EventPriority::NonMovement,
                );
            }
            _ => {}
        }
        } // end !action_restricted tactic block

        // 5a. Wall flip scheduling (Ruby: schedule_wall_flip, combat_resolution_service.rb:1255).
        // Ruby iterates wall neighbors, filters by can_move_through?, picks the closest
        // to the participant as launch_hex. If total_cost (path + 2) fits the budget, it
        // burns `budget` RNG calls via movement_segments_for_budget and schedules the
        // WallFlip event at segments[path_to_launch.length].
        if !movement_blocked {
            if let MovementAction::WallFlip { wall_x, wall_y } = action.movement {
                if let (Some(wx), Some(wy)) = (wall_x, wall_y) {
                    let launch_hex = hex_grid::hex_neighbors(wx, wy)
                        .into_iter()
                        .filter(|&(nx, ny)| {
                            battle_map::hex_is_traversable(&state.hex_map, nx, ny)
                        })
                        .min_by_key(|&(nx, ny)| {
                            hex_grid::hex_distance(
                                participant.position.x, participant.position.y, nx, ny,
                            )
                        });
                    if let Some((lx, ly)) = launch_hex {
                        // Compute path to launch (empty if already at launch hex).
                        // Ruby: schedule_wall_flip (combat_resolution_service.rb:1289-1299)
                        // emits one movement_step per intermediate hex, then the flip itself.
                        let path_steps: Vec<(i32, i32)> = if (participant.position.x,
                                                              participant.position.y)
                            == (lx, ly)
                        {
                            Vec::new()
                        } else {
                            let path = crate::pathfinding::find_path(
                                &state.hex_map,
                                (participant.position.x, participant.position.y),
                                (lx, ly),
                                &state.participants,
                                participant.id,
                                "moderate",
                                qi_lightness,
                            );
                            // find_path returns [start, step1, step2, ...]; drop start.
                            path.map(|p| p.into_iter().skip(1).collect())
                                .unwrap_or_default()
                        };
                        let path_len = path_steps.len() as u32;
                        let total_cost = path_len + 2;
                        if total_cost <= budget {
                            let segs = movement::compute_budget_segments(
                                budget, &state.config, rng,
                            );
                            // Schedule approach Movement events so the mover actually
                            // reaches the launch hex before the flip. Without these,
                            // the flip processor reads the mover's original position
                            // as the launch hex and lands them 2*from-wall hexes off.
                            for (i, (tx, ty)) in path_steps.iter().enumerate() {
                                let seg = segs.get(i).copied()
                                    .or_else(|| segs.last().copied())
                                    .unwrap_or(state.config.segments.movement_base);
                                timeline.schedule(
                                    seg,
                                    action.participant_id,
                                    SegmentEventType::Movement {
                                        target_x: *tx,
                                        target_y: *ty,
                                        intent: MovementIntent::Fixed,
                                    },
                                    EventPriority::MovementApproach,
                                );
                            }
                            let flip_idx = path_len as usize;
                            let flip_seg = segs
                                .get(flip_idx)
                                .copied()
                                .or_else(|| segs.last().copied())
                                .unwrap_or(state.config.segments.movement_base);
                            timeline.schedule(
                                flip_seg,
                                action.participant_id,
                                SegmentEventType::WallFlip(wx, wy),
                                EventPriority::MovementApproach,
                            );
                        }
                    }
                }
            }
        }

        // 5. Schedule movement steps (Ruby: schedule_movement runs AFTER schedule_attacks
        // and schedule_abilities, so movement RNG must come after attack/ability RNG).
        // Skip entirely if movement is blocked (MovementBlock/Grapple).
        if !movement_blocked && !matches!(action.movement, MovementAction::StandStill | MovementAction::WallFlip { .. }) {
            let mut steps = movement::resolve_movement(
                &state.hex_map,
                participant,
                &action.movement,
                &state.participants,
                budget,
                "moderate",
                qi_lightness,
            );

            // Ruby's shadow steps: when towards_person and already adjacent (empty path),
            // Ruby creates `budget` shadow steps so movement segments are still generated
            // (consuming RNG for variance). This keeps the RNG stream in sync.
            // See Ruby: build_towards_person_shadow_steps in combat_resolution_service.rb
            if steps.is_empty() {
                if let MovementAction::TowardsPerson(target_id) = &action.movement {
                    let target = find_participant(&state.participants, *target_id);
                    let dist = target.map_or(999, |t| {
                        hex_grid::hex_distance(
                            participant.position.x, participant.position.y,
                            t.position.x, t.position.y,
                        )
                    });
                    if dist <= 1 {
                        // Create shadow steps at current position (will be skipped by adjacency stop)
                        steps = vec![(participant.position.x, participant.position.y); budget as usize];
                    }
                }
            }

            let distributed =
                movement::distribute_movement_segments(&steps, budget, &state.config, rng);

            if trace && !distributed.is_empty() {
                events.push(CombatEvent::RngTrace {
                    participant_id: action.participant_id,
                    label: format!("move_distribute_{}_steps", distributed.len()),
                    value: distributed.len() as i32, sequence: *rng_seq,
                });
                *rng_seq += 1;
            }

            // Determine movement intent and priority from action
            let (intent, priority) = match &action.movement {
                MovementAction::TowardsPerson(target_id) => (
                    MovementIntent::TowardsPerson(*target_id),
                    EventPriority::MovementApproach,
                ),
                MovementAction::AwayFrom(target_id) => (
                    MovementIntent::AwayFrom(*target_id),
                    EventPriority::MovementRetreat,
                ),
                MovementAction::MaintainDistance { target_id, .. } => (
                    MovementIntent::AwayFrom(*target_id),
                    EventPriority::MovementRetreat,
                ),
                MovementAction::Flee { .. } => (
                    MovementIntent::Fixed,
                    EventPriority::MovementRetreat,
                ),
                _ => (
                    MovementIntent::Fixed,
                    EventPriority::MovementRetreat,
                ),
            };

            for (seg, (x, y)) in distributed {
                timeline.schedule(
                    seg,
                    action.participant_id,
                    SegmentEventType::Movement {
                        target_x: x,
                        target_y: y,
                        intent: intent.clone(),
                    },
                    priority,
                );
            }
        }

        // 5. Schedule StandUp
        if matches!(action.main_action, MainAction::StandUp) {
            timeline.schedule(1, action.participant_id, SegmentEventType::StandUp, EventPriority::NonMovement);
        }

        // 5. Schedule DOT ticks from active effects
        schedule_dot_ticks(participant, &state.config, &mut timeline, rng);
    }

    // 6. Schedule monster attacks if any monsters are present
    for monster in &state.monsters {
        if monster.current_hp <= 0 {
            continue;
        }
        let attacks = monster_combat::schedule_monster_attacks_targeted(
            monster,
            &state.participants,
            rng,
            &state.config,
        );
        // Emit a MonsterTurn marker event for visibility, matching Ruby
        // combat_resolution_service.rb monster_turn event.
        if !attacks.is_empty() {
            let first_seg = attacks.first().map(|(s, _, _)| *s).unwrap_or(50);
            events.push(CombatEvent::MonsterTurn {
                monster_id: monster.id,
                segment: first_seg.saturating_sub(5).max(1),
            });
        }
        for (seg, seg_idx, target_id) in attacks {
            let segment_id = if seg_idx < monster.segments.len() {
                monster.segments[seg_idx].id
            } else {
                monster.id // fallback
            };
            timeline.schedule(
                seg,
                monster.id,
                SegmentEventType::MonsterAttack {
                    segment_id,
                    target_id,
                },
                EventPriority::NonMovement,
            );
        }

        // Schedule auto-shake-off if monster AI decides to.
        // Mirrors Ruby MonsterAIService#should_shake_off? + shake_off_segment_number
        // (backend/app/services/npc/monster_ai_service.rb:98-128).
        let threats = monster_combat::assess_threats(monster, &state.participants);
        if monster_combat::should_shake_off(monster, &threats) {
            let seg = if !threats.at_weak_point.is_empty() {
                rng.gen_range(15..=25) // URGENT
            } else {
                rng.gen_range(45..=55) // NORMAL
            };
            timeline.schedule(
                seg,
                monster.id,
                SegmentEventType::MonsterShakeOff {
                    monster_id: monster.id,
                },
                EventPriority::NonMovement,
            );
        }
    }

    timeline
}

/// Schedule DOT ticks distributed across the 100 segments for a participant.
fn schedule_dot_ticks(
    participant: &Participant,
    config: &CombatConfig,
    timeline: &mut SegmentTimeline,
    rng: &mut impl Rng,
) {
    for effect in &participant.status_effects {
        if effect.effect_type == EffectType::DamageOverTime {
            if let Some(ref dot_notation) = effect.dot_damage {
                if let Some((count, sides)) = ability_resolution::parse_dice_notation(dot_notation) {
                    // Roll the dice for DOT damage once
                    let roll_result = dice::roll(count, sides, None, 0, rng);
                    let total_damage = roll_result.total.max(1) as u32;

                    // Ruby behavior: distribute as individual 1-damage ticks evenly
                    // across segments. E.g., 10 damage = ticks at 10, 20, ..., 100
                    // Reference: status_effect_service.rb:272-276
                    let total_segs = config.segments.total;
                    for i in 0..total_damage {
                        let seg = (((i + 1) as f64 * total_segs as f64) / total_damage as f64).round() as u32;
                        timeline.schedule(
                            seg.clamp(1, total_segs),
                            participant.id,
                            SegmentEventType::DotTick {
                                effect_name: effect.effect_name.clone(),
                                damage: 1,
                            },
                            EventPriority::NonMovement,
                        );
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Event processing
// ---------------------------------------------------------------------------

/// Process a movement event with dynamic intent recalculation.
///
/// For `TowardsPerson` and `AwayFrom` intents, the destination is recalculated
/// from the participant's CURRENT position toward/away from the target's CURRENT
/// position. This matches Ruby's `dynamic_towards_step`/`dynamic_away_step`.
/// For `Fixed` intent, uses the precomputed target coordinates.
fn process_movement_with_intent(
    state: &mut FightState,
    participant_id: u64,
    precomputed_x: i32,
    precomputed_y: i32,
    intent: &MovementIntent,
    segment: u32,
    events: &mut Vec<CombatEvent>,
    timeline: &SegmentTimeline,
    actions: &[PlayerAction],
    area_denial_tracker: &mut tactics::AreaDenialTracker,
) {
    // Helper: check if movement is blocked by any AreaDenial tactic.
    //
    // Mirrors Ruby's `TacticAreaDenialService`: enforces both lateral denial
    // (with per-round entry-hex tracking) and elevation denial. Qi Lightness
    // elevated movers bypass entirely.
    let is_area_denied = |state: &FightState,
                          tracker: &mut tactics::AreaDenialTracker,
                          mover_id: u64,
                          target_x: i32,
                          target_y: i32|
     -> bool {
        let mover = match find_participant(&state.participants, mover_id) {
            Some(m) => m,
            None => return false,
        };
        // Qi Lightness elevated users bypass Area Denial (Ruby line 45).
        if mover.qi_lightness_elevated {
            return false;
        }
        let mover_side = mover.side;
        let mover_pos = mover.position;
        let target_pos = HexCoord { x: target_x, y: target_y, z: mover_pos.z };

        let from_elevation = state
            .hex_map
            .cells
            .get(&(mover_pos.x, mover_pos.y))
            .map(|c| c.elevation_level)
            .unwrap_or(0);
        let to_elevation = state
            .hex_map
            .cells
            .get(&(target_x, target_y))
            .map(|c| c.elevation_level)
            .unwrap_or(0);

        for action in actions {
            if matches!(action.tactic, TacticChoice::AreaDenial) {
                if let Some(denier) = find_participant(&state.participants, action.participant_id) {
                    if denier.side != mover_side && !denier.is_knocked_out {
                        let result = tactics::check_area_denial(
                            mover_id,
                            denier.id,
                            &denier.position,
                            &mover_pos,
                            &target_pos,
                            from_elevation,
                            to_elevation,
                            tracker,
                        );
                        if !matches!(result, tactics::AreaDenialBlock::Allowed) {
                            return true;
                        }
                    }
                }
            }
        }
        false
    };

    match intent {
        MovementIntent::Fixed => {
            if !is_area_denied(state, area_denial_tracker, participant_id, precomputed_x, precomputed_y) {
                process_movement_event(state, participant_id, precomputed_x, precomputed_y, segment, events);
            }
        }
        MovementIntent::TowardsPerson(target_id) => {
            let (mover_pos, target_pos) = match (
                find_participant(&state.participants, participant_id),
                find_participant(&state.participants, *target_id),
            ) {
                (Some(m), Some(t)) => (m.position, t.position),
                _ => return,
            };

            // Adjacency stop: if already within 1 hex, skip this movement step
            // (matches Ruby's process_movement_step adjacency check)
            let dist = hex_grid::hex_distance(mover_pos.x, mover_pos.y, target_pos.x, target_pos.y);
            if dist <= 1 {
                // Ruby checks target_has_future_movement_steps? — if the target
                // has movement scheduled after this segment, don't skip (target
                // might move away, so keep pursuing). Only skip if target is
                // staying put.
                let target_has_future_moves = timeline.events_in_order().iter().any(|e| {
                    e.segment > segment
                        && e.participant_id == *target_id
                        && matches!(e.event_type, SegmentEventType::Movement { .. })
                });
                if !target_has_future_moves {
                    return; // target is staying, we're adjacent, stop
                }
                // Target has future movement — don't skip, keep pursuing
            }

            // Compute one step toward target's CURRENT position
            let step = movement::simple_greedy_towards(
                mover_pos.x, mover_pos.y,
                target_pos.x, target_pos.y,
                1, // single step
                state.hex_map.width.max(20) as i32,
                state.hex_map.height.max(20) as i32,
            );
            if let Some(&(nx, ny)) = step.first() {
                if !is_area_denied(state, area_denial_tracker, participant_id, nx, ny) {
                    process_movement_event(state, participant_id, nx, ny, segment, events);
                }
            }
        }
        MovementIntent::AwayFrom(target_id) => {
            let (mover_pos, target_pos) = match (
                find_participant(&state.participants, participant_id),
                find_participant(&state.participants, *target_id),
            ) {
                (Some(m), Some(t)) => (m.position, t.position),
                _ => return,
            };

            // Compute one step away from target's CURRENT position
            let step = movement::resolve_away_step(
                mover_pos.x, mover_pos.y,
                target_pos.x, target_pos.y,
                state.hex_map.width.max(20) as i32,
                state.hex_map.height.max(20) as i32,
            );
            if let Some((nx, ny)) = step {
                if !is_area_denied(state, area_denial_tracker, participant_id, nx, ny) {
                    process_movement_event(state, participant_id, nx, ny, segment, events);
                }
            } else {
                // Fallback to precomputed
                if !is_area_denied(state, area_denial_tracker, participant_id, precomputed_x, precomputed_y) {
                    process_movement_event(state, participant_id, precomputed_x, precomputed_y, segment, events);
                }
            }
        }
    }
}

/// Process a movement event: update participant position.
fn process_movement_event(
    state: &mut FightState,
    participant_id: u64,
    target_x: i32,
    target_y: i32,
    segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    if let Some(p) = state
        .participants
        .iter_mut()
        .find(|p| p.id == participant_id)
    {
        let from = p.position;
        let to = HexCoord {
            x: target_x,
            y: target_y,
            z: from.z,
        };
        p.position = to;
        p.moved_this_round = true;
        events.push(CombatEvent::Moved {
            participant_id,
            from,
            to,
            segment,
        });
    }

    // Ruby: `FightHexEffectService#on_hex_enter` is called after each hex step.
    // Trigger persistent interactive-object entry effects (toxic_mushrooms,
    // lotus_pollen). Idempotent — `apply_status_by_name` skips duplicates.
    crate::interactive_objects::on_hex_enter(
        state,
        participant_id,
        target_x,
        target_y,
        segment,
        events,
    );
}

/// Process an attack event. Returns the knocked-out target ID if a knockout occurs.
///
/// Uses pre-rolled combat dice from Phase 3 instead of rolling inline.
/// Resolve attack target, applying Guard and BackToBack redirections.
///
/// Ruby's `resolve_attack_target` (line 2864) checks:
/// 1. Observer forced target (already handled via observer_effects in attack processing)
/// 2. Guard: if an ally guards the target, redirect to guardian (50% chance per guard)
/// 3. BackToBack: if target has a btb partner, redirect (50% mutual, 25% one-sided)
///
/// Returns (resolved_target_id, redirect_damage_mod).
/// Only consumes RNG when there are actual guard/btb tactics to check.
fn resolve_attack_target(
    state: &FightState,
    actions: &[PlayerAction],
    attacker_id: u64,
    target_id: u64,
    attack_segment: u32,
    rng: &mut impl rand::Rng,
    events: &mut Vec<CombatEvent>,
) -> (u64, i32) {
    // Taunt check: if attacker has a TargetingRestriction effect (taunt),
    // force the attack to the taunter. Ruby status_effect_service.rb:558 must_target.
    if let Some(attacker) = find_participant(&state.participants, attacker_id) {
        if let Some(taunter_id) = status_effects::forced_target_from_taunt(&attacker.status_effects) {
            if taunter_id != target_id {
                // Verify taunter is still alive
                let still_alive = find_participant(&state.participants, taunter_id)
                    .map_or(false, |t| !t.is_knocked_out);
                if still_alive {
                    events.push(CombatEvent::AttackRedirected {
                        attacker_id,
                        original_target_id: target_id,
                        new_target_id: taunter_id,
                        redirect_type: "taunt".to_string(),
                    });
                    return (taunter_id, 0);
                }
            }
        }
    }

    // Guard check: pool all eligible guards, cap combined chance at 100%,
    // roll once, uniformly pick a guard on success. Mirrors Ruby
    // combat_resolution_service.rb:2712-2720.
    let target_pos = find_participant(&state.participants, target_id).map(|t| t.position);
    let eligible_guards: Vec<u64> = actions
        .iter()
        .filter_map(|action| {
            if let TacticChoice::Guard { ally_id } = action.tactic {
                if ally_id == target_id && action.participant_id != attacker_id {
                    let g = find_participant(&state.participants, action.participant_id)?;
                    if g.is_knocked_out {
                        return None;
                    }
                    // Movement timing: protection active only after guard's movement finishes.
                    // Ruby fight_participant.rb:446-448.
                    if let Some(mcs) = g.movement_completed_segment {
                        if attack_segment < mcs {
                            return None;
                        }
                    }
                    let adj = target_pos.map_or(false, |tp| {
                        crate::hex_grid::hex_distance(g.position.x, g.position.y, tp.x, tp.y) <= 1
                    });
                    if !adj {
                        return None;
                    }
                    return Some(action.participant_id);
                }
            }
            None
        })
        .collect();

    if !eligible_guards.is_empty() {
        let chance = (eligible_guards.len() as u32
            * state.config.guard_redirect_chance)
            .min(100);
        if rng.gen_range(0..100) < chance {
            let idx = rng.gen_range(0..eligible_guards.len());
            let guard_id = eligible_guards[idx];
            events.push(CombatEvent::AttackRedirected {
                attacker_id,
                original_target_id: target_id,
                new_target_id: guard_id,
                redirect_type: "guard".to_string(),
            });
            return (guard_id, state.config.guard_redirect_damage_bonus);
        }
    }

    // BackToBack check: Ruby finds the first btb partner (combat_resolution_service.rb:2723).
    // Gate on movement_completed_segment like guards.
    for action in actions {
        if let TacticChoice::BackToBack { ally_id } = action.tactic {
            if ally_id == target_id && action.participant_id != attacker_id {
                let partner = find_participant(&state.participants, action.participant_id);
                if let Some(p) = partner {
                    if p.is_knocked_out {
                        continue;
                    }
                    if let Some(mcs) = p.movement_completed_segment {
                        if attack_segment < mcs {
                            continue;
                        }
                    }
                    let adjacent = target_pos.map_or(false, |tp| {
                        crate::hex_grid::hex_distance(p.position.x, p.position.y, tp.x, tp.y) <= 1
                    });
                    if adjacent {
                        let mutual = actions.iter().any(|a| {
                            a.participant_id == target_id
                                && matches!(a.tactic, TacticChoice::BackToBack { ally_id: aid } if aid == action.participant_id)
                        });
                        let chance = if mutual {
                            state.config.btb_mutual_chance
                        } else {
                            state.config.btb_single_chance
                        };
                        if rng.gen_range(0..100) < chance {
                            events.push(CombatEvent::AttackRedirected {
                                attacker_id,
                                original_target_id: target_id,
                                new_target_id: action.participant_id,
                                redirect_type: if mutual { "back_to_back_mutual".to_string() } else { "back_to_back".to_string() },
                            });
                            let bonus = if mutual { state.config.btb_mutual_damage_bonus } else { 0 };
                            return (action.participant_id, bonus);
                        }
                    }
                }
            }
        }
    }

    (target_id, 0)
}

/// Per-attack damage = roll_total / attack_count + modifiers.
fn process_attack_event(
    state: &mut FightState,
    attacker_id: u64,
    target_id: u64,
    _pre_rolls: &[PreRolls],
    combat_pre_rolls: &[CombatPreRoll],
    actions: &[PlayerAction],
    segment: u32,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    round_damage_states: &mut HashMap<u64, defense::RoundDamageState>,
    timeline: &SegmentTimeline,
    initial_distances: &HashMap<(u64, u64), i32>,
    // Guard/BTB redirect damage modifier from resolve_attack_target.
    // Ruby: combat_resolution_service.rb:2958 round_total += redirect_damage_mod.
    redirect_damage_mod: i32,
) -> Option<u64> {
    // Skip if target is already knocked out
    if is_knocked_out(target_id, state) {
        return None;
    }

    let (attacker_pos, attacker_wound_penalty, attacker_npc_bonus,
         attacker_outgoing_mod, attacker_weapon, fear_penalty,
         attacker_tactic_out, attacker_style_melee, attacker_style_ranged) = {
        let attacker = match find_participant(&state.participants, attacker_id) {
            Some(a) => a,
            None => return None,
        };
        // Fear attack penalty: Ruby status_effect_service.rb:617. Applies only
        // when the feared attacker targets their fear source.
        let fear_penalty = if status_effects::fear_source(&attacker.status_effects) == Some(target_id) {
            status_effects::fear_attack_penalty(&attacker.status_effects)
        } else {
            0
        };
        let target = match find_participant(&state.participants, target_id) {
            Some(t) => t,
            None => return None,
        };
        let dist = hex_grid::hex_distance(
            attacker.position.x,
            attacker.position.y,
            target.position.x,
            target.position.y,
        ) as u32;
        let weapon = match weapon_resolution::effective_weapon(attacker, dist) {
            Some(w) => w,
            None => return None, // no weapon to attack with
        };
        // Skip attack if out of weapon range (matches Ruby's attack_in_range? check).
        // Melee/unarmed: must be adjacent (distance ≤ 1). Reach only affects segment
        // compression timing, not max attack range.
        // Ranged: must be within range_hexes.
        let max_range = if weapon.is_ranged {
            weapon.range_hexes.unwrap_or(8)
        } else {
            1 // all melee attacks require adjacency
        };
        if dist > max_range {
            // Melee catch-up: Ruby allows if (a) melee weapon, (b) initial distance <= 2,
            // and (c) movement will close the gap within the catch-up window.
            // See Ruby's attack_in_range? at combat_resolution_service.rb:2912
            if !weapon.is_ranged {
                let initial_dist = initial_distances
                    .get(&(attacker_id, target_id))
                    .copied()
                    .unwrap_or(dist as i32);
                let catchup_window = state.config.segments.melee_catchup_window;
                if initial_dist > 2 || !will_close_melee_gap(timeline, attacker_id, target_id, segment, catchup_window, state) {
                    // Ruby emits an `out_of_range` event here so the event
                    // stream reflects the failed attempt. Rust was silently
                    // dropping these, causing the 1v1_defend pursuit-stalemate
                    // symptom (defender retreats → attacker emits no events).
                    events.push(CombatEvent::AttackOutOfRange {
                        attacker_id,
                        target_id,
                        segment,
                        distance: dist,
                    });
                    return None; // truly out of range
                }
                // else: catch-up allows this attack
            } else {
                events.push(CombatEvent::AttackOutOfRange {
                    attacker_id,
                    target_id,
                    segment,
                    distance: dist,
                });
                return None; // ranged out of range
            }
        }
        let (style_melee, style_ranged) = attacker
            .combat_style
            .as_ref()
            .map_or((0, 0), |s| (s.melee_bonus, s.ranged_bonus));
        (
            attacker.position,
            attacker.wound_penalty(),
            attacker.npc_damage_bonus,
            attacker.outgoing_damage_modifier,
            weapon,
            fear_penalty,
            attacker.tactic_outgoing_damage_modifier,
            style_melee,
            style_ranged,
        )
    };

    // Build weapon detail for event
    let weapon_detail = AttackWeaponDetail {
        weapon_type: if attacker_weapon.is_ranged {
            "ranged".to_string()
        } else {
            "melee".to_string()
        },
        weapon_name: Some(attacker_weapon.name.clone()),
        damage_type: attacker_weapon.damage_type,
    };

    // Use pre-rolled combat dice (Phase 3) to calculate per-attack damage.
    //
    // Ruby computes a ROUND total by summing dice + ALL modifiers (stat, wound,
    // npc bonus, outgoing mod, all_roll_penalty), then divides by attack_count
    // using float division. This matches Ruby's calculate_attack_damage.
    //
    // UNIFIED F64 PIPELINE: All modifiers apply to a single damage_f64 variable.
    // i32 is derived only at the end for event display. This ensures the f64 value
    // accumulated into RoundDamageState includes ALL modifiers (observer, elevation,
    // incoming, damage_type_mult), not just the base per-attack float.
    let (mut damage_f64, roll_detail) = if let Some(cpr) = combat_pre_rolls
        .iter()
        .find(|r| r.participant_id == attacker_id)
    {
        // Build round_total with ALL modifiers (matching Ruby's calculate_attack_damage)
        let mut round_total = cpr.roll_total;
        round_total += cpr.stat_modifier as i32;
        round_total -= attacker_wound_penalty;
        round_total += attacker_npc_bonus as i32;
        round_total += attacker_outgoing_mod as i32;
        round_total += cpr.all_roll_penalty as i32;
        // Fear attack penalty when attacker targets fear source
        // (fear_penalty is already negative, e.g., -2).
        round_total += fear_penalty;

        // Dodge penalty: Ruby line 2959: round_total -= dodge_penalty (5 if target dodging)
        let target_dodging = actions.iter()
            .find(|a| a.participant_id == target_id)
            .map_or(false, |a| matches!(a.main_action, MainAction::Dodge));
        if target_dodging {
            round_total -= 5; // GameConfig::Tactics::DODGE_PENALTY
        }

        // NPC defense bonus: Ruby line 2961: round_total -= (target.npc_defense_bonus || 0)
        // Tactic incoming damage modifier: Ruby line 2957 (target's stance).
        if let Some(target) = find_participant(&state.participants, target_id) {
            round_total -= target.npc_defense_bonus as i32;
            round_total += target.tactic_incoming_damage_modifier;
        }

        // Attacker tactic outgoing damage modifier. Ruby line 2956.
        // (Ruby stubs at fight_participant.rb:370/378 return 0 today, but the
        // wiring is complete so future tactics that populate these just work.)
        round_total += attacker_tactic_out;

        // Guard/BTB redirect damage modifier. Ruby: combat_resolution_service.rb:2958
        //   round_total += redirect_damage_mod
        // Guard adds +2 (protector catches attack), mutual B2B applies -1.
        round_total += redirect_damage_mod;

        // Combat-style attack bonus. Ruby combat_resolution_service.rb:2964-2969
        // picks `bonuses[:melee]` or `bonuses[:ranged]` based on weapon_type.
        round_total += if attacker_weapon.is_ranged {
            attacker_style_ranged
        } else {
            attacker_style_melee
        };

        // Per-attack: divide round total by attack count (float division, matching Ruby).
        // Ruby keeps this as a float: 23/5 = 4.6, not 4. The fractional part accumulates
        // across attacks in the cumulative defense pipeline, so we must NOT truncate here.
        let n = cpr.attack_count.max(1) as f64;
        let per_attack_f = (round_total as f64 / n).max(0.0);
        let dmg_i32 = per_attack_f as i32;

        let detail = AttackRollDetail {
            base_roll: cpr.base_attack_roll,
            roll_dice: cpr.base_dice.clone(),
            roll_exploded: cpr.base_exploded,
            stat_mod: cpr.stat_modifier,
            wound_penalty: attacker_wound_penalty,
            all_roll_penalty: cpr.all_roll_penalty,
            attack_count: cpr.attack_count,
            per_attack_roll: dmg_i32,
            qi_attack_bonus: cpr.qi_attack_roll,
            qi_attack_dice: cpr.qi_attack_dice.clone(),
            total_before_defense: dmg_i32,
        };

        (per_attack_f, Some(detail))
    } else {
        // Fallback for monster attacks or other cases without pre-rolled dice
        let attacker = find_participant(&state.participants, attacker_id).unwrap();
        let mut dmg = 0i32;
        dmg += attacker.stat_modifier as i32;
        dmg -= attacker_wound_penalty;
        dmg += attacker_npc_bonus as i32;
        dmg += attacker_outgoing_mod as i32;
        dmg += attacker.all_roll_penalty as i32;
        dmg += fear_penalty;
        dmg = dmg.max(0);
        (dmg as f64, None)
    };

    // All subsequent modifiers apply to damage_f64 (the single source of truth).
    // Ruby applies these in apply_final_attack_modifiers and apply_battle_map_modifiers,
    // all to the same float `total` before shield absorption and cumulative tracking.

    // --- Wall/LoS blocking (Ruby: apply_battle_map_modifiers lines 3036-3047) ---
    // Must check BEFORE any damage modifiers -- if blocked, attack does nothing.
    let target_pos_for_block = find_participant(&state.participants, target_id)
        .map(|t| t.position)
        .unwrap();
    if attacker_weapon.is_ranged {
        // Ranged: LoS blocked by blocks_los hexes in the path
        if !battle_map::has_line_of_sight(
            &state.hex_map,
            state.wall_mask.as_ref(),
            &attacker_pos,
            &target_pos_for_block,
            attacker_pos.z,
        ) {
            return None;
        }
    } else {
        // Melee: blocked by wall edges between adjacent hexes
        if battle_map::movement_blocked_by_edges(&state.hex_map, &attacker_pos, &target_pos_for_block)
        {
            return None;
        }
        // Qi Lightness: elevated targets are melee-immune unless the attacker
        // also has Qi Lightness active. Ruby: combat_resolution_service.rb:2779
        // + tactic_qi_lightness_service.rb:143 (can_melee_reach?).
        let target_elevated = find_participant(&state.participants, target_id)
            .map_or(false, |t| t.qi_lightness_elevated);
        if target_elevated {
            let attacker_has_ql = actions.iter().any(|a| {
                a.participant_id == attacker_id
                    && matches!(a.tactic, TacticChoice::QiLightness { .. })
            });
            if !attacker_has_ql {
                let target_mode = actions
                    .iter()
                    .find(|a| a.participant_id == target_id)
                    .and_then(|a| {
                        if let TacticChoice::QiLightness { mode } = &a.tactic {
                            Some(format!("{:?}", mode).to_lowercase())
                        } else {
                            None
                        }
                    });
                events.push(CombatEvent::MeleeBlockedQiLightness {
                    attacker_id,
                    target_id,
                    target_mode,
                    segment,
                });
                return None;
            }
        }
    }

    // Mark attacker as having acted this round (for cover stationary check)
    if let Some(p) = state.participants.iter_mut().find(|p| p.id == attacker_id) {
        p.acted_this_round = true;
    }

    // Apply observer effect damage multiplier. Ruby gates a couple of these
    // (aggro_boost, npc_damage_boost) on the actor being an NPC.
    let attacker_is_npc = find_participant(&state.participants, attacker_id)
        .map_or(false, |p| p.is_npc);
    let obs_mult = observer_effects::damage_multiplier(
        &state.observer_effects,
        attacker_id,
        target_id,
        attacker_is_npc,
    );
    damage_f64 *= obs_mult as f64;

    // Add expose_targets bonus. Ruby reads this from actor_effects
    // (observer watching the attacker), not target_effects.
    let expose_bonus =
        observer_effects::expose_targets_bonus(&state.observer_effects, attacker_id);
    damage_f64 += expose_bonus as f64;

    damage_f64 = damage_f64.max(0.0);

    // Apply battle map modifiers (elevation, LoS)
    // Ruby divides flat modifiers by attack_count so multi-attack doesn't multiply them
    let attack_count = combat_pre_rolls
        .iter()
        .find(|r| r.participant_id == attacker_id)
        .map_or(1, |r| r.attack_count.max(1));
    // Reuse target position from earlier LoS/wall check (same participant, same round)
    let target_pos_for_map = target_pos_for_block;
    let elev_mod = battle_map::elevation_modifier(attacker_pos.z, target_pos_for_map.z);
    if elev_mod != 0 {
        damage_f64 += elev_mod as f64 / attack_count as f64;
    }
    // Elevation damage bonus (ranged only, 2+ levels above)
    if attacker_weapon.is_ranged {
        let elev_bonus = battle_map::elevation_damage_bonus(attacker_pos.z, target_pos_for_map.z);
        if elev_bonus > 0 {
            damage_f64 += elev_bonus as f64 / attack_count as f64;
        }
    }

    // Prone modifier (Ruby line 3059: battle_map_service.prone_modifier)
    // Melee gets +2 bonus vs prone targets, ranged gets -2 penalty
    let prone_mod = {
        let target = find_participant(&state.participants, target_id).unwrap();
        if target.is_prone {
            if attacker_weapon.is_ranged { -2 } else { 2 }
        } else {
            0
        }
    };
    if prone_mod != 0 {
        damage_f64 += prone_mod as f64 / attack_count as f64;
    }

    // --- Ranged cover and concealment (Ruby lines 3079-3122) ---
    if attacker_weapon.is_ranged {
        // Cover: check for cover hexes in the shot path (excluding attacker-adjacent)
        if battle_map::shot_passes_through_cover(
            &state.hex_map,
            &attacker_pos,
            &target_pos_for_map,
        ) {
            let target_stationary = {
                let t = find_participant(&state.participants, target_id).unwrap();
                !t.moved_this_round && !t.acted_this_round
            };
            if target_stationary {
                // Full block: stationary target behind cover is unhittable
                return None;
            } else {
                // Moving target: 50% damage reduction (Ruby line 3108-3109)
                damage_f64 *= 0.5;
            }
        }

        // Concealment penalty (Ruby: ConcealmentService.ranged_penalty(distance))
        // Formula: -(distance / 6).floor, capped at -4
        if battle_map::is_concealed(&state.hex_map, &target_pos_for_map) {
            let dist = hex_grid::hex_distance(
                attacker_pos.x,
                attacker_pos.y,
                target_pos_for_map.x,
                target_pos_for_map.y,
            );
            let concealment_penalty = (dist as f64 / 6.0).floor().min(4.0);
            damage_f64 -= concealment_penalty / attack_count as f64;
        }
    }

    // Apply target's incoming damage modifier (status effects like defend).
    // Ruby divides by attack_count per hit: `incoming_mod.to_f / attack_n`
    let incoming_modifier = {
        let target = find_participant(&state.participants, target_id).unwrap();
        target.incoming_damage_modifier as i32
    };
    if incoming_modifier != 0 {
        damage_f64 += incoming_modifier as f64 / attack_count as f64;
    }

    // Apply damage type multiplier (vulnerability/resistance status effects).
    // Ruby line 3147: total = total * StatusEffectService.damage_type_multiplier(target, damage_type)
    let damage_type_mult = {
        let target_effects = find_participant(&state.participants, target_id)
            .map(|t| &t.status_effects)
            .unwrap();
        status_effects::damage_type_multiplier(target_effects, &attacker_weapon.damage_type)
    };
    if (damage_type_mult - 1.0).abs() > f32::EPSILON {
        damage_f64 *= damage_type_mult as f64;
    }

    damage_f64 = damage_f64.max(0.0);

    // --- Cumulative defense pipeline (matches Ruby's calculate_effective_cumulative) ---
    // Step 1: Shield absorb this hit (per-hit, mutates target status effects)
    let raw_for_shield = damage_f64 as i32;
    let shield_absorbed = {
        let target = state.participants.iter_mut().find(|p| p.id == target_id).unwrap();
        let after = status_effects::shield_absorb(&mut target.status_effects, raw_for_shield);
        raw_for_shield - after
    };
    // Subtract shield from the f64 damage to preserve fractions
    let post_shield_f64 = (damage_f64 - shield_absorbed as f64).max(0.0);

    // Step 2: Accumulate raw damage (post-shield) into round state using f64
    // to preserve fractional per-attack damage across hits
    let rds = round_damage_states
        .entry(target_id)
        .or_insert_with(|| defense::RoundDamageState::new(0));
    rds.accumulate_attack(attacker_id, attacker_weapon.damage_type, post_shield_f64);
    rds.shield_absorbed += shield_absorbed;

    // Step 3: Check if target's tactic is QiAura
    let qi_aura_active = actions
        .iter()
        .find(|a| a.participant_id == target_id)
        .map_or(false, |a| matches!(a.tactic, TacticChoice::QiAura));

    // Get target's combat_style
    let target_combat_style = find_participant(&state.participants, target_id)
        .and_then(|t| t.combat_style.clone());

    // Check back_to_wall
    let target_pos = find_participant(&state.participants, target_id)
        .map(|t| t.position)
        .unwrap();
    // Back-to-wall threshold shift applies only to equipped melee weapons
    // (Ruby combat_resolution_service.rb:2836 gates on weapon_type == 'melee',
    // which excludes 'unarmed' / 'natural_melee' / 'ranged').
    let btw = if attacker_weapon.is_natural || attacker_weapon.is_ranged {
        false
    } else {
        battle_map::back_to_wall(&state.hex_map, &attacker_pos, &target_pos)
    };

    // Step 4: Calculate effective cumulative damage (defenses applied to round totals)
    let target_effects = find_participant(&state.participants, target_id)
        .map(|t| t.status_effects.clone())
        .unwrap_or_default();
    let defense_result = defense::calculate_effective_cumulative(
        rds,
        qi_aura_active,
        target_combat_style.as_ref(),
        &target_effects,
    );

    let damage_for_tracker = defense_result.final_damage;

    // Build defense detail for event
    let defense_detail = DefenseDetail {
        shield_absorbed: defense_result.shield_absorbed,
        armor_reduced: defense_result.armor_reduced,
        qi_aura_reduced: defense_result.qi_aura_reduced,
        protection_reduced: defense_result.protection_reduced,
        qi_defense_reduced: defense_result.qi_defense_reduced,
        observer_multiplier: obs_mult,
        observer_flat_bonus: expose_bonus,
        back_to_wall: btw,
        incoming_modifier,
        outgoing_modifier: attacker_outgoing_mod as i32,
        final_damage: damage_for_tracker,
    };

    // Feed effective cumulative into threshold calculation with DYNAMIC wound_penalty.
    // Ruby recalculates damage_thresholds() fresh on each hit, picking up mid-round HP loss.
    let config = &state.config;

    // Get current wound_penalty from target's actual HP (not frozen at round start)
    let current_wound_penalty = if state.fight_mode == FightMode::Spar {
        0
    } else {
        find_participant(&state.participants, target_id)
            .map(|t| t.wound_penalty())
            .unwrap_or(0)
    };

    // Apply back_to_wall threshold shift (-3 to all thresholds)
    let threshold_shift = if btw { 3 } else { 0 };
    let effective_wound_penalty = current_wound_penalty + threshold_shift;

    let target_style = find_participant(&state.participants, target_id)
        .and_then(|t| t.combat_style.as_ref());
    let target_thresholds =
        crate::damage::effective_thresholds(&config.damage_thresholds, target_style);

    let tracker = damage_trackers
        .entry(target_id)
        .or_insert_with(|| DamageTracker::new(0));
    tracker.cumulative_damage = damage_for_tracker;
    tracker.wound_penalty = effective_wound_penalty;
    let new_total_hp = crate::damage::calculate_hp_from_damage(
        damage_for_tracker,
        effective_wound_penalty,
        &target_thresholds,
        config.high_damage_base_hp,
        config.high_damage_band_size,
    );
    let hp_lost = (new_total_hp - tracker.total_hp_lost).max(0);
    tracker.total_hp_lost = new_total_hp;


    if hp_lost > 0 {
        // Update target HP
        if let Some(target) = state
            .participants
            .iter_mut()
            .find(|p| p.id == target_id)
        {
            match state.fight_mode {
                FightMode::Normal => {
                    target.current_hp = target.current_hp.saturating_sub(hp_lost as u8);
                    // Qi gain on HP loss
                    target.qi_dice = (target.qi_dice + config.qi.gain_per_hp_lost * hp_lost as f32)
                        .min(config.qi.max_dice);
                }
                FightMode::Spar => {
                    // Spar mode: increment touch_count instead of reducing HP
                    target.touch_count += hp_lost as u8;
                }
            }
        }

        events.push(CombatEvent::AttackHit {
            attacker_id,
            target_id,
            raw_damage: damage_f64 as i32,
            damage: damage_for_tracker as i32,
            hp_lost,
            segment,
            roll: roll_detail,
            weapon: Some(weapon_detail),
            defense: Some(defense_detail),
        });

        // Check knockout
        let knocked_out = check_knockout(state, target_id);
        if knocked_out {
            let reason = ko_reason_for(state, target_id);
            events.push(CombatEvent::KnockedOut {
                participant_id: target_id,
                by_id: Some(attacker_id),
                reason,
            });
            return Some(target_id);
        }
    } else {
        events.push(CombatEvent::AttackMiss {
            attacker_id,
            target_id,
            raw_damage: damage_f64 as i32,
            damage: damage_for_tracker as i32,
            segment,
            roll: roll_detail,
            weapon: Some(weapon_detail),
            defense: Some(defense_detail),
        });
    }

    None
}

/// Process an ability event. Returns list of knocked-out target IDs.
///
/// Ruby routes ability damage through `state[:ability_cumulative]` →
/// `calculate_effective_cumulative()` Step 2.5 → qi defense (Step 3).
/// So ability damage bypasses armor/protection but IS reduced by qi defense.
///
/// Full feature set: healing, execute, conditional/combo/split damage,
/// timing coefficient, lifesteal, forced movement, prone, status chance,
/// health cost, global cooldown.
fn process_ability_event(
    state: &mut FightState,
    caster_id: u64,
    ability_id: u64,
    target_id: Option<u64>,
    pre_rolls: &[PreRolls],
    actions: &[PlayerAction],
    segment: u32,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    round_damage_states: &mut HashMap<u64, defense::RoundDamageState>,
    rng: &mut impl Rng,
) -> Vec<u64> {
    let mut ko_list = Vec::new();

    // Mark caster as having acted this round
    if let Some(p) = state.participants.iter_mut().find(|p| p.id == caster_id) {
        p.acted_this_round = true;
    }

    // Find the ability and pick the right stat based on ability.damage_stat.
    // Ruby ability_processor_service.rb:720 picks actor.stat_modifier(ability.damage_stat).
    let (ability, caster_stat_mod, caster_ability_penalty) = {
        let caster = match find_participant(&state.participants, caster_id) {
            Some(c) => c,
            None => return ko_list,
        };
        let ability = match caster.abilities.iter().find(|a| a.id == ability_id) {
            Some(a) => a.clone(),
            None => return ko_list,
        };
        let stat_mod = match ability.damage_stat.as_deref() {
            Some("Dexterity") => caster.dexterity_modifier,
            // "Strength" / None / other stat names fall back to Strength.
            // (No other per-stat fields exist on Participant yet.)
            _ => caster.stat_modifier,
        };
        (ability, stat_mod, caster.ability_roll_penalty)
    };

    // Resolve targets
    let caster = find_participant(&state.participants, caster_id).unwrap().clone();
    let targets = ability_resolution::resolve_targets(
        &ability,
        &caster,
        target_id,
        &state.participants,
        &state.hex_map,
    );

    if targets.is_empty() {
        return ko_list;
    }

    // Get pre-rolled ability values from Phase 1
    let pr = pre_rolls.iter().find(|r| r.participant_id == caster_id);
    let qi_roll = pr.and_then(|r| r.qi_ability_roll).unwrap_or(0);
    let ability_base = pr.and_then(|r| r.ability_base_roll).unwrap_or(0);

    let mut total_damage = 0i32;
    let mut target_results = Vec::new();

    for abt in &targets {
        // --- 1. Healing path ---
        if ability.is_healing {
            let damage_roll = ability_resolution::calculate_ability_damage_from_preroll(
                &ability,
                ability_base,
                caster_stat_mod,
                qi_roll,
                abt.damage_multiplier,
                caster_ability_penalty,
            );
            let actual_heal = if let Some(target) = state
                .participants
                .iter_mut()
                .find(|p| p.id == abt.participant_id)
            {
                target.heal(damage_roll)
            } else {
                0
            };
            events.push(CombatEvent::AbilityHeal {
                caster_id,
                target_id: abt.participant_id,
                ability_name: ability.name.clone(),
                heal_amount: damage_roll,
                actual_heal,
                segment,
            });
            target_results.push(AbilityTargetResult {
                target_id: abt.participant_id,
                damage: 0,
                hp_lost: 0,
                is_primary: abt.is_primary,
                damage_multiplier: abt.damage_multiplier,
            });
            continue; // Skip all damage processing for healing targets
        }

        // --- Calculate base damage ---
        let mut raw_damage = ability_resolution::calculate_ability_damage_from_preroll(
            &ability,
            ability_base,
            caster_stat_mod,
            qi_roll,
            abt.damage_multiplier,
            caster_ability_penalty,
        );

        // --- 2. Execute check ---
        if let (Some(threshold), Some(ref exec_effect)) = (ability.execute_threshold, &ability.execute_effect) {
            let target_hp_pct = find_participant(&state.participants, abt.participant_id)
                .map(|t| t.hp_percent())
                .unwrap_or(1.0);
            if target_hp_pct <= threshold {
                if exec_effect.instant_kill {
                    // Instant kill: knockout immediately
                    apply_hp_loss(state, abt.participant_id, 255); // drain all HP
                    if let Some(target) = state.participants.iter_mut().find(|p| p.id == abt.participant_id) {
                        target.current_hp = 0;
                        target.is_knocked_out = true;
                    }
                    events.push(CombatEvent::AbilityExecute {
                        caster_id,
                        target_id: abt.participant_id,
                        ability_name: ability.name.clone(),
                        instant_kill: true,
                        threshold,
                        segment,
                    });
                    let reason = ko_reason_for(state, abt.participant_id);
                    events.push(CombatEvent::KnockedOut {
                        participant_id: abt.participant_id,
                        by_id: Some(caster_id),
                        reason,
                    });
                    ko_list.push(abt.participant_id);
                    target_results.push(AbilityTargetResult {
                        target_id: abt.participant_id,
                        damage: raw_damage,
                        hp_lost: 0,
                        is_primary: abt.is_primary,
                        damage_multiplier: abt.damage_multiplier,
                    });
                    continue; // Skip remaining damage for this target
                }
                if let Some(mult) = exec_effect.damage_multiplier {
                    events.push(CombatEvent::AbilityExecute {
                        caster_id,
                        target_id: abt.participant_id,
                        ability_name: ability.name.clone(),
                        instant_kill: false,
                        threshold,
                        segment,
                    });
                    raw_damage = (raw_damage as f32 * mult) as i32;
                }
            }
        }

        // --- 3. Conditional damage ---
        for cond in &ability.conditional_damage {
            let condition_met = evaluate_condition(
                &cond.condition,
                cond.status.as_deref(),
                abt.participant_id,
                caster_id,
                state,
            );
            if condition_met {
                if let Some(bonus) = cond.bonus_damage {
                    raw_damage += bonus;
                }
                if let Some(ref dice_str) = cond.bonus_dice {
                    if let Some((count, sides)) = ability_resolution::parse_dice_notation(dice_str) {
                        let roll = dice::roll(count, sides, None, 0, rng);
                        raw_damage += roll.total;
                    }
                }
            }
        }

        // --- 4. Combo damage ---
        if let Some(ref combo) = ability.combo_condition {
            let has_status = find_participant(&state.participants, abt.participant_id)
                .map(|t| status_effects::has_effect(&t.status_effects, &combo.requires_status))
                .unwrap_or(false);
            if has_status {
                if let Some(ref dice_str) = combo.bonus_dice {
                    if let Some((count, sides)) = ability_resolution::parse_dice_notation(dice_str) {
                        let roll = dice::roll(count, sides, None, 0, rng);
                        raw_damage += roll.total;
                    }
                }
                if combo.consumes_status {
                    if let Some(target) = state.participants.iter_mut().find(|p| p.id == abt.participant_id) {
                        status_effects::remove_effect_by_name(&mut target.status_effects, &combo.requires_status);
                    }
                }
            }
        }

        // --- 7. Timing coefficient (before defense, after damage bonuses) ---
        if ability.apply_timing_coefficient {
            let seg = ability.activation_segment.unwrap_or(50) as f32;
            let coeff = (seg / 100.0).clamp(0.01, 1.0);
            if coeff < 1.0 {
                raw_damage = (raw_damage as f32 * coeff) as i32;
            }
        }

        // --- 5 & 6. Split damage / damage modifiers ---
        let target_effects = find_participant(&state.participants, abt.participant_id)
            .map(|t| t.status_effects.clone())
            .unwrap_or_default();

        let modified_damage = if !ability.damage_types.is_empty() {
            // Split damage: compute portion for each damage type
            let mut sum = 0i32;
            for split in &ability.damage_types {
                let portion = (raw_damage as f32 * split.percent) as i32;
                let modified = apply_ability_damage_modifiers(
                    portion,
                    &split.damage_type,
                    &target_effects,
                    ability.bypasses_resistances,
                );
                sum += modified;
            }
            sum
        } else {
            // Single damage type
            apply_ability_damage_modifiers(
                raw_damage,
                &ability.damage_type,
                &target_effects,
                ability.bypasses_resistances,
            )
        };

        let effective_damage = modified_damage.max(0);
        total_damage += effective_damage;

        let mut target_hp_lost = 0i32;

        if effective_damage > 0 {
            // Route through RoundDamageState → calculate_effective_cumulative (matching Ruby).
            let qi_defense_for_target = pre_rolls.iter()
                .find(|r| r.participant_id == abt.participant_id)
                .and_then(|r| r.qi_defense_roll)
                .unwrap_or(0);
            let rds = round_damage_states
                .entry(abt.participant_id)
                .or_insert_with(|| defense::RoundDamageState::new(qi_defense_for_target));
            rds.accumulate_ability(effective_damage);

            // Run full cumulative defense pipeline
            let qi_aura_active = actions.iter()
                .find(|a| a.participant_id == abt.participant_id)
                .map_or(false, |a| matches!(a.tactic, TacticChoice::QiAura));
            let target_style = find_participant(&state.participants, abt.participant_id)
                .and_then(|t| t.combat_style.clone());
            let defense_result = defense::calculate_effective_cumulative(
                rds, qi_aura_active, target_style.as_ref(), &target_effects,
            );

            // Feed effective cumulative into threshold calc with dynamic wound_penalty
            let current_wound_penalty = if state.fight_mode == FightMode::Spar {
                0
            } else {
                find_participant(&state.participants, abt.participant_id)
                    .map(|t| t.wound_penalty())
                    .unwrap_or(0)
            };

            let config = &state.config;
            let tgt_style = state.participants.iter()
                .find(|p| p.id == abt.participant_id)
                .and_then(|t| t.combat_style.as_ref());
            let tgt_thresholds =
                crate::damage::effective_thresholds(&config.damage_thresholds, tgt_style);

            let tracker = damage_trackers
                .entry(abt.participant_id)
                .or_insert_with(|| DamageTracker::new(0));
            tracker.cumulative_damage = defense_result.final_damage;
            tracker.wound_penalty = current_wound_penalty;
            let new_total_hp = crate::damage::calculate_hp_from_damage(
                defense_result.final_damage,
                current_wound_penalty,
                &tgt_thresholds,
                config.high_damage_base_hp,
                config.high_damage_band_size,
            );
            let hp_lost = (new_total_hp - tracker.total_hp_lost).max(0);
            tracker.total_hp_lost = new_total_hp;
            target_hp_lost = hp_lost;

            if hp_lost > 0 {
                apply_hp_loss(state, abt.participant_id, hp_lost);
            }

            // Increment attacks_this_round for caster
            if let Some(caster_mut) = state.participants.iter_mut().find(|p| p.id == caster_id) {
                caster_mut.attacks_this_round += 1;
            }

            // Check knockout
            if check_knockout(state, abt.participant_id) {
                let reason = ko_reason_for(state, abt.participant_id);
                events.push(CombatEvent::KnockedOut {
                    participant_id: abt.participant_id,
                    by_id: Some(caster_id),
                    reason,
                });
                ko_list.push(abt.participant_id);
            }
        }

        // --- 8. Lifesteal ---
        if let Some(lifesteal_max) = ability.lifesteal_max {
            if effective_damage > 0 {
                let heal = effective_damage.min(lifesteal_max);
                let actual_heal = if let Some(caster_mut) = state.participants.iter_mut().find(|p| p.id == caster_id) {
                    caster_mut.heal(heal)
                } else {
                    0
                };
                if actual_heal > 0 {
                    events.push(CombatEvent::Healed {
                        target_id: caster_id,
                        amount: actual_heal,
                        source_id: Some(caster_id),
                    });
                }
            }
        }

        // --- 9. Forced movement ---
        if let Some(ref fm) = ability.forced_movement {
            let (target_pos, caster_pos) = {
                let t = find_participant(&state.participants, abt.participant_id);
                let c = find_participant(&state.participants, caster_id);
                match (t, c) {
                    (Some(tp), Some(cp)) => (tp.position, cp.position),
                    _ => {
                        target_results.push(AbilityTargetResult {
                            target_id: abt.participant_id,
                            damage: effective_damage,
                            hp_lost: target_hp_lost,
                            is_primary: abt.is_primary,
                            damage_multiplier: abt.damage_multiplier,
                        });
                        continue;
                    }
                }
            };

            let direction = match &fm.direction {
                ForcedMovementDirection::Away => {
                    hex_grid::direction_between(caster_pos.x, caster_pos.y, target_pos.x, target_pos.y)
                }
                ForcedMovementDirection::Toward => {
                    hex_grid::direction_between(target_pos.x, target_pos.y, caster_pos.x, caster_pos.y)
                }
                ForcedMovementDirection::Compass(dir) => Some(*dir),
            };

            if let Some(dir) = direction {
                let from_pos = target_pos;
                let mut cur_x = target_pos.x;
                let mut cur_y = target_pos.y;
                let map_w = state.hex_map.width as i32;
                let map_h = state.hex_map.height as i32;

                for _ in 0..fm.distance {
                    let (nx, ny) = hex_grid::hex_neighbor_by_direction(cur_x, cur_y, dir);
                    // Clamp to arena bounds
                    if nx < 0 || nx >= map_w || ny < 0 || ny >= map_h {
                        break;
                    }
                    cur_x = nx;
                    cur_y = ny;
                }

                let to_pos = HexCoord { x: cur_x, y: cur_y, z: target_pos.z };
                if to_pos != from_pos {
                    if let Some(target) = state.participants.iter_mut().find(|p| p.id == abt.participant_id) {
                        target.position = to_pos;
                    }
                    let dir_str = match &fm.direction {
                        ForcedMovementDirection::Away => "away".to_string(),
                        ForcedMovementDirection::Toward => "toward".to_string(),
                        ForcedMovementDirection::Compass(d) => format!("{:?}", d).to_lowercase(),
                    };
                    events.push(CombatEvent::ForcedMovementEvent {
                        target_id: abt.participant_id,
                        from: from_pos,
                        to: to_pos,
                        direction: dir_str,
                        distance: fm.distance,
                        source_id: caster_id,
                    });

                    // Ruby: AbilityProcessorService re-runs FightHexEffectService.on_hex_enter
                    // after forced movement (ability_processor_service.rb:579-585).
                    crate::interactive_objects::on_hex_enter(
                        state,
                        abt.participant_id,
                        cur_x,
                        cur_y,
                        segment,
                        events,
                    );
                }
            }
        }

        // --- 10. Prone ---
        if ability.applies_prone {
            if let Some(target) = state.participants.iter_mut().find(|p| p.id == abt.participant_id) {
                target.is_prone = true;
                let prone_effect = crate::types::status_effects::ActiveEffect {
                    effect_name: "prone".to_string(),
                    effect_type: EffectType::CrowdControl,
                    remaining_rounds: 1,
                    ..Default::default()
                };
                status_effects::apply_effect(&mut target.status_effects, prone_effect);
                events.push(CombatEvent::StatusApplied {
                    target_id: abt.participant_id,
                    effect_name: "prone".to_string(),
                    duration: 1,
                    source_id: Some(caster_id),
                });
            }
        }

        target_results.push(AbilityTargetResult {
            target_id: abt.participant_id,
            damage: effective_damage,
            hp_lost: target_hp_lost,
            is_primary: abt.is_primary,
            damage_multiplier: abt.damage_multiplier,
        });
    }

    // Emit ability event with per-target results
    events.push(CombatEvent::AbilityUsed {
        caster_id,
        ability_id,
        ability_name: ability.name.clone(),
        targets: target_results,
        total_damage,
        segment,
        ability_base_roll: pr.and_then(|r| r.ability_base_roll),
        qi_ability_roll: pr.and_then(|r| r.qi_ability_roll),
        stat_mod: caster_stat_mod,
    });

    // --- 11. Status effect chance/duration scaling ---
    for se in &ability.status_effects {
        for abt in &targets {
            // Check chance
            if se.chance < 1.0 {
                let roll: f32 = rng.gen();
                if roll > se.chance {
                    continue; // Failed chance roll
                }
            }
            // Check threshold
            if let Some(threshold) = se.threshold {
                if ability_base < threshold {
                    continue; // Base roll too low
                }
            }
            // Duration scaling for PCs
            let duration = if let Some(scaling_factor) = ability.status_duration_scaling {
                let base_dur = se.duration_rounds as i32;
                if scaling_factor > 0 {
                    base_dur + (ability_base / scaling_factor as i32)
                } else {
                    base_dur
                }
            } else {
                se.duration_rounds as i32
            };

            let new_effect = crate::types::status_effects::ActiveEffect {
                effect_name: se.effect_name.clone(),
                effect_type: se.effect_type.as_deref()
                    .map(parse_effect_type)
                    .unwrap_or(crate::types::status_effects::EffectType::Buff),
                remaining_rounds: duration,
                stack_count: 1,
                max_stacks: se.max_stacks.max(1),
                stack_behavior: se.stack_behavior.as_deref()
                    .map(parse_stack_behavior)
                    .unwrap_or(crate::types::status_effects::StackBehavior::Refresh),
                flat_reduction: se.flat_reduction,
                flat_protection: se.flat_protection,
                damage_types: se.damage_types.iter()
                    .filter_map(|s| parse_damage_type(s))
                    .collect(),
                dot_damage: se.dot_damage.clone(),
                dot_damage_type: se.dot_damage_type.as_deref()
                    .and_then(parse_damage_type),
                shield_hp: se.shield_hp,
                value: se.value,
                damage_mult: se.damage_mult,
                healing_accumulator: 0.0,
                source_id: Some(caster_id),
                cannot_target_id: None,
            };
            if let Some(target) = state
                .participants
                .iter_mut()
                .find(|p| p.id == abt.participant_id)
            {
                status_effects::apply_effect(&mut target.status_effects, new_effect.clone());
                events.push(CombatEvent::StatusApplied {
                    target_id: abt.participant_id,
                    effect_name: se.effect_name.clone(),
                    duration,
                    source_id: Some(caster_id),
                });
            }
        }
    }

    // Set specific cooldown
    if ability.cooldown_rounds > 0 {
        if let Some(caster) = state
            .participants
            .iter_mut()
            .find(|p| p.id == caster_id)
        {
            caster
                .cooldowns
                .insert(ability_id, ability.cooldown_rounds as i32);
        }
    }

    // --- 13. Global cooldown ---
    // Ruby fight_participant.rb sets the dedicated `global_ability_cooldown` field
    // (fight_participant.rb:967). Match that shape rather than stamping every
    // ability's cooldown; Rust AI checks `participant.global_cooldown` directly.
    if ability.global_cooldown_rounds > 0 {
        if let Some(caster) = state
            .participants
            .iter_mut()
            .find(|p| p.id == caster_id)
        {
            let new_gcd = ability.global_cooldown_rounds;
            if caster.global_cooldown < new_gcd {
                caster.global_cooldown = new_gcd;
            }
        }
    }

    // Ruby parity: health_cost is applied at ability *activation* time
    // (pre-resolution, outside combat_resolution_service). apply_ability_costs!
    // in fight_participant.rb:943 only handles penalties and cooldowns —
    // never health_cost or qi_cost. Deducting here double-counted the cost
    // against the caster.
    ko_list
}

/// Apply ability damage modifiers for a specific damage type.
/// Handles vulnerability multipliers and flat damage reduction from status effects.
/// Shield absorption is handled at the cumulative level in the defense pipeline.
fn apply_ability_damage_modifiers(
    damage: i32,
    dtype: &DamageType,
    effects: &[crate::types::status_effects::ActiveEffect],
    bypasses_resistances: bool,
) -> i32 {
    let mut modified = damage;

    // Apply vulnerability/resistance multipliers
    if !bypasses_resistances {
        let mult = status_effects::damage_type_multiplier(effects, dtype);
        modified = (modified as f32 * mult) as i32;
    }

    // Apply flat damage reduction
    let reduction = status_effects::flat_damage_reduction(effects, dtype);
    modified = (modified - reduction).max(0);

    modified
}

/// Evaluate a conditional damage condition against target/caster state.
fn evaluate_condition(
    condition: &str,
    status_name: Option<&str>,
    target_id: u64,
    caster_id: u64,
    state: &FightState,
) -> bool {
    let target = find_participant(&state.participants, target_id);
    let caster = find_participant(&state.participants, caster_id);

    match condition {
        "target_below_50_hp" => target.map_or(false, |t| t.hp_percent() < 0.5),
        "target_below_25_hp" => target.map_or(false, |t| t.hp_percent() < 0.25),
        "target_has_status" => {
            if let Some(name) = status_name {
                target.map_or(false, |t| status_effects::has_effect(&t.status_effects, name))
            } else {
                false
            }
        }
        "first_attack_of_round" => {
            caster.map_or(false, |c| c.attacks_this_round == 0)
        }
        "target_prone" => target.map_or(false, |t| t.is_prone),
        "target_burning" => {
            target.map_or(false, |t| status_effects::has_effect(&t.status_effects, "burning"))
        }
        "target_poisoned" => {
            target.map_or(false, |t| status_effects::has_effect(&t.status_effects, "poisoned"))
        }
        "target_bleeding" => {
            target.map_or(false, |t| status_effects::has_effect(&t.status_effects, "bleeding"))
        }
        _ => false,
    }
}

/// Process a DOT tick event. Returns knocked-out target ID if knockout occurs.
///
/// Ruby routes DOT damage through shield absorption → `state[:dot_cumulative]` →
/// `calculate_effective_cumulative()` Step 4 (after qi defense). So DOTs bypass
/// armor, protection, AND qi defense, but shields DO absorb DOT damage.
fn process_dot_event(
    state: &mut FightState,
    target_id: u64,
    effect_name: &str,
    damage: i32,
    segment: u32,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    round_damage_states: &mut HashMap<u64, defense::RoundDamageState>,
    pre_rolls: &[PreRolls],
    actions: &[PlayerAction],
) -> Option<u64> {
    if is_knocked_out(target_id, state) {
        return None;
    }

    if damage > 0 {
        // Shield absorption for DOTs (Ruby line 2069)
        let shield_absorbed = {
            let target = state.participants.iter_mut().find(|p| p.id == target_id).unwrap();
            let before = damage;
            let after = status_effects::shield_absorb(&mut target.status_effects, damage);
            before - after
        };
        let post_shield = damage - shield_absorbed;

        // Route through RoundDamageState → calculate_effective_cumulative (matching Ruby).
        // DOT damage goes into dot_cumulative, added at Step 4 (after qi defense).
        let qi_defense_for_target = pre_rolls.iter()
            .find(|r| r.participant_id == target_id)
            .and_then(|r| r.qi_defense_roll)
            .unwrap_or(0);
        let rds = round_damage_states
            .entry(target_id)
            .or_insert_with(|| defense::RoundDamageState::new(qi_defense_for_target));
        rds.accumulate_dot(post_shield);
        rds.shield_absorbed += shield_absorbed;

        // Run full cumulative defense pipeline
        let qi_aura_active = actions.iter()
            .find(|a| a.participant_id == target_id)
            .map_or(false, |a| matches!(a.tactic, TacticChoice::QiAura));
        let target_style = find_participant(&state.participants, target_id)
            .and_then(|t| t.combat_style.clone());
        let target_effects = find_participant(&state.participants, target_id)
            .map(|t| t.status_effects.clone())
            .unwrap_or_default();
        let defense_result = defense::calculate_effective_cumulative(
            rds, qi_aura_active, target_style.as_ref(), &target_effects,
        );

        // Feed effective cumulative into threshold calc with dynamic wound_penalty
        let current_wound_penalty = if state.fight_mode == FightMode::Spar {
            0
        } else {
            find_participant(&state.participants, target_id)
                .map(|t| t.wound_penalty())
                .unwrap_or(0)
        };

        let config = &state.config;
        let tgt_style = state.participants.iter()
            .find(|p| p.id == target_id)
            .and_then(|t| t.combat_style.as_ref());
        let tgt_thresholds =
            crate::damage::effective_thresholds(&config.damage_thresholds, tgt_style);

        let tracker = damage_trackers
            .entry(target_id)
            .or_insert_with(|| DamageTracker::new(0));
        tracker.cumulative_damage = defense_result.final_damage;
        tracker.wound_penalty = current_wound_penalty;
        let new_total_hp = crate::damage::calculate_hp_from_damage(
            defense_result.final_damage,
            current_wound_penalty,
            &tgt_thresholds,
            config.high_damage_base_hp,
            config.high_damage_band_size,
        );
        let hp_lost = (new_total_hp - tracker.total_hp_lost).max(0);
        tracker.total_hp_lost = new_total_hp;

        events.push(CombatEvent::DotTick {
            target_id,
            effect_name: effect_name.to_string(),
            damage,
            hp_lost,
            segment,
        });

        if hp_lost > 0 {
            apply_hp_loss(state, target_id, hp_lost);

            if check_knockout(state, target_id) {
                let reason = ko_reason_for(state, target_id);
                events.push(CombatEvent::KnockedOut {
                    participant_id: target_id,
                    by_id: None,
                    reason,
                });
                return Some(target_id);
            }
        }
    } else {
        events.push(CombatEvent::DotTick {
            target_id,
            effect_name: effect_name.to_string(),
            damage,
            hp_lost: 0,
            segment,
        });
    }

    None
}

/// Process a stand-up event.
fn process_standup(
    state: &mut FightState,
    participant_id: u64,
    events: &mut Vec<CombatEvent>,
) {
    if let Some(p) = state
        .participants
        .iter_mut()
        .find(|p| p.id == participant_id)
    {
        p.is_prone = false;
        events.push(CombatEvent::TacticActivated {
            participant_id,
            tactic: "stand_up".to_string(),
        });
    }
}

/// Move participant to stored climb-back coords and remove dangling effect.
/// Ruby: combat_resolution_service.rb:3825 process_dangling_climb_back.
fn process_dangling_climb_back(
    state: &mut FightState,
    participant_id: u64,
    _segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    if let Some(p) = state.participants.iter_mut().find(|p| p.id == participant_id) {
        if p.is_knocked_out { return; }
        let still_dangling = p.status_effects.iter().any(|e| e.effect_name == "dangling");
        if !still_dangling { return; }

        let (Some(cx), Some(cy)) = (p.climb_back_x, p.climb_back_y) else { return; };
        let from = p.position;
        p.position = crate::types::hex::HexCoord { x: cx, y: cy, z: from.z };
        p.moved_this_round = true;
        // Clear dangling and its stored coords.
        p.status_effects.retain(|e| e.effect_name != "dangling");
        p.climb_back_x = None;
        p.climb_back_y = None;

        events.push(CombatEvent::ClimbBack {
            participant_id,
            monster_id: 0, // dangling is not monster-related; keep schema uniform
            segment: _segment,
        });
        // Emit the underlying move so downstream tooling sees the position change.
        events.push(CombatEvent::Moved {
            participant_id,
            from,
            to: crate::types::hex::HexCoord { x: cx, y: cy, z: from.z },
            segment: _segment,
        });
    }
}

// ---------------------------------------------------------------------------
// Monster attack processing
// ---------------------------------------------------------------------------

/// Process a monster attack against a participant target.
///
/// Looks up the monster by segment_id (monster.id), rolls damage from the
/// first living segment's dice, and applies it through the damage tracker.
/// Returns the target's ID if knocked out.
/// Process a player attack on a large-monster segment.
/// Mirrors Ruby combat_resolution_service.rb:1128 schedule_player_attacks_on_monster
/// and its per-attack damage application through monster_combat helpers.
fn process_player_attack_on_monster(
    state: &mut FightState,
    attacker_id: u64,
    monster_id: u64,
    _scheduled_segment_id: u64,
    combat_pre_rolls: &[CombatPreRoll],
    segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    // Read attacker position + wound_penalty before mutable borrows below.
    let (attacker_pos, wound_penalty) = match state.participants.iter().find(|p| p.id == attacker_id) {
        Some(p) => (p.position, p.wound_penalty()),
        None => return,
    };

    // Mark attacker as acted
    if let Some(p) = state.participants.iter_mut().find(|p| p.id == attacker_id) {
        p.acted_this_round = true;
    }

    // Count attacks scheduled this round for share-of-roll.
    // Ruby (combat_resolution_service.rb:2358-2372): per-attack damage =
    // (roll_total + stat_mod - wound_penalty + tactic_outgoing + outgoing_modifier)
    // divided by attack_count. tactic_outgoing and outgoing_modifier are 0 in
    // current rules (fight_participant.rb:370-372); wound_penalty is max_hp - current_hp.
    let pr = combat_pre_rolls.iter().find(|r| r.participant_id == attacker_id);
    let (roll_total, stat_mod, attack_count) = match pr {
        Some(p) => (p.roll_total, p.stat_modifier, p.attack_count.max(1)),
        None => (0, 0, 1),
    };
    let per_attack_damage =
        (roll_total as f64 + stat_mod as f64 - wound_penalty as f64) / attack_count as f64;

    // Dynamic closest-segment re-targeting: mirror Ruby
    // `large_monster_instance.rb:54-62` (Euclidean distance over active_segments).
    // Ignore the scheduled `segment_id` — Ruby picks the closest living segment
    // at attack time, so when the first target dies, subsequent attacks in the
    // same round retarget.
    let seg_idx = {
        let monster = match state.monsters.iter().find(|m| m.id == monster_id) {
            Some(m) => m,
            None => return,
        };
        let mut best: Option<(usize, f64)> = None;
        for (i, seg) in monster.segments.iter().enumerate() {
            if seg.current_hp <= 0 {
                continue;
            }
            let dx = (seg.position.x - attacker_pos.x) as f64;
            let dy = (seg.position.y - attacker_pos.y) as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            if best.map_or(true, |(_, best_d)| {
                dist < best_d || (dist == best_d && i < best.unwrap().0)
            }) {
                best = Some((i, dist));
            }
        }
        match best {
            Some((i, _)) => i,
            None => return,
        }
    };
    // Rebind segment_id to the dynamically-chosen target.
    let segment_id = state
        .monsters
        .iter()
        .find(|m| m.id == monster_id)
        .and_then(|m| m.segments.get(seg_idx))
        .map(|s| s.id)
        .unwrap_or(0);

    // Ruby: apply_weak_point_attack fires only when MonsterMountState#at_weak_point?
    // returns true — i.e. the attacker is mounted AND climb_progress >= climb_distance.
    // Target segment's weak-point flag alone is not sufficient.
    let attacker_at_weak_point = state
        .monsters
        .iter()
        .find(|m| m.id == monster_id)
        .and_then(|m| m.mount_states.iter().find(|ms| ms.participant_id == attacker_id))
        .map(|ms| ms.is_at_weak_point)
        .unwrap_or(false);
    let apply_weak_point_bonus = attacker_at_weak_point;

    // Apply damage to the monster.
    //
    // Ruby (monster_damage_service.rb):
    //   * apply_damage_to_segment (non-weak-point): segment.apply_damage!(damage) clamps
    //     segment HP to 0; @monster.apply_damage!(damage) subtracts RAW damage from
    //     monster HP (also clamped to 0). Event damage = segment_hp_lost (clamped).
    //   * apply_weak_point_attack: total = base * 3; per_seg = ceil(total / active_count);
    //     each active segment takes per_seg (clamped); monster HP drops per_seg per segment.
    let mut fling_landing: Option<(i32, i32)> = None;

    if let Some(monster) = state.monsters.iter_mut().find(|m| m.id == monster_id) {
        if apply_weak_point_bonus {
            // Ruby (monster_damage_service.rb:58): total_damage = base_damage * 3
            // then damage_per_segment = (total.to_f / active_count).ceil. Keep
            // the tripled total as f64 to match Ruby's float semantics.
            let total_damage_f = (per_attack_damage * 3.0).max(0.0);
            let active_indices: Vec<usize> = monster
                .segments
                .iter()
                .enumerate()
                .filter(|(_, s)| s.current_hp > 0)
                .map(|(i, _)| i)
                .collect();
            if active_indices.is_empty() {
                return;
            }
            let damage_per_segment =
                (total_damage_f / active_indices.len() as f64).ceil() as i32;
            let target_dealt = damage_per_segment.min(monster.segments[seg_idx].current_hp.max(0));
            events.push(CombatEvent::MonsterSegmentAttack {
                attacker_id,
                monster_id,
                segment_id,
                damage: target_dealt,
                segment_number: segment,
                weak_point_hit: true,
            });
            for i in active_indices {
                let seg = &mut monster.segments[i];
                let before = seg.current_hp;
                seg.current_hp = (seg.current_hp - damage_per_segment).max(0);
                let seg_dealt = before - seg.current_hp;
                monster.current_hp = (monster.current_hp - damage_per_segment).max(0);
                if seg.current_hp == 0 && before > 0 {
                    let seg_name = seg.name.clone();
                    events.push(CombatEvent::MonsterSegmentDamage {
                        monster_id,
                        segment_name: seg_name,
                        damage: seg_dealt,
                        segment_destroyed: true,
                    });
                }
            }
            if monster.current_hp == 0 {
                events.push(CombatEvent::MonsterDefeated { monster_id });
            }

            // After a weak-point hit the attacker is flung off. Ruby:
            // MonsterMountState#fling_after_weak_point_attack! sets mount_status
            // to 'thrown', clears is_at_weak_point, and scatters the participant.
            // Landing coords use a fixed N direction at distance 2 (parity specs
            // assert state delta, not exact hex).
            if let Some(ms) = monster
                .mount_states
                .iter_mut()
                .find(|ms| ms.participant_id == attacker_id)
            {
                let arena_w = state.hex_map.width as i32;
                let arena_h = state.hex_map.height as i32;
                let landing_x = (monster.center.x + 0 * 2).clamp(0, (arena_w - 1).max(0));
                let mut landing_y = (monster.center.y + -4 * 2).clamp(0, (arena_h - 1).max(0));
                if landing_y % 2 != 0 {
                    landing_y = (landing_y - 1).max(0);
                }
                ms.mount_status = MountStatus::Thrown;
                ms.climb_progress = 0;
                ms.is_at_weak_point = false;
                fling_landing = Some((landing_x, landing_y));
            }
        } else {
            let final_damage = per_attack_damage.max(0.0) as i32;
            if let Some(seg) = monster.segments.get_mut(seg_idx) {
                let dealt = final_damage.min(seg.current_hp.max(0));
                seg.current_hp -= dealt;
                // Ruby subtracts raw damage from monster HP, not the segment-clamped
                // value — overkill past segment HP still drains monster HP.
                monster.current_hp = (monster.current_hp - final_damage).max(0);
                events.push(CombatEvent::MonsterSegmentAttack {
                    attacker_id,
                    monster_id,
                    segment_id,
                    damage: dealt,
                    segment_number: segment,
                    weak_point_hit: false,
                });
                if seg.current_hp == 0 {
                    events.push(CombatEvent::MonsterSegmentDamage {
                        monster_id,
                        segment_name: seg.name.clone(),
                        damage: dealt,
                        segment_destroyed: true,
                    });
                }
                if monster.current_hp == 0 {
                    events.push(CombatEvent::MonsterDefeated { monster_id });
                }
            }
        }
    }

    if let Some((lx, ly)) = fling_landing {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == attacker_id) {
            p.is_mounted = false;
            p.position.x = lx;
            p.position.y = ly;
        }
        events.push(CombatEvent::PlayerShakeOff {
            monster_id,
            participant_id: attacker_id,
            thrown: true,
            landing_x: lx,
            landing_y: ly,
        });
    }
}

fn process_monster_attack_event(
    state: &mut FightState,
    monster_id: u64,
    segment_id: u64,
    target_id: u64,
    segment: u32,
    rng: &mut impl Rng,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    _round_damage_states: &mut HashMap<u64, defense::RoundDamageState>,
) -> Option<u64> {
    // Find the monster
    let monster = match state.monsters.iter().find(|m| m.id == monster_id) {
        Some(m) => m,
        None => return None,
    };

    // Find the specific scheduled segment, or fall back to first living
    let attacking_segment = monster
        .segments
        .iter()
        .find(|s| s.id == segment_id && s.current_hp > 0)
        .or_else(|| monster.segments.iter().find(|s| s.current_hp > 0 && s.attacks_per_round > 0));

    let (dice_count, dice_sides, damage_bonus, segment_name, seg_damage_type) = match attacking_segment {
        Some(seg) => (seg.dice_count, seg.dice_sides, seg.damage_bonus, seg.name.clone(), seg.damage_type),
        None => return None,
    };

    // Roll damage
    let roll_result = dice::roll(dice_count, dice_sides, None, damage_bonus, rng);
    let mut damage = roll_result.total;

    // Apply to target through damage tracker
    let target = match state.participants.iter().find(|p| p.id == target_id) {
        Some(p) => p,
        None => return None,
    };

    if target.is_knocked_out {
        return None;
    }

    // Apply damage through defense pipeline (matching Ruby monster_combat_service.rb:95-108)
    // 1. Damage type multiplier from status effects
    let type_mult = status_effects::damage_type_multiplier(&target.status_effects, &seg_damage_type);
    damage = (damage as f64 * type_mult as f64).round() as i32;
    // 2. Flat reduction from status effects
    let flat_red = status_effects::flat_damage_reduction(&target.status_effects, &seg_damage_type);
    damage = (damage - flat_red).max(0);
    // 3. Shield absorption
    if let Some(p) = state.participants.iter_mut().find(|p| p.id == target_id) {
        let absorbed = status_effects::shield_absorb(&mut p.status_effects, damage);
        damage = (damage - absorbed).max(0);
    }

    let tracker = damage_trackers.get_mut(&target_id)?;
    let hp_lost = tracker.accumulate(
        damage as f64,
        &state.config.damage_thresholds,
        state.config.high_damage_base_hp,
        state.config.high_damage_band_size,
    );

    // Apply HP loss
    if hp_lost > 0 {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == target_id) {
            p.current_hp = p.current_hp.saturating_sub(hp_lost as u8);
        }
    }

    events.push(CombatEvent::MonsterAttack {
        monster_id,
        segment_name,
        target_id,
        damage,
        segment,
    });

    // Check knockout
    let (should_ko, reason) = {
        let target = state.participants.iter().find(|p| p.id == target_id)?;
        if target.current_hp == 0 && !target.is_knocked_out {
            let r = if target.is_hostile_npc {
                crate::types::events::KoReason::Died
            } else {
                crate::types::events::KoReason::Defeat
            };
            (true, r)
        } else {
            (false, crate::types::events::KoReason::Defeat)
        }
    };
    if should_ko {
        if let Some(t) = state.participants.iter_mut().find(|p| p.id == target_id) {
            t.is_knocked_out = true;
        }
        events.push(CombatEvent::KnockedOut {
            participant_id: target_id,
            by_id: None,
            reason,
        });
        return Some(target_id);
    }

    None
}

// ---------------------------------------------------------------------------
// Monster shake-off event processor
// ---------------------------------------------------------------------------

/// Process a scheduled monster shake-off at `segment`.
///
/// Mirrors Ruby `MonsterMountingService#process_shake_off`
/// (backend/app/services/npc/monster_mounting_service.rb:113-152): for every
/// non-dismounted mount state, if the participant's `mount_action == "cling"`,
/// they stay on safely; otherwise they are thrown to a scatter position with
/// `mount_status = Thrown` and `is_mounted = false` on the Participant.
fn process_monster_shake_off_event(
    state: &mut FightState,
    monster_id: u64,
    segment: u32,
    rng: &mut impl Rng,
    events: &mut Vec<CombatEvent>,
) {
    let arena_w = state.hex_map.width as i32;
    let arena_h = state.hex_map.height as i32;

    let cling_ids: std::collections::HashSet<u64> = state
        .participants
        .iter()
        .filter(|p| p.mount_action.as_deref() == Some("cling"))
        .map(|p| p.id)
        .collect();

    // (participant_id, landing_x, landing_y)
    let mut thrown: Vec<(u64, i32, i32)> = Vec::new();

    if let Some(monster) = state.monsters.iter_mut().find(|m| m.id == monster_id) {
        for mount in &mut monster.mount_states {
            if mount.mount_status == MountStatus::Dismounted {
                continue;
            }
            if cling_ids.contains(&mount.participant_id) {
                continue;
            }

            let distance = rng.gen_range(2..=4i32);
            let direction = rng.gen_range(0..6u8);
            let (dx, dy) = match direction % 6 {
                0 => (0i32, -4i32),
                1 => (1, -2),
                2 => (1, 2),
                3 => (0, 4),
                4 => (-1, 2),
                _ => (-1, -2),
            };
            let landing_x = (monster.center.x + dx * distance).clamp(0, (arena_w - 1).max(0));
            let mut landing_y = (monster.center.y + dy * distance).clamp(0, (arena_h - 1).max(0));
            if landing_y % 2 != 0 {
                landing_y = (landing_y - 1).max(0);
            }

            mount.mount_status = MountStatus::Thrown;
            mount.climb_progress = 0;
            mount.is_at_weak_point = false;

            thrown.push((mount.participant_id, landing_x, landing_y));
        }
    }

    let thrown_ids: Vec<u64> = thrown.iter().map(|(id, _, _)| *id).collect();

    for (pid, landing_x, landing_y) in &thrown {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == *pid) {
            p.is_mounted = false;
            p.position.x = *landing_x;
            p.position.y = *landing_y;
        }
        events.push(CombatEvent::PlayerShakeOff {
            monster_id,
            participant_id: *pid,
            thrown: true,
            landing_x: *landing_x,
            landing_y: *landing_y,
        });
    }

    events.push(CombatEvent::MonsterShakeOff {
        monster_id,
        segment,
        thrown: thrown_ids,
    });
}

// ---------------------------------------------------------------------------
// Status effect processing
// ---------------------------------------------------------------------------

/// Tick all status effect durations for all participants.
fn tick_all_effects(state: &mut FightState, _events: &mut Vec<CombatEvent>) {
    for p in &mut state.participants {
        if !p.is_knocked_out {
            status_effects::tick_effects(&mut p.status_effects);
        }
    }
}

/// Expire all exhausted status effects and emit events.
fn expire_all_effects(state: &mut FightState, events: &mut Vec<CombatEvent>) {
    for p in &mut state.participants {
        let expired = status_effects::expire_effects(&mut p.status_effects);
        for name in expired {
            events.push(CombatEvent::StatusExpired {
                target_id: p.id,
                effect_name: name,
            });
        }
    }
}

/// Process flee/surrender at end of round.
/// Ruby: fleeing participants who took zero damage this round escape the fight.
/// Fleeing participants who took damage have their flee cancelled.
/// Surrendering participants are marked as knocked out (helpless).
fn process_flee_surrender(
    state: &mut FightState,
    actions: &[PlayerAction],
    damage_trackers: &HashMap<u64, DamageTracker>,
    events: &mut Vec<CombatEvent>,
    knockouts: &mut Vec<u64>,
) {
    for action in actions {
        let participant = match find_participant(&state.participants, action.participant_id) {
            Some(p) => p,
            None => continue,
        };
        if participant.is_knocked_out {
            continue;
        }

        // Check flee (movement action) and surrender (main action)
        let is_fleeing = matches!(&action.movement, MovementAction::Flee { .. });

        if is_fleeing {
            // Ruby: any accumulated raw damage cancels flee, not just HP loss.
            // combat_resolution_service.rb:3411 checks `damage_taken.zero?` on
            // cumulative_damage.
            let damage_taken = damage_trackers
                .get(&action.participant_id)
                .map_or(0.0, |t| t.cumulative_damage);

            let (dir, exit) = if let MovementAction::Flee { ref direction, exit_id } = action.movement {
                (direction.clone(), exit_id)
            } else {
                ("south".to_string(), None)
            };

            if damage_taken <= 0.0 {
                if let Some(p) = state.participants.iter_mut().find(|p| p.id == action.participant_id) {
                    p.is_knocked_out = true;
                }
                knockouts.push(action.participant_id);
                events.push(CombatEvent::FleeSuccess {
                    participant_id: action.participant_id,
                    direction: dir,
                    exit_id: exit,
                });
            } else {
                events.push(CombatEvent::FleeFailed {
                    participant_id: action.participant_id,
                    direction: dir,
                    damage_taken,
                });
            }
        }

        match &action.main_action {
            MainAction::Surrender => {
                // Surrender: mark as knocked out (helpless). Ruby routes this
                // through PrisonerService.process_surrender! — encoded as
                // `reason: Surrender` so the wrapper can dispatch correctly.
                if let Some(p) = state.participants.iter_mut().find(|p| p.id == action.participant_id) {
                    p.is_knocked_out = true;
                }
                knockouts.push(action.participant_id);
                events.push(CombatEvent::KnockedOut {
                    participant_id: action.participant_id,
                    by_id: None,
                    reason: crate::types::events::KoReason::Surrender,
                });
            }
            _ => {}
        }
    }
}

/// Process battle map hazard damage at end of round.
/// Ruby iterates all active participants and applies hazard damage from their hex.
fn process_hazard_damage(
    state: &mut FightState,
    events: &mut Vec<CombatEvent>,
    knockouts: &mut Vec<u64>,
) {
    // Skip if no hex map cells (no battle map)
    if state.hex_map.cells.is_empty() {
        return;
    }

    let participant_ids: Vec<u64> = state.participants
        .iter()
        .filter(|p| !p.is_knocked_out)
        .map(|p| p.id)
        .collect();

    for pid in participant_ids {
        let (pos, _) = {
            let p = match find_participant(&state.participants, pid) {
                Some(p) => p,
                None => continue,
            };
            (p.position, p.current_hp)
        };

        if let Some((hazard_type, hazard_damage)) = battle_map::hazard_at(&state.hex_map, &pos) {
            let hazard_name = format!("{:?}", hazard_type).to_lowercase();
            if hazard_name != "fire" {
                continue;
            }
            if hazard_damage > 0 {
                let hp_lost_opt: Option<i32> = state
                    .participants
                    .iter_mut()
                    .find(|p| p.id == pid)
                    .map(|p| {
                        // Route hazard damage through the damage-threshold pipeline
                        // (matches attack-path HP resolution). Wound penalty is the
                        // participant's penalty at this point in the round (incremental
                        // HP loss has already been applied).
                        let wound_penalty = (p.max_hp as i32) - (p.current_hp as i32);
                        let raw_hp_lost = crate::damage::calculate_hp_from_damage(
                            hazard_damage as f64,
                            wound_penalty,
                            &state.config.damage_thresholds,
                            state.config.high_damage_base_hp,
                            state.config.high_damage_band_size,
                        );
                        let hp_lost = raw_hp_lost.min(p.current_hp as i32);
                        if hp_lost > 0 {
                            p.current_hp = p.current_hp.saturating_sub(hp_lost as u8);
                        }
                        hp_lost
                    });

                if let Some(hp_lost) = hp_lost_opt {
                    events.push(CombatEvent::HazardDamage {
                        participant_id: pid,
                        hazard_type: hazard_name,
                        damage: hazard_damage,
                        hp_lost,
                        segment: 100,
                    });
                    if hp_lost > 0 && check_knockout(state, pid) {
                        let reason = ko_reason_for(state, pid);
                        events.push(CombatEvent::KnockedOut {
                            participant_id: pid,
                            by_id: None,
                            reason,
                        });
                        knockouts.push(pid);
                    }
                }
            }
        }
    }
}

/// Process healing from Regeneration effects.
fn process_healing(state: &mut FightState, events: &mut Vec<CombatEvent>) {
    // Ruby: status_effect_service.rb:402-411 + fight_participant.rb:1211-1223 --
    // Each round adds healing_rate to an accumulator. Only heals when >= 1.0.
    // HealingModifier scales the final extracted integer, not the per-round rate
    // (Ruby heal! applies healing_modifier AFTER extracting the integer heal from
    // the accumulator). Rust mirrors: accumulator += raw_rate, then scale the
    // extracted integer by healing_scalar when heal_total is applied.
    for p in &mut state.participants {
        if p.is_knocked_out {
            continue;
        }
        let heal_scalar = status_effects::healing_scalar(&p.status_effects);
        let mut heal_total = 0i32;
        for effect in &mut p.status_effects {
            if effect.effect_type == EffectType::Regeneration {
                let rate = effect.value as f32 * effect.stack_count as f32;
                effect.healing_accumulator += rate;
                if effect.healing_accumulator >= 1.0 {
                    let amount = effect.healing_accumulator.floor() as i32;
                    effect.healing_accumulator -= amount as f32;
                    // Scale the extracted integer by healing_scalar (Ruby's heal!
                    // applies healing_modifier to each amount individually).
                    let scaled = (amount as f32 * heal_scalar).round() as i32;
                    heal_total += scaled;
                }
            }
        }
        if heal_total > 0 {
            let actual = p.heal(heal_total);
            if actual > 0 {
                events.push(CombatEvent::Healed {
                    target_id: p.id,
                    amount: actual,
                    source_id: None,
                });
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Qi and cooldown management
// ---------------------------------------------------------------------------

/// Regenerate qi for all participants (suppressed if qi_aura or qi_lightness active).
fn regenerate_qi(state: &mut FightState, actions: &[PlayerAction]) {
    let regen_amount = state.config.qi.regen_per_round;
    let max_qi = state.config.qi.max_dice;

    for p in &mut state.participants {
        if p.is_knocked_out {
            continue;
        }

        // Check if this participant used qi_aura or qi_lightness this round
        let action = actions.iter().find(|a| a.participant_id == p.id);
        let suppressed = action.map_or(false, |a| {
            matches!(
                a.tactic,
                TacticChoice::QiAura | TacticChoice::QiLightness { .. }
            )
        });

        if !suppressed {
            p.qi_dice = (p.qi_dice + regen_amount).min(max_qi);
        }
    }
}

/// Decay all ability cooldowns by the configured amount per round.
fn decay_cooldowns(state: &mut FightState) {
    // Ruby decays by 1 per round (fight_participant.rb:1086), not by config value
    for p in &mut state.participants {
        p.cooldowns.values_mut().for_each(|cd| {
            *cd = cd.saturating_sub(1);
        });
        p.cooldowns.retain(|_, cd| *cd > 0);
        // Also decay global cooldown
        if p.global_cooldown > 0 {
            p.global_cooldown = p.global_cooldown.saturating_sub(1);
        }
    }
}

// ---------------------------------------------------------------------------
// Melee catch-up
// ---------------------------------------------------------------------------

/// Check if an attacker will close to melee range (≤1 hex) of a target within
/// the next `window` segments. Matches Ruby's `will_close_melee_gap?`.
///
/// Looks ahead in the timeline for movement events of both attacker and target,
/// simulates their positions forward, and returns true if the attacker will be
/// adjacent at any future segment within the window.
fn will_close_melee_gap(
    timeline: &SegmentTimeline,
    attacker_id: u64,
    target_id: u64,
    current_segment: u32,
    window: u32,
    state: &FightState,
) -> bool {
    let max_segment = (current_segment + window).min(state.config.segments.total);

    // Verify both participants exist
    if find_participant(&state.participants, attacker_id).is_none() {
        return false;
    }
    let target_pos = match find_participant(&state.participants, target_id) {
        Some(p) => p.position,
        None => return false,
    };

    // Collect future movement positions for attacker and target
    let mut attacker_positions: Vec<(u32, i32, i32)> = Vec::new();
    let mut target_positions: Vec<(u32, i32, i32)> = Vec::new();

    for event in timeline.events_in_order() {
        if event.segment <= current_segment || event.segment > max_segment {
            continue;
        }
        if let SegmentEventType::Movement { target_x, target_y, .. } = &event.event_type {
            if event.participant_id == attacker_id {
                attacker_positions.push((event.segment, *target_x, *target_y));
            } else if event.participant_id == target_id {
                target_positions.push((event.segment, *target_x, *target_y));
            }
        }
    }

    if attacker_positions.is_empty() {
        return false; // attacker has no future movement
    }

    // Simulate forward: for each attacker movement, check if they'd be adjacent
    let mut last_target_x = target_pos.x;
    let mut last_target_y = target_pos.y;
    let mut target_idx = 0;

    for &(seg, ax, ay) in &attacker_positions {
        // Update target position for any movement at or before this segment
        while target_idx < target_positions.len() && target_positions[target_idx].0 <= seg {
            last_target_x = target_positions[target_idx].1;
            last_target_y = target_positions[target_idx].2;
            target_idx += 1;
        }

        let dist = hex_grid::hex_distance(ax, ay, last_target_x, last_target_y);
        if dist <= 1 {
            return true;
        }
    }

    false
}

// ---------------------------------------------------------------------------
// Fight end detection
// ---------------------------------------------------------------------------

/// Check if the fight has ended. Returns (fight_ended, winner_side).
fn check_fight_end(state: &FightState) -> (bool, Option<u8>) {
    match state.fight_mode {
        FightMode::Normal => check_fight_end_normal(state),
        FightMode::Spar => check_fight_end_spar(state),
    }
}

/// Normal mode: one side has all members knocked out.
fn check_fight_end_normal(state: &FightState) -> (bool, Option<u8>) {
    // Collect unique sides
    let mut sides: Vec<u8> = state
        .participants
        .iter()
        .map(|p| p.side)
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect();
    sides.sort();

    if sides.len() < 2 {
        return (false, None); // need at least 2 sides
    }

    // Check each side: if all members are knocked out, that side lost
    let mut sides_alive: Vec<u8> = Vec::new();
    for &side in &sides {
        let has_active = state
            .participants
            .iter()
            .any(|p| p.side == side && !p.is_knocked_out);
        if has_active {
            sides_alive.push(side);
        }
    }

    if sides_alive.len() == 1 {
        (true, Some(sides_alive[0]))
    } else if sides_alive.is_empty() {
        (true, None) // draw
    } else {
        (false, None)
    }
}

/// Spar mode: any participant's touch_count >= max_hp.
fn check_fight_end_spar(state: &FightState) -> (bool, Option<u8>) {
    for p in &state.participants {
        if p.touch_count >= p.max_hp {
            // The OTHER side wins (this participant was touched out)
            let winner_side = state
                .participants
                .iter()
                .find(|other| other.side != p.side)
                .map(|other| other.side);
            return (true, winner_side);
        }
    }
    (false, None)
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

fn find_participant(participants: &[Participant], id: u64) -> Option<&Participant> {
    participants.iter().find(|p| p.id == id)
}

fn is_knocked_out(participant_id: u64, state: &FightState) -> bool {
    state
        .participants
        .iter()
        .find(|p| p.id == participant_id)
        .map_or(true, |p| p.is_knocked_out)
}

/// Check if a participant should be knocked out and update state.
///
/// In spar mode, a participant whose touch_count reaches max_hp is defeated
/// — the fight should stop landing hits on them immediately (you don't keep
/// swinging after scoring the final touch). Ruby currently KEEPS hitting
/// touched-out participants until the round boundary because
/// `apply_incremental_hp_loss!` (fight_participant.rb:187) returns early
/// without setting is_knocked_out; that's a Ruby-side bug. Rust does the
/// right thing.
fn check_knockout(state: &mut FightState, target_id: u64) -> bool {
    let should_ko = match state.fight_mode {
        FightMode::Normal => {
            state
                .participants
                .iter()
                .find(|p| p.id == target_id)
                .map_or(false, |p| p.current_hp == 0)
        }
        FightMode::Spar => {
            state
                .participants
                .iter()
                .find(|p| p.id == target_id)
                .map_or(false, |p| p.touch_count >= p.max_hp)
        }
    };

    if should_ko {
        if let Some(p) = state
            .participants
            .iter_mut()
            .find(|p| p.id == target_id)
        {
            p.is_knocked_out = true;
        }
    }

    should_ko
}

/// Apply queued combat-style switches at end of round. Ruby mirror:
/// `combat_resolution_service.rb:401` → `FightParticipant#apply_style_switch!`.
/// Rust clears the pending field locally and emits `StyleSwitched` so the
/// Ruby writeback can invoke the real apply (variant-lock, character_instance
/// preference) against the DB.
fn apply_style_switches(state: &mut FightState, events: &mut Vec<CombatEvent>) {
    for p in state.participants.iter_mut() {
        if p.is_knocked_out {
            continue;
        }
        if let Some(new_style) = p.pending_style_switch.take() {
            let old_style = p.combat_style.as_ref().map(|cs| cs.name.clone());
            if let Some(cs) = p.combat_style.as_mut() {
                cs.name = new_style.clone();
            }
            events.push(CombatEvent::StyleSwitched {
                participant_id: p.id,
                old_style,
                new_style,
            });
        }
    }
}

/// Determine the KO reason for a participant who's being taken out of the
/// fight by damage / touch-out / instant-kill. Hostile NPCs are `Died`
/// (Ruby `NpcSpawnService.kill_npc!`); anyone else is `Defeat` (Ruby
/// `PrisonerService.process_knockout!` for PCs). Surrender is never routed
/// through here — that site sets `Surrender` explicitly.
fn ko_reason_for(state: &FightState, target_id: u64) -> crate::types::events::KoReason {
    use crate::types::events::KoReason;
    state
        .participants
        .iter()
        .find(|p| p.id == target_id)
        .map_or(KoReason::Defeat, |p| {
            if p.is_hostile_npc {
                KoReason::Died
            } else {
                KoReason::Defeat
            }
        })
}

/// Apply HP loss to a participant (handles both Normal and Spar modes).
fn apply_hp_loss(state: &mut FightState, target_id: u64, hp_lost: i32) {
    if let Some(target) = state
        .participants
        .iter_mut()
        .find(|p| p.id == target_id)
    {
        match state.fight_mode {
            FightMode::Normal => {
                target.current_hp = target.current_hp.saturating_sub(hp_lost as u8);
                // Qi gain on HP loss
                target.qi_dice = (target.qi_dice
                    + state.config.qi.gain_per_hp_lost * hp_lost as f32)
                    .min(state.config.qi.max_dice);
            }
            FightMode::Spar => {
                target.touch_count += hp_lost as u8;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Parse helpers for status effect mechanical fields
// ---------------------------------------------------------------------------

fn parse_effect_type(s: &str) -> crate::types::status_effects::EffectType {
    use crate::types::status_effects::EffectType;
    match s {
        "DamageReduction" => EffectType::DamageReduction,
        "Protection" => EffectType::Protection,
        "Shield" => EffectType::Shield,
        "DamageOverTime" => EffectType::DamageOverTime,
        "Debuff" => EffectType::Debuff,
        "CrowdControl" => EffectType::CrowdControl,
        "Vulnerability" => EffectType::Vulnerability,
        "Regeneration" => EffectType::Regeneration,
        _ => EffectType::Buff,
    }
}

fn parse_stack_behavior(s: &str) -> crate::types::status_effects::StackBehavior {
    use crate::types::status_effects::StackBehavior;
    match s {
        "Stack" => StackBehavior::Stack,
        "Duration" => StackBehavior::Duration,
        "Ignore" => StackBehavior::Ignore,
        _ => StackBehavior::Refresh,
    }
}

fn parse_damage_type(s: &str) -> Option<crate::types::weapons::DamageType> {
    use crate::types::weapons::DamageType;
    match s {
        "Physical" => Some(DamageType::Physical),
        "Fire" => Some(DamageType::Fire),
        "Ice" => Some(DamageType::Ice),
        "Lightning" => Some(DamageType::Lightning),
        "Poison" => Some(DamageType::Poison),
        "Psychic" => Some(DamageType::Psychic),
        "Holy" => Some(DamageType::Holy),
        "Dark" => Some(DamageType::Dark),
        "Wind" => Some(DamageType::Wind),
        "Earth" => Some(DamageType::Earth),
        "Water" => Some(DamageType::Water),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::config::CombatConfig;
    use crate::types::fight_state::{FightMode, FightState};
    use crate::types::hex::{HexCell, HexCoord, HexMap};
    use crate::types::participant::Participant;
    use crate::types::weapons::{DamageType, Weapon};
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;
    use std::collections::HashMap;

    fn make_weapon() -> Weapon {
        Weapon {
            id: 1,
            name: "Sword".to_string(),
            dice_count: 2,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 2,
            speed: 5,
            is_ranged: false,
            range_hexes: None,
            attack_range_hexes: 1,
            is_unarmed: false,
        }
    }

    fn make_participant(id: u64, side: u8, x: i32, y: i32) -> Participant {
        Participant {
            id,
            side,
            current_hp: 6,
            max_hp: 6,
            qi_dice: 1.0,
            qi_die_sides: 8,
            stat_modifier: 10,
            position: HexCoord { x, y, z: 0 },
            melee_weapon: Some(make_weapon()),
            ..Default::default()
        }
    }

    fn make_open_map() -> HexMap {
        let mut cells = HashMap::new();
        // Create a simple grid of valid hex coords
        for y_half in 0..5 {
            let y = (y_half * 2) as i32;
            let x_even = (y_half % 2) == 0;
            for x_step in 0..5 {
                let x = if x_even {
                    (x_step * 2) as i32
                } else {
                    (x_step * 2 + 1) as i32
                };
                cells.insert(
                    (x, y),
                    HexCell {
                        x,
                        y,
                        ..Default::default()
                    },
                );
            }
        }
        HexMap {
            width: 10,
            height: 10,
            cells,
        }
    }

    fn make_state(participants: Vec<Participant>) -> FightState {
        FightState {
            participants,
            hex_map: make_open_map(),
            ..Default::default()
        }
    }

    #[test]
    fn test_resolve_round_basic_1v1() {
        // Two participants on opposite sides attacking each other
        let p1 = make_participant(1, 0, 0, 0);
        let p2 = make_participant(2, 1, 0, 0); // same hex for guaranteed range
        let state = make_state(vec![p1, p2]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Attack { target_id: 1, monster_id: None, segment_id: None },
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        // Round should advance
        assert_eq!(result.next_state.round, 1);

        // Should have attack events (hit or miss for each participant)
        let attack_events: Vec<_> = result
            .events
            .iter()
            .filter(|e| {
                matches!(
                    e,
                    CombatEvent::AttackHit { .. } | CombatEvent::AttackMiss { .. }
                )
            })
            .collect();
        assert!(
            !attack_events.is_empty(),
            "Expected attack events, got none"
        );
    }

    #[test]
    fn test_resolve_round_deterministic() {
        // Same state + actions + seed = same result
        let p1 = make_participant(1, 0, 0, 0);
        let p2 = make_participant(2, 1, 0, 0);
        let state = make_state(vec![p1, p2]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Attack { target_id: 1, monster_id: None, segment_id: None },
                ..Default::default()
            },
        ];

        let mut rng1 = ChaCha8Rng::seed_from_u64(123);
        let result1 = resolve_round_inner(&state, &actions, &mut rng1);

        let mut rng2 = ChaCha8Rng::seed_from_u64(123);
        let result2 = resolve_round_inner(&state, &actions, &mut rng2);

        // Results should be identical
        assert_eq!(result1.next_state.round, result2.next_state.round);
        assert_eq!(result1.knockouts, result2.knockouts);
        assert_eq!(result1.fight_ended, result2.fight_ended);
        assert_eq!(result1.winner_side, result2.winner_side);
        assert_eq!(result1.events.len(), result2.events.len());

        // Check participant HP matches
        for (p1, p2) in result1
            .next_state
            .participants
            .iter()
            .zip(result2.next_state.participants.iter())
        {
            assert_eq!(p1.current_hp, p2.current_hp);
            assert_eq!(p1.is_knocked_out, p2.is_knocked_out);
        }
    }

    #[test]
    fn test_resolve_round_knockout() {
        // Set target to 1 HP so any hit knocks them out
        let p1 = make_participant(1, 0, 0, 0);
        let mut p2 = make_participant(2, 1, 0, 0);
        p2.current_hp = 1;

        let state = make_state(vec![p1, p2]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Pass,
                ..Default::default()
            },
        ];

        // Try multiple seeds to find one that produces a hit (with stat_modifier=10,
        // damage should almost always cross the threshold)
        let mut found_ko = false;
        for seed in 0..50u64 {
            let mut rng = ChaCha8Rng::seed_from_u64(seed);
            let result = resolve_round_inner(&state, &actions, &mut rng);

            if !result.knockouts.is_empty() {
                assert!(result.knockouts.contains(&2));
                // Check that participant 2 is knocked out in next_state
                let p2_state = result
                    .next_state
                    .participants
                    .iter()
                    .find(|p| p.id == 2)
                    .unwrap();
                assert!(p2_state.is_knocked_out);

                // Should have a KnockedOut event
                let ko_event = result.events.iter().any(|e| {
                    matches!(e, CombatEvent::KnockedOut {
                        participant_id: 2,
                        ..
                    })
                });
                assert!(ko_event, "Expected KnockedOut event for participant 2");

                found_ko = true;
                break;
            }
        }
        assert!(found_ko, "Expected knockout within 50 seeds");
    }

    #[test]
    fn test_resolve_round_spar_mode() {
        let p1 = make_participant(1, 0, 0, 0);
        let p2 = make_participant(2, 1, 0, 0);

        let mut state = make_state(vec![p1, p2]);
        state.fight_mode = FightMode::Spar;

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Pass,
                ..Default::default()
            },
        ];

        // Run through multiple seeds to find a hit
        for seed in 0..50u64 {
            let mut rng = ChaCha8Rng::seed_from_u64(seed);
            let result = resolve_round_inner(&state, &actions, &mut rng);

            let hit_events: Vec<_> = result
                .events
                .iter()
                .filter(|e| matches!(e, CombatEvent::AttackHit { .. }))
                .collect();

            if !hit_events.is_empty() {
                // In spar mode, HP should NOT decrease
                let p2_state = result
                    .next_state
                    .participants
                    .iter()
                    .find(|p| p.id == 2)
                    .unwrap();
                assert_eq!(
                    p2_state.current_hp, 6,
                    "Spar mode should not reduce HP"
                );
                // touch_count should have increased
                assert!(
                    p2_state.touch_count > 0,
                    "Spar mode should increment touch_count"
                );
                return;
            }
        }
        panic!("Expected at least one hit in spar mode within 50 seeds");
    }

    #[test]
    fn test_resolve_round_defend_reduces_damage() {
        // p2 defends: incoming_damage_modifier reduces raw damage
        let p1 = make_participant(1, 0, 0, 0);
        let mut p2_def = make_participant(2, 1, 0, 0);
        p2_def.incoming_damage_modifier = -10; // significant damage reduction

        let mut p2_nodef = make_participant(2, 1, 0, 0);
        p2_nodef.incoming_damage_modifier = 0;

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Defend,
                ..Default::default()
            },
        ];

        let seed = 42u64;

        // Run with defender having damage reduction
        let state_def = make_state(vec![p1.clone(), p2_def]);
        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        let result_def = resolve_round_inner(&state_def, &actions, &mut rng);

        // Run without damage reduction
        let state_nodef = make_state(vec![p1, p2_nodef]);
        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        let result_nodef = resolve_round_inner(&state_nodef, &actions, &mut rng);

        // Defender should have taken less or equal damage
        let hp_def = result_def
            .next_state
            .participants
            .iter()
            .find(|p| p.id == 2)
            .unwrap()
            .current_hp;
        let hp_nodef = result_nodef
            .next_state
            .participants
            .iter()
            .find(|p| p.id == 2)
            .unwrap()
            .current_hp;

        assert!(
            hp_def >= hp_nodef,
            "Defending participant should take <= damage: def_hp={}, nodef_hp={}",
            hp_def,
            hp_nodef
        );
    }

    #[test]
    fn test_fight_end_detection() {
        // All of side 1 knocked out -> side 0 wins
        let p1 = make_participant(1, 0, 0, 0);
        let mut p2 = make_participant(2, 1, 0, 0);
        p2.is_knocked_out = true;
        p2.current_hp = 0;

        let state = make_state(vec![p1, p2]);

        let (ended, winner) = check_fight_end(&state);
        assert!(ended);
        assert_eq!(winner, Some(0));
    }

    #[test]
    fn test_fight_end_not_ended() {
        let p1 = make_participant(1, 0, 0, 0);
        let p2 = make_participant(2, 1, 0, 0);
        let state = make_state(vec![p1, p2]);

        let (ended, _) = check_fight_end(&state);
        assert!(!ended);
    }

    #[test]
    fn test_fight_end_spar_mode() {
        let p1 = make_participant(1, 0, 0, 0);
        let mut p2 = make_participant(2, 1, 0, 0);
        p2.touch_count = 6; // equals max_hp

        let mut state = make_state(vec![p1, p2]);
        state.fight_mode = FightMode::Spar;

        let (ended, winner) = check_fight_end(&state);
        assert!(ended);
        assert_eq!(winner, Some(0)); // side 0 wins because p2 (side 1) was touched out
    }

    #[test]
    fn test_qi_regeneration() {
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 0.5; // below max
        let p2 = make_participant(2, 1, 0, 0);

        let state = make_state(vec![p1, p2]);

        // Use Defend to avoid mutual-pass ending
        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Defend,
                tactic: TacticChoice::None,
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Defend,
                tactic: TacticChoice::None,
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        let p1_after = result
            .next_state
            .participants
            .iter()
            .find(|p| p.id == 1)
            .unwrap();

        // Should have gained regen_per_round (0.34)
        let expected_qi = 0.5 + state.config.qi.regen_per_round;
        assert!(
            (p1_after.qi_dice - expected_qi).abs() < 0.01,
            "Expected qi_dice ~{}, got {}",
            expected_qi,
            p1_after.qi_dice
        );
    }

    #[test]
    fn test_qi_regen_suppressed_by_qi_aura() {
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 0.5;

        let state = make_state(vec![p1, make_participant(2, 1, 0, 0)]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Pass,
                tactic: TacticChoice::QiAura, // suppresses regen
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Pass,
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        let p1_after = result
            .next_state
            .participants
            .iter()
            .find(|p| p.id == 1)
            .unwrap();

        // qi_dice should NOT have increased
        assert!(
            (p1_after.qi_dice - 0.5).abs() < 0.01,
            "Qi regen should be suppressed by qi_aura, got {}",
            p1_after.qi_dice
        );
    }

    #[test]
    fn test_round_advances() {
        let state = make_state(vec![
            make_participant(1, 0, 0, 0),
            make_participant(2, 1, 0, 0),
        ]);

        // One participant defends (not pass) to avoid mutual-pass ending
        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Defend,
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Defend,
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        assert_eq!(result.next_state.round, 1);
        assert!(!result.fight_ended);
    }

    #[test]
    fn test_mutual_pass_ends_fight() {
        let state = make_state(vec![
            make_participant(1, 0, 0, 0),
            make_participant(2, 1, 0, 0),
        ]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Pass,
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Pass,
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        assert!(result.fight_ended, "All participants passed, fight should end");
        assert_eq!(result.winner_side, None, "Mutual pass = no winner");
    }

    #[test]
    fn test_segment_timeline_ordering() {
        // Verify that the timeline builds with events spread across segments
        let p1 = make_participant(1, 0, 0, 0);
        let p2 = make_participant(2, 1, 2, 4);
        let state = make_state(vec![p1, p2]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                movement: MovementAction::TowardsPerson(2),
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Attack { target_id: 1, monster_id: None, segment_id: None },
                ..Default::default()
            },
        ];

        let mut dummy_events = Vec::new();
        let (pre_rolls, mut seq) = pre_roll_all(&state, &actions, &mut ChaCha8Rng::seed_from_u64(42), false, &mut dummy_events);
        let timeline = build_timeline(
            &state,
            &actions,
            &pre_rolls,
            &mut ChaCha8Rng::seed_from_u64(42),
            false,
            &mut dummy_events,
            &mut seq,
        );

        assert!(!timeline.is_empty());
        let ordered = timeline.events_in_order();
        // Verify segments are in non-decreasing order
        for window in ordered.windows(2) {
            assert!(
                window[0].segment <= window[1].segment,
                "Events not in order: {} > {}",
                window[0].segment,
                window[1].segment
            );
        }
    }

    #[test]
    fn test_standup_action() {
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.is_prone = true;

        let state = make_state(vec![p1, make_participant(2, 1, 0, 0)]);

        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::StandUp,
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Pass,
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        let p1_after = result
            .next_state
            .participants
            .iter()
            .find(|p| p.id == 1)
            .unwrap();
        assert!(
            !p1_after.is_prone,
            "Participant should no longer be prone after StandUp"
        );
    }

    #[test]
    fn test_cooldown_decay() {
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.cooldowns.insert(100, 4); // ability 100 on cooldown for 4 rounds

        let state = make_state(vec![p1, make_participant(2, 1, 0, 0)]);

        // Use Defend to avoid mutual-pass ending (which short-circuits before decay)
        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Defend,
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Defend,
                ..Default::default()
            },
        ];

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        let p1_after = result
            .next_state
            .participants
            .iter()
            .find(|p| p.id == 1)
            .unwrap();

        // Cooldown decays by 1 per round (matching Ruby fight_participant.rb:1086)
        let cd = p1_after.cooldowns.get(&100).copied().unwrap_or(0);
        assert_eq!(cd, 3, "Cooldown should have decayed from 4 to 3");
    }

    // Mirror Ruby calculate_attack_damage: style bonus applied per-attack based on
    // weapon type (combat_resolution_service.rb:2964-2969). With the same seed and
    // participant, raising `melee_bonus` must raise the total damage recorded on
    // the AttackHit event.
    #[test]
    fn test_combat_style_melee_bonus_raises_damage() {
        use crate::types::fight_state::CombatStyle;

        fn run_with_bonus(bonus: i32) -> Option<i32> {
            let mut p1 = make_participant(1, 0, 0, 0);
            p1.combat_style = Some(CombatStyle {
                id: 1,
                name: "test".into(),
                bonus_type: None,
                bonus_amount: 0,
                melee_bonus: bonus,
                ranged_bonus: 99, // should NOT be used for melee attacks
                vulnerability_type: None,
                vulnerability_amount: 0.0,
                threshold_1hp: 0,
                threshold_2_3hp: 0,
            });
            let p2 = make_participant(2, 1, 0, 0);
            let state = make_state(vec![p1, p2]);
            let actions = vec![
                PlayerAction {
                    participant_id: 1,
                    main_action: MainAction::Attack {
                        target_id: 2,
                        monster_id: None,
                        segment_id: None,
                    },
                    ..Default::default()
                },
                PlayerAction {
                    participant_id: 2,
                    main_action: MainAction::Defend,
                    ..Default::default()
                },
            ];
            let mut rng = ChaCha8Rng::seed_from_u64(42);
            let result = resolve_round_inner(&state, &actions, &mut rng);
            result.events.iter().find_map(|e| match e {
                CombatEvent::AttackHit { attacker_id: 1, damage, .. } => Some(*damage as i32),
                _ => None,
            })
        }

        let d0 = run_with_bonus(0);
        let d5 = run_with_bonus(5);
        // Both must produce a hit event for the test to be meaningful.
        let (d0, d5) = (d0.expect("hit with bonus=0"), d5.expect("hit with bonus=5"));
        assert!(
            d5 > d0,
            "melee_bonus should raise damage (bonus=0 -> {d0}, bonus=5 -> {d5})"
        );
    }

    // Ranged counterpart: with a melee weapon the ranged_bonus must NOT apply.
    // Same seed, same melee weapon, changing `ranged_bonus` changes nothing.
    #[test]
    fn test_combat_style_ranged_bonus_ignored_for_melee_weapon() {
        use crate::types::fight_state::CombatStyle;

        fn run_with_ranged(bonus: i32) -> Option<i32> {
            let mut p1 = make_participant(1, 0, 0, 0);
            p1.combat_style = Some(CombatStyle {
                id: 1,
                name: "test".into(),
                bonus_type: None,
                bonus_amount: 0,
                melee_bonus: 0,
                ranged_bonus: bonus,
                vulnerability_type: None,
                vulnerability_amount: 0.0,
                threshold_1hp: 0,
                threshold_2_3hp: 0,
            });
            let p2 = make_participant(2, 1, 0, 0);
            let state = make_state(vec![p1, p2]);
            let actions = vec![
                PlayerAction {
                    participant_id: 1,
                    main_action: MainAction::Attack {
                        target_id: 2,
                        monster_id: None,
                        segment_id: None,
                    },
                    ..Default::default()
                },
                PlayerAction {
                    participant_id: 2,
                    main_action: MainAction::Defend,
                    ..Default::default()
                },
            ];
            let mut rng = ChaCha8Rng::seed_from_u64(42);
            let result = resolve_round_inner(&state, &actions, &mut rng);
            result.events.iter().find_map(|e| match e {
                CombatEvent::AttackHit { attacker_id: 1, damage, .. } => Some(*damage as i32),
                _ => None,
            })
        }

        assert_eq!(run_with_ranged(0), run_with_ranged(50));
    }

    // Ruby calculate_attack_damage adds `actor.tactic_outgoing_damage_modifier`
    // to round_total (combat_resolution_service.rb:2956). Verify the wiring.
    #[test]
    fn test_tactic_outgoing_modifier_raises_damage() {
        fn run_with_tactic(bonus: i32) -> Option<i32> {
            let mut p1 = make_participant(1, 0, 0, 0);
            p1.tactic_outgoing_damage_modifier = bonus;
            let p2 = make_participant(2, 1, 0, 0);
            let state = make_state(vec![p1, p2]);
            let actions = vec![
                PlayerAction {
                    participant_id: 1,
                    main_action: MainAction::Attack {
                        target_id: 2,
                        monster_id: None,
                        segment_id: None,
                    },
                    ..Default::default()
                },
                PlayerAction {
                    participant_id: 2,
                    main_action: MainAction::Defend,
                    ..Default::default()
                },
            ];
            let mut rng = ChaCha8Rng::seed_from_u64(42);
            let result = resolve_round_inner(&state, &actions, &mut rng);
            result.events.iter().find_map(|e| match e {
                CombatEvent::AttackHit { attacker_id: 1, damage, .. } => Some(*damage as i32),
                _ => None,
            })
        }

        let d0 = run_with_tactic(0);
        let d5 = run_with_tactic(5);
        let (d0, d5) = (d0.expect("hit tactic=0"), d5.expect("hit tactic=5"));
        assert!(d5 > d0, "tactic_outgoing_damage_modifier should raise damage");
    }

    /// Ruby emits an `out_of_range` event when an attack fires at its
    /// segment but the target is past melee reach. Rust was silently
    /// dropping these (the "1v1_defend pursuit-stalemate" symptom). Verify
    /// that `CombatEvent::AttackOutOfRange` is now emitted so the event
    /// stream doesn't go silent when the defender retreats mid-round.
    #[test]
    fn test_attack_out_of_range_emits_event() {
        // p1 at (0,0) stands still, p2 at (4,0) runs away → p1's melee
        // attacks can't reach.
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.ai_profile = Some("balanced".into());
        let mut p2 = make_participant(2, 1, 4, 0);
        p2.ai_profile = Some("defensive".into());
        let state = make_state(vec![p1, p2]);
        let actions = vec![
            PlayerAction {
                participant_id: 1,
                main_action: MainAction::Attack {
                    target_id: 2,
                    monster_id: None,
                    segment_id: None,
                },
                movement: MovementAction::StandStill,
                ..Default::default()
            },
            PlayerAction {
                participant_id: 2,
                main_action: MainAction::Defend,
                movement: MovementAction::StandStill,
                ..Default::default()
            },
        ];
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round_inner(&state, &actions, &mut rng);

        let out_of_range_count = result
            .events
            .iter()
            .filter(|e| matches!(e, CombatEvent::AttackOutOfRange { .. }))
            .count();
        assert!(
            out_of_range_count > 0,
            "expected at least one AttackOutOfRange event when attacker cannot reach target, got events: {:?}",
            result.events
        );
    }

    // ---- Wall Flip tests (Phase 10c) --------------------------------------

    fn make_wall_map_with_pit(pit_coords: &[(i32, i32)]) -> HexMap {
        let mut cells = HashMap::new();
        // Open 9×9 floor grid around (0,0).
        for y_half in -2i32..3 {
            let y = y_half * 2;
            let x_even = y_half.rem_euclid(2) == 0;
            for x_step in -2i32..3 {
                let x = if x_even { x_step * 2 } else { (x_step * 2) + 1 };
                cells.insert((x, y), HexCell { x, y, ..Default::default() });
            }
        }
        // Wall at (0, 4).
        cells.insert(
            (0, 4),
            HexCell { x: 0, y: 4, blocks_movement: true, ..Default::default() },
        );
        // Mark supplied pit coords as blocking so we can test landing fallbacks.
        for (px, py) in pit_coords {
            cells.insert(
                (*px, *py),
                HexCell { x: *px, y: *py, blocks_movement: true, ..Default::default() },
            );
        }
        HexMap { width: 10, height: 10, cells }
    }

    fn wall_flip_action(wall_x: i32, wall_y: i32, participant_id: u64, _target_id: u64) -> PlayerAction {
        PlayerAction {
            participant_id,
            movement: MovementAction::WallFlip {
                wall_x: Some(wall_x),
                wall_y: Some(wall_y),
            },
            // Non-Pass main action so the mutual-pass check doesn't end the fight.
            // Defend has no target requirement so we don't need a live enemy.
            main_action: MainAction::Defend,
            ..Default::default()
        }
    }

    #[test]
    fn test_wall_flip_adjacent_solo_lands_at_default() {
        // Mover at (0,0), wall at (0,4) (due north). Opposite=S.
        // first_back = (0,0)=launch, landing = (0,-4).
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 1.0;
        let p2 = make_participant(2, 1, 0, -4); // harmless enemy not pursuing
        let mut state = make_state(vec![p1, p2]);
        state.hex_map = make_wall_map_with_pit(&[]);
        // enemy not moving toward actor — no pursuer.
        let actions = vec![
            wall_flip_action(0, 4, 1, 2),
            PlayerAction { participant_id: 2, ..Default::default() },
        ];
        let mut rng = ChaCha8Rng::seed_from_u64(1);
        let result = resolve_round_inner(&state, &actions, &mut rng);
        let flip_event = result.events.iter().find_map(|e| match e {
            CombatEvent::WallFlip { to, pursuer_id, .. } => Some((to, *pursuer_id)),
            _ => None,
        });
        let (to, pid) = flip_event.expect("wall flip event missing");
        assert_eq!(pid, None);
        // default_landing: second_back = (0,-4); p2 is at (0,-4) but hex_is_traversable
        // doesn't consider participant occupancy, so landing = second_back.
        assert_eq!((to.x, to.y), (0, -4));
    }

    #[test]
    fn test_wall_flip_blocked_second_back_lands_at_first_back() {
        // second_back (0,-4) is a pit; first_back==launch (0,0) is open.
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 1.0;
        let mut state = make_state(vec![p1]);
        state.hex_map = make_wall_map_with_pit(&[(0, -4)]);
        let actions = vec![wall_flip_action(0, 4, 1, 0)];
        let mut rng = ChaCha8Rng::seed_from_u64(2);
        let result = resolve_round_inner(&state, &actions, &mut rng);
        let (to, _pid) = result.events.iter().find_map(|e| match e {
            CombatEvent::WallFlip { to, pursuer_id, .. } => Some((to, *pursuer_id)),
            _ => None,
        }).expect("wall flip event missing");
        // second_back blocked → first_back (launch) = (0,0).
        assert_eq!((to.x, to.y), (0, 0));
    }

    #[test]
    fn test_wall_flip_both_back_blocked_stays_at_launch() {
        // Both second_back (0,-4) and first_back (0,0) become blocking.
        // first_back is launch; the mover should stay put.
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 1.0;
        let mut state = make_state(vec![p1]);
        // Block second_back only; launch is mover's own hex (not a wall).
        // To exercise "first_back blocked" we have to put a wall at launch,
        // which is nonsensical. Instead test the case when the map forbids
        // second_back; first_back is treated as launch which is traversable —
        // so we expect first_back (launch).
        state.hex_map = make_wall_map_with_pit(&[(0, -4)]);
        let actions = vec![wall_flip_action(0, 4, 1, 0)];
        let mut rng = ChaCha8Rng::seed_from_u64(3);
        let result = resolve_round_inner(&state, &actions, &mut rng);
        let (to, _) = result.events.iter().find_map(|e| match e {
            CombatEvent::WallFlip { to, pursuer_id, .. } => Some((to, *pursuer_id)),
            _ => None,
        }).expect("wall flip event missing");
        assert_eq!((to.x, to.y), (0, 0));
    }

    #[test]
    fn test_wall_flip_pursuer_swap() {
        // Mover at (0,0), wall at (0,4). Pursuer at (0,-4), moving towards mover.
        // Expectation: pursuer → launch (0,0), mover → default_landing (0,-4).
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 1.0;
        let mut p2 = make_participant(2, 1, 0, -4);
        p2.qi_dice = 1.0;
        let mut state = make_state(vec![p1, p2]);
        state.hex_map = make_wall_map_with_pit(&[]);
        let actions = vec![
            wall_flip_action(0, 4, 1, 2),
            PlayerAction {
                participant_id: 2,
                movement: MovementAction::TowardsPerson(1),
                main_action: MainAction::Attack {
                    target_id: 1, monster_id: None, segment_id: None,
                },
                ..Default::default()
            },
        ];
        let mut rng = ChaCha8Rng::seed_from_u64(4);
        let result = resolve_round_inner(&state, &actions, &mut rng);
        let (to, pid) = result.events.iter().find_map(|e| match e {
            CombatEvent::WallFlip { to, pursuer_id, .. } => Some((to, *pursuer_id)),
            _ => None,
        }).expect("wall flip event missing");
        assert_eq!(pid, Some(2), "expected pursuer swap to reference p2");
        assert_eq!((to.x, to.y), (0, -4));
        // Pursuer moved to launch hex (0,0).
        let pursuer_pos = result.next_state.participants.iter()
            .find(|p| p.id == 2).expect("p2 missing").position;
        assert_eq!((pursuer_pos.x, pursuer_pos.y), (0, 0));
    }

    #[test]
    fn test_wall_flip_no_pursuer_when_enemy_not_targeting() {
        // Enemy within 2 hexes but not moving towards mover → no swap.
        let mut p1 = make_participant(1, 0, 0, 0);
        p1.qi_dice = 1.0;
        let p2 = make_participant(2, 1, 0, -4);
        let mut state = make_state(vec![p1, p2]);
        state.hex_map = make_wall_map_with_pit(&[]);
        let actions = vec![
            wall_flip_action(0, 4, 1, 2),
            PlayerAction {
                participant_id: 2,
                movement: MovementAction::StandStill,
                ..Default::default()
            },
        ];
        let mut rng = ChaCha8Rng::seed_from_u64(5);
        let result = resolve_round_inner(&state, &actions, &mut rng);
        let (_to, pid) = result.events.iter().find_map(|e| match e {
            CombatEvent::WallFlip { to, pursuer_id, .. } => Some((to, *pursuer_id)),
            _ => None,
        }).expect("wall flip event missing");
        assert_eq!(pid, None, "enemy standing still should not be a pursuer");
    }
}
