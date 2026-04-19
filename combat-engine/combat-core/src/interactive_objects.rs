//! Element-tactic dispatch (break / detonate / ignite).
//!
//! Mirrors Ruby `Battlemap::FightHexEffectService#resolve_tactic`
//! (backend/app/services/battlemap/fight_hex_effect_service.rb:54-65). Each
//! tactic is scheduled at `config.segments.tactical_fallback` (= 20) via
//! `SegmentEventType::ElementTactic` and dispatched here.
//!
//! Effects:
//! - **ignite**: converts an `Oil` FightHexOverlay at (target_x, target_y) to
//!   `Fire` + sets hazard on the underlying HexCell so existing
//!   `process_hazard_damage` picks it up at end-of-round.
//! - **break**: marks a BattleMapElement `state=Broken` and spreads a
//!   FightHexOverlay of the appropriate type to center + 6 neighbors
//!   (water_barrel → Puddle, oil_barrel → Oil, vase → SharpGround). Only
//!   traversable hexes receive the overlay.
//! - **detonate**: marks a `munitions_crate` `state=Detonated`, applies ring
//!   damage (30/15/5 raw to rings 0-1 / 2 / 3) to all participants in radius,
//!   and triggers chain reactions on other elements in the blast radius
//!   (cycle prevention via visited-set).

use std::collections::{HashMap, HashSet};

use crate::damage::DamageTracker;
use crate::defense;
use crate::hex_grid;
use crate::types::events::CombatEvent;
use crate::types::fight_state::FightState;
use crate::types::hex::HazardType;
use crate::types::interactive::{ElementState, ElementType, FightHexType};
use crate::types::weapons::DamageType;

/// Called when a participant enters a hex (per movement step) and at
/// end-of-round for each active participant on their current hex. Applies
/// persistent on-entry element effects (toxic_mushrooms → poisoned,
/// lotus_pollen → intoxicated). Mirrors Ruby
/// `Battlemap::FightHexEffectService#on_hex_enter` + `process_element_entry`
/// (fight_hex_effect_service.rb:14-32, 85-92).
pub fn on_hex_enter(
    state: &mut FightState,
    participant_id: u64,
    hex_x: i32,
    hex_y: i32,
    segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    // FightHex overlays: fire, puddle, long_fall, oil, sharp_ground.
    // Mirrors Ruby fight_hex_effect_service.rb:69-82 process_fight_hex_entry.
    let overlay_types: Vec<FightHexType> = state
        .fight_hexes
        .iter()
        .filter(|fh| fh.hex_x == hex_x && fh.hex_y == hex_y)
        .map(|fh| fh.hex_type)
        .collect();

    let prone = state
        .participants
        .iter()
        .find(|p| p.id == participant_id)
        .map_or(false, |p| p.is_prone);

    for ft in overlay_types {
        match ft {
            FightHexType::Fire => process_fire_entry(state, participant_id, events),
            FightHexType::Puddle => {
                process_water_entry(state, participant_id, prone, events)
            }
            FightHexType::LongFall => {
                apply_status_with_event(state, participant_id, "dangling", events);
            }
            FightHexType::Oil => {
                if prone {
                    apply_status_with_event(state, participant_id, "oil_slicked", events);
                }
            }
            FightHexType::SharpGround => {
                if prone {
                    process_sharp_ground_entry(state, participant_id, events);
                }
            }
            FightHexType::OpenWindow => {}
        }
    }

    // Persistent BattleMapElement objects at this hex: mushrooms / lotus.
    let triggers: Vec<ElementType> = state
        .interactive_objects
        .iter()
        .filter(|e| e.hex_x == hex_x && e.hex_y == hex_y && e.state == ElementState::Intact)
        .map(|e| e.element_type)
        .collect();

    for etype in triggers {
        let name = match etype {
            ElementType::ToxicMushrooms => "poisoned",
            ElementType::LotusPollen => "intoxicated",
            _ => continue,
        };
        apply_status_with_event(state, participant_id, name, events);
    }

    let _ = segment;
}

fn apply_status_with_event(
    state: &mut FightState,
    participant_id: u64,
    effect_name: &str,
    events: &mut Vec<CombatEvent>,
) {
    if !crate::status_effects::apply_status_by_name(state, participant_id, effect_name) {
        return;
    }
    let duration = state
        .participants
        .iter()
        .find(|p| p.id == participant_id)
        .and_then(|p| p.status_effects.iter().find(|e| e.effect_name == effect_name))
        .map(|e| e.remaining_rounds)
        .unwrap_or(0);
    events.push(CombatEvent::StatusApplied {
        target_id: participant_id,
        effect_name: effect_name.to_string(),
        duration,
        source_id: None,
    });
}

fn process_fire_entry(
    state: &mut FightState,
    participant_id: u64,
    events: &mut Vec<CombatEvent>,
) {
    // Fire clears wet; oil_slicked + fire → on_fire (oil ignition).
    // Ruby fight_hex_effect_service.rb:94-107.
    let (has_wet, has_oil) = {
        let p = match state.participants.iter().find(|p| p.id == participant_id) {
            Some(p) => p,
            None => return,
        };
        (
            crate::status_effects::has_effect(&p.status_effects, "wet"),
            crate::status_effects::has_effect(&p.status_effects, "oil_slicked"),
        )
    };
    if has_wet {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == participant_id) {
            crate::status_effects::remove_effect_by_name(&mut p.status_effects, "wet");
        }
    }
    if has_oil {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == participant_id) {
            crate::status_effects::remove_effect_by_name(&mut p.status_effects, "oil_slicked");
        }
        apply_status_with_event(state, participant_id, "on_fire", events);
    }
}

fn process_water_entry(
    state: &mut FightState,
    participant_id: u64,
    prone: bool,
    events: &mut Vec<CombatEvent>,
) {
    // Ruby fight_hex_effect_service.rb:109-129.
    let (has_fire, has_oil) = {
        let p = match state.participants.iter().find(|p| p.id == participant_id) {
            Some(p) => p,
            None => return,
        };
        (
            crate::status_effects::has_effect(&p.status_effects, "on_fire"),
            crate::status_effects::has_effect(&p.status_effects, "oil_slicked"),
        )
    };
    if has_fire {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == participant_id) {
            crate::status_effects::remove_effect_by_name(&mut p.status_effects, "on_fire");
        }
        apply_status_with_event(state, participant_id, "wet", events);
        return;
    }
    if has_oil {
        if let Some(p) = state.participants.iter_mut().find(|p| p.id == participant_id) {
            crate::status_effects::remove_effect_by_name(&mut p.status_effects, "oil_slicked");
        }
    }
    if prone {
        apply_status_with_event(state, participant_id, "wet", events);
    }
}

fn process_sharp_ground_entry(
    state: &mut FightState,
    participant_id: u64,
    events: &mut Vec<CombatEvent>,
) {
    // Ruby fight_hex_effect_service.rb:139-145: 15 raw bonus damage through
    // the threshold system when prone.
    let (wound_penalty, current_hp) = {
        let p = match state.participants.iter().find(|p| p.id == participant_id) {
            Some(p) => p,
            None => return,
        };
        ((p.max_hp as i32) - (p.current_hp as i32), p.current_hp)
    };
    let hp_lost = crate::damage::calculate_hp_from_damage(
        15.0,
        wound_penalty,
        &state.config.damage_thresholds,
        state.config.high_damage_base_hp,
        state.config.high_damage_band_size,
    )
    .min(current_hp as i32);
    events.push(CombatEvent::HazardDamage {
        participant_id,
        hazard_type: "sharp_ground".to_string(),
        damage: 15,
        hp_lost,
        segment: 0,
    });
    if hp_lost > 0 {
        let reason_opt: Option<crate::types::events::KoReason> = state
            .participants
            .iter_mut()
            .find(|p| p.id == participant_id)
            .and_then(|p| {
                p.current_hp = p.current_hp.saturating_sub(hp_lost as u8);
                if p.current_hp == 0 && !p.is_knocked_out {
                    p.is_knocked_out = true;
                    Some(if p.is_hostile_npc {
                        crate::types::events::KoReason::Died
                    } else {
                        crate::types::events::KoReason::Defeat
                    })
                } else {
                    None
                }
            });
        if let Some(reason) = reason_opt {
            events.push(CombatEvent::KnockedOut {
                participant_id,
                by_id: None,
                reason,
            });
        }
    }
}

/// Dispatcher called from the segment event loop.
pub fn process_element_tactic_event(
    state: &mut FightState,
    actor_id: u64,
    tactic_type: &str,
    element_id: Option<u64>,
    target_x: Option<i32>,
    target_y: Option<i32>,
    segment: u32,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    round_damage_states: &mut HashMap<u64, defense::RoundDamageState>,
    knockouts: &mut Vec<u64>,
) {
    // Ruby: `return if knocked_out?(actor.id)` — but the top-level event loop
    // already skips knocked-out participant events.

    match tactic_type {
        "ignite" => {
            if let (Some(tx), Some(ty)) = (target_x, target_y) {
                ignite_oil(state, tx, ty, actor_id, segment, events);
            }
        }
        "break" => {
            if let Some(eid) = element_id {
                break_element(state, eid, actor_id, segment, events);
            } else if let (Some(tx), Some(ty)) = (target_x, target_y) {
                break_window_hex(state, tx, ty, actor_id, segment, events);
            }
        }
        "detonate" => {
            if let Some(eid) = element_id {
                detonate_element(
                    state,
                    eid,
                    actor_id,
                    segment,
                    events,
                    damage_trackers,
                    round_damage_states,
                    knockouts,
                );
            }
        }
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// Ignite
// ---------------------------------------------------------------------------

/// Convert an `Oil` FightHex overlay at (target_x, target_y) to `Fire`.
///
/// Ruby: `ignite_oil_at` (fight_hex_effect_service.rb:314-323). Ruby validates
/// `within_range?(participant, target_x, target_y, 1)`; Rust mirrors that gate.
pub fn ignite_oil(
    state: &mut FightState,
    target_x: i32,
    target_y: i32,
    actor_id: u64,
    segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    // Range check (Ruby within_range?): hex_distance <= 1.
    let actor_pos = match state.participants.iter().find(|p| p.id == actor_id) {
        Some(p) => p.position,
        None => return,
    };
    if hex_grid::hex_distance(actor_pos.x, actor_pos.y, target_x, target_y) > 1 {
        return;
    }

    // Ruby `ignite_oil_at` only flips hex_type/hazard_type; on_fire status comes
    // from the fire-overlay end-of-round handler, not persistent hazard damage.
    let mut converted = false;
    for fh in &mut state.fight_hexes {
        if fh.hex_x == target_x && fh.hex_y == target_y && fh.hex_type == FightHexType::Oil {
            fh.hex_type = FightHexType::Fire;
            fh.hazard_type = Some(HazardType::Fire);
            converted = true;
            break;
        }
    }
    if !converted {
        return;
    }

    if let Some(cell) = state.hex_map.cells.get_mut(&(target_x, target_y)) {
        cell.hazard_type = Some(HazardType::Fire);
    }

    events.push(CombatEvent::OilIgnite {
        participant_id: actor_id,
        hex_x: target_x,
        hex_y: target_y,
        segment,
    });
}

// ---------------------------------------------------------------------------
// Break
// ---------------------------------------------------------------------------

/// Break a BattleMapElement (water_barrel / oil_barrel / vase). Marks state
/// `Broken` and spreads a FightHex overlay to the element's hex + 6 neighbors.
///
/// Ruby: `resolve_break` (fight_hex_effect_service.rb:161-182) dispatching to
/// `break_water_barrel` / `break_oil_barrel` / `break_vase`.
pub fn break_element(
    state: &mut FightState,
    element_id: u64,
    actor_id: u64,
    segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    let (hex_x, hex_y, element_type) = {
        let el = match state
            .interactive_objects
            .iter()
            .find(|e| e.id == element_id && e.state == ElementState::Intact)
        {
            Some(e) => e,
            None => return,
        };
        (el.hex_x, el.hex_y, el.element_type)
    };

    // Range check (Ruby within_range? — distance ≤ 1).
    let actor_pos = match state.participants.iter().find(|p| p.id == actor_id) {
        Some(p) => p.position,
        None => return,
    };
    if hex_grid::hex_distance(actor_pos.x, actor_pos.y, hex_x, hex_y) > 1 {
        return;
    }

    let spread_type = match element_type {
        ElementType::WaterBarrel => Some(FightHexType::Puddle),
        ElementType::OilBarrel => Some(FightHexType::Oil),
        ElementType::Vase => Some(FightHexType::SharpGround),
        _ => None, // non-breakable types silently ignored
    };
    let spread_type = match spread_type {
        Some(t) => t,
        None => return,
    };

    // Mark element broken.
    if let Some(el) = state
        .interactive_objects
        .iter_mut()
        .find(|e| e.id == element_id)
    {
        el.state = ElementState::Broken;
    }

    spread_fight_hexes(state, hex_x, hex_y, spread_type);

    events.push(CombatEvent::ElementBreak {
        participant_id: actor_id,
        element_type: element_type_name(element_type).into(),
        hex_x,
        hex_y,
        segment,
    });
}

fn element_type_name(t: ElementType) -> &'static str {
    match t {
        ElementType::WaterBarrel => "water_barrel",
        ElementType::OilBarrel => "oil_barrel",
        ElementType::MunitionsCrate => "munitions_crate",
        ElementType::ToxicMushrooms => "toxic_mushrooms",
        ElementType::LotusPollen => "lotus_pollen",
        ElementType::Vase => "vase",
        ElementType::CliffEdge => "cliff_edge",
    }
}

/// Ruby `spread_to_hex_and_neighbors` (fight_hex_effect_service.rb:401-409).
/// Adds a new FightHex overlay at center + 6 neighbors; each new overlay has
/// `id = 0` so Ruby writeback inserts a fresh DB row. Skips non-traversable
/// hexes (Ruby filters via `RoomHex#traversable`).
fn spread_fight_hexes(state: &mut FightState, cx: i32, cy: i32, hex_type: FightHexType) {
    let mut positions: Vec<(i32, i32)> = vec![(cx, cy)];
    positions.extend(hex_grid::hex_neighbors(cx, cy));

    for (x, y) in positions {
        // Ruby filters via `room_hex&.traversable` — only spreads onto hexes
        // that EXIST and are traversable. Rust's `hex_is_traversable` returns
        // true for absent hexes (safer default for movement), but here we
        // need to mirror Ruby: require the cell to be present.
        match state.hex_map.cells.get(&(x, y)) {
            Some(cell) if !cell.blocks_movement => {}
            _ => continue,
        }

        // Avoid duplicating an existing overlay of the same type.
        if state
            .fight_hexes
            .iter()
            .any(|fh| fh.hex_x == x && fh.hex_y == y && fh.hex_type == hex_type)
        {
            continue;
        }

        state.fight_hexes.push(crate::types::interactive::FightHexOverlay {
            id: 0, // Ruby writeback inserts as a new row.
            hex_x: x,
            hex_y: y,
            hex_type,
            hazard_type: None,
            hazard_damage_per_round: 0,
        });
    }
}

// ---------------------------------------------------------------------------
// Window break (RoomHex target)
// ---------------------------------------------------------------------------

/// Break a RoomHex window at (target_x, target_y). Adds an `OpenWindow`
/// FightHex overlay so the window becomes traversable, and spreads
/// `SharpGround` overlays to each of the 6 neighbors. For non-traversable
/// neighbors, a BFS within radius 3 picks the closest traversable cell.
///
/// Ruby: `break_window` (fight_hex_effect_service.rb:229-253).
pub fn break_window_hex(
    state: &mut FightState,
    target_x: i32,
    target_y: i32,
    actor_id: u64,
    segment: u32,
    events: &mut Vec<CombatEvent>,
) {
    // Guard: target must be a known window position (Ruby: `room_hex.hex_type == 'window'`).
    if !state
        .window_positions
        .iter()
        .any(|&(x, y)| x == target_x && y == target_y)
    {
        return;
    }

    // Range check (Ruby within_range? ≤ 1, enforced in the targeting UI).
    let actor_pos = match state.participants.iter().find(|p| p.id == actor_id) {
        Some(p) => p.position,
        None => return,
    };
    if hex_grid::hex_distance(actor_pos.x, actor_pos.y, target_x, target_y) > 1 {
        return;
    }

    // Skip if already broken (open_window overlay present).
    if state.fight_hexes.iter().any(|fh| {
        fh.hex_x == target_x && fh.hex_y == target_y && fh.hex_type == FightHexType::OpenWindow
    }) {
        return;
    }

    state
        .fight_hexes
        .push(crate::types::interactive::FightHexOverlay {
            id: 0,
            hex_x: target_x,
            hex_y: target_y,
            hex_type: FightHexType::OpenWindow,
            hazard_type: None,
            hazard_damage_per_round: 0,
        });

    // Spread sharp_ground to each neighbor (or to its closest traversable if blocked).
    for (nx, ny) in hex_grid::hex_neighbors(target_x, target_y) {
        let landing = if is_traversable_cell(state, nx, ny) {
            Some((nx, ny))
        } else {
            find_closest_traversable(state, nx, ny, 3)
        };

        if let Some((sx, sy)) = landing {
            if !state.fight_hexes.iter().any(|fh| {
                fh.hex_x == sx && fh.hex_y == sy && fh.hex_type == FightHexType::SharpGround
            }) {
                state
                    .fight_hexes
                    .push(crate::types::interactive::FightHexOverlay {
                        id: 0,
                        hex_x: sx,
                        hex_y: sy,
                        hex_type: FightHexType::SharpGround,
                        hazard_type: None,
                        hazard_damage_per_round: 0,
                    });
            }
        }
    }

    events.push(CombatEvent::WindowBreak {
        participant_id: actor_id,
        hex_x: target_x,
        hex_y: target_y,
        segment,
    });
}

fn is_traversable_cell(state: &FightState, x: i32, y: i32) -> bool {
    matches!(state.hex_map.cells.get(&(x, y)), Some(cell) if !cell.blocks_movement)
}

/// Ruby `find_closest_traversable`: ring-by-ring search out to `max_radius`,
/// returning the first traversable hex found.
fn find_closest_traversable(
    state: &FightState,
    from_x: i32,
    from_y: i32,
    max_radius: i32,
) -> Option<(i32, i32)> {
    for r in 1..=max_radius {
        for dx in -r..=r {
            for dy in -r..=r {
                let x = from_x + dx;
                let y = from_y + dy;
                if hex_grid::hex_distance(from_x, from_y, x, y) as i32 != r {
                    continue;
                }
                if is_traversable_cell(state, x, y) {
                    return Some((x, y));
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Detonate + chain reactions
// ---------------------------------------------------------------------------

/// Detonate a munitions_crate. Applies ring damage to participants (30 raw at
/// rings 0-1, 15 at ring 2, 5 at ring 3) and triggers chain reactions on
/// other intact elements in the blast radius.
///
/// Ruby: `resolve_detonate` + `detonate_munitions` + `trigger_chain_reactions`
/// (fight_hex_effect_service.rb:184-310).
#[allow(clippy::too_many_arguments)]
pub fn detonate_element(
    state: &mut FightState,
    element_id: u64,
    actor_id: u64,
    segment: u32,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    _round_damage_states: &mut HashMap<u64, defense::RoundDamageState>,
    knockouts: &mut Vec<u64>,
) {
    // Range check for the initial detonate on the primary element (Ruby
    // within_range? ≤ 1). Chain reactions skip this check — they fire on
    // proximity to a detonating element, not proximity to the actor.
    let actor_pos = match state.participants.iter().find(|p| p.id == actor_id) {
        Some(p) => p.position,
        None => return,
    };

    let primary = match state
        .interactive_objects
        .iter()
        .find(|e| e.id == element_id && e.state == ElementState::Intact)
    {
        Some(e) => (e.id, e.hex_x, e.hex_y, e.element_type),
        None => return,
    };
    if primary.3 != ElementType::MunitionsCrate {
        return;
    }
    if hex_grid::hex_distance(actor_pos.x, actor_pos.y, primary.1, primary.2) > 1 {
        return;
    }

    // Worklist of (element_id, kind) — "detonate" for munitions, "break" for barrels/vase.
    let mut detonate_queue: Vec<u64> = vec![primary.0];
    let mut break_queue: Vec<u64> = Vec::new();
    let mut visited: HashSet<u64> = HashSet::new();

    while let Some(eid) = detonate_queue.pop() {
        if !visited.insert(eid) {
            continue;
        }

        let (cx, cy) = {
            let el = match state.interactive_objects.iter_mut().find(|e| e.id == eid) {
                Some(e) => e,
                None => continue,
            };
            if el.state != ElementState::Intact || el.element_type != ElementType::MunitionsCrate {
                continue;
            }
            el.state = ElementState::Detonated;
            (el.hex_x, el.hex_y)
        };

        // Apply ring damage: ring 0-1 = 30, ring 2 = 15, ring 3 = 5.
        apply_explosion_damage(state, cx, cy, 0..=1, 30, actor_id, segment, events, damage_trackers, knockouts);
        apply_explosion_damage(state, cx, cy, 2..=2, 15, actor_id, segment, events, damage_trackers, knockouts);
        apply_explosion_damage(state, cx, cy, 3..=3,  5, actor_id, segment, events, damage_trackers, knockouts);

        events.push(CombatEvent::ElementDetonate {
            participant_id: actor_id,
            hex_x: cx,
            hex_y: cy,
            segment,
        });

        // Enqueue chain-reaction elements in blast radius (rings 0-3).
        let blast: HashSet<(i32, i32)> = hexes_within(cx, cy, 3).into_iter().collect();
        for el in state.interactive_objects.iter() {
            if visited.contains(&el.id) {
                continue;
            }
            if el.state != ElementState::Intact {
                continue;
            }
            if !blast.contains(&(el.hex_x, el.hex_y)) {
                continue;
            }
            match el.element_type {
                ElementType::MunitionsCrate => detonate_queue.push(el.id),
                ElementType::WaterBarrel | ElementType::OilBarrel | ElementType::Vase => {
                    break_queue.push(el.id);
                }
                _ => {}
            }
        }
    }

    // Apply break reactions after all detonations have resolved. break_element
    // validates range-from-actor, so chain-reaction breaks need to bypass —
    // handle inline instead.
    for eid in break_queue {
        if !visited.insert(eid) {
            continue;
        }
        let (hex_x, hex_y, etype) = match state.interactive_objects.iter().find(|e| e.id == eid) {
            Some(e) if e.state == ElementState::Intact => (e.hex_x, e.hex_y, e.element_type),
            _ => continue,
        };
        let spread_type = match etype {
            ElementType::WaterBarrel => FightHexType::Puddle,
            ElementType::OilBarrel => FightHexType::Oil,
            ElementType::Vase => FightHexType::SharpGround,
            _ => continue,
        };
        if let Some(el) = state.interactive_objects.iter_mut().find(|e| e.id == eid) {
            el.state = ElementState::Broken;
        }
        spread_fight_hexes(state, hex_x, hex_y, spread_type);

        events.push(CombatEvent::ElementBreak {
            participant_id: actor_id,
            element_type: element_type_name(etype).into(),
            hex_x,
            hex_y,
            segment,
        });
    }
}

/// Apply raw damage to each participant whose position is in `ring` hexes
/// from (cx, cy). Uses the standard damage threshold pipeline so wound_penalty,
/// shields, incoming_modifier all apply consistently.
#[allow(clippy::too_many_arguments)]
fn apply_explosion_damage(
    state: &mut FightState,
    cx: i32,
    cy: i32,
    ring: std::ops::RangeInclusive<i32>,
    raw_damage: i32,
    actor_id: u64,
    segment: u32,
    events: &mut Vec<CombatEvent>,
    damage_trackers: &mut HashMap<u64, DamageTracker>,
    knockouts: &mut Vec<u64>,
) {
    let targets: Vec<u64> = state
        .participants
        .iter()
        .filter(|p| !p.is_knocked_out)
        .filter(|p| {
            let d = hex_grid::hex_distance(cx, cy, p.position.x, p.position.y) as i32;
            ring.contains(&d)
        })
        .map(|p| p.id)
        .collect();

    for target_id in targets {
        // Apply incoming damage modifier + shield absorption + type multiplier
        // (mirrors `process_attack_event` tail). Fire type, since munitions.
        let damage = raw_damage.max(0);

        // Shield absorption first (Ruby: absorb_damage_with_shields).
        let absorbed = if let Some(p) = state.participants.iter_mut().find(|p| p.id == target_id) {
            crate::status_effects::shield_absorb(&mut p.status_effects, damage)
        } else {
            0
        };
        let damage_after_shield = (damage - absorbed).max(0);

        let tracker = match damage_trackers.get_mut(&target_id) {
            Some(t) => t,
            None => continue,
        };
        let hp_lost = tracker.accumulate(
            damage_after_shield as f64,
            &state.config.damage_thresholds,
            state.config.high_damage_base_hp,
            state.config.high_damage_band_size,
        );

        if hp_lost > 0 {
            if let Some(p) = state.participants.iter_mut().find(|p| p.id == target_id) {
                p.current_hp = p.current_hp.saturating_sub(hp_lost as u8);
                if p.current_hp == 0 && !p.is_knocked_out {
                    p.is_knocked_out = true;
                    knockouts.push(p.id);
                    let reason = if p.is_hostile_npc {
                        crate::types::events::KoReason::Died
                    } else {
                        crate::types::events::KoReason::Defeat
                    };
                    events.push(CombatEvent::KnockedOut {
                        participant_id: p.id,
                        by_id: None,
                        reason,
                    });
                }
            }
        }

        events.push(CombatEvent::ExplosionDamage {
            target_id,
            actor_id,
            raw_damage,
            damage_after_shield,
            hp_lost: hp_lost as i32,
            segment,
        });
    }

    // Silence unused warnings for fields kept for future extension.
    let _ = DamageType::Physical;
}

/// All hex coords within `max_distance` of (cx, cy) inclusive.
fn hexes_within(cx: i32, cy: i32, max_distance: i32) -> Vec<(i32, i32)> {
    let mut result = Vec::new();
    for dx in -max_distance..=max_distance {
        for dy in -max_distance..=max_distance {
            let x = cx + dx;
            let y = cy + dy;
            if hex_grid::hex_distance(cx, cy, x, y) as i32 <= max_distance {
                result.push((x, y));
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::fight_state::FightState;
    use crate::types::hex::{HexCell, HexCoord};
    use crate::types::interactive::FightHexOverlay;
    use crate::types::participant::Participant;

    #[test]
    fn ignite_oil_does_not_add_hazard_damage() {
        // Ruby parity: ignite_oil_at only flips hex_type/hazard_type and emits
        // an event. No hazard_damage_per_round is set, and the underlying
        // HexCell.hazard_damage must remain zero — Ruby reads hazard damage
        // from persistent RoomHex columns, not from ignited runtime state.
        let mut state = FightState {
            participants: vec![Participant {
                id: 1,
                position: HexCoord { x: 0, y: 0, z: 0 },
                ..Default::default()
            }],
            fight_hexes: vec![FightHexOverlay {
                id: 1,
                hex_x: 1,
                hex_y: 0,
                hex_type: FightHexType::Oil,
                hazard_type: None,
                hazard_damage_per_round: 0,
            }],
            ..Default::default()
        };
        state
            .hex_map
            .cells
            .insert((1, 0), HexCell::default());

        let mut events = Vec::new();
        ignite_oil(&mut state, 1, 0, 1, 20, &mut events);

        let fh = state
            .fight_hexes
            .iter()
            .find(|fh| fh.hex_x == 1 && fh.hex_y == 0)
            .expect("overlay present");
        assert_eq!(fh.hex_type, FightHexType::Fire);
        assert_eq!(fh.hazard_type, Some(HazardType::Fire));
        assert_eq!(
            fh.hazard_damage_per_round, 0,
            "Ruby parity: ignite must not add persistent hazard damage"
        );

        let cell = state.hex_map.cells.get(&(1, 0)).expect("cell present");
        assert_eq!(cell.hazard_damage, 0);
        assert_eq!(cell.hazard_type, Some(HazardType::Fire));
        assert_eq!(events.len(), 1);
    }
}
