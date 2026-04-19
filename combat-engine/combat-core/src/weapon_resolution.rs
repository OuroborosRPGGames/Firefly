use rand::Rng;

use crate::dice;
use crate::types::config::CombatConfig;
use crate::types::participant::Participant;
use crate::types::weapons::{DamageType, NaturalAttack, Weapon};

/// Represents a resolved weapon/attack source for use in combat resolution.
/// Provides a unified interface over both equipped weapons and NPC natural attacks.
#[derive(Debug, Clone)]
pub struct AttackSource {
    pub name: String,
    pub dice_count: u32,
    pub dice_sides: u32,
    pub damage_type: DamageType,
    pub reach: u32,
    pub is_ranged: bool,
    pub range_hexes: Option<u32>,
    /// True when sourced from a natural attack (Ruby weapon_type=unarmed/natural_*).
    /// Natural melee attacks don't receive the back_to_wall threshold bonus —
    /// only equipped melee weapons do (Ruby combat_resolution_service.rb:2836).
    pub is_natural: bool,
}

impl From<&Weapon> for AttackSource {
    fn from(w: &Weapon) -> Self {
        AttackSource {
            name: w.name.clone(),
            dice_count: w.dice_count,
            dice_sides: w.dice_sides,
            damage_type: w.damage_type,
            reach: w.reach,
            is_ranged: w.is_ranged,
            range_hexes: w.range_hexes,
            // Treat synthetic-unarmed fallback weapons like natural attacks for the
            // purposes of weapon_type discrimination (unarmed/natural_* are not 'melee').
            is_natural: w.is_unarmed,
        }
    }
}

impl From<&NaturalAttack> for AttackSource {
    fn from(na: &NaturalAttack) -> Self {
        AttackSource {
            name: na.name.clone(),
            dice_count: na.dice_count,
            dice_sides: na.dice_sides,
            damage_type: na.damage_type,
            reach: na.reach,
            is_ranged: na.is_ranged,
            range_hexes: na.range_hexes,
            is_natural: true,
        }
    }
}

/// Pick the natural attack that would be scheduled for the given range.
/// Mirrors Ruby archetype.best_attack_for_range(distance): first attack whose
/// reach (melee) or range_hexes (ranged) covers the distance; else first entry.
///
/// Used by pre-roll dice selection so the rolled dice match the scheduled
/// attack's dice_count/dice_sides (Ruby natural_attack_for_pre_roll parity).
pub fn best_natural_attack_for_range(
    attacks: &[NaturalAttack],
    distance: u32,
) -> Option<&NaturalAttack> {
    for na in attacks {
        if na.is_ranged {
            if let Some(range) = na.range_hexes {
                if distance <= range {
                    return Some(na);
                }
            }
        } else if distance <= na.reach {
            return Some(na);
        }
    }
    attacks.first()
}

/// Select the effective weapon based on distance to target.
///
/// NPCs with natural attacks always use those (first matching by range,
/// falling back to the first entry). Players use melee at close range,
/// ranged at distance, with melee as fallback when no ranged weapon exists.
pub fn effective_weapon(participant: &Participant, target_distance: u32) -> Option<AttackSource> {
    // NPC natural attacks take priority when present
    if !participant.natural_attacks.is_empty() {
        // Find best matching natural attack for the current range
        for na in &participant.natural_attacks {
            if na.is_ranged {
                if let Some(range) = na.range_hexes {
                    if target_distance <= range {
                        return Some(na.into());
                    }
                }
            } else if target_distance <= na.reach {
                return Some(na.into());
            }
        }
        // Fallback to first natural attack regardless of range
        return participant.natural_attacks.first().map(|na| na.into());
    }

    // Player weapons: melee when adjacent (distance ≤ 1), ranged at distance.
    // Reach only affects segment compression timing, not max attack range.
    if target_distance <= 1 {
        // Adjacent -- prefer melee weapon
        participant
            .melee_weapon
            .as_ref()
            .map(|w| w.into())
            .or_else(|| participant.ranged_weapon.as_ref().map(|w| w.into()))
    } else {
        // Not adjacent -- prefer ranged weapon, fall back to melee
        // (melee weapon returned here allows the range check in process_attack_event
        // to skip the attack if they haven't closed the gap yet)
        participant
            .ranged_weapon
            .as_ref()
            .map(|w| w.into())
            .or_else(|| participant.melee_weapon.as_ref().map(|w| w.into()))
    }
}

/// Calculate raw damage for a single weapon attack.
///
/// Rolls the weapon's dice pool and applies modifiers:
/// `dice_roll + stat_modifier - wound_penalty + npc_damage_bonus + outgoing_damage_modifier`
///
/// Returns the raw damage value (minimum 0) before the defense pipeline.
/// No explosion -- that happens at the qi level, not base weapon attacks.
pub fn calculate_attack_damage(
    weapon: &AttackSource,
    stat_modifier: i16,
    wound_penalty: i32,
    npc_damage_bonus: i16,
    outgoing_damage_modifier: i16,
    rng: &mut impl Rng,
) -> i32 {
    let roll = dice::roll(weapon.dice_count, weapon.dice_sides, None, 0, rng);
    let mut damage = roll.total;
    damage += stat_modifier as i32;
    damage -= wound_penalty;
    damage += npc_damage_bonus as i32;
    damage += outgoing_damage_modifier as i32;
    damage.max(0)
}

/// Calculate number of attacks per round from weapon speed.
///
/// Default speed 5 = 1 attack. Higher speed grants more attacks.
/// Formula: `1 + (speed - 5) / 3` (minimum 1).
/// Return the number of attacks per round for a weapon.
///
/// The `speed` field on a weapon IS the attacks-per-round count (1-10).
/// Ruby's `fight_participant.rb#attacks_per_round` returns `weapon.pattern.attack_speed`
/// directly (clamped 1-10). The serializer already encodes this value.
pub fn attacks_per_round(speed: u32) -> u32 {
    speed.clamp(1, 10)
}

/// Distribute attack timings across the 100-segment combat timeline.
///
/// Matches Ruby's `FightParticipant#attack_segments`:
///   interval = total / speed
///   base = ((i + 1) * interval).round
/// For speed 5: [20, 40, 60, 80, 100]
///
/// Attacks are spread evenly with randomized jitter. Returns the segment
/// number (1..=total) for each attack.
pub fn attack_segments(
    num_attacks: u32,
    config: &CombatConfig,
    rng: &mut impl Rng,
) -> Vec<u32> {
    if num_attacks == 0 {
        return vec![];
    }
    let total = config.segments.total;
    let interval = total as f64 / num_attacks as f64;

    let mut segs: Vec<u32> = (0..num_attacks)
        .map(|i| {
            let base = ((i + 1) as f64 * interval).round() as u32;
            let variance = (base as f64 * config.segments.attack_randomization as f64).round() as i32;
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

/// Calculate segment range for reach-based compression.
///
/// Mirrors Ruby's `ReachSegmentService#calculate_segment_range`:
/// - Equal reach → full range (1-100)
/// - Non-adjacent: longer reach attacks earlier (1-66)
/// - Adjacent: shorter reach attacks earlier (1-66), longer attacks later (34-100)
///
/// Returns `(start, end)` segment range for the attacker.
pub fn reach_segment_range(
    attacker_reach: u32,
    defender_reach: u32,
    is_adjacent: bool,
    config: &CombatConfig,
) -> (u32, u32) {
    if attacker_reach == defender_reach {
        return (1, config.segments.total);
    }

    let has_advantage = attacker_reach > defender_reach;

    if is_adjacent {
        // Close quarters: shorter weapon attacks first
        if has_advantage {
            // Long weapon at disadvantage when adjacent
            (config.reach.short_weapon_start, config.reach.short_weapon_end)
        } else {
            // Short weapon advantage when adjacent
            (config.reach.long_weapon_start, config.reach.long_weapon_end)
        }
    } else {
        // Non-adjacent: longer weapon attacks first
        if has_advantage {
            (config.reach.long_weapon_start, config.reach.long_weapon_end)
        } else {
            (config.reach.short_weapon_start, config.reach.short_weapon_end)
        }
    }
}

/// Compress attack segments into a restricted range, preserving proportional spacing.
///
/// Mirrors Ruby's `ReachSegmentService#compress_segments`:
///   normalized = (seg - 1) / 99.0
///   compressed = start + (normalized * range_size)
pub fn compress_segments(segments: &[u32], range_start: u32, range_end: u32) -> Vec<u32> {
    if range_start == 1 && range_end == 100 {
        return segments.to_vec();
    }
    if segments.is_empty() {
        return vec![];
    }

    let range_size = range_end - range_start;

    let mut compressed: Vec<u32> = segments
        .iter()
        .map(|&seg| {
            let normalized = (seg as f64 - 1.0) / 99.0;
            let c = range_start as f64 + normalized * range_size as f64;
            (c.round() as u32).clamp(range_start, range_end)
        })
        .collect();
    compressed.sort();
    compressed
}

/// Get effective melee reach for a participant.
/// Uses weapon reach if available, falls back to unarmed reach from config.
pub fn effective_reach(participant: &Participant, config: &CombatConfig) -> u32 {
    // Check melee weapon first
    if let Some(ref w) = participant.melee_weapon {
        if !w.is_ranged {
            return w.reach;
        }
    }
    // Check natural melee attacks
    for na in &participant.natural_attacks {
        if !na.is_ranged {
            return na.reach;
        }
    }
    // Default to unarmed
    config.reach.unarmed_reach
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::weapons::*;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn sword() -> Weapon {
        Weapon {
            id: 1,
            name: "Sword".into(),
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

    fn bow() -> Weapon {
        Weapon {
            id: 2,
            name: "Bow".into(),
            dice_count: 1,
            dice_sides: 10,
            damage_type: DamageType::Physical,
            reach: 1,
            speed: 4,
            is_ranged: true,
            range_hexes: Some(8),
            attack_range_hexes: 1,
            is_unarmed: false,
        }
    }

    #[test]
    fn test_effective_weapon_melee_at_close() {
        let p = Participant {
            melee_weapon: Some(sword()),
            ranged_weapon: Some(bow()),
            ..Default::default()
        };
        let w = effective_weapon(&p, 1).unwrap();
        assert_eq!(w.name, "Sword");
    }

    #[test]
    fn test_effective_weapon_ranged_at_distance() {
        let p = Participant {
            melee_weapon: Some(sword()),
            ranged_weapon: Some(bow()),
            ..Default::default()
        };
        let w = effective_weapon(&p, 5).unwrap();
        assert_eq!(w.name, "Bow");
    }

    #[test]
    fn test_effective_weapon_melee_fallback() {
        let p = Participant {
            melee_weapon: Some(sword()),
            ranged_weapon: None,
            ..Default::default()
        };
        let w = effective_weapon(&p, 5).unwrap();
        assert_eq!(w.name, "Sword"); // fallback to melee when no ranged
    }

    #[test]
    fn test_effective_weapon_no_weapons() {
        let p = Participant {
            melee_weapon: None,
            ranged_weapon: None,
            ..Default::default()
        };
        let w = effective_weapon(&p, 1);
        assert!(w.is_none());
    }

    #[test]
    fn test_natural_attack_priority() {
        let p = Participant {
            natural_attacks: vec![NaturalAttack {
                name: "Bite".into(),
                dice_count: 2,
                dice_sides: 6,
                damage_type: DamageType::Physical,
                reach: 1,
                is_ranged: false,
                range_hexes: None,
            }],
            melee_weapon: Some(sword()),
            ..Default::default()
        };
        let w = effective_weapon(&p, 1).unwrap();
        assert_eq!(w.name, "Bite"); // natural attack takes priority
    }

    #[test]
    fn test_natural_attack_ranged_selection() {
        let p = Participant {
            natural_attacks: vec![
                NaturalAttack {
                    name: "Bite".into(),
                    dice_count: 2,
                    dice_sides: 6,
                    damage_type: DamageType::Physical,
                    reach: 1,
                    is_ranged: false,
                    range_hexes: None,
                },
                NaturalAttack {
                    name: "Fire Breath".into(),
                    dice_count: 3,
                    dice_sides: 8,
                    damage_type: DamageType::Fire,
                    reach: 1,
                    is_ranged: true,
                    range_hexes: Some(6),
                },
            ],
            ..Default::default()
        };
        // At distance 4, Bite can't reach but Fire Breath can
        let w = effective_weapon(&p, 4).unwrap();
        assert_eq!(w.name, "Fire Breath");
    }

    #[test]
    fn test_natural_attack_fallback() {
        let p = Participant {
            natural_attacks: vec![NaturalAttack {
                name: "Bite".into(),
                dice_count: 2,
                dice_sides: 6,
                damage_type: DamageType::Physical,
                reach: 1,
                is_ranged: false,
                range_hexes: None,
            }],
            ..Default::default()
        };
        // At distance 5, Bite can't reach -- fallback to first natural attack
        let w = effective_weapon(&p, 5).unwrap();
        assert_eq!(w.name, "Bite");
    }

    #[test]
    fn test_attack_damage_basic() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let weapon = AttackSource {
            name: "Sword".into(),
            dice_count: 2,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 2,
            is_ranged: false,
            range_hexes: None,
            is_natural: false,
        };
        let damage = calculate_attack_damage(&weapon, 10, 0, 0, 0, &mut rng);
        assert!(damage >= 12 && damage <= 26); // 2-16 + 10
    }

    #[test]
    fn test_attack_damage_wound_penalty() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let weapon = AttackSource {
            name: "Sword".into(),
            dice_count: 2,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 2,
            is_ranged: false,
            range_hexes: None,
            is_natural: false,
        };
        let no_wound = calculate_attack_damage(&weapon, 10, 0, 0, 0, &mut rng);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let with_wound = calculate_attack_damage(&weapon, 10, 3, 0, 0, &mut rng);
        assert_eq!(no_wound - with_wound, 3);
    }

    #[test]
    fn test_attack_damage_all_modifiers() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let weapon = AttackSource {
            name: "Sword".into(),
            dice_count: 2,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 2,
            is_ranged: false,
            range_hexes: None,
            is_natural: false,
        };
        // stat_modifier=5, wound_penalty=2, npc_bonus=3, outgoing_mod=4
        // total modifier = 5 - 2 + 3 + 4 = 10
        let damage = calculate_attack_damage(&weapon, 5, 2, 3, 4, &mut rng);
        let mut rng2 = ChaCha8Rng::seed_from_u64(42);
        let base = calculate_attack_damage(&weapon, 0, 0, 0, 0, &mut rng2);
        assert_eq!(damage - base, 10);
    }

    #[test]
    fn test_attack_damage_floor_zero() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let weapon = AttackSource {
            name: "Weak".into(),
            dice_count: 1,
            dice_sides: 4,
            damage_type: DamageType::Physical,
            reach: 1,
            is_ranged: false,
            range_hexes: None,
            is_natural: false,
        };
        // Massive wound penalty should floor at 0
        let damage = calculate_attack_damage(&weapon, 0, 100, 0, 0, &mut rng);
        assert_eq!(damage, 0);
    }

    #[test]
    fn test_attacks_per_round() {
        // speed IS the attacks-per-round count (clamped 1-10)
        assert_eq!(attacks_per_round(1), 1);
        assert_eq!(attacks_per_round(3), 3);
        assert_eq!(attacks_per_round(5), 5);
        assert_eq!(attacks_per_round(7), 7);
        assert_eq!(attacks_per_round(10), 10);
        // Clamping
        assert_eq!(attacks_per_round(0), 1);
        assert_eq!(attacks_per_round(15), 10);
    }

    #[test]
    fn test_attack_segments_count() {
        let config = CombatConfig::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let segs = attack_segments(3, &config, &mut rng);
        assert_eq!(segs.len(), 3);
        for s in &segs {
            assert!(*s >= 1 && *s <= 100);
        }
    }

    #[test]
    fn test_attack_segments_single() {
        let config = CombatConfig::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let segs = attack_segments(1, &config, &mut rng);
        assert_eq!(segs.len(), 1);
        assert!(segs[0] >= 1 && segs[0] <= 100);
    }

    #[test]
    fn test_attack_segments_empty() {
        let config = CombatConfig::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let segs = attack_segments(0, &config, &mut rng);
        assert!(segs.is_empty());
    }

    #[test]
    fn test_reach_segment_range_equal_reach() {
        let config = CombatConfig::default();
        // Equal reach = no compression
        assert_eq!(reach_segment_range(2, 2, false, &config), (1, 100));
        assert_eq!(reach_segment_range(2, 2, true, &config), (1, 100));
    }

    #[test]
    fn test_reach_segment_range_non_adjacent() {
        let config = CombatConfig::default();
        // Non-adjacent: longer reach attacks first (1-66)
        assert_eq!(reach_segment_range(4, 2, false, &config), (1, 66));
        // Non-adjacent: shorter reach attacks later (34-100)
        assert_eq!(reach_segment_range(2, 4, false, &config), (34, 100));
    }

    #[test]
    fn test_reach_segment_range_adjacent() {
        let config = CombatConfig::default();
        // Adjacent: shorter reach attacks first (1-66)
        assert_eq!(reach_segment_range(2, 4, true, &config), (1, 66));
        // Adjacent: longer reach attacks later (34-100)
        assert_eq!(reach_segment_range(4, 2, true, &config), (34, 100));
    }

    #[test]
    fn test_compress_segments_no_compression() {
        let segs = vec![20, 40, 60, 80, 100];
        assert_eq!(compress_segments(&segs, 1, 100), segs);
    }

    #[test]
    fn test_compress_segments_to_early_range() {
        // Compress [20, 40, 60, 80, 100] into 1-66 (range_size=65)
        let segs = vec![20, 40, 60, 80, 100];
        let compressed = compress_segments(&segs, 1, 66);
        // 20: (19/99)*65+1=13.47→13, 40: 26.60→27, 60: 39.73→40, 80: 52.87→53, 100: 66
        assert_eq!(compressed, vec![13, 27, 40, 53, 66]);
    }

    #[test]
    fn test_compress_segments_to_late_range() {
        // Compress [20, 40, 60, 80, 100] into 34-100 (range_size=66)
        let segs = vec![20, 40, 60, 80, 100];
        let compressed = compress_segments(&segs, 34, 100);
        // 20: (19/99)*66+34=46.67→47, 40: 60.0→60, 60: 73.33→73, 80: 86.67→87, 100: 100
        assert_eq!(compressed, vec![47, 60, 73, 87, 100]);
    }

    #[test]
    fn test_compress_segments_empty() {
        assert_eq!(compress_segments(&[], 1, 66), Vec::<u32>::new());
    }

    #[test]
    fn test_attack_source_from_weapon() {
        let w = sword();
        let src = AttackSource::from(&w);
        assert_eq!(src.name, "Sword");
        assert_eq!(src.dice_count, 2);
        assert_eq!(src.dice_sides, 8);
        assert_eq!(src.damage_type, DamageType::Physical);
        assert_eq!(src.reach, 2);
        assert!(!src.is_ranged);
        assert!(src.range_hexes.is_none());
    }

    #[test]
    fn test_attack_source_from_natural_attack() {
        let na = NaturalAttack {
            name: "Claw".into(),
            dice_count: 1,
            dice_sides: 6,
            damage_type: DamageType::Physical,
            reach: 1,
            is_ranged: false,
            range_hexes: None,
        };
        let src = AttackSource::from(&na);
        assert_eq!(src.name, "Claw");
        assert_eq!(src.dice_count, 1);
        assert_eq!(src.dice_sides, 6);
    }
}
