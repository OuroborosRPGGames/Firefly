//! Qi Lightness wall/tree path calculators.
//!
//! Ports `TacticQiLightnessService` (combat/tactic_qi_lightness_service.rb):
//! - Wall run: approach nearest wall, then slide along hexes that are still
//!   adjacent to a wall.
//! - Wall bounce: approach nearest wall, then move away in the reflected
//!   direction for the remaining budget.
//! - Tree leap: head straight for the nearest tree hex.
//!
//! Rust consumes `WallFeature::Wall`/`WallCorner`/`Tree` plus `HexKind::Wall`
//! from the serialized hex map — these are populated by
//! `FightStateSerializer#serialize_hex_map` (Phase 7b).

use std::collections::HashSet;

use crate::hex_grid;
use crate::types::fight_state::FightState;
use crate::types::hex::{HexCell, HexKind, HexMap, WallFeature};
use crate::types::participant::Participant;

/// Locate the closest wall hex (`HexKind::Wall` or `WallFeature::Wall`).
pub fn closest_wall<'a>(state: &'a FightState, origin: (i32, i32)) -> Option<&'a HexCell> {
    state
        .hex_map
        .cells
        .values()
        .filter(|c| is_wall(c))
        .min_by_key(|c| hex_grid::hex_distance(origin.0, origin.1, c.x, c.y) as i64)
}

/// Locate the closest tree hex (`WallFeature::Tree`).
pub fn closest_tree<'a>(state: &'a FightState, origin: (i32, i32)) -> Option<&'a HexCell> {
    state
        .hex_map
        .cells
        .values()
        .filter(|c| matches!(c.wall_feature, Some(WallFeature::Tree)))
        .min_by_key(|c| hex_grid::hex_distance(origin.0, origin.1, c.x, c.y) as i64)
}

/// Wall run: approach the wall, then slide along hexes that remain adjacent
/// to a wall, spending the remaining budget. Returns step list (each entry is
/// a hex coord the participant enters, in order).
pub fn calculate_wall_run_path(
    state: &FightState,
    participant: &Participant,
    wall: &HexCell,
    budget: u32,
) -> Vec<(i32, i32)> {
    let origin = (participant.position.x, participant.position.y);
    let adjacent = walkable_hexes_adjacent_to(&state.hex_map, wall.x, wall.y);
    if adjacent.is_empty() {
        return Vec::new();
    }
    let start = adjacent
        .iter()
        .min_by_key(|(x, y)| hex_grid::hex_distance(origin.0, origin.1, *x, *y) as i64)
        .copied()
        .unwrap();
    let mut path = approach_path(origin, start, budget);
    let remaining = budget.saturating_sub(path.len() as u32);
    if remaining == 0 {
        return path;
    }
    trace_along_wall(state, &mut path, start, remaining);
    path
}

/// Wall bounce: approach the wall, then reflect away in the direction
/// opposite the approach vector.
pub fn calculate_wall_bounce_path(
    state: &FightState,
    participant: &Participant,
    wall: &HexCell,
    budget: u32,
) -> Vec<(i32, i32)> {
    let origin = (participant.position.x, participant.position.y);
    let adjacent = walkable_hexes_adjacent_to(&state.hex_map, wall.x, wall.y);
    if adjacent.is_empty() {
        return Vec::new();
    }
    let bounce_start = adjacent
        .iter()
        .min_by_key(|(x, y)| hex_grid::hex_distance(origin.0, origin.1, *x, *y) as i64)
        .copied()
        .unwrap();
    let mut path = approach_path(origin, bounce_start, budget);
    let remaining = budget.saturating_sub(path.len() as u32);
    if remaining == 0 {
        return path;
    }
    // Bounce vector is opposite the participant-to-wall direction.
    let dx = -(wall.x - origin.0);
    let dy = -(wall.y - origin.1);
    trace_bounce(state, &mut path, bounce_start, (dx, dy), remaining);
    path
}

/// Tree leap: straight-line approach to the tree hex. Trees sit on passable
/// cover hexes so the path ends on the tree itself.
pub fn calculate_tree_leap_path(
    _state: &FightState,
    participant: &Participant,
    tree: &HexCell,
    budget: u32,
) -> Vec<(i32, i32)> {
    let origin = (participant.position.x, participant.position.y);
    approach_path(origin, (tree.x, tree.y), budget)
}

// --- helpers ----------------------------------------------------------------

fn is_wall(cell: &HexCell) -> bool {
    cell.hex_kind == HexKind::Wall
        || matches!(
            cell.wall_feature,
            Some(WallFeature::Wall) | Some(WallFeature::WallCorner)
        )
}

fn walkable_hexes_adjacent_to(map: &HexMap, x: i32, y: i32) -> Vec<(i32, i32)> {
    let mut out = Vec::new();
    for (nx, ny) in hex_grid::hex_neighbors(x, y) {
        match map.cells.get(&(nx, ny)) {
            Some(c) if !c.blocks_movement => out.push((nx, ny)),
            None => out.push((nx, ny)), // absent = default traversable
            _ => {}
        }
    }
    out
}

/// Build an approach path from `origin` to `goal` by taking one hex step per
/// iteration toward the goal (matches Ruby's `CombatPathfindingService#find_path`
/// shape enough for the budget-limited prefix semantics). Caps at `budget`.
fn approach_path(origin: (i32, i32), goal: (i32, i32), budget: u32) -> Vec<(i32, i32)> {
    if origin == goal || budget == 0 {
        return Vec::new();
    }
    let hexes = hex_grid::hexes_in_line(origin.0, origin.1, goal.0, goal.1);
    // Drop the starting hex (we're already there).
    hexes
        .into_iter()
        .skip(1)
        .take(budget as usize)
        .collect()
}

fn trace_along_wall(
    state: &FightState,
    path: &mut Vec<(i32, i32)>,
    start: (i32, i32),
    budget: u32,
) {
    let mut visited: HashSet<(i32, i32)> = path.iter().copied().collect();
    visited.insert(start);
    let mut current = start;
    for _ in 0..budget {
        let mut best: Option<(i32, i32)> = None;
        let mut best_wall_adj = false;
        for (nx, ny) in hex_grid::hex_neighbors(current.0, current.1) {
            if visited.contains(&(nx, ny)) {
                continue;
            }
            match state.hex_map.cells.get(&(nx, ny)) {
                Some(c) if c.blocks_movement => continue,
                _ => {}
            }
            let wall_adj = is_adjacent_to_wall(&state.hex_map, nx, ny);
            if wall_adj && !best_wall_adj {
                best = Some((nx, ny));
                best_wall_adj = true;
            } else if wall_adj == best_wall_adj && best.is_none() {
                best = Some((nx, ny));
            }
        }
        match best {
            Some(next) => {
                path.push(next);
                visited.insert(next);
                current = next;
            }
            None => break,
        }
    }
}

fn trace_bounce(
    state: &FightState,
    path: &mut Vec<(i32, i32)>,
    start: (i32, i32),
    vector: (i32, i32),
    budget: u32,
) {
    let mut current = start;
    for _ in 0..budget {
        let mut best: Option<(i32, i32)> = None;
        let mut best_score = i32::MIN;
        for (nx, ny) in hex_grid::hex_neighbors(current.0, current.1) {
            match state.hex_map.cells.get(&(nx, ny)) {
                Some(c) if c.blocks_movement => continue,
                _ => {}
            }
            let mdx = nx - current.0;
            let mdy = ny - current.1;
            let score = mdx * vector.0 + mdy * vector.1;
            if score > best_score {
                best = Some((nx, ny));
                best_score = score;
            }
        }
        match best {
            Some(next) => {
                path.push(next);
                current = next;
            }
            None => break,
        }
    }
}

fn is_adjacent_to_wall(map: &HexMap, x: i32, y: i32) -> bool {
    hex_grid::hex_neighbors(x, y)
        .into_iter()
        .filter_map(|(nx, ny)| map.cells.get(&(nx, ny)))
        .any(is_wall)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::fight_state::FightState;
    use crate::types::hex::{HexCell, HexCoord, HexKind, HexMap, WallFeature};
    use crate::types::participant::Participant;
    use std::collections::HashMap;

    fn floor_cell(x: i32, y: i32) -> HexCell {
        HexCell {
            x,
            y,
            ..Default::default()
        }
    }

    fn wall_cell(x: i32, y: i32) -> HexCell {
        HexCell {
            x,
            y,
            hex_kind: HexKind::Wall,
            blocks_movement: true,
            ..Default::default()
        }
    }

    fn tree_cell(x: i32, y: i32) -> HexCell {
        HexCell {
            x,
            y,
            wall_feature: Some(WallFeature::Tree),
            ..Default::default()
        }
    }

    fn build_state(cells: Vec<HexCell>) -> FightState {
        let mut map_cells = HashMap::new();
        for c in cells {
            map_cells.insert((c.x, c.y), c);
        }
        let hex_map = HexMap {
            width: 50,
            height: 50,
            cells: map_cells,
        };
        FightState {
            hex_map,
            ..Default::default()
        }
    }

    fn participant_at(x: i32, y: i32) -> Participant {
        Participant {
            position: HexCoord { x, y, z: 0 },
            ..Default::default()
        }
    }

    #[test]
    fn test_closest_wall_picks_minimum_distance() {
        let state = build_state(vec![
            floor_cell(0, 0),
            wall_cell(0, 8),
            wall_cell(0, 16),
        ]);
        let wall = closest_wall(&state, (0, 0)).unwrap();
        assert_eq!((wall.x, wall.y), (0, 8));
    }

    #[test]
    fn test_closest_wall_via_wall_feature() {
        // A hex with wall_feature=Wall but hex_kind!=Wall should still count.
        let mut c = floor_cell(0, 8);
        c.wall_feature = Some(WallFeature::WallCorner);
        let state = build_state(vec![floor_cell(0, 0), c]);
        let wall = closest_wall(&state, (0, 0)).unwrap();
        assert_eq!((wall.x, wall.y), (0, 8));
    }

    #[test]
    fn test_closest_wall_none_when_empty() {
        let state = build_state(vec![floor_cell(0, 0)]);
        assert!(closest_wall(&state, (0, 0)).is_none());
    }

    #[test]
    fn test_closest_tree() {
        let state = build_state(vec![floor_cell(0, 0), tree_cell(0, 4), tree_cell(0, 12)]);
        let tree = closest_tree(&state, (0, 0)).unwrap();
        assert_eq!((tree.x, tree.y), (0, 4));
    }

    #[test]
    fn test_wall_run_approach_then_slide() {
        // Wall at (2,0) — impassable. Surrounding hexes are floor.
        let cells = vec![
            floor_cell(0, 0),
            floor_cell(1, 2),
            floor_cell(3, 2),
            floor_cell(1, -2),
            floor_cell(3, -2),
            wall_cell(2, 0),
        ];
        let state = build_state(cells);
        let p = participant_at(0, 0);
        let wall = closest_wall(&state, (0, 0)).unwrap().clone();
        let path = calculate_wall_run_path(&state, &p, &wall, 6);
        assert!(!path.is_empty(), "path should be non-empty");
        // Path should not step onto the wall hex itself.
        assert!(!path.iter().any(|&(x, y)| (x, y) == (2, 0)));
    }

    #[test]
    fn test_wall_bounce_reflects_away_from_wall() {
        let cells = vec![
            floor_cell(0, 0),
            floor_cell(1, 2),
            floor_cell(3, 2),
            floor_cell(1, -2),
            floor_cell(3, -2),
            floor_cell(-1, 2),
            floor_cell(-1, -2),
            wall_cell(2, 0),
        ];
        let state = build_state(cells);
        let p = participant_at(0, 0);
        let wall = closest_wall(&state, (0, 0)).unwrap().clone();
        let path = calculate_wall_bounce_path(&state, &p, &wall, 4);
        assert!(!path.is_empty());
        // Must not include the wall hex.
        assert!(!path.iter().any(|&(x, y)| (x, y) == (2, 0)));
    }

    #[test]
    fn test_tree_leap_goes_straight_at_tree() {
        let cells = vec![floor_cell(0, 0), tree_cell(0, 8)];
        let state = build_state(cells);
        let p = participant_at(0, 0);
        let tree = closest_tree(&state, (0, 0)).unwrap().clone();
        let path = calculate_tree_leap_path(&state, &p, &tree, 4);
        assert!(!path.is_empty());
        assert_eq!(path.last().copied(), Some((0, 8)));
    }

    #[test]
    fn test_paths_respect_budget_cap() {
        let cells = vec![floor_cell(0, 0), tree_cell(0, 16)];
        let state = build_state(cells);
        let p = participant_at(0, 0);
        let tree = closest_tree(&state, (0, 0)).unwrap().clone();
        let path = calculate_tree_leap_path(&state, &p, &tree, 2);
        assert_eq!(path.len(), 2);
    }
}
