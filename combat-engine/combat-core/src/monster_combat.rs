use rand::Rng;

use crate::hex_grid;
use crate::types::config::CombatConfig;
use crate::types::hex::HexCoord;
use crate::types::monsters::{
    MonsterData, MonsterSegment, MountState, MountStatus, SegmentStatus,
};
use crate::types::participant::Participant;

// ---------------------------------------------------------------------------
// Mounting helpers
// ---------------------------------------------------------------------------

/// Check if a participant can mount a monster segment.
///
/// The participant must be adjacent to (or on top of) the segment.
pub fn can_mount(participant_pos: &HexCoord, segment_pos: &HexCoord) -> bool {
    hex_grid::hex_distance(
        participant_pos.x,
        participant_pos.y,
        segment_pos.x,
        segment_pos.y,
    ) <= 1
}

/// Process a climb action. Returns the new climb progress, capped at 100.
pub fn process_climb(current_progress: u32, climb_distance: i32) -> u32 {
    (current_progress + climb_distance.max(0) as u32).min(100)
}

/// Check if a participant has reached the weak point.
pub fn at_weak_point(climb_progress: u32) -> bool {
    climb_progress >= 100
}

/// Roll a shake-off check. Returns `true` if the participant is thrown off.
///
/// Higher `num_climbers` makes it easier for the monster to shake off.
pub fn shake_off_check(
    shake_off_threshold: i32,
    num_climbers: u32,
    rng: &mut impl Rng,
) -> bool {
    let roll: i32 = rng.gen_range(1..=20);
    roll <= shake_off_threshold + num_climbers as i32
}

// ---------------------------------------------------------------------------
// Segment checks
// ---------------------------------------------------------------------------

/// Check if a monster segment is destroyed.
pub fn is_segment_destroyed(segment: &MonsterSegment) -> bool {
    segment.current_hp <= 0
}

/// Check if a monster is defeated (all segments destroyed or overall HP <= 0).
pub fn is_monster_defeated(monster: &MonsterData) -> bool {
    monster.current_hp <= 0
        || monster.segments.iter().all(|s| s.current_hp <= 0)
}

/// Check if a monster has lost mobility (all mobility-required segments destroyed).
pub fn mobility_destroyed(monster: &MonsterData) -> bool {
    monster
        .segments
        .iter()
        .filter(|s| s.required_for_mobility)
        .all(|s| s.current_hp <= 0)
}

// ---------------------------------------------------------------------------
// Damage functions
// ---------------------------------------------------------------------------

/// Apply damage to a specific monster segment.
///
/// Updates segment HP, checks destruction, updates monster total HP.
/// Returns (hp_lost_on_segment, segment_destroyed).
pub fn apply_segment_damage(
    monster: &mut MonsterData,
    segment_idx: usize,
    damage: i32,
) -> (i32, bool) {
    let segment = match monster.segments.get_mut(segment_idx) {
        Some(s) => s,
        None => return (0, false),
    };

    // Already destroyed: no further damage
    if segment.status == SegmentStatus::Destroyed {
        return (0, false);
    }

    let actual_damage = damage.min(segment.current_hp).max(0);
    segment.current_hp -= actual_damage;

    let destroyed = segment.current_hp <= 0;
    if destroyed {
        segment.current_hp = 0;
        segment.status = SegmentStatus::Destroyed;
    } else if segment.current_hp < segment.max_hp {
        segment.status = SegmentStatus::Damaged;
    }

    // Reduce monster overall HP
    monster.current_hp = (monster.current_hp - actual_damage).max(0);

    (actual_damage, destroyed)
}

/// Apply weak point attack: 3x damage distributed to all active segments.
///
/// Returns total damage dealt across all segments.
pub fn apply_weak_point_damage(monster: &mut MonsterData, base_damage: i32) -> i32 {
    let total = base_damage * 3;
    let active_count = monster
        .segments
        .iter()
        .filter(|s| s.status != SegmentStatus::Destroyed)
        .count();

    if active_count == 0 {
        return 0;
    }

    let per_segment = total / active_count as i32;
    let mut total_dealt = 0;

    // Collect active segment indices first to avoid borrow issues
    let active_indices: Vec<usize> = monster
        .segments
        .iter()
        .enumerate()
        .filter(|(_, s)| s.status != SegmentStatus::Destroyed)
        .map(|(i, _)| i)
        .collect();

    for idx in active_indices {
        let (dealt, _) = apply_segment_damage(monster, idx, per_segment);
        total_dealt += dealt;
    }

    total_dealt
}

/// Check if monster should collapse (majority of mobility segments destroyed).
pub fn check_collapse(monster: &MonsterData) -> bool {
    let mobility_segments: Vec<&MonsterSegment> = monster
        .segments
        .iter()
        .filter(|s| s.required_for_mobility)
        .collect();

    let total = mobility_segments.len();
    if total == 0 {
        return false;
    }

    let destroyed = mobility_segments
        .iter()
        .filter(|s| s.status == SegmentStatus::Destroyed)
        .count();

    destroyed >= (total + 1) / 2
}

/// Check if monster is defeated (HP% below threshold).
pub fn check_defeat(monster: &MonsterData) -> bool {
    if monster.max_hp <= 0 {
        return true;
    }
    let hp_pct = (monster.current_hp * 100) / monster.max_hp;
    hp_pct <= monster.defeat_threshold_percent as i32
}

// ---------------------------------------------------------------------------
// Mounting / climbing functions
// ---------------------------------------------------------------------------

/// Process a shake-off attempt by the monster.
///
/// Non-weak-point mounted players get thrown to random scatter positions.
/// Returns list of (participant_id, thrown, landing_x, landing_y).
pub fn process_monster_shake_off(
    monster: &mut MonsterData,
    rng: &mut impl Rng,
    arena_w: i32,
    arena_h: i32,
) -> Vec<(u64, bool, i32, i32)> {
    let mut results = Vec::new();

    for mount in &mut monster.mount_states {
        match mount.mount_status {
            MountStatus::Mounted | MountStatus::Climbing => {
                mount.mount_status = MountStatus::Thrown;
                mount.climb_progress = 0;
                mount.is_at_weak_point = false;

                // Generate scatter position: random direction, distance 2-4 hexes
                let distance = rng.gen_range(2..=4i32);
                let direction = rng.gen_range(0..6u8);

                let (dx, dy) = direction_offset(direction);
                let landing_x = (monster.center.x + dx * distance).clamp(0, arena_w - 1);
                let landing_y = (monster.center.y + dy * distance).clamp(0, arena_h - 1);

                // Snap to valid hex coords (even y)
                let landing_y = if landing_y % 2 != 0 {
                    (landing_y - 1).max(0)
                } else {
                    landing_y
                };

                results.push((mount.participant_id, true, landing_x, landing_y));
            }
            MountStatus::AtWeakPoint => {
                // Players at weak point cling on and are not thrown
            }
            _ => {}
        }
    }

    results
}

/// Get the hex offset for a given direction (0-5).
fn direction_offset(direction: u8) -> (i32, i32) {
    match direction % 6 {
        0 => (0, -4),  // North
        1 => (1, -2),  // NE
        2 => (1, 2),   // SE
        3 => (0, 4),   // South
        4 => (-1, 2),  // SW
        5 => (-1, -2), // NW
        _ => unreachable!(),
    }
}

/// Advance a participant's climb by one step.
///
/// Returns (new_progress, reached_weak_point).
pub fn advance_climb(mount_state: &mut MountState, climb_distance: u32) -> (u32, bool) {
    mount_state.climb_progress += 1;
    let reached = mount_state.climb_progress >= climb_distance;
    if reached {
        mount_state.mount_status = MountStatus::AtWeakPoint;
        mount_state.is_at_weak_point = true;
    }
    (mount_state.climb_progress, reached)
}

// ---------------------------------------------------------------------------
// Monster attack scheduling
// ---------------------------------------------------------------------------

/// Schedule monster attacks across segments.
///
/// Returns `(segment_number, attacking_segment_id, target_id)` tuples sorted
/// by segment number. Each living segment attacks once per `attacks_per_round`,
/// with jittered timing across the 100-segment timeline.
pub fn schedule_monster_attacks(
    monster: &MonsterData,
    potential_targets: &[u64],
    config: &CombatConfig,
    rng: &mut impl Rng,
) -> Vec<(u32, u64, u64)> {
    let mut attacks = Vec::new();

    if potential_targets.is_empty() {
        return attacks;
    }

    for segment in &monster.segments {
        if segment.current_hp <= 0 || segment.status == SegmentStatus::Destroyed {
            continue;
        }
        for i in 0..segment.attacks_per_round {
            let target = potential_targets[rng.gen_range(0..potential_targets.len())];
            let seg_num =
                ((i + 1) * config.segments.total) / (segment.attacks_per_round + 1);
            let jitter = rng.gen_range(-5i32..=5);
            let seg =
                (seg_num as i32 + jitter).clamp(1, config.segments.total as i32) as u32;
            attacks.push((seg, segment.id, target));
        }
    }

    attacks.sort_by_key(|&(seg, _, _)| seg);
    attacks
}

/// Schedule monster attacks with threat-based targeting.
///
/// Returns: Vec of (segment_number, segment_index, target_participant_id).
pub fn schedule_monster_attacks_targeted(
    monster: &MonsterData,
    participants: &[Participant],
    rng: &mut impl Rng,
    config: &CombatConfig,
) -> Vec<(u32, usize, u64)> {
    let mut attacks = Vec::new();
    let threats = assess_threats(monster, participants);

    for (seg_idx, segment) in monster.segments.iter().enumerate() {
        if segment.current_hp <= 0 || segment.status == SegmentStatus::Destroyed {
            continue;
        }
        if segment.attacks_per_round == 0 {
            continue;
        }

        // Select target based on threat priority
        let target_id = select_target_for_segment(&threats, participants, rng);
        let target_id = match target_id {
            Some(id) => id,
            None => continue,
        };

        for i in 0..segment.attacks_per_round {
            // Evenly spread attacks across 100 segments with jitter
            let seg_num =
                ((i + 1) * config.segments.total) / (segment.attacks_per_round + 1);
            let jitter = rng.gen_range(-5i32..=5);
            let seg =
                (seg_num as i32 + jitter).clamp(1, config.segments.total as i32) as u32;
            attacks.push((seg, seg_idx, target_id));
        }
    }

    attacks.sort_by_key(|&(seg, _, _)| seg);
    attacks
}

/// Select a target for a monster segment based on threat priority.
/// Priority: weak_point attackers > climbers > mounted > closest ground enemy.
fn select_target_for_segment(
    threats: &ThreatAssessment,
    participants: &[Participant],
    rng: &mut impl Rng,
) -> Option<u64> {
    // Priority 1: Players at weak point
    if !threats.at_weak_point.is_empty() {
        let idx = rng.gen_range(0..threats.at_weak_point.len());
        return Some(threats.at_weak_point[idx]);
    }
    // Priority 2: Climbing players
    if !threats.climbing.is_empty() {
        let idx = rng.gen_range(0..threats.climbing.len());
        return Some(threats.climbing[idx]);
    }
    // Priority 3: Mounted players
    if !threats.mounted.is_empty() {
        let idx = rng.gen_range(0..threats.mounted.len());
        return Some(threats.mounted[idx]);
    }
    // Priority 4: Ground enemies
    if !threats.ground_targets.is_empty() {
        let idx = rng.gen_range(0..threats.ground_targets.len());
        return Some(threats.ground_targets[idx]);
    }
    // Fallback: any active participant on opposing side
    let active: Vec<u64> = participants
        .iter()
        .filter(|p| p.is_active())
        .map(|p| p.id)
        .collect();
    if !active.is_empty() {
        let idx = rng.gen_range(0..active.len());
        return Some(active[idx]);
    }
    None
}

// ---------------------------------------------------------------------------
// Threat assessment / Monster AI
// ---------------------------------------------------------------------------

/// Threat levels for all participants relative to a monster.
#[derive(Debug, Clone, Default)]
pub struct ThreatAssessment {
    pub at_weak_point: Vec<u64>,
    pub climbing: Vec<u64>,
    pub mounted: Vec<u64>,
    pub ground_targets: Vec<u64>,
    pub total_mounted: u32,
}

/// Assess threat levels for all participants relative to a monster.
pub fn assess_threats(monster: &MonsterData, participants: &[Participant]) -> ThreatAssessment {
    let mut assessment = ThreatAssessment::default();

    // Categorize based on mount states
    let mounted_ids: Vec<u64> = monster
        .mount_states
        .iter()
        .map(|ms| ms.participant_id)
        .collect();

    for mount in &monster.mount_states {
        match mount.mount_status {
            MountStatus::AtWeakPoint => {
                assessment.at_weak_point.push(mount.participant_id);
            }
            MountStatus::Climbing => {
                assessment.climbing.push(mount.participant_id);
            }
            MountStatus::Mounted => {
                assessment.mounted.push(mount.participant_id);
            }
            _ => {}
        }
    }

    assessment.total_mounted = assessment.at_weak_point.len() as u32
        + assessment.climbing.len() as u32
        + assessment.mounted.len() as u32;

    // Everyone else who is active and not mounted is a ground target
    for p in participants {
        if p.is_active() && !mounted_ids.contains(&p.id) {
            assessment.ground_targets.push(p.id);
        }
    }

    assessment
}

/// Decide if monster should shake off this round.
pub fn should_shake_off(monster: &MonsterData, threats: &ThreatAssessment) -> bool {
    // Always shake off if anyone is at the weak point
    if !threats.at_weak_point.is_empty() {
        return true;
    }

    // Adjusted threshold: base threshold reduced by number of climbers
    let adjusted_threshold = (monster.shake_off_threshold as u32)
        .saturating_sub(threats.climbing.len() as u32);

    threats.total_mounted >= adjusted_threshold
}

/// Select which segments should attack and their targets.
///
/// Returns Vec of (segment_index, target_id).
pub fn select_segment_targets(
    monster: &MonsterData,
    threats: &ThreatAssessment,
    participants: &[Participant],
) -> Vec<(usize, u64)> {
    let mut result = Vec::new();

    for (seg_idx, segment) in monster.segments.iter().enumerate() {
        if segment.current_hp <= 0 || segment.status == SegmentStatus::Destroyed {
            continue;
        }
        if segment.attacks_per_round == 0 {
            continue;
        }

        // Select target based on threat priority (deterministic, no RNG)
        let target_id = if !threats.at_weak_point.is_empty() {
            threats.at_weak_point[0]
        } else if !threats.climbing.is_empty() {
            threats.climbing[0]
        } else if !threats.mounted.is_empty() {
            threats.mounted[0]
        } else if !threats.ground_targets.is_empty() {
            // Pick closest ground target to this segment
            let closest = participants
                .iter()
                .filter(|p| threats.ground_targets.contains(&p.id))
                .min_by_key(|p| {
                    hex_grid::hex_distance(
                        p.position.x,
                        p.position.y,
                        segment.position.x,
                        segment.position.y,
                    )
                });
            match closest {
                Some(p) => p.id,
                None => continue,
            }
        } else {
            continue;
        };

        result.push((seg_idx, target_id));
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::HexCoord;
    use crate::types::monsters::{MonsterData, MonsterSegment, MonsterStatus, MountState};
    use crate::types::weapons::DamageType;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn coord(x: i32, y: i32) -> HexCoord {
        HexCoord { x, y, z: 0 }
    }

    fn test_segment(id: u64, hp: i32, mobility: bool) -> MonsterSegment {
        MonsterSegment {
            id,
            name: format!("segment_{}", id),
            current_hp: hp,
            max_hp: 20,
            attacks_per_round: 1,
            dice_count: 2,
            dice_sides: 6,
            damage_bonus: 3,
            damage_type: DamageType::Physical,
            reach: 2,
            is_weak_point: false,
            required_for_mobility: mobility,
            position: coord(0, 0),
            status: if hp <= 0 {
                SegmentStatus::Destroyed
            } else {
                SegmentStatus::Healthy
            },
            attacks_remaining: 1,
            damage_dice: None,
            hex_offset_x: 0,
            hex_offset_y: 0,
        }
    }

    fn test_monster(segments: Vec<MonsterSegment>, hp: i32) -> MonsterData {
        MonsterData {
            id: 1,
            name: "Test Monster".to_string(),
            current_hp: hp,
            max_hp: 100,
            center: coord(0, 0),
            segments,
            shake_off_threshold: 5,
            climb_distance: 10,
            facing: 0,
            status: MonsterStatus::Active,
            hex_width: 3,
            hex_height: 3,
            defeat_threshold_percent: 0,
            mount_states: Vec::new(),
        }
    }

    fn test_participant(id: u64) -> Participant {
        Participant {
            id,
            side: 0,
            current_hp: 6,
            max_hp: 6,
            position: coord(2, 4),
            ..Default::default()
        }
    }

    // --- can_mount ---

    #[test]
    fn test_can_mount_adjacent() {
        let participant = coord(1, 2); // adjacent to (0,0)
        let segment = coord(0, 0);
        assert!(can_mount(&participant, &segment));
    }

    #[test]
    fn test_can_mount_same_hex() {
        let participant = coord(0, 0);
        let segment = coord(0, 0);
        assert!(can_mount(&participant, &segment));
    }

    #[test]
    fn test_can_mount_distant() {
        let participant = coord(4, 8); // far away
        let segment = coord(0, 0);
        assert!(!can_mount(&participant, &segment));
    }

    // --- process_climb ---

    #[test]
    fn test_process_climb_basic() {
        assert_eq!(process_climb(30, 25), 55);
    }

    #[test]
    fn test_process_climb_caps_at_100() {
        assert_eq!(process_climb(80, 30), 100);
    }

    #[test]
    fn test_process_climb_negative_distance() {
        // Negative climb distance treated as 0
        assert_eq!(process_climb(50, -10), 50);
    }

    // --- at_weak_point ---

    #[test]
    fn test_at_weak_point_not_yet() {
        assert!(!at_weak_point(99));
    }

    #[test]
    fn test_at_weak_point_exactly() {
        assert!(at_weak_point(100));
    }

    #[test]
    fn test_at_weak_point_over() {
        assert!(at_weak_point(120));
    }

    // --- is_segment_destroyed ---

    #[test]
    fn test_segment_destroyed_zero_hp() {
        let seg = test_segment(1, 0, false);
        assert!(is_segment_destroyed(&seg));
    }

    #[test]
    fn test_segment_destroyed_negative_hp() {
        let seg = test_segment(1, -5, false);
        assert!(is_segment_destroyed(&seg));
    }

    #[test]
    fn test_segment_alive() {
        let seg = test_segment(1, 10, false);
        assert!(!is_segment_destroyed(&seg));
    }

    // --- is_monster_defeated ---

    #[test]
    fn test_monster_defeated_by_hp() {
        let monster = test_monster(vec![test_segment(1, 10, false)], 0);
        assert!(is_monster_defeated(&monster));
    }

    #[test]
    fn test_monster_defeated_all_segments_destroyed() {
        let monster = test_monster(
            vec![test_segment(1, 0, false), test_segment(2, 0, true)],
            50,
        );
        assert!(is_monster_defeated(&monster));
    }

    #[test]
    fn test_monster_alive() {
        let monster = test_monster(
            vec![test_segment(1, 10, false), test_segment(2, 5, true)],
            50,
        );
        assert!(!is_monster_defeated(&monster));
    }

    // --- mobility_destroyed ---

    #[test]
    fn test_mobility_destroyed_all_legs_gone() {
        let monster = test_monster(
            vec![
                test_segment(1, 10, false), // not mobility
                test_segment(2, 0, true),   // mobility, destroyed
                test_segment(3, 0, true),   // mobility, destroyed
            ],
            50,
        );
        assert!(mobility_destroyed(&monster));
    }

    #[test]
    fn test_mobility_intact() {
        let monster = test_monster(
            vec![
                test_segment(1, 10, false),
                test_segment(2, 5, true),  // mobility, alive
                test_segment(3, 0, true),  // mobility, destroyed
            ],
            50,
        );
        assert!(!mobility_destroyed(&monster));
    }

    // --- shake_off_check ---

    #[test]
    fn test_shake_off_with_many_climbers() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let trials = 100;
        // threshold 15 + 5 climbers = 20 -- always succeeds on d20
        let shaken: usize = (0..trials)
            .filter(|_| shake_off_check(15, 5, &mut rng))
            .count();
        assert_eq!(shaken, trials);
    }

    #[test]
    fn test_shake_off_low_threshold() {
        let mut rng = ChaCha8Rng::seed_from_u64(99);
        let trials = 200;
        // threshold 1 + 0 climbers = 1 -- only roll of 1 succeeds (5%)
        let shaken: usize = (0..trials)
            .filter(|_| shake_off_check(1, 0, &mut rng))
            .count();
        assert!(
            shaken < 30,
            "expected ~10 shakeoffs, got {}",
            shaken
        );
    }

    // --- schedule_monster_attacks ---

    #[test]
    fn test_schedule_attacks_skips_dead_segments() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let config = CombatConfig::default();
        let monster = test_monster(
            vec![test_segment(1, 0, false), test_segment(2, 10, false)],
            50,
        );
        let targets = vec![100, 101, 102];
        let attacks = schedule_monster_attacks(&monster, &targets, &config, &mut rng);
        // Only segment 2 should generate attacks
        assert!(attacks.iter().all(|&(_, seg_id, _)| seg_id == 2));
    }

    #[test]
    fn test_schedule_attacks_sorted_by_segment() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let config = CombatConfig::default();
        let mut seg1 = test_segment(1, 10, false);
        seg1.attacks_per_round = 3;
        let mut seg2 = test_segment(2, 10, false);
        seg2.attacks_per_round = 2;
        let monster = test_monster(vec![seg1, seg2], 50);
        let targets = vec![100, 101];
        let attacks = schedule_monster_attacks(&monster, &targets, &config, &mut rng);
        assert_eq!(attacks.len(), 5); // 3 + 2
        // Should be sorted by segment number
        for i in 1..attacks.len() {
            assert!(attacks[i].0 >= attacks[i - 1].0);
        }
    }

    // --- apply_segment_damage ---

    #[test]
    fn test_apply_segment_damage_basic() {
        let mut monster = test_monster(vec![test_segment(1, 20, false)], 100);
        let (dealt, destroyed) = apply_segment_damage(&mut monster, 0, 5);
        assert_eq!(dealt, 5);
        assert!(!destroyed);
        assert_eq!(monster.segments[0].current_hp, 15);
        assert_eq!(monster.segments[0].status, SegmentStatus::Damaged);
        assert_eq!(monster.current_hp, 95);
    }

    #[test]
    fn test_apply_segment_damage_destroys() {
        let mut monster = test_monster(vec![test_segment(1, 5, false)], 50);
        let (dealt, destroyed) = apply_segment_damage(&mut monster, 0, 10);
        assert_eq!(dealt, 5);
        assert!(destroyed);
        assert_eq!(monster.segments[0].current_hp, 0);
        assert_eq!(monster.segments[0].status, SegmentStatus::Destroyed);
        assert_eq!(monster.current_hp, 45);
    }

    #[test]
    fn test_apply_segment_damage_already_destroyed() {
        let mut monster = test_monster(vec![test_segment(1, 0, false)], 50);
        let (dealt, destroyed) = apply_segment_damage(&mut monster, 0, 10);
        assert_eq!(dealt, 0);
        assert!(!destroyed);
        assert_eq!(monster.current_hp, 50);
    }

    #[test]
    fn test_apply_segment_damage_invalid_index() {
        let mut monster = test_monster(vec![test_segment(1, 10, false)], 50);
        let (dealt, destroyed) = apply_segment_damage(&mut monster, 99, 10);
        assert_eq!(dealt, 0);
        assert!(!destroyed);
    }

    // --- apply_weak_point_damage ---

    #[test]
    fn test_apply_weak_point_damage() {
        let mut monster = test_monster(
            vec![
                test_segment(1, 20, false),
                test_segment(2, 20, false),
            ],
            100,
        );
        let total = apply_weak_point_damage(&mut monster, 10);
        // 10 * 3 = 30, split across 2 segments = 15 each
        assert_eq!(total, 30);
        assert_eq!(monster.segments[0].current_hp, 5);
        assert_eq!(monster.segments[1].current_hp, 5);
    }

    #[test]
    fn test_apply_weak_point_damage_skips_destroyed() {
        let mut monster = test_monster(
            vec![
                test_segment(1, 0, false),  // destroyed
                test_segment(2, 20, false), // active
            ],
            100,
        );
        let total = apply_weak_point_damage(&mut monster, 5);
        // 5 * 3 = 15, only 1 active segment
        assert_eq!(total, 15);
        assert_eq!(monster.segments[1].current_hp, 5);
    }

    #[test]
    fn test_apply_weak_point_damage_no_active_segments() {
        let mut monster = test_monster(
            vec![test_segment(1, 0, false), test_segment(2, 0, false)],
            0,
        );
        let total = apply_weak_point_damage(&mut monster, 10);
        assert_eq!(total, 0);
    }

    // --- check_collapse ---

    #[test]
    fn test_check_collapse_majority_destroyed() {
        let monster = test_monster(
            vec![
                test_segment(1, 10, false), // not mobility
                test_segment(2, 0, true),   // mobility, destroyed
                test_segment(3, 0, true),   // mobility, destroyed
                test_segment(4, 10, true),  // mobility, alive
            ],
            50,
        );
        // 2 of 3 mobility destroyed = majority
        assert!(check_collapse(&monster));
    }

    #[test]
    fn test_check_collapse_not_majority() {
        let monster = test_monster(
            vec![
                test_segment(1, 10, true), // mobility, alive
                test_segment(2, 0, true),  // mobility, destroyed
                test_segment(3, 10, true), // mobility, alive
            ],
            50,
        );
        // 1 of 3 destroyed, not majority
        assert!(!check_collapse(&monster));
    }

    #[test]
    fn test_check_collapse_no_mobility_segments() {
        let monster = test_monster(
            vec![test_segment(1, 10, false), test_segment(2, 10, false)],
            50,
        );
        // No mobility segments means no collapse possible
        assert!(!check_collapse(&monster));
    }

    // --- check_defeat ---

    #[test]
    fn test_check_defeat_zero_hp() {
        let monster = test_monster(vec![test_segment(1, 0, false)], 0);
        assert!(check_defeat(&monster));
    }

    #[test]
    fn test_check_defeat_below_threshold() {
        let mut monster = test_monster(vec![test_segment(1, 10, false)], 10);
        monster.defeat_threshold_percent = 15;
        // 10 / 100 = 10% <= 15%
        assert!(check_defeat(&monster));
    }

    #[test]
    fn test_check_defeat_above_threshold() {
        let mut monster = test_monster(vec![test_segment(1, 10, false)], 50);
        monster.defeat_threshold_percent = 10;
        // 50 / 100 = 50% > 10%
        assert!(!check_defeat(&monster));
    }

    // --- advance_climb ---

    #[test]
    fn test_advance_climb_basic() {
        let mut ms = MountState {
            participant_id: 1,
            monster_id: 1,
            segment_id: 1,
            mount_status: MountStatus::Climbing,
            climb_progress: 3,
            is_at_weak_point: false,
        };
        let (progress, reached) = advance_climb(&mut ms, 10);
        assert_eq!(progress, 4);
        assert!(!reached);
        assert_eq!(ms.mount_status, MountStatus::Climbing);
    }

    #[test]
    fn test_advance_climb_reaches_weak_point() {
        let mut ms = MountState {
            participant_id: 1,
            monster_id: 1,
            segment_id: 1,
            mount_status: MountStatus::Climbing,
            climb_progress: 9,
            is_at_weak_point: false,
        };
        let (progress, reached) = advance_climb(&mut ms, 10);
        assert_eq!(progress, 10);
        assert!(reached);
        assert_eq!(ms.mount_status, MountStatus::AtWeakPoint);
        assert!(ms.is_at_weak_point);
    }

    // --- process_monster_shake_off ---

    #[test]
    fn test_shake_off_throws_mounted_and_climbing() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let mut monster = test_monster(vec![test_segment(1, 20, false)], 100);
        monster.mount_states = vec![
            MountState {
                participant_id: 10,
                monster_id: 1,
                segment_id: 1,
                mount_status: MountStatus::Mounted,
                climb_progress: 0,
                is_at_weak_point: false,
            },
            MountState {
                participant_id: 11,
                monster_id: 1,
                segment_id: 1,
                mount_status: MountStatus::Climbing,
                climb_progress: 5,
                is_at_weak_point: false,
            },
            MountState {
                participant_id: 12,
                monster_id: 1,
                segment_id: 1,
                mount_status: MountStatus::AtWeakPoint,
                climb_progress: 10,
                is_at_weak_point: true,
            },
        ];
        let results = process_monster_shake_off(&mut monster, &mut rng, 20, 20);
        // Only mounted and climbing should be thrown
        assert_eq!(results.len(), 2);
        let thrown_ids: Vec<u64> = results.iter().map(|r| r.0).collect();
        assert!(thrown_ids.contains(&10));
        assert!(thrown_ids.contains(&11));
        // All should be marked thrown
        for r in &results {
            assert!(r.1); // thrown = true
        }
        // AtWeakPoint player 12 should NOT be thrown
        assert!(!thrown_ids.contains(&12));
    }

    // --- assess_threats ---

    #[test]
    fn test_assess_threats_categorizes_correctly() {
        let mut monster = test_monster(vec![test_segment(1, 20, false)], 100);
        monster.mount_states = vec![
            MountState {
                participant_id: 1,
                mount_status: MountStatus::AtWeakPoint,
                ..Default::default()
            },
            MountState {
                participant_id: 2,
                mount_status: MountStatus::Climbing,
                ..Default::default()
            },
            MountState {
                participant_id: 3,
                mount_status: MountStatus::Mounted,
                ..Default::default()
            },
        ];
        let participants = vec![
            test_participant(1),
            test_participant(2),
            test_participant(3),
            test_participant(4),
        ];
        let threats = assess_threats(&monster, &participants);
        assert_eq!(threats.at_weak_point, vec![1]);
        assert_eq!(threats.climbing, vec![2]);
        assert_eq!(threats.mounted, vec![3]);
        assert_eq!(threats.ground_targets, vec![4]);
        assert_eq!(threats.total_mounted, 3);
    }

    // --- should_shake_off ---

    #[test]
    fn test_should_shake_off_at_weak_point() {
        let monster = test_monster(vec![], 100);
        let threats = ThreatAssessment {
            at_weak_point: vec![1],
            ..Default::default()
        };
        assert!(should_shake_off(&monster, &threats));
    }

    #[test]
    fn test_should_shake_off_above_threshold() {
        let mut monster = test_monster(vec![], 100);
        monster.shake_off_threshold = 3;
        let threats = ThreatAssessment {
            mounted: vec![1, 2, 3],
            total_mounted: 3,
            ..Default::default()
        };
        assert!(should_shake_off(&monster, &threats));
    }

    #[test]
    fn test_should_shake_off_below_threshold() {
        let mut monster = test_monster(vec![], 100);
        monster.shake_off_threshold = 5;
        let threats = ThreatAssessment {
            mounted: vec![1],
            total_mounted: 1,
            ..Default::default()
        };
        assert!(!should_shake_off(&monster, &threats));
    }

    // --- select_segment_targets ---

    #[test]
    fn test_select_segment_targets_prefers_weak_point_attackers() {
        let mut monster = test_monster(
            vec![test_segment(1, 20, false), test_segment(2, 20, false)],
            100,
        );
        monster.mount_states = vec![
            MountState {
                participant_id: 10,
                mount_status: MountStatus::AtWeakPoint,
                ..Default::default()
            },
        ];
        let participants = vec![test_participant(10), test_participant(20)];
        let threats = assess_threats(&monster, &participants);
        let targets = select_segment_targets(&monster, &threats, &participants);
        assert_eq!(targets.len(), 2);
        for (_, target_id) in &targets {
            assert_eq!(*target_id, 10);
        }
    }

    #[test]
    fn test_select_segment_targets_falls_back_to_ground() {
        let monster = test_monster(
            vec![test_segment(1, 20, false)],
            100,
        );
        let participants = vec![test_participant(10), test_participant(20)];
        let threats = assess_threats(&monster, &participants);
        let targets = select_segment_targets(&monster, &threats, &participants);
        assert_eq!(targets.len(), 1);
        // Should pick a ground target (closest)
        assert!(targets[0].1 == 10 || targets[0].1 == 20);
    }

    // --- schedule_monster_attacks_targeted ---

    #[test]
    fn test_schedule_targeted_attacks() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let config = CombatConfig::default();
        let mut seg = test_segment(1, 20, false);
        seg.attacks_per_round = 2;
        let monster = test_monster(vec![seg], 100);
        let participants = vec![test_participant(10)];
        let attacks =
            schedule_monster_attacks_targeted(&monster, &participants, &mut rng, &config);
        assert_eq!(attacks.len(), 2);
        for (_, seg_idx, target_id) in &attacks {
            assert_eq!(*seg_idx, 0);
            assert_eq!(*target_id, 10);
        }
    }

    #[test]
    fn test_schedule_attacks_empty_targets() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let config = CombatConfig::default();
        let monster = test_monster(vec![test_segment(1, 20, false)], 100);
        let attacks = schedule_monster_attacks(&monster, &[], &config, &mut rng);
        assert!(attacks.is_empty());
    }
}
