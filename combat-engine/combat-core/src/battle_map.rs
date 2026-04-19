use crate::hex_grid;
use crate::types::events::CombatEvent;
use crate::types::hex::{Direction, HazardType, HexCoord, HexKind, HexMap};
use crate::types::participant::Participant;
use crate::types::wall_mask::WallMask;
use std::collections::HashSet;

/// Check line-of-sight between two positions for a viewer at `viewer_z`.
///
/// Dispatches in priority order:
/// 1. If `wall_mask` is present → pixel-level Bresenham ray-cast matching
///    Ruby's `WallMaskService#ray_los_clear?` (wall_mask_service.rb:72-89).
///    Walls block; windows are transparent; doors block unless open.
/// 2. Else → hex-level fallback with elevation-aware blocking (`RoomHex#
///    blocks_los_at_elevation?`, room_hex.rb:371-377): a hex with
///    `blocks_los` only blocks when `viewer_z < elevation_level + cover_height`.
pub fn has_line_of_sight(
    map: &HexMap,
    wall_mask: Option<&WallMask>,
    from: &HexCoord,
    to: &HexCoord,
    viewer_z: i32,
) -> bool {
    if let Some(mask) = wall_mask {
        let (px1, py1) = mask.hex_to_pixel(from.x, from.y);
        let (px2, py2) = mask.hex_to_pixel(to.x, to.y);
        return mask.ray_los_clear(px1, py1, px2, py2, |px, py| {
            // Door pixel → find the hex it belongs to and read its runtime
            // door state. Ruby currently defaults door_open to false; this
            // closure keeps the hook wired for the future.
            door_pixel_is_open(map, mask, px, py)
        });
    }
    let line = hex_grid::hexes_in_line(from.x, from.y, to.x, to.y);
    for (x, y) in &line[1..line.len().saturating_sub(1)] {
        if let Some(cell) = map.cells.get(&(*x, *y)) {
            if cell.blocks_los
                && viewer_z < cell.elevation_level + cell.cover_height as i32
            {
                return false;
            }
        }
    }
    true
}

/// For a door pixel at `(px, py)`, find the owning hex and report whether
/// its door is open. Uses the nearest hex whose `hex_to_pixel` matches the
/// sample point; falls back to `false` (closed) when no such hex is
/// registered — this mirrors Ruby's default `door_open_fn` behavior.
fn door_pixel_is_open(map: &HexMap, mask: &WallMask, px: i32, py: i32) -> bool {
    // Iterate cells, find the one whose pixel anchor is closest to (px, py)
    // and is marked as a door. O(N) over the hex map; battlemaps are
    // typically under ~1000 hexes so the cost is negligible.
    let mut best: Option<((i32, i32), i32)> = None;
    for ((hx, hy), cell) in map.cells.iter() {
        if cell.hex_kind != HexKind::Door {
            continue;
        }
        let (cx, cy) = mask.hex_to_pixel(*hx, *hy);
        let dist = (cx - px).pow(2) + (cy - py).pow(2);
        match best {
            None => best = Some(((*hx, *hy), dist)),
            Some((_, d)) if dist < d => best = Some(((*hx, *hy), dist)),
            _ => {}
        }
    }
    match best {
        Some(((hx, hy), _)) => map
            .cells
            .get(&(hx, hy))
            .map(|c| c.door_open)
            .unwrap_or(false),
        None => false,
    }
}

/// Check if a shot from attacker to target passes through cover.
/// Mirrors Ruby `CoverLosService.cover_applies?`: group intermediate cover hexes
/// into contiguous blocks (flood-fill), then cover applies only if at least one
/// block has no hex adjacent to the attacker.
pub fn shot_passes_through_cover(map: &HexMap, from: &HexCoord, to: &HexCoord) -> bool {
    let line = hex_grid::hexes_in_line(from.x, from.y, to.x, to.y);
    if line.len() <= 2 {
        return false;
    }
    // Collect intermediate cover hexes (skip attacker + target).
    let cover: Vec<(i32, i32)> = line[1..line.len().saturating_sub(1)]
        .iter()
        .filter(|&&(x, y)| {
            map.cells
                .get(&(x, y))
                .map_or(false, |c| c.cover_type.is_some())
        })
        .copied()
        .collect();
    if cover.is_empty() {
        return false;
    }
    let attacker_adj: HashSet<(i32, i32)> = hex_grid::hex_neighbors(from.x, from.y)
        .into_iter()
        .collect();
    let blocks = group_contiguous_cover(&cover);
    blocks
        .iter()
        .any(|blk| blk.iter().all(|hex| !attacker_adj.contains(hex)))
}

/// Flood-fill cover hexes into contiguous blocks. Two hexes share a block
/// if they are hex-grid neighbors (directly or transitively).
fn group_contiguous_cover(hexes: &[(i32, i32)]) -> Vec<Vec<(i32, i32)>> {
    let mut remaining: Vec<(i32, i32)> = hexes.to_vec();
    let mut blocks: Vec<Vec<(i32, i32)>> = Vec::new();
    while let Some(first) = remaining.pop() {
        let mut blk: Vec<(i32, i32)> = vec![first];
        let mut added = true;
        while added {
            added = false;
            let mut i = 0;
            while i < remaining.len() {
                let hex = remaining[i];
                let adj = blk.iter().any(|&b| {
                    hex_grid::hex_neighbors(b.0, b.1).contains(&hex)
                });
                if adj {
                    blk.push(hex);
                    remaining.swap_remove(i);
                    added = true;
                } else {
                    i += 1;
                }
            }
        }
        blocks.push(blk);
    }
    blocks
}

/// Check if target is "back to wall" -- the hex behind them (away from attacker)
/// is impassable. When true, all damage thresholds shift down by 3.
pub fn back_to_wall(
    map: &HexMap,
    attacker_pos: &HexCoord,
    defender_pos: &HexCoord,
) -> bool {
    // No battle map = no back-to-wall (empty maps have no walls)
    if map.cells.is_empty() {
        return false;
    }

    // Get direction from attacker to defender
    let dir = match hex_grid::direction_between(
        attacker_pos.x,
        attacker_pos.y,
        defender_pos.x,
        defender_pos.y,
    ) {
        Some(d) => d,
        None => return false,
    };
    // Check the hex behind the defender (in the same direction)
    let (retreat_x, retreat_y) =
        hex_grid::hex_neighbor_by_direction(defender_pos.x, defender_pos.y, dir);
    match map.cells.get(&(retreat_x, retreat_y)) {
        None => true, // off-map = wall
        Some(cell) => cell.blocks_movement,
    }
}

/// Get elevation modifier for combat. Higher ground = bonus.
/// Returns -2 to +2 based on elevation difference.
pub fn elevation_modifier(attacker_z: i32, defender_z: i32) -> i32 {
    let diff = attacker_z - defender_z;
    match diff {
        d if d >= 2 => 2,
        1 => 1,
        0 => 0,
        -1 => -1,
        _ => -2, // -2 or lower
    }
}

/// Bonus damage for significant elevation advantage (2+ levels above).
/// Returns 2 if attacker is 2+ levels above, else 0.
pub fn elevation_damage_bonus(attacker_z: i32, defender_z: i32) -> i32 {
    if attacker_z - defender_z >= 2 {
        2
    } else {
        0
    }
}

/// Check if a hex provides concealment.
pub fn is_concealed(map: &HexMap, pos: &HexCoord) -> bool {
    map.cells
        .get(&(pos.x, pos.y))
        .map_or(false, |c| c.is_concealment)
}

/// Get hazard at a position, returns (type, damage) if present.
pub fn hazard_at(map: &HexMap, pos: &HexCoord) -> Option<(HazardType, i32)> {
    map.cells
        .get(&(pos.x, pos.y))
        .and_then(|c| c.hazard_type.map(|ht| (ht, c.hazard_damage)))
}

/// Check if a hex is occupied by another participant (not the excluded one).
pub fn is_hex_occupied(
    participants: &[Participant],
    pos: &HexCoord,
    exclude_id: u64,
) -> bool {
    participants.iter().any(|p| {
        p.id != exclude_id
            && !p.is_knocked_out
            && p.position.x == pos.x
            && p.position.y == pos.y
    })
}

/// Check if a hex is traversable (Ruby: `can_move_through?` gates on `hex.traversable`).
/// Absent hexes default to traversable.
pub fn hex_is_traversable(map: &HexMap, x: i32, y: i32) -> bool {
    match map.cells.get(&(x, y)) {
        None => true,
        Some(cell) => !cell.blocks_movement,
    }
}

/// Check if a hex is *playable* for a participant to stand on.
/// Mirrors Ruby `RoomHex.playable_at?` (room_hex.rb:497): the hex must exist
/// in the map and must not block movement. Absent cells are NOT playable
/// (stricter than `hex_is_traversable`).
///
/// When the fight has no explicit battle map (hex_map empty), treat all
/// positions as playable — the room is an open field, not a tactical grid.
pub fn is_playable(map: &HexMap, x: i32, y: i32) -> bool {
    if map.cells.is_empty() {
        return true;
    }
    match map.cells.get(&(x, y)) {
        None => false,
        Some(cell) => !cell.blocks_movement,
    }
}

/// Check if movement from one hex to another is blocked by passable_edges.
pub fn movement_blocked_by_edges(
    map: &HexMap,
    from: &HexCoord,
    to: &HexCoord,
) -> bool {
    let dir = match hex_grid::direction_between(from.x, from.y, to.x, to.y) {
        Some(d) => d,
        None => return false,
    };
    // Check if the destination hex has passable_edges and if this direction is blocked
    if let Some(cell) = map.cells.get(&(to.x, to.y)) {
        if let Some(ref edges) = cell.passable_edges {
            // Need to check the opposite direction (entering from the other side)
            let opposite = opposite_direction(dir);
            return edges.get(&opposite).copied() == Some(false);
        }
    }
    false
}

/// Apply `damage` to a destructible cover hex.
///
/// Mirrors Ruby `BattleMapCombatService#damage_cover` (battlemap/
/// battle_map_combat_service.rb:62-74):
/// - No-op if the hex is absent, non-destructible, or already out of HP.
/// - Subtract damage from `hit_points`. If HP ≤ 0, transition to debris:
///   clear `cover_type`, set `hex_kind = Debris`, `blocks_los = false`,
///   emit `CombatEvent::CoverDestroyed`.
///
/// Returns `true` if the cover was destroyed by this call.
pub fn damage_cover_hex(
    map: &mut HexMap,
    x: i32,
    y: i32,
    damage: i32,
    destroyer_id: Option<u64>,
    segment: u32,
    events: &mut Vec<CombatEvent>,
) -> bool {
    let cell = match map.cells.get_mut(&(x, y)) {
        Some(c) => c,
        None => return false,
    };
    // Only destructible cover with HP remaining can take damage.
    if cell.cover_type.is_none() {
        return false;
    }
    let hp = match cell.hit_points {
        Some(hp) if hp > 0 => hp,
        _ => return false,
    };
    let new_hp = hp - damage;
    if new_hp <= 0 {
        cell.cover_type = None;
        cell.hit_points = None;
        cell.hex_kind = HexKind::Debris;
        cell.blocks_los = false;
        events.push(CombatEvent::CoverDestroyed {
            hex_x: x,
            hex_y: y,
            destroyer_id,
            segment,
        });
        true
    } else {
        cell.hit_points = Some(new_hp);
        false
    }
}

fn opposite_direction(dir: Direction) -> Direction {
    match dir {
        Direction::N => Direction::S,
        Direction::NE => Direction::SW,
        Direction::SE => Direction::NW,
        Direction::S => Direction::N,
        Direction::SW => Direction::NE,
        Direction::NW => Direction::SE,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::*;
    use std::collections::HashMap;

    fn empty_map() -> HexMap {
        HexMap {
            width: 10,
            height: 10,
            cells: HashMap::new(),
        }
    }

    fn map_with_blocker_at(x: i32, y: i32) -> HexMap {
        let mut map = empty_map();
        map.cells.insert(
            (x, y),
            HexCell {
                x,
                y,
                blocks_los: true,
                blocks_movement: true,
                ..Default::default()
            },
        );
        map
    }

    #[test]
    fn test_los_clear_path() {
        let map = empty_map();
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 0, y: 8, z: 0 };
        assert!(has_line_of_sight(&map, None, &from, &to, 0));
    }

    #[test]
    fn test_los_blocked() {
        // Default cover_height=0, but a blocker with blocks_los=true and cover_height=0
        // still blocks at elevation_level 0. Give it height 1 so viewer_z=0 < 0+1.
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                blocks_los: true,
                blocks_movement: true,
                cover_height: 1,
                ..Default::default()
            },
        );
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 0, y: 8, z: 0 };
        assert!(!has_line_of_sight(&map, None, &from, &to, 0));
    }

    #[test]
    fn test_los_adjacent_always_clear() {
        let map = map_with_blocker_at(0, 4);
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord {
            x: 0,
            y: 4,
            z: 0,
        };
        assert!(has_line_of_sight(&map, None, &from, &to, 0));
    }

    #[test]
    fn test_los_dispatches_to_pixel_ray_cast_when_mask_present() {
        // hex-level blocks_los would say clear (no blocker), but the mask has
        // a wall pixel between the two hex-pixel positions. Mask wins.
        use crate::types::wall_mask::{HexGeometry, WallMask};
        let map = empty_map();
        // Minimum viable geometry so hex (0,0) and (0,8) map to distinct
        // horizontal pixels; keep it 1-pixel tall to keep math trivial.
        let mut pixels = vec![0u8; 20];
        pixels[10] = 1; // wall pixel at x=10, y=0
        let mask = WallMask {
            width: 20,
            height: 1,
            pixels,
            hex_geometry: HexGeometry {
                hex_size: 1.0,
                hex_height: 1.0,
                min_x: 0,
                min_y: 0,
                num_visual_rows: 1,
            },
        };
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 19, y: 0, z: 0 };
        // With the mask, the ray traverses the wall pixel → blocked.
        assert!(!has_line_of_sight(&map, Some(&mask), &from, &to, 0));
        // Without the mask, the empty hex line is clear.
        assert!(has_line_of_sight(&map, None, &from, &to, 0));
    }

    #[test]
    fn test_los_see_over_short_cover() {
        // Cover at elevation 0 with height 2. Viewer at z=3 sees over it.
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                blocks_los: true,
                elevation_level: 0,
                cover_height: 2,
                ..Default::default()
            },
        );
        let from = HexCoord { x: 0, y: 0, z: 3 };
        let to = HexCoord { x: 0, y: 8, z: 0 };
        assert!(has_line_of_sight(&map, None, &from, &to, 3));
    }

    #[test]
    fn test_los_blocked_by_tall_cover() {
        // Cover at elevation 0 with height 5. Viewer at z=3 does not see over.
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                blocks_los: true,
                elevation_level: 0,
                cover_height: 5,
                ..Default::default()
            },
        );
        let from = HexCoord { x: 0, y: 0, z: 3 };
        let to = HexCoord { x: 0, y: 8, z: 0 };
        assert!(!has_line_of_sight(&map, None, &from, &to, 3));
    }

    #[test]
    fn test_back_to_wall_blocked() {
        let mut map = empty_map();
        // Defender at (0,4), wall behind them at (0,8)
        map.cells.insert(
            (0, 8),
            HexCell {
                x: 0,
                y: 8,
                blocks_movement: true,
                ..Default::default()
            },
        );
        let attacker = HexCoord { x: 0, y: 0, z: 0 };
        let defender = HexCoord {
            x: 0,
            y: 4,
            z: 0,
        };
        assert!(back_to_wall(&map, &attacker, &defender));
    }

    #[test]
    fn test_back_to_wall_open() {
        let mut map = empty_map();
        // Add a passable cell behind the defender so retreat is possible
        map.cells.insert(
            (0, 8),
            HexCell {
                x: 0,
                y: 8,
                blocks_movement: false,
                ..Default::default()
            },
        );
        let attacker = HexCoord { x: 0, y: 0, z: 0 };
        let defender = HexCoord {
            x: 0,
            y: 4,
            z: 0,
        };
        assert!(!back_to_wall(&map, &attacker, &defender));
    }

    #[test]
    fn test_back_to_wall_off_map() {
        // If retreat hex is off map (not in cells) on an active battle map, treated as wall
        let mut map = empty_map();
        // Add at least one cell so the map is considered "active"
        map.cells.insert(
            (0, 0),
            HexCell {
                x: 0,
                y: 0,
                ..Default::default()
            },
        );
        let attacker = HexCoord { x: 0, y: 0, z: 0 };
        let defender = HexCoord {
            x: 0,
            y: 4,
            z: 0,
        };
        // retreat hex (0,8) not in map -> true (wall)
        assert!(back_to_wall(&map, &attacker, &defender));
    }

    #[test]
    fn test_back_to_wall_empty_map() {
        // Empty map (no battle map) = never back-to-wall
        let map = empty_map();
        let attacker = HexCoord { x: 0, y: 0, z: 0 };
        let defender = HexCoord {
            x: 0,
            y: 4,
            z: 0,
        };
        assert!(!back_to_wall(&map, &attacker, &defender));
    }

    #[test]
    fn test_elevation_modifier_higher() {
        assert_eq!(elevation_modifier(3, 1), 2);
        assert_eq!(elevation_modifier(2, 1), 1);
    }

    #[test]
    fn test_elevation_modifier_same() {
        assert_eq!(elevation_modifier(1, 1), 0);
    }

    #[test]
    fn test_elevation_modifier_lower() {
        assert_eq!(elevation_modifier(1, 2), -1);
        assert_eq!(elevation_modifier(1, 4), -2);
    }

    #[test]
    fn test_elevation_damage_bonus() {
        assert_eq!(elevation_damage_bonus(3, 1), 2);
        assert_eq!(elevation_damage_bonus(2, 1), 0); // only 1 level diff
        assert_eq!(elevation_damage_bonus(1, 1), 0);
        assert_eq!(elevation_damage_bonus(1, 3), 0); // below = no bonus
    }

    #[test]
    fn test_hazard_at() {
        let mut map = empty_map();
        map.cells.insert(
            (0, 0),
            HexCell {
                x: 0,
                y: 0,
                hazard_type: Some(HazardType::Fire),
                hazard_damage: 4,
                ..Default::default()
            },
        );
        let pos = HexCoord { x: 0, y: 0, z: 0 };
        let result = hazard_at(&map, &pos);
        assert_eq!(result, Some((HazardType::Fire, 4)));
    }

    #[test]
    fn test_no_hazard() {
        let map = empty_map();
        let pos = HexCoord { x: 0, y: 0, z: 0 };
        assert_eq!(hazard_at(&map, &pos), None);
    }

    #[test]
    fn test_cover_detection() {
        // Cover at (0,8) between attacker (0,0) and target (0,16)
        // (0,4) is adjacent to attacker so gets skipped per Ruby adjacency rule
        let mut map = empty_map();
        map.cells.insert(
            (0, 8),
            HexCell {
                x: 0,
                y: 8,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord {
            x: 0,
            y: 16,
            z: 0,
        };
        assert!(shot_passes_through_cover(&map, &from, &to));

        // Cover adjacent to attacker should NOT block (Ruby ignores adjacent cover)
        let mut map2 = empty_map();
        map2.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );
        let from2 = HexCoord { x: 0, y: 0, z: 0 };
        let to2 = HexCoord { x: 0, y: 8, z: 0 };
        assert!(!shot_passes_through_cover(&map2, &from2, &to2));
    }

    #[test]
    fn test_cover_grouping_adjacent_block_ignored() {
        // Ruby CoverLosService: contiguous block of cover where one hex is adjacent
        // to attacker → entire block is ignored (cover doesn't apply).
        // Cover at (0,4) (adjacent to attacker) and (0,8) (not adjacent).
        // Both form one contiguous block → block ignored → no cover penalty.
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );
        map.cells.insert(
            (0, 8),
            HexCell {
                x: 0,
                y: 8,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 0, y: 16, z: 0 };
        assert!(!shot_passes_through_cover(&map, &from, &to));
    }

    #[test]
    fn test_cover_grouping_separate_block_applies() {
        // Two separate cover blocks: one adjacent to attacker (ignored), one distant
        // (applies). Cover applies if ANY block has no attacker-adjacent hex.
        // Cover at (0,4) (adjacent, part of block A), (0,12) (distant block B).
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );
        map.cells.insert(
            (0, 12),
            HexCell {
                x: 0,
                y: 12,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 0, y: 16, z: 0 };
        assert!(shot_passes_through_cover(&map, &from, &to));
    }

    #[test]
    fn test_concealment() {
        let mut map = empty_map();
        map.cells.insert(
            (0, 0),
            HexCell {
                x: 0,
                y: 0,
                is_concealment: true,
                ..Default::default()
            },
        );
        let pos = HexCoord { x: 0, y: 0, z: 0 };
        assert!(is_concealed(&map, &pos));

        let empty_pos = HexCoord { x: 2, y: 0, z: 0 };
        assert!(!is_concealed(&map, &empty_pos));
    }

    #[test]
    fn test_is_hex_occupied() {
        let participants = vec![
            Participant {
                id: 1,
                position: HexCoord { x: 0, y: 0, z: 0 },
                is_knocked_out: false,
                ..Default::default()
            },
            Participant {
                id: 2,
                position: HexCoord { x: 2, y: 0, z: 0 },
                is_knocked_out: false,
                ..Default::default()
            },
            Participant {
                id: 3,
                position: HexCoord { x: 0, y: 0, z: 0 },
                is_knocked_out: true,
                ..Default::default()
            },
        ];

        let pos = HexCoord { x: 0, y: 0, z: 0 };
        // Participant 1 is there, excluding id 2 -> occupied
        assert!(is_hex_occupied(&participants, &pos, 2));
        // Excluding id 1, only knocked-out id 3 is there -> not occupied
        assert!(!is_hex_occupied(&participants, &pos, 1));
        // Empty hex
        let empty_pos = HexCoord { x: 0, y: 4, z: 0 };
        assert!(!is_hex_occupied(&participants, &empty_pos, 1));
    }

    #[test]
    fn test_movement_blocked_by_edges() {
        let mut map = empty_map();
        let mut edges = HashMap::new();
        edges.insert(Direction::S, false); // Block entry from the south
        edges.insert(Direction::N, true);
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                passable_edges: Some(edges),
                ..Default::default()
            },
        );

        let from_south = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 0, y: 4, z: 0 };
        // Moving north into (0,4), entering from south -> blocked
        assert!(movement_blocked_by_edges(&map, &from_south, &to));

        let from_north = HexCoord { x: 0, y: 8, z: 0 };
        // Moving south into (0,4), entering from north -> allowed
        assert!(!movement_blocked_by_edges(&map, &from_north, &to));
    }

    #[test]
    fn test_movement_no_edges() {
        let map = empty_map();
        let from = HexCoord { x: 0, y: 0, z: 0 };
        let to = HexCoord { x: 0, y: 4, z: 0 };
        assert!(!movement_blocked_by_edges(&map, &from, &to));
    }

    #[test]
    fn test_opposite_direction() {
        assert_eq!(opposite_direction(Direction::N), Direction::S);
        assert_eq!(opposite_direction(Direction::NE), Direction::SW);
        assert_eq!(opposite_direction(Direction::SE), Direction::NW);
        assert_eq!(opposite_direction(Direction::S), Direction::N);
        assert_eq!(opposite_direction(Direction::SW), Direction::NE);
        assert_eq!(opposite_direction(Direction::NW), Direction::SE);
    }

    fn destructible_cover_map(hp: i32) -> HexMap {
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                cover_type: Some(CoverType::Destructible),
                hit_points: Some(hp),
                blocks_los: true,
                ..Default::default()
            },
        );
        map
    }

    #[test]
    fn test_damage_cover_partial_no_destroy() {
        let mut map = destructible_cover_map(10);
        let mut events: Vec<CombatEvent> = Vec::new();
        let destroyed = damage_cover_hex(&mut map, 0, 4, 3, Some(7), 12, &mut events);
        assert!(!destroyed);
        assert!(events.is_empty());
        let cell = map.cells.get(&(0, 4)).unwrap();
        assert_eq!(cell.hit_points, Some(7));
        assert!(cell.cover_type.is_some());
        assert!(cell.blocks_los);
    }

    #[test]
    fn test_damage_cover_destroys_at_zero() {
        let mut map = destructible_cover_map(5);
        let mut events: Vec<CombatEvent> = Vec::new();
        let destroyed = damage_cover_hex(&mut map, 0, 4, 10, Some(7), 12, &mut events);
        assert!(destroyed);
        assert_eq!(events.len(), 1);
        match &events[0] {
            CombatEvent::CoverDestroyed {
                hex_x,
                hex_y,
                destroyer_id,
                segment,
            } => {
                assert_eq!(*hex_x, 0);
                assert_eq!(*hex_y, 4);
                assert_eq!(*destroyer_id, Some(7));
                assert_eq!(*segment, 12);
            }
            other => panic!("unexpected event: {:?}", other),
        }
        let cell = map.cells.get(&(0, 4)).unwrap();
        assert!(cell.cover_type.is_none());
        assert!(cell.hit_points.is_none());
        assert!(!cell.blocks_los);
        assert_eq!(cell.hex_kind, HexKind::Debris);
    }

    #[test]
    fn test_damage_cover_noop_on_nondestructible() {
        // A non-destructible cover (Half) has hit_points=None; damage is a no-op.
        let mut map = empty_map();
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                cover_type: Some(CoverType::Half),
                hit_points: None,
                ..Default::default()
            },
        );
        let mut events: Vec<CombatEvent> = Vec::new();
        let destroyed = damage_cover_hex(&mut map, 0, 4, 100, None, 0, &mut events);
        assert!(!destroyed);
        assert!(events.is_empty());
        assert_eq!(
            map.cells.get(&(0, 4)).unwrap().cover_type,
            Some(CoverType::Half)
        );
    }

    #[test]
    fn test_damage_cover_noop_on_missing_hex() {
        let mut map = empty_map();
        let mut events: Vec<CombatEvent> = Vec::new();
        let destroyed = damage_cover_hex(&mut map, 99, 99, 5, None, 0, &mut events);
        assert!(!destroyed);
        assert!(events.is_empty());
    }
}
