use crate::battle_map;
use crate::hex_grid;
use crate::status_effects;
use crate::types::abilities::{Ability, AoEShape, ForcedMovementDirection};
use crate::types::fight_state::FightState;
use crate::types::hex::HexCoord;
use crate::types::participant::Participant;

/// Score for a particular ability + target combination.
#[derive(Debug, Clone)]
pub struct AbilityScore {
    pub ability_id: u64,
    pub target_id: Option<u64>,
    pub base_power: f32,
    pub aoe_multiplier: f32,
    pub execute_bonus: f32,
    pub combo_bonus: f32,
    pub vulnerability_bonus: f32,
    pub hazard_knockback_bonus: f32,
    pub total_score: f32,
}

/// Rank all usable abilities for a participant, returning scored options
/// sorted by total_score descending.
pub fn rank_abilities(
    participant: &Participant,
    enemies: &[&Participant],
    allies: &[&Participant],
    state: &FightState,
) -> Vec<AbilityScore> {
    // Global cooldown blocks all abilities (Ruby fight_participant.rb:1052).
    if participant.global_cooldown > 0 {
        return Vec::new();
    }
    let usable: Vec<&Ability> = participant
        .abilities
        .iter()
        .filter(|a| {
            let cd = participant.cooldowns.get(&a.id).copied().unwrap_or(0);
            cd <= 0 && a.qi_cost <= participant.available_qi_dice()
        })
        .collect();

    if usable.is_empty() {
        return Vec::new();
    }

    let mut scores: Vec<AbilityScore> = Vec::new();

    for ability in &usable {
        let bp = base_power(ability);

        // Determine valid targets based on target_type
        let targets: Vec<Option<&Participant>> = match ability.target_type {
            crate::types::abilities::TargetType::Self_ => {
                vec![Some(participant)]
            }
            crate::types::abilities::TargetType::Ally => {
                // Ruby valid_targets_for_ability returns `allies + [participant]`
                // (combat_ai_service.rb:461). Self is a valid ally target.
                let mut v: Vec<Option<&Participant>> =
                    allies.iter().map(|a| Some(*a)).collect();
                v.push(Some(participant));
                v
            }
            _ => {
                // Enemy-targeting abilities
                if enemies.is_empty() {
                    vec![None]
                } else {
                    enemies.iter().map(|e| Some(*e)).collect()
                }
            }
        };

        for target_opt in &targets {
            let target_id = target_opt.map(|t| t.id);
            // Ruby AbilityEffectivePowerCalculator (ability_effective_power_calculator.rb:35-52)
            // computes effective_power = base × (aoe × hazard × execute × combo × vuln).
            // All are multiplicative multipliers, starting at 1.0. Values default to 1.0 when
            // the bonus doesn't apply, so their product equals base_power in the null case.
            let aoe_mult = match *target_opt {
                Some(target) => {
                    aoe_cluster_multiplier(ability, target, enemies, &participant.position)
                }
                None => 1.0,
            };
            let exec_bonus = match *target_opt {
                Some(target) => execute_bonus_multiplier(ability, target),
                None => 1.0,
            };
            let cmb_bonus = match *target_opt {
                Some(target) => combo_bonus_multiplier(ability, target),
                None => 1.0,
            };
            let vuln_bonus = match *target_opt {
                Some(target) => vulnerability_bonus_multiplier(ability, target),
                None => 1.0,
            };
            let hazard_bonus = match *target_opt {
                Some(target) => hazard_knockback_multiplier(ability, target, state),
                None => 1.0,
            };

            let total = bp * aoe_mult * exec_bonus * cmb_bonus * vuln_bonus * hazard_bonus;

            scores.push(AbilityScore {
                ability_id: ability.id,
                target_id,
                base_power: bp,
                aoe_multiplier: aoe_mult,
                execute_bonus: exec_bonus,
                combo_bonus: cmb_bonus,
                vulnerability_bonus: vuln_bonus,
                hazard_knockback_bonus: hazard_bonus,
                total_score: total,
            });
        }
    }

    // Sort descending by total_score
    scores.sort_by(|a, b| b.total_score.partial_cmp(&a.total_score).unwrap_or(std::cmp::Ordering::Equal));
    scores
}

/// Parse `base_damage_dice` string (NdM format) and compute average damage:
/// `N * (M + 1) / 2.0 + damage_modifier`. Multiply by `damage_multiplier`.
fn base_power(ability: &Ability) -> f32 {
    let avg_dice = match &ability.base_damage_dice {
        Some(dice_str) => parse_dice_average(dice_str),
        None => 0.0,
    };
    (avg_dice + ability.damage_modifier as f32) * ability.damage_multiplier
}

/// Parse "NdM" dice notation and return the average value.
fn parse_dice_average(dice_str: &str) -> f32 {
    let lower = dice_str.to_lowercase();
    let parts: Vec<&str> = lower.split('d').collect();
    if parts.len() != 2 {
        return 0.0;
    }
    let n: f32 = match parts[0].parse() {
        Ok(v) => v,
        Err(_) => return 0.0,
    };
    let m: f32 = match parts[1].parse() {
        Ok(v) => v,
        Err(_) => return 0.0,
    };
    n * (m + 1.0) / 2.0
}

/// If ability has AoE Circle with aoe_radius > 0: count enemies within
/// aoe_radius of target position. Multiplier = max(1.0, enemy_count * 0.7).
/// For Cone/Line, do simplified check.
fn aoe_cluster_multiplier(
    ability: &Ability,
    target: &Participant,
    enemies: &[&Participant],
    _caster_pos: &HexCoord,
) -> f32 {
    let shape = match ability.aoe_shape {
        Some(s) => s,
        None => return 1.0,
    };
    let radius = ability.aoe_radius.unwrap_or(0);
    if radius == 0 && shape == AoEShape::Circle {
        return 1.0;
    }

    match shape {
        AoEShape::Circle => {
            let count = enemies
                .iter()
                .filter(|e| {
                    let dist = hex_grid::hex_distance(
                        target.position.x,
                        target.position.y,
                        e.position.x,
                        e.position.y,
                    );
                    dist <= radius as i32
                })
                .count();
            (count as f32 * 0.7).max(1.0)
        }
        AoEShape::Cone | AoEShape::Line => {
            // Simplified: estimate 1.5 targets for cone/line if enemies are clustered
            let length = ability
                .aoe_length
                .unwrap_or(ability.aoe_radius.unwrap_or(3));
            let nearby = enemies
                .iter()
                .filter(|e| {
                    let dist = hex_grid::hex_distance(
                        target.position.x,
                        target.position.y,
                        e.position.x,
                        e.position.y,
                    );
                    dist <= length as i32
                })
                .count();
            if nearby > 1 {
                (nearby as f32 * 0.5).max(1.0)
            } else {
                1.0
            }
        }
    }
}

/// If ability has execute_threshold and target HP% <= threshold:
/// return 2.0 if instant_kill, 1.0 + damage_multiplier otherwise.
/// Multiplicative execute bonus. Returns 1.0 (no bonus) when the ability doesn't
/// execute or the target's HP is above the threshold. Matches Ruby
/// ability_effective_power_calculator.rb:158-182 semantics: returns a multiplier
/// that gets folded into the product, not an additive bonus.
fn execute_bonus_multiplier(ability: &Ability, target: &Participant) -> f32 {
    let threshold = match ability.execute_threshold {
        Some(t) => t,
        None => return 1.0,
    };

    let hp_pct = target.hp_percent();
    if hp_pct > threshold {
        return 1.0;
    }

    match &ability.execute_effect {
        Some(effect) => {
            if effect.instant_kill {
                3.0
            } else {
                // Ruby: 1.0 + (damage_multiplier - 1.0). Use the raw multiplier.
                1.0 + (effect.damage_multiplier.unwrap_or(1.0) - 1.0).max(0.0)
            }
        }
        None => 1.5,
    }
}

/// If ability has combo_condition and target has the required status:
/// return 1.5.
/// Multiplicative combo bonus. 1.5x if target has the required status, 1.0 otherwise.
fn combo_bonus_multiplier(ability: &Ability, target: &Participant) -> f32 {
    match &ability.combo_condition {
        Some(condition) => {
            if status_effects::has_effect(&target.status_effects, &condition.requires_status) {
                1.5
            } else {
                1.0
            }
        }
        None => 1.0,
    }
}

/// Multiplicative vulnerability bonus: returns the target's vuln multiplier
/// against the ability's damage type, or 1.0 when not vulnerable.
fn vulnerability_bonus_multiplier(ability: &Ability, target: &Participant) -> f32 {
    let mult = status_effects::damage_type_multiplier(&target.status_effects, &ability.damage_type);
    if mult > 1.0 { mult } else { 1.0 }
}

/// Multiplicative hazard-knockback bonus. If forced movement lands target in a
/// hazard, returns `1.0 + hazard_damage * 0.1` (bounded); else 1.0.
fn hazard_knockback_multiplier(ability: &Ability, target: &Participant, state: &FightState) -> f32 {
    let forced = match &ability.forced_movement {
        Some(fm) => fm,
        None => return 1.0,
    };

    let dest = calculate_forced_movement_destination(target, forced, state);

    match battle_map::hazard_at(&state.hex_map, &dest) {
        Some((_hazard_type, hazard_damage)) => {
            (1.0 + hazard_damage as f32 * 0.1).min(3.0)
        }
        None => 1.0,
    }
}

/// Calculate where a target would end up after forced movement.
fn calculate_forced_movement_destination(
    target: &Participant,
    forced: &crate::types::abilities::ForcedMovement,
    _state: &FightState,
) -> HexCoord {
    let direction = match forced.direction {
        ForcedMovementDirection::Away => {
            // Away from caster: approximate as moving in the target's current facing
            // For simplicity, push south (default direction)
            crate::types::hex::Direction::S
        }
        ForcedMovementDirection::Toward => crate::types::hex::Direction::N,
        ForcedMovementDirection::Compass(dir) => dir,
    };

    let mut pos = target.position;
    for _ in 0..forced.distance {
        let (nx, ny) = hex_grid::hex_neighbor_by_direction(pos.x, pos.y, direction);
        pos = HexCoord {
            x: nx,
            y: ny,
            z: pos.z,
        };
    }
    pos
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::abilities::{AoEShape, ComboCondition, ExecuteEffect, ForcedMovement};
    use crate::types::hex::{HazardType, HexCell, HexCoord};
    use crate::types::status_effects::{ActiveEffect, EffectType, StackBehavior};
    use crate::types::weapons::DamageType;

    fn make_participant(id: u64, side: u8, hp: u8, max_hp: u8) -> Participant {
        Participant {
            id,
            side,
            current_hp: hp,
            max_hp,
            ..Default::default()
        }
    }

    fn make_ability(id: u64, dice: &str, modifier: i32, multiplier: f32) -> Ability {
        Ability {
            id,
            name: format!("ability_{}", id),
            base_damage_dice: Some(dice.to_string()),
            damage_modifier: modifier,
            damage_multiplier: multiplier,
            ..Default::default()
        }
    }

    #[test]
    fn test_parse_dice_average() {
        // 2d8 -> 2 * (8+1) / 2.0 = 9.0
        assert!((parse_dice_average("2d8") - 9.0).abs() < f32::EPSILON);
        // 1d6 -> 1 * (6+1) / 2.0 = 3.5
        assert!((parse_dice_average("1d6") - 3.5).abs() < f32::EPSILON);
        // 3d10 -> 3 * (10+1) / 2.0 = 16.5
        assert!((parse_dice_average("3d10") - 16.5).abs() < f32::EPSILON);
        // Invalid
        assert!((parse_dice_average("invalid")).abs() < f32::EPSILON);
    }

    #[test]
    fn test_base_power_calculation() {
        let ability = make_ability(1, "2d8", 3, 1.5);
        // (9.0 + 3) * 1.5 = 18.0
        let power = base_power(&ability);
        assert!((power - 18.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_base_power_no_dice() {
        let ability = Ability {
            id: 1,
            damage_modifier: 5,
            damage_multiplier: 2.0,
            ..Default::default()
        };
        // (0.0 + 5) * 2.0 = 10.0
        let power = base_power(&ability);
        assert!((power - 10.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_aoe_cluster_multiplier_no_aoe() {
        let ability = make_ability(1, "2d8", 0, 1.0);
        let target = make_participant(2, 1, 6, 6);
        let enemies: Vec<&Participant> = vec![&target];
        let caster_pos = HexCoord::default();
        let mult = aoe_cluster_multiplier(&ability, &target, &enemies, &caster_pos);
        assert!((mult - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_aoe_cluster_multiplier_circle() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.aoe_shape = Some(AoEShape::Circle);
        ability.aoe_radius = Some(2);

        let mut target = make_participant(2, 1, 6, 6);
        target.position = HexCoord { x: 0, y: 0, z: 0 };

        let mut e2 = make_participant(3, 1, 6, 6);
        e2.position = HexCoord { x: 1, y: 2, z: 0 }; // dist 1 from target

        let mut e3 = make_participant(4, 1, 6, 6);
        e3.position = HexCoord { x: 0, y: 4, z: 0 }; // dist 1 from target

        let enemies: Vec<&Participant> = vec![&target, &e2, &e3];
        let caster_pos = HexCoord {
            x: 0,
            y: -8,
            z: 0,
        };
        let mult = aoe_cluster_multiplier(&ability, &target, &enemies, &caster_pos);
        // 3 enemies within radius 2 -> 3 * 0.7 = 2.1
        assert!((mult - 2.1).abs() < 0.01);
    }

    #[test]
    fn test_execute_bonus_below_threshold() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.execute_threshold = Some(0.25);
        ability.execute_effect = Some(ExecuteEffect {
            instant_kill: true,
            damage_multiplier: None,
        });

        let target = make_participant(2, 1, 1, 6); // ~16.7% HP
        let bonus = execute_bonus_multiplier(&ability, &target);
        // Instant-kill execute below threshold: 3.0x multiplier
        assert!((bonus - 3.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_execute_bonus_above_threshold() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.execute_threshold = Some(0.25);

        let target = make_participant(2, 1, 4, 6); // ~66.7% HP
        let bonus = execute_bonus_multiplier(&ability, &target);
        // Above threshold: multiplier is 1.0 (no bonus).
        assert!((bonus - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_execute_bonus_non_instant() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.execute_threshold = Some(0.25);
        ability.execute_effect = Some(ExecuteEffect {
            instant_kill: false,
            damage_multiplier: Some(2.0),
        });

        let target = make_participant(2, 1, 1, 6); // ~16.7% HP
        let bonus = execute_bonus_multiplier(&ability, &target);
        // 1.0 + (2.0 - 1.0) = 2.0
        assert!((bonus - 2.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_combo_bonus_has_status() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.combo_condition = Some(ComboCondition {
            requires_status: "burning".to_string(),
            bonus_dice: None,
            consumes_status: false,
        });

        let mut target = make_participant(2, 1, 6, 6);
        target.status_effects.push(ActiveEffect {
            effect_name: "burning".to_string(),
            effect_type: EffectType::DamageOverTime,
            remaining_rounds: 3,
            stack_count: 1,
            max_stacks: 1,
            stack_behavior: StackBehavior::Refresh,
            ..Default::default()
        });

        let bonus = combo_bonus_multiplier(&ability, &target);
        assert!((bonus - 1.5).abs() < f32::EPSILON);
    }

    #[test]
    fn test_combo_bonus_no_status() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.combo_condition = Some(ComboCondition {
            requires_status: "burning".to_string(),
            bonus_dice: None,
            consumes_status: false,
        });

        let target = make_participant(2, 1, 6, 6);
        let bonus = combo_bonus_multiplier(&ability, &target);
        // No status: multiplier is 1.0 (no bonus).
        assert!((bonus - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_vulnerability_bonus_vulnerable() {
        let ability = Ability {
            id: 1,
            damage_type: DamageType::Fire,
            ..Default::default()
        };

        let mut target = make_participant(2, 1, 6, 6);
        target.status_effects.push(ActiveEffect {
            effect_name: "fire_vuln".to_string(),
            effect_type: EffectType::Vulnerability,
            remaining_rounds: 3,
            stack_count: 1,
            max_stacks: 1,
            stack_behavior: StackBehavior::Refresh,
            damage_mult: Some(2.0),
            damage_types: vec![DamageType::Fire],
            ..Default::default()
        });

        let bonus = vulnerability_bonus_multiplier(&ability, &target);
        // mult = 2.0, passes through as multiplier
        assert!((bonus - 2.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_vulnerability_bonus_no_vulnerability() {
        let ability = Ability {
            id: 1,
            damage_type: DamageType::Fire,
            ..Default::default()
        };
        let target = make_participant(2, 1, 6, 6);
        let bonus = vulnerability_bonus_multiplier(&ability, &target);
        // No vulnerability: 1.0 (no bonus).
        assert!((bonus - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_hazard_knockback_bonus_with_hazard() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.has_forced_movement = true;
        ability.forced_movement = Some(ForcedMovement {
            direction: ForcedMovementDirection::Compass(crate::types::hex::Direction::S),
            distance: 1,
        });

        let mut target = make_participant(2, 1, 6, 6);
        target.position = HexCoord { x: 0, y: 4, z: 0 };

        let mut state = FightState::default();
        // Place a fire hazard at (0, 0), which is 1 hex south of (0, 4)
        state.hex_map.cells.insert(
            (0, 0),
            HexCell {
                x: 0,
                y: 0,
                hazard_type: Some(HazardType::Fire),
                hazard_damage: 8,
                ..Default::default()
            },
        );

        let bonus = hazard_knockback_multiplier(&ability, &target, &state);
        // 1.0 + 8 * 0.1 = 1.8
        assert!((bonus - 1.8).abs() < 0.01);
    }

    #[test]
    fn test_hazard_knockback_bonus_no_hazard() {
        let mut ability = make_ability(1, "2d8", 0, 1.0);
        ability.has_forced_movement = true;
        ability.forced_movement = Some(ForcedMovement {
            direction: ForcedMovementDirection::Compass(crate::types::hex::Direction::S),
            distance: 1,
        });

        let target = make_participant(2, 1, 6, 6);
        let state = FightState::default();

        let bonus = hazard_knockback_multiplier(&ability, &target, &state);
        // No hazard: 1.0 (no bonus).
        assert!((bonus - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_rank_abilities_sorted_descending() {
        let mut participant = make_participant(1, 0, 6, 6);
        // Weak ability
        participant
            .abilities
            .push(make_ability(10, "1d4", 0, 1.0));
        // Strong ability
        participant
            .abilities
            .push(make_ability(11, "3d10", 5, 2.0));

        let enemy = make_participant(2, 1, 6, 6);
        let enemies: Vec<&Participant> = vec![&enemy];
        let state = FightState::default();

        let scores = rank_abilities(&participant, &enemies, &[], &state);
        assert!(!scores.is_empty());
        // First score should be higher than second
        assert!(scores[0].total_score >= scores[1].total_score);
        // The stronger ability (id 11) should be first
        assert_eq!(scores[0].ability_id, 11);
    }

    #[test]
    fn test_rank_abilities_empty() {
        let participant = make_participant(1, 0, 6, 6);
        let enemy = make_participant(2, 1, 6, 6);
        let enemies: Vec<&Participant> = vec![&enemy];
        let state = FightState::default();

        let scores = rank_abilities(&participant, &enemies, &[], &state);
        assert!(scores.is_empty());
    }

    #[test]
    fn test_rank_abilities_on_cooldown_excluded() {
        let mut participant = make_participant(1, 0, 6, 6);
        participant
            .abilities
            .push(make_ability(10, "2d8", 0, 1.0));
        participant.cooldowns.insert(10, 3); // on cooldown

        let enemy = make_participant(2, 1, 6, 6);
        let enemies: Vec<&Participant> = vec![&enemy];
        let state = FightState::default();

        let scores = rank_abilities(&participant, &enemies, &[], &state);
        assert!(scores.is_empty());
    }
}
