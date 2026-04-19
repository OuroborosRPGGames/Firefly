use rand::Rng;

use crate::types::actions::MovementAction;
use crate::types::config::CombatConfig;
use crate::types::hex::{HexCoord, HexMap};
use crate::types::participant::Participant;

/// A single movement step (for event generation).
#[derive(Debug, Clone)]
pub struct MovementStep {
    pub from: HexCoord,
    pub to: HexCoord,
    pub segment: u32,
}

/// Resolve a movement action into concrete hex steps.
///
/// Returns the list of hexes the participant moves through (may be empty for
/// `StandStill`). The returned coordinates do NOT include the mover's current
/// position -- only the hexes they step *into*.
pub fn resolve_movement(
    map: &HexMap,
    mover: &Participant,
    action: &MovementAction,
    participants: &[Participant],
    budget: u32,
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Vec<(i32, i32)> {
    // Fear overrides player's chosen movement: run from the fear source.
    // Ruby status_effect_service.rb:605 fear_source.
    if let Some(fear_src) = crate::status_effects::fear_source(&mover.status_effects) {
        if let Some(src) = find_participant(participants, fear_src) {
            return resolve_away_from(
                map, mover, &src.position, budget, participants,
                hazard_avoidance, qi_lightness,
            );
        }
    }
    match action {
        MovementAction::StandStill => vec![],

        MovementAction::TowardsPerson(target_id) => {
            match find_participant(participants, *target_id) {
                Some(t) => resolve_towards(
                    map,
                    mover,
                    &t.position,
                    budget,
                    participants,
                    hazard_avoidance,
                    qi_lightness,
                ),
                None => vec![],
            }
        }

        MovementAction::AwayFrom(target_id) => {
            match find_participant(participants, *target_id) {
                Some(t) => resolve_away_from(
                    map,
                    mover,
                    &t.position,
                    budget,
                    participants,
                    hazard_avoidance,
                    qi_lightness,
                ),
                None => vec![],
            }
        }

        MovementAction::MaintainDistance { target_id, range } => {
            match find_participant(participants, *target_id) {
                Some(t) => resolve_maintain_distance(
                    map,
                    mover,
                    &t.position,
                    *range as u32,
                    budget,
                    participants,
                    hazard_avoidance,
                    qi_lightness,
                ),
                None => vec![],
            }
        }

        MovementAction::MoveToHex(coord) => {
            resolve_to_hex(map, mover, coord, budget, participants, hazard_avoidance, qi_lightness)
        }

        MovementAction::Flee { .. } => resolve_flee(
            map,
            mover,
            budget,
            participants,
            hazard_avoidance,
            qi_lightness,
        ),

        // Mount/Climb/Cling/Dismount/WallFlip are handled by other modules
        _ => vec![],
    }
}

/// Calculate movement budget for a participant this round.
pub fn calculate_movement_budget(
    config: &CombatConfig,
    is_sprinting: bool,
    tactic_movement_bonus: u32,
    qi_lightness: bool,
    qi_lightness_wall_bounce: bool,
    is_slowed: bool,
) -> u32 {
    let mut budget = config.movement.base;
    if is_sprinting {
        budget += config.movement.sprint_bonus;
    }
    budget += tactic_movement_bonus;
    if qi_lightness {
        budget += if qi_lightness_wall_bounce { 6 } else { 3 };
    }
    if is_slowed {
        budget /= 2;
    }
    budget
}

/// Distribute movement steps across the 100-segment timeline.
///
/// Matches Ruby's approach: generate segments based on movement BUDGET
/// (not actual step count), then take only as many as needed for the path.
/// This ensures early movement timing even when the path is short.
///
///   interval = total / budget
///   base = ((i + 1) * interval).round
///   segments = first(steps.len())
///
/// Returns `(segment, hex_coord)` pairs indicating when each step occurs.
pub fn distribute_movement_segments(
    steps: &[(i32, i32)],
    movement_budget: u32,
    config: &CombatConfig,
    rng: &mut impl Rng,
) -> Vec<(u32, (i32, i32))> {
    if steps.is_empty() {
        return vec![];
    }

    let total_segments = config.segments.total;
    // Use movement budget for segment distribution (not step count).
    // Ruby: movement_segments_for_budget(budget) then .first(path.length)
    let segment_count = movement_budget.max(steps.len() as u32) as f64;
    let interval = total_segments as f64 / segment_count;

    // Generate all budget-worth of segments (with RNG for each)
    let mut all_segs: Vec<u32> = (0..segment_count as u32)
        .map(|i| {
            let base_seg = ((i as f64 + 1.0) * interval).round() as u32;
            let variance =
                (base_seg as f64 * config.segments.movement_randomization as f64).round() as i32;
            let jitter = if variance > 0 {
                rng.gen_range(-variance..=variance)
            } else {
                0
            };
            (base_seg as i32 + jitter).clamp(1, total_segments as i32) as u32
        })
        .collect();
    all_segs.sort();

    // Take only the first steps.len() segments (matching Ruby's .first(path.length))
    let mut result: Vec<(u32, (i32, i32))> = steps
        .iter()
        .enumerate()
        .map(|(i, &pos)| (all_segs[i], pos))
        .collect();
    result.sort_by_key(|&(seg, _)| seg);
    result
}

/// Mirror Ruby's `movement_segments_for_budget(budget)` — returns a sorted
/// list of `budget` randomized segment values, burning `budget` RNG calls.
pub fn compute_budget_segments(
    budget: u32,
    config: &CombatConfig,
    rng: &mut impl Rng,
) -> Vec<u32> {
    if budget == 0 {
        return vec![];
    }
    let total = config.segments.total;
    let interval = total as f64 / budget as f64;
    let mut segs: Vec<u32> = (0..budget)
        .map(|i| {
            let base = ((i as f64 + 1.0) * interval).round() as u32;
            let variance =
                (base as f64 * config.segments.movement_randomization as f64).round() as i32;
            let jitter = if variance > 0 {
                rng.gen_range(-variance..=variance)
            } else {
                0
            };
            (base as i32 + jitter).clamp(1, total as i32) as u32
        })
        .collect();
    segs.sort();
    segs
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn find_participant(participants: &[Participant], id: u64) -> Option<&Participant> {
    participants
        .iter()
        .find(|p| p.id == id && !p.is_knocked_out)
}

fn resolve_towards(
    map: &HexMap,
    mover: &Participant,
    target_pos: &HexCoord,
    budget: u32,
    participants: &[Participant],
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Vec<(i32, i32)> {
    // If hex map has cells populated, use A* pathfinding.
    // Mirrors Ruby's best_adjacent_path_to_target: try each of the target's
    // neighbors in order of distance from the mover so the mover ends up
    // adjacent (rather than trying to land on the occupied target hex). If
    // none of those pathfind, fall back to a direct A* to the target, then
    // finally to a simple greedy walk — matching Ruby's cascade
    // (calculate_towards_path → calculate_simple_towards_path at the
    // bottom).
    if !map.cells.is_empty() {
        let start = (mover.position.x, mover.position.y);

        // 1. Try adjacent landing hexes sorted by distance from mover
        let mut neighbors = crate::hex_grid::hex_neighbors(target_pos.x, target_pos.y);
        neighbors.sort_by_key(|&(nx, ny)| {
            crate::hex_grid::hex_distance(start.0, start.1, nx, ny)
        });
        for (nx, ny) in &neighbors {
            if (*nx, *ny) == start {
                // Already adjacent; no steps needed. Let the shadow-step
                // branch in build_timeline pick it up.
                return vec![];
            }
            if let Some(p) = crate::pathfinding::find_path(
                map,
                start,
                (*nx, *ny),
                participants,
                mover.id,
                hazard_avoidance,
                qi_lightness,
            ) {
                let truncated = crate::pathfinding::steps_within_budget(&p, budget);
                if truncated.len() > 1 {
                    return truncated[1..].to_vec();
                }
            }
        }

        // 2. Fall back to pathfinding directly to the target
        if let Some(p) = crate::pathfinding::find_path(
            map,
            start,
            (target_pos.x, target_pos.y),
            participants,
            mover.id,
            hazard_avoidance,
            qi_lightness,
        ) {
            let truncated = crate::pathfinding::steps_within_budget(&p, budget);
            if truncated.len() > 1 {
                return truncated[1..].to_vec();
            }
        }

        // 3. Last resort: simple greedy walk, ignoring map cells.
        // Ruby falls back to calculate_simple_towards_path in the
        // "all adjacent hexes unreachable" case when the map is sparse
        // (spec fixtures often have gaps in odd-y rows).
        let arena_w = map.width.max(20) as i32;
        let arena_h = map.height.max(20) as i32;
        return simple_greedy_towards(
            mover.position.x, mover.position.y,
            target_pos.x, target_pos.y,
            budget, arena_w, arena_h,
        );
    }

    // No battle map: simple greedy walk toward target (matches Ruby's
    // calculate_simple_towards_path). Walk to nearest neighbor that reduces
    // distance to target, stop when adjacent (distance ≤ 1) or budget exhausted.
    simple_greedy_towards(
        mover.position.x, mover.position.y,
        target_pos.x, target_pos.y,
        budget, map.width as i32, map.height as i32,
    )
}

/// Simple greedy movement toward a target without pathfinding.
/// Mirrors Ruby's `calculate_simple_towards_path`.
/// Public so resolution.rs can use it for dynamic movement recalculation.
pub fn simple_greedy_towards(
    start_x: i32, start_y: i32,
    target_x: i32, target_y: i32,
    budget: u32,
    arena_width: i32, arena_height: i32,
) -> Vec<(i32, i32)> {
    let mut steps = Vec::new();
    let mut cx = start_x;
    let mut cy = start_y;
    let max_x = (arena_width as i32 - 1).max(0);
    let max_y = ((arena_height as i32 - 1) * 4 + 2).max(0);

    for _ in 0..budget {
        if cx == target_x && cy == target_y {
            break;
        }
        let current_dist = crate::hex_grid::hex_distance(cx, cy, target_x, target_y);
        if current_dist <= 1 {
            break; // adjacent, stop
        }

        let neighbors = crate::hex_grid::hex_neighbors(cx, cy);
        // Filter to within arena bounds
        let valid: Vec<(i32, i32)> = neighbors
            .into_iter()
            .filter(|&(nx, ny)| nx >= 0 && ny >= 0 && nx <= max_x && ny <= max_y)
            .collect();

        if valid.is_empty() {
            break;
        }

        // Pick neighbor closest to target
        let best = valid
            .iter()
            .min_by_key(|&&(nx, ny)| crate::hex_grid::hex_distance(nx, ny, target_x, target_y));

        match best {
            Some(&(bx, by)) => {
                let best_dist = crate::hex_grid::hex_distance(bx, by, target_x, target_y);
                if best_dist >= current_dist {
                    break; // no progress, stop
                }
                cx = bx;
                cy = by;
                steps.push((cx, cy));
            }
            None => break,
        }
    }

    steps
}

/// Compute one step away from a target position using simple greedy logic.
/// Used for dynamic movement recalculation in resolution.rs.
/// Returns Some((x, y)) if a step can be taken, None if stuck.
pub fn resolve_away_step(
    start_x: i32, start_y: i32,
    threat_x: i32, threat_y: i32,
    arena_width: i32, arena_height: i32,
) -> Option<(i32, i32)> {
    let max_x = (arena_width - 1).max(0);
    let max_y = ((arena_height - 1) * 4 + 2).max(0);
    let current_dist = crate::hex_grid::hex_distance(start_x, start_y, threat_x, threat_y);

    let neighbors = crate::hex_grid::hex_neighbors(start_x, start_y);
    let best = neighbors
        .into_iter()
        .filter(|&(nx, ny)| nx >= 0 && ny >= 0 && nx <= max_x && ny <= max_y)
        .max_by_key(|&(nx, ny)| crate::hex_grid::hex_distance(nx, ny, threat_x, threat_y));

    match best {
        Some((bx, by)) if crate::hex_grid::hex_distance(bx, by, threat_x, threat_y) > current_dist => {
            Some((bx, by))
        }
        _ => None,
    }
}

fn resolve_away_from(
    map: &HexMap,
    mover: &Participant,
    threat_pos: &HexCoord,
    budget: u32,
    participants: &[Participant],
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Vec<(i32, i32)> {
    let max_x = (map.width as i32 - 1).max(0);
    let max_y = ((map.height as i32 - 1) * 4 + 2).max(0);
    let mut current = (mover.position.x, mover.position.y);
    let mut steps = Vec::new();

    for _ in 0..budget {
        let neighbors = crate::hex_grid::hex_neighbors(current.0, current.1);
        let best = neighbors
            .into_iter()
            .filter(|&(nx, ny)| {
                // Arena bounds check for empty maps
                if nx < 0 || ny < 0 || nx > max_x || ny > max_y {
                    return false;
                }
                // If map has cells, also check movement cost
                if !map.cells.is_empty() {
                    crate::pathfinding::movement_cost_between(
                        map,
                        current,
                        (nx, ny),
                        participants,
                        mover.id,
                        hazard_avoidance,
                        qi_lightness,
                    ) < f32::INFINITY
                } else {
                    true
                }
            })
            .max_by_key(|&(nx, ny)| {
                crate::hex_grid::hex_distance(nx, ny, threat_pos.x, threat_pos.y)
            });

        match best {
            Some(next)
                if crate::hex_grid::hex_distance(
                    next.0,
                    next.1,
                    threat_pos.x,
                    threat_pos.y,
                ) > crate::hex_grid::hex_distance(
                    current.0,
                    current.1,
                    threat_pos.x,
                    threat_pos.y,
                ) =>
            {
                steps.push(next);
                current = next;
            }
            _ => break, // can't move further away
        }
    }

    steps
}

fn resolve_maintain_distance(
    map: &HexMap,
    mover: &Participant,
    target_pos: &HexCoord,
    desired_range: u32,
    budget: u32,
    participants: &[Participant],
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Vec<(i32, i32)> {
    let current_dist = crate::hex_grid::hex_distance(
        mover.position.x,
        mover.position.y,
        target_pos.x,
        target_pos.y,
    ) as u32;

    if current_dist == desired_range {
        return vec![]; // already at the right distance
    }

    if current_dist < desired_range {
        // Too close, move away
        resolve_away_from(
            map,
            mover,
            target_pos,
            budget.min(desired_range - current_dist),
            participants,
            hazard_avoidance,
            qi_lightness,
        )
    } else {
        // Too far, move closer (but stop at desired range)
        let steps_needed = current_dist - desired_range;
        resolve_towards(
            map,
            mover,
            target_pos,
            budget.min(steps_needed),
            participants,
            hazard_avoidance,
            qi_lightness,
        )
    }
}

fn resolve_to_hex(
    map: &HexMap,
    mover: &Participant,
    target: &HexCoord,
    budget: u32,
    participants: &[Participant],
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Vec<(i32, i32)> {
    // Empty map: use simple greedy walk
    if map.cells.is_empty() {
        return simple_greedy_towards(
            mover.position.x, mover.position.y,
            target.x, target.y,
            budget, map.width as i32, map.height as i32,
        );
    }

    let path = crate::pathfinding::find_path(
        map,
        (mover.position.x, mover.position.y),
        (target.x, target.y),
        participants,
        mover.id,
        hazard_avoidance,
        qi_lightness,
    );
    match path {
        Some(p) => {
            let truncated = crate::pathfinding::steps_within_budget(&p, budget);
            if truncated.len() > 1 {
                truncated[1..].to_vec()
            } else {
                vec![]
            }
        }
        None => vec![],
    }
}

/// Flee during hex-level round resolution: move away from nearest enemy.
/// The room-level direction (`Flee::direction`) is consumed at end of round by
/// `process_flee_surrender` and Ruby's `process_successful_flee!`; hex movement
/// during the round just needs to increase distance from threats so the fleer
/// takes no damage (flee is cancelled by damage).
fn resolve_flee(
    map: &HexMap,
    mover: &Participant,
    budget: u32,
    participants: &[Participant],
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Vec<(i32, i32)> {
    // Find nearest enemy; if none, stand still.
    let nearest = participants.iter()
        .filter(|p| p.id != mover.id && p.side != mover.side && !p.is_knocked_out)
        .min_by_key(|p| crate::hex_grid::hex_distance(
            mover.position.x, mover.position.y, p.position.x, p.position.y
        ));
    let Some(enemy) = nearest else { return Vec::new(); };

    // Reuse away-from logic: retreat from the nearest enemy's position.
    resolve_away_from(
        map,
        mover,
        &enemy.position,
        budget,
        participants,
        hazard_avoidance,
        qi_lightness,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::*;
    use crate::types::participant::Participant;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;
    use std::collections::HashMap;

    fn open_map() -> HexMap {
        let mut cells = HashMap::new();
        for y_half in 0..10 {
            let y = (y_half * 2) as i32;
            let x_even = (y_half % 2) == 0;
            for x_step in 0..10 {
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
            height: 20,
            cells,
        }
    }

    fn participant_at(id: u64, x: i32, y: i32) -> Participant {
        Participant {
            id,
            position: HexCoord { x, y, z: 0 },
            ..Default::default()
        }
    }

    #[test]
    fn test_stand_still() {
        let map = open_map();
        let mover = participant_at(1, 0, 0);
        let steps = resolve_movement(
            &map,
            &mover,
            &MovementAction::StandStill,
            &[mover.clone()],
            6,
            "moderate",
            false,
        );
        assert!(steps.is_empty());
    }

    #[test]
    fn test_towards_person() {
        let map = open_map();
        let mover = participant_at(1, 0, 0);
        let target = participant_at(2, 2, 4);
        let participants = vec![mover.clone(), target.clone()];
        let steps = resolve_movement(
            &map,
            &mover,
            &MovementAction::TowardsPerson(2),
            &participants,
            6,
            "moderate",
            false,
        );
        assert!(!steps.is_empty());
        // Should end closer to target
        let last = steps.last().unwrap();
        let start_dist = crate::hex_grid::hex_distance(0, 0, 2, 4);
        let end_dist = crate::hex_grid::hex_distance(last.0, last.1, 2, 4);
        assert!(end_dist < start_dist);
    }

    #[test]
    fn test_away_from() {
        let map = open_map();
        let mover = participant_at(1, 4, 4);
        let threat = participant_at(2, 4, 0);
        let participants = vec![mover.clone(), threat.clone()];
        let steps = resolve_movement(
            &map,
            &mover,
            &MovementAction::AwayFrom(2),
            &participants,
            3,
            "moderate",
            false,
        );
        assert!(!steps.is_empty());
        let last = steps.last().unwrap();
        let start_dist = crate::hex_grid::hex_distance(4, 4, 4, 0);
        let end_dist = crate::hex_grid::hex_distance(last.0, last.1, 4, 0);
        assert!(end_dist > start_dist);
    }

    #[test]
    fn test_movement_budget_basic() {
        let config = CombatConfig::default();
        assert_eq!(
            calculate_movement_budget(&config, false, 0, false, false, false),
            6
        );
    }

    #[test]
    fn test_movement_budget_sprint() {
        let config = CombatConfig::default();
        assert_eq!(
            calculate_movement_budget(&config, true, 0, false, false, false),
            11
        ); // 6+5
    }

    #[test]
    fn test_movement_budget_qi_lightness() {
        let config = CombatConfig::default();
        assert_eq!(
            calculate_movement_budget(&config, false, 0, true, false, false),
            9
        ); // 6+3
    }

    #[test]
    fn test_movement_budget_slowed() {
        let config = CombatConfig::default();
        assert_eq!(
            calculate_movement_budget(&config, false, 0, false, false, true),
            3
        ); // 6/2
    }

    #[test]
    fn test_distribute_segments() {
        let config = CombatConfig::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let steps = vec![(1, 2), (2, 4), (3, 6)];
        let distributed = distribute_movement_segments(&steps, 6, &config, &mut rng);
        assert_eq!(distributed.len(), 3);
        // All segments should be within 1-100
        for (seg, _) in &distributed {
            assert!(*seg >= 1 && *seg <= 100);
        }
    }
}
