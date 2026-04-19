use rand::Rng;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::types::hex::HexCoord;

/// Qi lightness movement modes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum QiLightnessMode {
    WallRun,
    WallBounce,
    TreeLeap,
}

/// Outcome of an area-denial check on a single mover/denier pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AreaDenialBlock {
    Allowed,
    /// Mover tried to move closer/sideways relative to an adjacent denier,
    /// and the target is not their entry hex.
    Lateral,
    /// Mover tried to gain elevation while adjacent (at source or destination)
    /// to an enemy denier.
    Elevation,
}

/// Per-round state tracking where each mover first entered adjacency of each
/// denier, so a return to that entry hex is allowed.
///
/// Key: `(mover_id, denier_id)` → entry hex `(x, y)`.
#[derive(Debug, Default, Clone)]
pub struct AreaDenialTracker {
    entries: HashMap<(u64, u64), (i32, i32)>,
}

impl AreaDenialTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn entry_for(&self, mover_id: u64, denier_id: u64) -> Option<(i32, i32)> {
        self.entries.get(&(mover_id, denier_id)).copied()
    }

    pub fn record_entry(&mut self, mover_id: u64, denier_id: u64, x: i32, y: i32) {
        self.entries.entry((mover_id, denier_id)).or_insert((x, y));
    }
}

/// Stateless legacy check retained for callers that don't track entry hexes
/// or elevation. Prefer `check_area_denial`.
pub fn area_denial_blocks_movement(
    denier_pos: &HexCoord,
    mover_pos: &HexCoord,
    target_pos: &HexCoord,
) -> bool {
    let current_dist = crate::hex_grid::hex_distance(
        mover_pos.x,
        mover_pos.y,
        denier_pos.x,
        denier_pos.y,
    );
    let target_dist = crate::hex_grid::hex_distance(
        target_pos.x,
        target_pos.y,
        denier_pos.x,
        denier_pos.y,
    );
    if current_dist > 1 {
        return false;
    }
    target_dist <= current_dist
}

/// Full area-denial check mirroring Ruby's `TacticAreaDenialService`:
///
/// * **Elevation** (`check_elevation_denial`): if the mover is adjacent to the
///   denier at either the source OR the destination hex, blocks any move that
///   gains elevation (`to_elevation > from_elevation`).
/// * **Lateral** (`check_lateral_denial`): if the mover is adjacent at the
///   source, the target hex must either increase distance from the denier OR
///   match the tracked entry hex (first hex where the mover entered adjacency
///   this round).
///
/// The tracker is updated in-place when a new adjacency is observed.
pub fn check_area_denial(
    mover_id: u64,
    denier_id: u64,
    denier_pos: &HexCoord,
    mover_pos: &HexCoord,
    target_pos: &HexCoord,
    from_elevation: i32,
    to_elevation: i32,
    tracker: &mut AreaDenialTracker,
) -> AreaDenialBlock {
    let dist_from = crate::hex_grid::hex_distance(
        mover_pos.x,
        mover_pos.y,
        denier_pos.x,
        denier_pos.y,
    );
    let dist_to = crate::hex_grid::hex_distance(
        target_pos.x,
        target_pos.y,
        denier_pos.x,
        denier_pos.y,
    );

    let from_adjacent = dist_from <= 1;
    let to_adjacent = dist_to <= 1;

    // Elevation denial: adjacency at either end is sufficient.
    if (from_adjacent || to_adjacent) && to_elevation > from_elevation {
        return AreaDenialBlock::Elevation;
    }

    // If mover is currently adjacent, record the entry hex (first time wins).
    if from_adjacent {
        tracker.record_entry(mover_id, denier_id, mover_pos.x, mover_pos.y);
    }

    // Lateral denial only applies when mover is adjacent at the source.
    if !from_adjacent {
        return AreaDenialBlock::Allowed;
    }

    // Moving away (increasing distance) is always allowed.
    if dist_to > dist_from {
        return AreaDenialBlock::Allowed;
    }

    // Returning to entry hex is allowed.
    if let Some((ex, ey)) = tracker.entry_for(mover_id, denier_id) {
        if target_pos.x == ex && target_pos.y == ey {
            return AreaDenialBlock::Allowed;
        }
    }

    AreaDenialBlock::Lateral
}

/// Qi aura damage reduction per attacker (flat 5).
pub fn qi_aura_reduction() -> i32 {
    5
}

/// Qi lightness movement bonus in hexes.
pub fn qi_lightness_movement_bonus(mode: &QiLightnessMode) -> u32 {
    match mode {
        QiLightnessMode::WallRun => 3,
        QiLightnessMode::WallBounce => 6,
        QiLightnessMode::TreeLeap => 3,
    }
}

/// Qi lightness elevation bonus.
pub fn qi_lightness_elevation(mode: &QiLightnessMode) -> i32 {
    match mode {
        QiLightnessMode::WallRun => 4,
        QiLightnessMode::WallBounce => 16,
        QiLightnessMode::TreeLeap => 16,
    }
}

/// Guard redirect check: should attack on protected ally redirect to guardian?
///
/// Returns `true` with 50% probability.
pub fn guard_redirect(rng: &mut impl Rng) -> bool {
    rng.gen_ratio(1, 2)
}

/// Back-to-back redirect check: should attack redirect to partner?
///
/// Returns `true` with 50% probability if mutual, 25% if one-sided.
pub fn back_to_back_redirect(is_mutual: bool, rng: &mut impl Rng) -> bool {
    if is_mutual {
        rng.gen_ratio(1, 2) // 50% mutual
    } else {
        rng.gen_ratio(1, 4) // 25% one-sided
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::HexCoord;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn coord(x: i32, y: i32) -> HexCoord {
        HexCoord { x, y, z: 0 }
    }

    // --- area_denial ---

    #[test]
    fn test_area_denial_blocks_closing_movement() {
        // Denier at (0,0), mover adjacent at NE (1,2), trying to move to (0,0)
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(0, 0); // moving closer
        assert!(area_denial_blocks_movement(&denier, &mover, &target));
    }

    #[test]
    fn test_area_denial_blocks_sideways_movement() {
        // Denier at (0,0), mover adjacent at NE (1,2), trying to move sideways
        // to NW (-1,2) -- same distance from denier
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(-1, 2); // same distance (1)
        assert!(area_denial_blocks_movement(&denier, &mover, &target));
    }

    #[test]
    fn test_area_denial_allows_retreat() {
        // Denier at (0,0), mover at NE (1,2), moving further away to (2,4)
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(2, 4); // distance 2 from denier
        assert!(!area_denial_blocks_movement(&denier, &mover, &target));
    }

    #[test]
    fn test_area_denial_ignores_distant_mover() {
        // Denier at (0,0), mover at (2,4) -- distance 2, not adjacent
        let denier = coord(0, 0);
        let mover = coord(2, 4);
        let target = coord(1, 2); // moving closer
        assert!(!area_denial_blocks_movement(&denier, &mover, &target));
    }

    // --- check_area_denial (stateful: elevation + entry tracking) ---

    #[test]
    fn test_check_area_denial_blocks_elevation_gain_when_from_adjacent() {
        // Mover adjacent to denier at source, attempting to step up.
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(2, 4); // moving away laterally but gaining elevation
        let mut tracker = AreaDenialTracker::new();
        let r = check_area_denial(10, 20, &denier, &mover, &target, 0, 4, &mut tracker);
        assert_eq!(r, AreaDenialBlock::Elevation);
    }

    #[test]
    fn test_check_area_denial_blocks_elevation_gain_when_to_adjacent() {
        // Mover non-adjacent at source, but target hex is adjacent AND higher.
        // Ruby's check_elevation_denial guards both ends.
        let denier = coord(0, 0);
        let mover = coord(2, 4); // distance 2, not adjacent
        let target = coord(1, 2); // distance 1, adjacent
        let mut tracker = AreaDenialTracker::new();
        let r = check_area_denial(10, 20, &denier, &mover, &target, 0, 4, &mut tracker);
        assert_eq!(r, AreaDenialBlock::Elevation);
    }

    #[test]
    fn test_check_area_denial_allows_same_elevation_retreat() {
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(2, 4); // further away, same elevation
        let mut tracker = AreaDenialTracker::new();
        let r = check_area_denial(10, 20, &denier, &mover, &target, 0, 0, &mut tracker);
        assert_eq!(r, AreaDenialBlock::Allowed);
    }

    #[test]
    fn test_check_area_denial_allows_descending_adjacent() {
        // Losing or keeping elevation is fine even while adjacent.
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(2, 4);
        let mut tracker = AreaDenialTracker::new();
        let r = check_area_denial(10, 20, &denier, &mover, &target, 5, 2, &mut tracker);
        assert_eq!(r, AreaDenialBlock::Allowed);
    }

    #[test]
    fn test_check_area_denial_lateral_blocks_sideways() {
        // Mover adjacent at same distance, not entry hex → blocked.
        let denier = coord(0, 0);
        let mover = coord(1, 2);
        let target = coord(-1, 2); // still distance 1, lateral
        let mut tracker = AreaDenialTracker::new();
        let r = check_area_denial(10, 20, &denier, &mover, &target, 0, 0, &mut tracker);
        assert_eq!(r, AreaDenialBlock::Lateral);
    }

    #[test]
    fn test_check_area_denial_allows_return_to_entry_hex() {
        // Ruby records entry when the mover is adjacent at the FROM hex.
        // Mimic the full sequence across segments:
        //   (1,2) → (-1,2)  [sideways, blocked; entry recorded = (1,2)]
        //   assume the mover ends up at (-1,2) via another path, then
        //   (-1,2) → (1,2)  [return to entry hex — must be allowed]
        let denier = coord(0, 0);
        let mut tracker = AreaDenialTracker::new();

        // First check while already adjacent records entry = from hex.
        let r_side = check_area_denial(
            10,
            20,
            &denier,
            &coord(1, 2),
            &coord(-1, 2),
            0,
            0,
            &mut tracker,
        );
        assert_eq!(r_side, AreaDenialBlock::Lateral);
        assert_eq!(tracker.entry_for(10, 20), Some((1, 2)));

        // Suppose mover ended up at (-1,2). Now retreating back to entry hex.
        // Same distance (1→1), but allowed because target matches entry.
        let r_back = check_area_denial(
            10,
            20,
            &denier,
            &coord(-1, 2),
            &coord(1, 2),
            0,
            0,
            &mut tracker,
        );
        assert_eq!(r_back, AreaDenialBlock::Allowed);
    }

    #[test]
    fn test_check_area_denial_entry_first_wins() {
        // First adjacency wins; later from-adjacent calls do NOT overwrite.
        let denier = coord(0, 0);
        let mut tracker = AreaDenialTracker::new();

        // First adjacent check at from=(1,2).
        let _ = check_area_denial(10, 20, &denier, &coord(1, 2), &coord(2, 4), 0, 0, &mut tracker);
        assert_eq!(tracker.entry_for(10, 20), Some((1, 2)));

        // Later adjacent check at from=(-1,2) — should NOT overwrite.
        let _ = check_area_denial(10, 20, &denier, &coord(-1, 2), &coord(-2, 4), 0, 0, &mut tracker);
        assert_eq!(tracker.entry_for(10, 20), Some((1, 2)));
    }

    #[test]
    fn test_check_area_denial_ignores_non_adjacent_mover() {
        // Mover far away, no adjacency at either end → always allowed.
        let denier = coord(0, 0);
        let mover = coord(4, 8);
        let target = coord(3, 6);
        let mut tracker = AreaDenialTracker::new();
        let r = check_area_denial(10, 20, &denier, &mover, &target, 5, 10, &mut tracker);
        assert_eq!(r, AreaDenialBlock::Allowed);
    }

    // --- qi_aura ---

    #[test]
    fn test_qi_aura_reduction() {
        assert_eq!(qi_aura_reduction(), 5);
    }

    // --- qi_lightness ---

    #[test]
    fn test_qi_lightness_movement_bonus_wall_run() {
        assert_eq!(
            qi_lightness_movement_bonus(&QiLightnessMode::WallRun),
            3
        );
    }

    #[test]
    fn test_qi_lightness_movement_bonus_wall_bounce() {
        assert_eq!(
            qi_lightness_movement_bonus(&QiLightnessMode::WallBounce),
            6
        );
    }

    #[test]
    fn test_qi_lightness_movement_bonus_tree_leap() {
        assert_eq!(
            qi_lightness_movement_bonus(&QiLightnessMode::TreeLeap),
            3
        );
    }

    #[test]
    fn test_qi_lightness_elevation_wall_run() {
        assert_eq!(qi_lightness_elevation(&QiLightnessMode::WallRun), 4);
    }

    #[test]
    fn test_qi_lightness_elevation_wall_bounce() {
        assert_eq!(qi_lightness_elevation(&QiLightnessMode::WallBounce), 16);
    }

    #[test]
    fn test_qi_lightness_elevation_tree_leap() {
        assert_eq!(qi_lightness_elevation(&QiLightnessMode::TreeLeap), 16);
    }

    // --- guard_redirect ---

    #[test]
    fn test_guard_redirect_probability() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let trials = 1000;
        let redirects: usize = (0..trials)
            .filter(|_| guard_redirect(&mut rng))
            .count();
        // Expect ~50%, allow 40%-60% range
        assert!(
            redirects > 400 && redirects < 600,
            "guard_redirect redirected {} out of {} (expected ~500)",
            redirects,
            trials
        );
    }

    // --- back_to_back_redirect ---

    #[test]
    fn test_back_to_back_mutual_probability() {
        let mut rng = ChaCha8Rng::seed_from_u64(123);
        let trials = 1000;
        let redirects: usize = (0..trials)
            .filter(|_| back_to_back_redirect(true, &mut rng))
            .count();
        // Expect ~50%, allow 40%-60% range
        assert!(
            redirects > 400 && redirects < 600,
            "mutual back_to_back redirected {} out of {} (expected ~500)",
            redirects,
            trials
        );
    }

    #[test]
    fn test_back_to_back_one_sided_probability() {
        let mut rng = ChaCha8Rng::seed_from_u64(456);
        let trials = 1000;
        let redirects: usize = (0..trials)
            .filter(|_| back_to_back_redirect(false, &mut rng))
            .count();
        // Expect ~25%, allow 18%-32% range
        assert!(
            redirects > 180 && redirects < 320,
            "one-sided back_to_back redirected {} out of {} (expected ~250)",
            redirects,
            trials
        );
    }
}
