use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};

use crate::types::hex::{HexCoord, HexMap, WaterType};
use crate::types::participant::Participant;
use crate::{battle_map, hex_grid};

const MAX_VISITED: usize = 800;
const OCCUPIED_HEX_COST: f32 = 0.5;

/// Hazard avoidance costs by AI profile.
pub fn hazard_avoidance_cost(avoidance: &str) -> f32 {
    match avoidance {
        "ignore" => 1.0,
        "low" => 5.0,
        "moderate" => 15.0,
        "high" => 50.0,
        _ => 15.0, // default moderate
    }
}

/// Calculate movement cost between two adjacent hexes.
/// Returns `f32::INFINITY` if the move is impassable.
pub fn movement_cost_between(
    map: &HexMap,
    from: (i32, i32),
    to: (i32, i32),
    participants: &[Participant],
    exclude_id: u64,
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> f32 {
    let to_cell = match map.cells.get(&to) {
        Some(c) => c,
        None => return f32::INFINITY, // off map
    };

    // Blocked hex
    if to_cell.blocks_movement {
        return f32::INFINITY;
    }

    // Edge-based blocking
    if battle_map::movement_blocked_by_edges(
        map,
        &HexCoord {
            x: from.0,
            y: from.1,
            z: 0,
        },
        &HexCoord {
            x: to.0,
            y: to.1,
            z: 0,
        },
    ) {
        return f32::INFINITY;
    }

    // Qi Lightness: ignore terrain costs
    if qi_lightness {
        let mut cost = 1.0;
        if is_occupied(participants, to, exclude_id) {
            cost += OCCUPIED_HEX_COST;
        }
        return cost;
    }

    // Hazard cost
    if to_cell.hazard_type.is_some() {
        let avoidance_cost = hazard_avoidance_cost(hazard_avoidance);
        if avoidance_cost >= 50.0 {
            return f32::INFINITY; // "high" avoidance = impassable
        }
        return avoidance_cost;
    }

    // Water cost multiplier. Ruby: `RoomHex#water_movement_cost` — Deep water
    // is impassable; wading/swimming multiply base movement cost.
    let water_mul: f32 = match to_cell.water_type {
        Some(WaterType::Deep) => return f32::INFINITY,
        Some(WaterType::Swimming) => 3.0,
        Some(WaterType::Wading) => 2.0,
        Some(WaterType::Puddle) | None => 1.0,
    };
    let terrain_mul: f32 = if to_cell.is_difficult_terrain { 2.0 } else { 1.0 };
    // Ruby's `calculated_movement_cost` uses `.max(1.0, water_cost, terrain)`.
    let mut cost = water_mul.max(terrain_mul).max(1.0_f32);

    // Occupied hex
    if is_occupied(participants, to, exclude_id) {
        cost += OCCUPIED_HEX_COST;
    }

    // Elevation transition
    if let Some(from_cell) = map.cells.get(&from) {
        let diff = (to_cell.elevation_level - from_cell.elevation_level).abs();
        if diff > 0 {
            let has_aid = from_cell.is_ramp
                || to_cell.is_ramp
                || from_cell.is_stairs
                || to_cell.is_stairs
                || from_cell.is_ladder
                || to_cell.is_ladder;
            if has_aid {
                // No extra cost with aid
            } else if diff <= 5 {
                cost *= 1.5;
            } else {
                return f32::INFINITY; // too high without aid
            }
        }
    }

    cost
}

fn is_occupied(participants: &[Participant], pos: (i32, i32), exclude_id: u64) -> bool {
    participants.iter().any(|p| {
        p.id != exclude_id && !p.is_knocked_out && p.position.x == pos.0 && p.position.y == pos.1
    })
}

/// A* pathfinding on hex grid. Returns path from start to goal (inclusive),
/// or `None` if no path exists.
pub fn find_path(
    map: &HexMap,
    start: (i32, i32),
    goal: (i32, i32),
    participants: &[Participant],
    exclude_id: u64,
    hazard_avoidance: &str,
    qi_lightness: bool,
) -> Option<Vec<(i32, i32)>> {
    if start == goal {
        return Some(vec![start]);
    }

    // Check goal is passable
    if let Some(cell) = map.cells.get(&goal) {
        if cell.blocks_movement {
            return None;
        }
    }

    let mut open = BinaryHeap::new();
    let mut came_from: HashMap<(i32, i32), (i32, i32)> = HashMap::new();
    let mut g_score: HashMap<(i32, i32), f32> = HashMap::new();
    let mut visited = 0usize;

    g_score.insert(start, 0.0);
    open.push(Node {
        pos: start,
        f_score: hex_grid::hex_distance(start.0, start.1, goal.0, goal.1) as f32,
    });

    while let Some(current) = open.pop() {
        if current.pos == goal {
            return Some(reconstruct_path(&came_from, current.pos));
        }

        visited += 1;
        if visited > MAX_VISITED {
            return None;
        }

        let current_g = g_score[&current.pos];

        for (nx, ny) in hex_grid::hex_neighbors(current.pos.0, current.pos.1) {
            let cost = movement_cost_between(
                map,
                current.pos,
                (nx, ny),
                participants,
                exclude_id,
                hazard_avoidance,
                qi_lightness,
            );
            if cost == f32::INFINITY {
                continue;
            }

            let tentative_g = current_g + cost;
            let existing_g = g_score.get(&(nx, ny)).copied().unwrap_or(f32::INFINITY);

            if tentative_g < existing_g {
                came_from.insert((nx, ny), current.pos);
                g_score.insert((nx, ny), tentative_g);
                let h = hex_grid::hex_distance(nx, ny, goal.0, goal.1) as f32;
                open.push(Node {
                    pos: (nx, ny),
                    f_score: tentative_g + h,
                });
            }
        }
    }

    None // no path found
}

/// Truncate a path to fit within a movement budget (number of steps/edges).
pub fn steps_within_budget(path: &[(i32, i32)], budget: u32) -> Vec<(i32, i32)> {
    if path.len() <= 1 {
        return path.to_vec();
    }
    // budget = number of STEPS (edges), not nodes
    let max_nodes = budget as usize + 1;
    path[..max_nodes.min(path.len())].to_vec()
}

// --- A* internal types ---

#[derive(Debug, Clone)]
struct Node {
    pos: (i32, i32),
    f_score: f32,
}

impl PartialEq for Node {
    fn eq(&self, other: &Self) -> bool {
        self.pos == other.pos
    }
}
impl Eq for Node {}

impl Ord for Node {
    fn cmp(&self, other: &Self) -> Ordering {
        // BinaryHeap is a max-heap, so reverse for min-heap behavior
        other
            .f_score
            .partial_cmp(&self.f_score)
            .unwrap_or(Ordering::Equal)
    }
}

impl PartialOrd for Node {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn reconstruct_path(
    came_from: &HashMap<(i32, i32), (i32, i32)>,
    end: (i32, i32),
) -> Vec<(i32, i32)> {
    let mut path = vec![end];
    let mut current = end;
    while let Some(&prev) = came_from.get(&current) {
        path.push(prev);
        current = prev;
    }
    path.reverse();
    path
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::*;
    use std::collections::HashMap;

    fn open_map(width: u32, height: u32) -> HexMap {
        let mut cells = HashMap::new();
        // Populate with valid hex coordinates
        for y_half in 0..height {
            let y = (y_half * 2) as i32;
            let x_even = (y_half % 2) == 0;
            for x_step in 0..width {
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
            width,
            height: height * 2,
            cells,
        }
    }

    #[test]
    fn test_path_same_point() {
        let map = open_map(5, 5);
        let path = find_path(&map, (0, 0), (0, 0), &[], 0, "moderate", false);
        assert_eq!(path, Some(vec![(0, 0)]));
    }

    #[test]
    fn test_path_to_neighbor() {
        let map = open_map(5, 5);
        let path = find_path(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert!(path.is_some());
        let p = path.unwrap();
        assert_eq!(p.first(), Some(&(0, 0)));
        assert_eq!(p.last(), Some(&(1, 2)));
        assert_eq!(p.len(), 2); // direct neighbor = 1 step
    }

    #[test]
    fn test_path_around_obstacle() {
        let mut map = open_map(5, 5);
        // Block the direct path
        if let Some(cell) = map.cells.get_mut(&(1, 2)) {
            cell.blocks_movement = true;
        }
        let path = find_path(&map, (0, 0), (2, 4), &[], 0, "moderate", false);
        assert!(path.is_some());
        let p = path.unwrap();
        assert!(!p.contains(&(1, 2))); // should avoid blocked hex
    }

    #[test]
    fn test_no_path_to_unreachable() {
        let mut map = open_map(3, 3);
        // Block all neighbors of goal
        let goal = (2, 4);
        for (nx, ny) in hex_grid::hex_neighbors(goal.0, goal.1) {
            if let Some(cell) = map.cells.get_mut(&(nx, ny)) {
                cell.blocks_movement = true;
            }
        }
        let path = find_path(&map, (0, 0), goal, &[], 0, "moderate", false);
        assert!(path.is_none());
    }

    #[test]
    fn test_steps_within_budget() {
        let path = vec![(0, 0), (1, 2), (2, 4), (3, 6), (4, 8)];
        let truncated = steps_within_budget(&path, 2);
        assert_eq!(truncated, vec![(0, 0), (1, 2), (2, 4)]); // 2 steps = 3 nodes
    }

    #[test]
    fn test_hazard_avoidance_costs() {
        assert_eq!(hazard_avoidance_cost("ignore"), 1.0);
        assert_eq!(hazard_avoidance_cost("low"), 5.0);
        assert_eq!(hazard_avoidance_cost("moderate"), 15.0);
        assert_eq!(hazard_avoidance_cost("high"), 50.0);
    }

    #[test]
    fn test_elevation_cost_with_aid() {
        let mut map = open_map(3, 3);
        // Set elevation difference with ramp
        if let Some(cell) = map.cells.get_mut(&(1, 2)) {
            cell.elevation_level = 2;
            cell.is_ramp = true;
        }
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, 1.0); // ramp = no extra cost
    }

    #[test]
    fn test_elevation_cost_without_aid() {
        let mut map = open_map(3, 3);
        if let Some(cell) = map.cells.get_mut(&(1, 2)) {
            cell.elevation_level = 3;
        }
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, 1.5); // 3 levels without aid = 1.5x
    }

    #[test]
    fn test_qi_lightness_ignores_terrain() {
        let mut map = open_map(3, 3);
        if let Some(cell) = map.cells.get_mut(&(1, 2)) {
            cell.is_difficult_terrain = true;
            cell.elevation_level = 5;
        }
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", true);
        assert_eq!(cost, 1.0); // qi lightness = flat 1.0
    }

    fn water_map(kind: WaterType) -> HexMap {
        let mut map = open_map(5, 5);
        if let Some(cell) = map.cells.get_mut(&(1, 2)) {
            cell.water_type = Some(kind);
        }
        map
    }

    #[test]
    fn test_water_puddle_is_free() {
        let map = water_map(WaterType::Puddle);
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, 1.0);
    }

    #[test]
    fn test_water_wading_doubles_cost() {
        let map = water_map(WaterType::Wading);
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, 2.0);
    }

    #[test]
    fn test_water_swimming_triples_cost() {
        let map = water_map(WaterType::Swimming);
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, 3.0);
    }

    #[test]
    fn test_water_deep_is_impassable() {
        let map = water_map(WaterType::Deep);
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, f32::INFINITY);
    }

    #[test]
    fn test_water_qi_lightness_ignores_cost() {
        let map = water_map(WaterType::Swimming);
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", true);
        assert_eq!(cost, 1.0);
    }

    #[test]
    fn test_water_and_difficult_take_max() {
        // Wading (2.0) + difficult (2.0) → take the max, not product.
        let mut map = water_map(WaterType::Wading);
        if let Some(cell) = map.cells.get_mut(&(1, 2)) {
            cell.is_difficult_terrain = true;
        }
        let cost = movement_cost_between(&map, (0, 0), (1, 2), &[], 0, "moderate", false);
        assert_eq!(cost, 2.0);
    }
}
