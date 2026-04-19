use rand::Rng;

use crate::types::abilities::{Ability, AoEShape, TargetType};
use crate::types::hex::{HexCoord, HexMap};
use crate::types::participant::Participant;

/// Target of an ability with damage multiplier (for chains).
#[derive(Debug, Clone)]
pub struct AbilityTarget {
    pub participant_id: u64,
    pub is_primary: bool,
    pub damage_multiplier: f32, // 1.0 for primary, decays for chain bounces
}

/// Check whether `target` is a valid primary target for `ability` cast by `caster`.
/// Mirrors Ruby ability_processor_service.rb:291 valid_target_for_ability?.
pub fn valid_primary_target(
    ability: &Ability,
    caster: &Participant,
    target: &Participant,
) -> bool {
    if target.is_knocked_out {
        return false;
    }
    // Range check (Ruby enforces via schedule_abilities; Rust enforces here).
    if ability.range_hexes > 0 {
        let dist = crate::hex_grid::hex_distance(
            caster.position.x, caster.position.y,
            target.position.x, target.position.y,
        ) as u32;
        if dist > ability.range_hexes {
            return false;
        }
    }
    match ability.target_type {
        TargetType::Self_ => target.id == caster.id,
        TargetType::Ally => target.id == caster.id || target.side == caster.side,
        TargetType::Enemy | TargetType::Single => {
            target.id != caster.id && target.side != caster.side
        }
        // AoE shapes use the target_id to locate the center; validity is checked
        // per-tile within resolve_aoe.
        _ => true,
    }
}

/// Resolve targets for an ability based on its target type and AoE shape.
pub fn resolve_targets(
    ability: &Ability,
    caster: &Participant,
    target_id: Option<u64>,
    participants: &[Participant],
    map: &HexMap,
) -> Vec<AbilityTarget> {
    // Validate the caster's chosen primary target against Ruby's rules before
    // anything else. An invalid target (wrong side, out of range, dead) yields
    // an empty target list, matching Ruby's behavior.
    if let Some(tid) = target_id {
        if !matches!(ability.target_type, TargetType::Self_) {
            let ok = participants.iter()
                .find(|p| p.id == tid)
                .map(|t| valid_primary_target(ability, caster, t))
                .unwrap_or(false);
            if !ok {
                return vec![];
            }
        }
    }

    match ability.target_type {
        TargetType::Single | TargetType::Enemy => {
            // Enemy is like Single but with explicit side filtering (done in resolve_single)
            resolve_single(ability, caster, target_id, participants)
        }
        TargetType::Self_ => vec![AbilityTarget {
            participant_id: caster.id,
            is_primary: true,
            damage_multiplier: 1.0,
        }],
        TargetType::Ally => resolve_ally(caster, target_id, participants),
        TargetType::Circle | TargetType::Cone | TargetType::Line => {
            resolve_aoe(ability, caster, target_id, participants, map)
        }
    }
}

fn resolve_single(
    ability: &Ability,
    caster: &Participant,
    target_id: Option<u64>,
    participants: &[Participant],
) -> Vec<AbilityTarget> {
    let tid = match target_id {
        Some(id) => id,
        None => return vec![],
    };
    let mut targets = vec![AbilityTarget {
        participant_id: tid,
        is_primary: true,
        damage_multiplier: 1.0,
    }];

    // Handle chain abilities
    if ability.has_chain && ability.chain_max_targets > 1 {
        let mut hit_ids = vec![caster.id, tid];
        let mut current_pos = participants
            .iter()
            .find(|p| p.id == tid)
            .map(|p| p.position);
        let mut multiplier = ability.chain_damage_falloff;

        for _ in 1..ability.chain_max_targets {
            if let Some(pos) = current_pos {
                // Find nearest valid target not yet hit.
                // chain_friendly_fire=false: skip same-side participants.
                let next = participants
                    .iter()
                    .filter(|p| !hit_ids.contains(&p.id) && p.is_active())
                    .filter(|p| ability.chain_friendly_fire || p.side != caster.side)
                    .filter(|p| {
                        crate::hex_grid::hex_distance(pos.x, pos.y, p.position.x, p.position.y)
                            as u32
                            <= ability.chain_range
                    })
                    .min_by_key(|p| {
                        crate::hex_grid::hex_distance(pos.x, pos.y, p.position.x, p.position.y)
                    });

                if let Some(next_target) = next {
                    hit_ids.push(next_target.id);
                    targets.push(AbilityTarget {
                        participant_id: next_target.id,
                        is_primary: false,
                        damage_multiplier: multiplier,
                    });
                    current_pos = Some(next_target.position);
                    multiplier *= ability.chain_damage_falloff;
                } else {
                    break;
                }
            }
        }
    }
    targets
}

fn resolve_ally(
    caster: &Participant,
    target_id: Option<u64>,
    participants: &[Participant],
) -> Vec<AbilityTarget> {
    let tid = match target_id {
        Some(id) => id,
        None => {
            return vec![AbilityTarget {
                participant_id: caster.id,
                is_primary: true,
                damage_multiplier: 1.0,
            }]
        }
    };
    // Verify target is on same side
    if let Some(target) = participants.iter().find(|p| p.id == tid) {
        if target.side == caster.side {
            return vec![AbilityTarget {
                participant_id: tid,
                is_primary: true,
                damage_multiplier: 1.0,
            }];
        }
    }
    vec![]
}

fn resolve_aoe(
    ability: &Ability,
    caster: &Participant,
    target_id: Option<u64>,
    participants: &[Participant],
    _map: &HexMap,
) -> Vec<AbilityTarget> {
    let center = match target_id {
        Some(id) => participants.iter().find(|p| p.id == id).map(|p| p.position),
        None => Some(caster.position),
    };
    let center = match center {
        Some(c) => c,
        None => return vec![],
    };

    match ability.aoe_shape {
        Some(AoEShape::Circle) => {
            resolve_circle(ability, caster, center, target_id, participants)
        }
        Some(AoEShape::Cone) => resolve_cone(ability, caster, center, participants),
        Some(AoEShape::Line) => resolve_line(ability, caster, center, participants),
        None => resolve_circle(ability, caster, center, target_id, participants), // default
    }
}

fn resolve_circle(
    ability: &Ability,
    caster: &Participant,
    center: HexCoord,
    target_id: Option<u64>,
    participants: &[Participant],
) -> Vec<AbilityTarget> {
    let radius = ability.aoe_radius.unwrap_or(1);
    participants
        .iter()
        .filter(|p| p.is_active())
        .filter(|p| {
            if ability.target_type == TargetType::Self_ {
                return true;
            }
            if p.id == caster.id {
                return false;
            } // exclude caster unless self-target
            // aoe_hits_allies=false → exclude same-side (matches Ruby
            // ability_processor_service.rb:292 valid_target_for_ability?).
            if !ability.aoe_hits_allies && p.side == caster.side {
                return false;
            }
            true
        })
        .filter(|p| {
            crate::hex_grid::hex_distance(center.x, center.y, p.position.x, p.position.y) as u32
                <= radius
        })
        .map(|p| AbilityTarget {
            participant_id: p.id,
            is_primary: target_id == Some(p.id),
            damage_multiplier: 1.0,
        })
        .collect()
}

fn resolve_cone(
    ability: &Ability,
    caster: &Participant,
    target_pos: HexCoord,
    participants: &[Participant],
) -> Vec<AbilityTarget> {
    let length = ability.aoe_length.unwrap_or(3);
    let half_angle = (ability.aoe_angle.unwrap_or(60) as f64 / 2.0).to_radians();

    let dx = (target_pos.x - caster.position.x) as f64;
    let dy = (target_pos.y - caster.position.y) as f64;
    let cone_dir = dy.atan2(dx);

    participants
        .iter()
        .filter(|p| p.is_active() && p.id != caster.id)
        .filter(|p| ability.aoe_hits_allies || p.side != caster.side)
        .filter(|p| {
            let dist = crate::hex_grid::hex_distance(
                caster.position.x,
                caster.position.y,
                p.position.x,
                p.position.y,
            ) as u32;
            if dist == 0 || dist > length {
                return false;
            }

            let pdx = (p.position.x - caster.position.x) as f64;
            let pdy = (p.position.y - caster.position.y) as f64;
            let p_dir = pdy.atan2(pdx);
            let mut angle_diff = (p_dir - cone_dir).abs();
            if angle_diff > std::f64::consts::PI {
                angle_diff = 2.0 * std::f64::consts::PI - angle_diff;
            }
            angle_diff <= half_angle
        })
        .map(|p| AbilityTarget {
            participant_id: p.id,
            is_primary: false,
            damage_multiplier: 1.0,
        })
        .collect()
}

fn resolve_line(
    ability: &Ability,
    caster: &Participant,
    target_pos: HexCoord,
    participants: &[Participant],
) -> Vec<AbilityTarget> {
    let length = ability.aoe_length.unwrap_or(5);
    let dx = (target_pos.x - caster.position.x) as f64;
    let dy = (target_pos.y - caster.position.y) as f64;
    let mag = (dx * dx + dy * dy).sqrt();
    if mag == 0.0 {
        return vec![];
    }
    let ndx = dx / mag;
    let ndy = dy / mag;

    participants
        .iter()
        .filter(|p| p.is_active() && p.id != caster.id)
        .filter(|p| ability.aoe_hits_allies || p.side != caster.side)
        .filter(|p| {
            let px = (p.position.x - caster.position.x) as f64;
            let py = (p.position.y - caster.position.y) as f64;
            let proj = px * ndx + py * ndy;
            if proj <= 0.0 || proj > length as f64 {
                return false;
            }
            let perp = (px * ndy - py * ndx).abs();
            perp <= 1.5 // ~0.5 hex width tolerance
        })
        .map(|p| AbilityTarget {
            participant_id: p.id,
            is_primary: false,
            damage_multiplier: 1.0,
        })
        .collect()
}

/// Calculate ability damage.
pub fn calculate_ability_damage(
    ability: &Ability,
    stat_modifier: i16,
    qi_roll_total: i32,
    target_damage_multiplier: f32, // from chain falloff
    rng: &mut impl Rng,
) -> i32 {
    let mut damage = 0i32;

    // Base damage dice (parse notation like "2d8")
    if let Some(ref notation) = ability.base_damage_dice {
        if let Some((count, sides)) = parse_dice_notation(notation) {
            let roll = crate::dice::roll(count, sides, None, 0, rng);
            damage += roll.total;
        }
    }

    // Damage modifier (flat)
    damage += ability.damage_modifier;

    // Stat scaling
    damage += stat_modifier as i32;

    // Qi roll bonus
    damage += qi_roll_total;

    // Damage multiplier (percentage from ability)
    damage = (damage as f32 * ability.damage_multiplier) as i32;

    // Chain falloff
    damage = (damage as f32 * target_damage_multiplier) as i32;

    damage.max(0)
}

/// Calculate ability damage using a pre-rolled base value (no mid-round RNG).
/// Matches Ruby ability_processor_service.rb:720-738: stat pick via ability.damage_stat
/// and ability_roll_penalty subtracted from the total.
pub fn calculate_ability_damage_from_preroll(
    ability: &Ability,
    ability_base_roll: i32,
    stat_modifier: i16,
    qi_roll_total: i32,
    target_damage_multiplier: f32,
    ability_roll_penalty: i16,
) -> i32 {
    let mut damage = ability_base_roll;

    // Damage modifier (flat)
    damage += ability.damage_modifier;

    // Stat scaling (caller already picked the right stat per ability.damage_stat)
    damage += stat_modifier as i32;

    // Qi roll bonus
    damage += qi_roll_total;

    // Ability roll penalty (Ruby: actor.ability_roll_penalty, subtracted from total)
    damage += ability_roll_penalty as i32;

    // Damage multiplier (percentage from ability)
    damage = (damage as f32 * ability.damage_multiplier) as i32;

    // Chain falloff
    damage = (damage as f32 * target_damage_multiplier) as i32;

    damage.max(0)
}

/// Parse dice notation "NdS" into (count, sides).
pub fn parse_dice_notation(notation: &str) -> Option<(u32, u32)> {
    let parts: Vec<&str> = notation.split('d').collect();
    if parts.len() != 2 {
        return None;
    }
    let count = parts[0].parse::<u32>().ok()?;
    let sides = parts[1].parse::<u32>().ok()?;
    Some((count, sides))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::abilities::*;
    use crate::types::hex::*;
    use crate::types::participant::Participant;
    use crate::types::weapons::DamageType;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn make_ability() -> Ability {
        Ability {
            id: 1,
            name: "Fireball".into(),
            base_damage_dice: Some("2d8".into()),
            damage_modifier: 5,
            damage_multiplier: 1.0,
            damage_type: DamageType::Fire,
            target_type: TargetType::Single,
            range_hexes: 5,
            cooldown_rounds: 2,
            qi_cost: 1,
            ..Default::default()
        }
    }

    fn participant_at(id: u64, side: u8, x: i32, y: i32) -> Participant {
        Participant {
            id,
            side,
            position: HexCoord { x, y, z: 0 },
            ..Default::default()
        }
    }

    #[test]
    fn test_resolve_single_target() {
        let ability = make_ability();
        let caster = participant_at(1, 0, 0, 0);
        let target = participant_at(2, 1, 2, 4);
        let participants = vec![caster.clone(), target];
        let targets = resolve_targets(&ability, &caster, Some(2), &participants, &HexMap::default());
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].participant_id, 2);
        assert!(targets[0].is_primary);
    }

    #[test]
    fn test_resolve_self_target() {
        let mut ability = make_ability();
        ability.target_type = TargetType::Self_;
        let caster = participant_at(1, 0, 0, 0);
        let targets =
            resolve_targets(&ability, &caster, None, &[caster.clone()], &HexMap::default());
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].participant_id, 1);
    }

    #[test]
    fn test_resolve_circle_aoe() {
        let mut ability = make_ability();
        ability.target_type = TargetType::Circle;
        ability.aoe_shape = Some(AoEShape::Circle);
        ability.aoe_radius = Some(2);
        let caster = participant_at(1, 0, 0, 0);
        let t1 = participant_at(2, 1, 1, 2); // distance 1, in radius
        let t2 = participant_at(3, 1, 2, 4); // distance 2, in radius
        let t3 = participant_at(4, 1, 4, 8); // distance 4, out of radius
        let participants = vec![caster.clone(), t1, t2, t3];
        let targets = resolve_targets(&ability, &caster, Some(2), &participants, &HexMap::default());
        let ids: Vec<u64> = targets.iter().map(|t| t.participant_id).collect();
        assert!(ids.contains(&2));
        assert!(ids.contains(&3));
        assert!(!ids.contains(&4)); // too far
        assert!(!ids.contains(&1)); // caster excluded
    }

    #[test]
    fn test_chain_ability() {
        let mut ability = make_ability();
        ability.has_chain = true;
        ability.chain_max_targets = 3;
        ability.chain_range = 3;
        ability.chain_damage_falloff = 0.5;
        let caster = participant_at(1, 0, 0, 0);
        let t1 = participant_at(2, 1, 1, 2);
        let t2 = participant_at(3, 1, 2, 4);
        let t3 = participant_at(4, 1, 3, 6);
        let participants = vec![caster.clone(), t1, t2, t3];
        let targets = resolve_targets(&ability, &caster, Some(2), &participants, &HexMap::default());
        assert_eq!(targets.len(), 3);
        assert_eq!(targets[0].damage_multiplier, 1.0); // primary
        assert_eq!(targets[1].damage_multiplier, 0.5); // first bounce
        assert_eq!(targets[2].damage_multiplier, 0.25); // second bounce
    }

    #[test]
    fn test_calculate_damage() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let ability = make_ability();
        let damage = calculate_ability_damage(&ability, 10, 5, 1.0, &mut rng);
        // 2d8(2-16) + 5(mod) + 10(stat) + 5(qi) = 22-36
        assert!(damage >= 22 && damage <= 36);
    }

    #[test]
    fn test_parse_dice_notation() {
        assert_eq!(parse_dice_notation("2d8"), Some((2, 8)));
        assert_eq!(parse_dice_notation("1d6"), Some((1, 6)));
        assert_eq!(parse_dice_notation("10d10"), Some((10, 10)));
        assert_eq!(parse_dice_notation("invalid"), None);
    }

    #[test]
    fn test_ally_target_same_side() {
        let mut ability = make_ability();
        ability.target_type = TargetType::Ally;
        let caster = participant_at(1, 0, 0, 0);
        let ally = participant_at(2, 0, 1, 2); // same side
        let enemy = participant_at(3, 1, 2, 4); // different side
        let participants = vec![caster.clone(), ally, enemy];
        let targets = resolve_targets(&ability, &caster, Some(2), &participants, &HexMap::default());
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].participant_id, 2);
        // Try targeting enemy
        let targets = resolve_targets(&ability, &caster, Some(3), &participants, &HexMap::default());
        assert_eq!(targets.len(), 0); // can't target enemy with ally ability
    }
}
