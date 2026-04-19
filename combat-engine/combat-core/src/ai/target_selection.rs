use crate::types::*;
use rand::Rng;

/// Select a target from the given enemies based on the specified strategy.
///
/// Strategies:
/// - `"weakest"`: lowest current HP (default fallback)
/// - `"closest"`: nearest by hex distance
/// - `"strongest"`: highest current HP
/// - `"threat"`: composite score from proximity, wounds, and observer aggro
/// - `"random"`: uniformly random
pub fn select_target(
    participant: &Participant,
    enemies: &[&Participant],
    strategy: &str,
    state: &FightState,
    rng: &mut impl Rng,
) -> Option<u64> {
    if enemies.is_empty() {
        return None;
    }

    match strategy {
        "weakest" => select_weakest(enemies),
        "closest" => select_closest(participant, enemies),
        "strongest" => select_strongest(enemies),
        "threat" => select_by_threat(participant, enemies, state),
        "random" => Some(enemies[rng.gen_range(0..enemies.len())].id),
        _ => select_weakest(enemies), // default to weakest
    }
}

/// Dispatcher that uses cover-aware targeting for ranged attackers and
/// existing strategies for melee.
pub fn select_best_target(
    participant: &Participant,
    enemies: &[&Participant],
    state: &FightState,
    strategy: &str,
) -> Option<u64> {
    if enemies.is_empty() {
        return None;
    }

    // Use cover-aware targeting for ranged combatants
    let has_ranged = participant.ranged_weapon.is_some();
    let has_melee = participant.melee_weapon.is_some();

    if has_ranged && !has_melee {
        // Pure ranged: always use cover-aware
        return select_cover_aware(participant, enemies, state);
    }

    if has_ranged && has_melee {
        // Flexible: try cover-aware first, fall back to strategy-based
        if let Some(target) = select_cover_aware(participant, enemies, state) {
            return Some(target);
        }
    }

    // Melee or fallback: use standard strategy
    match strategy {
        "weakest" => select_weakest(enemies),
        "closest" => select_closest(participant, enemies),
        "strongest" => select_strongest(enemies),
        "threat" => select_by_threat(participant, enemies, state),
        _ => select_weakest(enemies),
    }
}

/// Cover-aware target selection for ranged combatants.
///
/// Scores each enemy based on distance, cover, elevation, concealment,
/// and line-of-sight. Targets without LoS are skipped entirely.
pub fn select_cover_aware(
    participant: &Participant,
    enemies: &[&Participant],
    state: &FightState,
) -> Option<u64> {
    let mut best_id: Option<u64> = None;
    let mut best_score = f32::NEG_INFINITY;

    for enemy in enemies {
        // LoS check: skip targets we can't see
        if !crate::battle_map::has_line_of_sight(
            &state.hex_map,
            state.wall_mask.as_ref(),
            &participant.position,
            &enemy.position,
            participant.position.z,
        ) {
            continue;
        }

        let dist = crate::hex_grid::hex_distance(
            participant.position.x,
            participant.position.y,
            enemy.position.x,
            enemy.position.y,
        );

        // Base score: closer = higher (max 10)
        let mut score = 10.0 - (dist.min(10) as f32);

        // Cover penalty
        if crate::battle_map::shot_passes_through_cover(
            &state.hex_map,
            &participant.position,
            &enemy.position,
        ) {
            score -= 5.0;
        }

        // Elevation bonus
        let elev_mod = crate::battle_map::elevation_modifier(
            participant.position.z,
            enemy.position.z,
        );
        score += elev_mod as f32;

        // Concealment penalty
        if crate::battle_map::is_concealed(&state.hex_map, &enemy.position) {
            score -= 3.0;
        }

        if score > best_score {
            best_score = score;
            best_id = Some(enemy.id);
        }
    }

    best_id
}

fn select_weakest(enemies: &[&Participant]) -> Option<u64> {
    enemies
        .iter()
        .min_by_key(|e| e.current_hp)
        .map(|e| e.id)
}

fn select_closest(participant: &Participant, enemies: &[&Participant]) -> Option<u64> {
    enemies
        .iter()
        .min_by_key(|e| {
            crate::hex_grid::hex_distance(
                participant.position.x,
                participant.position.y,
                e.position.x,
                e.position.y,
            )
        })
        .map(|e| e.id)
}

fn select_strongest(enemies: &[&Participant]) -> Option<u64> {
    enemies
        .iter()
        .max_by_key(|e| e.current_hp)
        .map(|e| e.id)
}

fn select_by_threat(
    participant: &Participant,
    enemies: &[&Participant],
    state: &FightState,
) -> Option<u64> {
    enemies
        .iter()
        .max_by_key(|e| {
            let mut threat = 0i32;

            // Bonus when this enemy is already targeting us. Ruby:
            // combat_ai_service.rb:275 `if enemy.target_participant_id == participant.id`.
            if e.current_target_id == Some(participant.id) {
                threat += state.config.threat_weights.targeted_by_enemy;
            }

            // Proximity bonus: closer = more threatening
            let dist = crate::hex_grid::hex_distance(
                participant.position.x,
                participant.position.y,
                e.position.x,
                e.position.y,
            );
            threat += (state.config.threat_weights.max_proximity_bonus - dist).max(0);

            // Wounded = desperate = threatening
            threat += (e.max_hp as i32) - (e.current_hp as i32);

            // Observer aggro boost
            threat +=
                crate::observer_effects::aggro_threat_modifier(&state.observer_effects, e.id);

            threat
        })
        .map(|e| e.id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::{CoverType, HexCell};
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn make_participant(id: u64, side: u8, hp: u8, max_hp: u8) -> Participant {
        Participant {
            id,
            side,
            current_hp: hp,
            max_hp,
            ..Default::default()
        }
    }

    fn simple_state(participants: Vec<Participant>) -> FightState {
        FightState {
            participants,
            ..Default::default()
        }
    }

    #[test]
    fn test_weakest_strategy() {
        let p = make_participant(1, 0, 6, 6);
        let e1 = make_participant(2, 1, 3, 6);
        let e2 = make_participant(3, 1, 5, 6);
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert_eq!(
            select_target(&p, &enemies, "weakest", &state, &mut rng),
            Some(2)
        );
    }

    #[test]
    fn test_strongest_strategy() {
        let p = make_participant(1, 0, 6, 6);
        let e1 = make_participant(2, 1, 3, 6);
        let e2 = make_participant(3, 1, 5, 6);
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert_eq!(
            select_target(&p, &enemies, "strongest", &state, &mut rng),
            Some(3)
        );
    }

    #[test]
    fn test_closest_strategy() {
        let mut p = make_participant(1, 0, 6, 6);
        p.position = HexCoord { x: 0, y: 0, z: 0 };

        let mut e1 = make_participant(2, 1, 6, 6);
        e1.position = HexCoord { x: 2, y: 4, z: 0 }; // dist 2

        let mut e2 = make_participant(3, 1, 6, 6);
        e2.position = HexCoord { x: 1, y: 2, z: 0 }; // dist 1

        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert_eq!(
            select_target(&p, &enemies, "closest", &state, &mut rng),
            Some(3)
        );
    }

    #[test]
    fn test_threat_strategy_considers_wounds() {
        let p = make_participant(1, 0, 6, 6);
        let e1 = make_participant(2, 1, 2, 6); // heavily wounded -> high threat
        let e2 = make_participant(3, 1, 6, 6); // full HP -> low threat
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert_eq!(
            select_target(&p, &enemies, "threat", &state, &mut rng),
            Some(2)
        );
    }

    #[test]
    fn test_random_strategy() {
        let p = make_participant(1, 0, 6, 6);
        let e1 = make_participant(2, 1, 6, 6);
        let e2 = make_participant(3, 1, 6, 6);
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let target = select_target(&p, &enemies, "random", &state, &mut rng);
        assert!(target == Some(2) || target == Some(3));
    }

    #[test]
    fn test_empty_enemies() {
        let p = make_participant(1, 0, 6, 6);
        let enemies: Vec<&Participant> = vec![];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert_eq!(
            select_target(&p, &enemies, "weakest", &state, &mut rng),
            None
        );
    }

    #[test]
    fn test_unknown_strategy_defaults_to_weakest() {
        let p = make_participant(1, 0, 6, 6);
        let e1 = make_participant(2, 1, 2, 6);
        let e2 = make_participant(3, 1, 5, 6);
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = simple_state(vec![]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert_eq!(
            select_target(&p, &enemies, "nonsense", &state, &mut rng),
            Some(2)
        );
    }

    // --- Cover-aware targeting tests ---

    #[test]
    fn test_cover_aware_prefers_uncovered_target() {
        let mut p = make_participant(1, 0, 6, 6);
        p.position = HexCoord { x: 0, y: 0, z: 0 };
        p.ranged_weapon = Some(Weapon {
            id: 1,
            name: "bow".into(),
            dice_count: 1,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 1,
            speed: 5,
            is_ranged: true,
            range_hexes: Some(10),
            attack_range_hexes: 1,
            is_unarmed: false,
        });

        // Enemy behind cover (cover at (0,8) between attacker (0,0) and target (0,16))
        // Cover must NOT be adjacent to attacker (adjacency skip rule)
        let mut e1 = make_participant(2, 1, 6, 6);
        e1.position = HexCoord { x: 0, y: 16, z: 0 };

        // Enemy without cover at same distance
        let mut e2 = make_participant(3, 1, 6, 6);
        e2.position = HexCoord { x: 2, y: 16, z: 0 };

        let mut map = crate::types::hex::HexMap::default();
        // Place cover between attacker and e1 (not adjacent to attacker)
        map.cells.insert(
            (0, 8),
            HexCell {
                x: 0,
                y: 8,
                cover_type: Some(CoverType::Half),
                ..Default::default()
            },
        );

        let state = FightState {
            hex_map: map,
            ..Default::default()
        };

        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let result = select_cover_aware(&p, &enemies, &state);
        // Should prefer e2 (no cover penalty)
        assert_eq!(result, Some(3));
    }

    #[test]
    fn test_cover_aware_skips_no_los() {
        let mut p = make_participant(1, 0, 6, 6);
        p.position = HexCoord { x: 0, y: 0, z: 0 };

        // Enemy behind LoS blocker
        let mut e1 = make_participant(2, 1, 6, 6);
        e1.position = HexCoord { x: 0, y: 8, z: 0 };

        // Visible enemy further away
        let mut e2 = make_participant(3, 1, 6, 6);
        e2.position = HexCoord {
            x: 2,
            y: 8,
            z: 0,
        };

        let mut map = crate::types::hex::HexMap::default();
        // LoS blocker between attacker and e1. cover_height must be >0 so
        // a ground-level viewer (z=0) is below the cover top.
        map.cells.insert(
            (0, 4),
            HexCell {
                x: 0,
                y: 4,
                blocks_los: true,
                cover_height: 1,
                ..Default::default()
            },
        );

        let state = FightState {
            hex_map: map,
            ..Default::default()
        };

        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let result = select_cover_aware(&p, &enemies, &state);
        // Should pick e2 since e1 has no LoS
        assert_eq!(result, Some(3));
    }

    #[test]
    fn test_cover_aware_elevation_bonus() {
        let mut p = make_participant(1, 0, 6, 6);
        p.position = HexCoord { x: 0, y: 0, z: 2 }; // elevated

        let mut e1 = make_participant(2, 1, 6, 6);
        e1.position = HexCoord { x: 1, y: 2, z: 0 }; // low ground

        let mut e2 = make_participant(3, 1, 6, 6);
        e2.position = HexCoord { x: -1, y: 2, z: 2 }; // same elevation

        let state = FightState::default();
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let result = select_cover_aware(&p, &enemies, &state);
        // e1 gets elevation bonus (+2), both are dist 1 so base 9.0
        // e1: 9.0 + 2.0 = 11.0
        // e2: 9.0 + 0.0 = 9.0
        assert_eq!(result, Some(2));
    }

    #[test]
    fn test_cover_aware_concealment_penalty() {
        let mut p = make_participant(1, 0, 6, 6);
        p.position = HexCoord { x: 0, y: 0, z: 0 };

        let mut e1 = make_participant(2, 1, 6, 6);
        e1.position = HexCoord { x: 1, y: 2, z: 0 }; // concealed

        let mut e2 = make_participant(3, 1, 6, 6);
        e2.position = HexCoord { x: -1, y: 2, z: 0 }; // not concealed

        let mut map = crate::types::hex::HexMap::default();
        map.cells.insert(
            (1, 2),
            HexCell {
                x: 1,
                y: 2,
                is_concealment: true,
                ..Default::default()
            },
        );

        let state = FightState {
            hex_map: map,
            ..Default::default()
        };

        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let result = select_cover_aware(&p, &enemies, &state);
        // e1 has concealment penalty (-3.0), e2 does not
        assert_eq!(result, Some(3));
    }

    #[test]
    fn test_cover_aware_empty_enemies() {
        let p = make_participant(1, 0, 6, 6);
        let enemies: Vec<&Participant> = vec![];
        let state = FightState::default();
        assert_eq!(select_cover_aware(&p, &enemies, &state), None);
    }

    // --- select_best_target tests ---

    #[test]
    fn test_best_target_melee_uses_strategy() {
        let mut p = make_participant(1, 0, 6, 6);
        p.melee_weapon = Some(Weapon {
            id: 1,
            name: "sword".into(),
            dice_count: 2,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 2,
            speed: 5,
            is_ranged: false,
            range_hexes: None,
            attack_range_hexes: 1,
            is_unarmed: false,
        });

        let e1 = make_participant(2, 1, 3, 6); // weaker
        let e2 = make_participant(3, 1, 5, 6);
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let state = FightState::default();

        let result = select_best_target(&p, &enemies, &state, "weakest");
        assert_eq!(result, Some(2));
    }

    #[test]
    fn test_best_target_ranged_uses_cover_aware() {
        let mut p = make_participant(1, 0, 6, 6);
        p.position = HexCoord { x: 0, y: 0, z: 0 };
        p.ranged_weapon = Some(Weapon {
            id: 1,
            name: "bow".into(),
            dice_count: 1,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 1,
            speed: 5,
            is_ranged: true,
            range_hexes: Some(10),
            attack_range_hexes: 1,
            is_unarmed: false,
        });
        // No melee weapon -> pure ranged

        let mut e1 = make_participant(2, 1, 6, 6);
        e1.position = HexCoord { x: 1, y: 2, z: 0 };

        let enemies: Vec<&Participant> = vec![&e1];
        let state = FightState::default();

        let result = select_best_target(&p, &enemies, &state, "weakest");
        assert_eq!(result, Some(2));
    }

    #[test]
    fn test_best_target_empty_enemies() {
        let p = make_participant(1, 0, 6, 6);
        let enemies: Vec<&Participant> = vec![];
        let state = FightState::default();
        assert_eq!(select_best_target(&p, &enemies, &state, "weakest"), None);
    }
}
