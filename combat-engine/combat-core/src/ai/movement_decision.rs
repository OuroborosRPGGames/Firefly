use crate::types::*;

/// Combat role based on weapon loadout.
#[derive(Debug, Clone, Copy, PartialEq)]
enum CombatRole {
    Melee,
    Ranged,
    Flexible,
}

/// Assess the combat role of a participant based on their weapon loadout.
fn assess_combat_role(participant: &Participant) -> CombatRole {
    let has_ranged = participant.ranged_weapon.is_some();
    let has_melee = participant.melee_weapon.is_some();

    match (has_melee, has_ranged) {
        (false, true) => CombatRole::Ranged,
        (true, false) => CombatRole::Melee,
        (true, true) => CombatRole::Flexible,
        (false, false) => CombatRole::Melee, // Default: unarmed melee
    }
}

/// Choose a movement action for the AI participant based on its target,
/// profile, combat role, and current state.
///
/// Melee combatants close to weapon reach. Ranged combatants maintain
/// optimal distance and avoid close range. Flexible combatants adapt
/// based on cover and situation. If there is no target, stand still.
pub fn choose_movement(
    participant: &Participant,
    target_id: Option<u64>,
    profile: &AiProfileConfig,
    state: &FightState,
) -> MovementAction {
    let target_id = match target_id {
        Some(id) => id,
        None => return MovementAction::StandStill,
    };

    let target = state.participants.iter().find(|p| p.id == target_id);
    let target_dist = target
        .map(|t| {
            crate::hex_grid::hex_distance(
                participant.position.x,
                participant.position.y,
                t.position.x,
                t.position.y,
            )
        })
        .unwrap_or(0);

    // Flee check: if HP is critically low, flee regardless of role
    if participant.hp_percent() <= profile.flee_threshold && profile.flee_threshold > 0.0 {
        return MovementAction::AwayFrom(target_id);
    }

    let role = assess_combat_role(participant);

    match role {
        CombatRole::Melee => choose_melee_movement(participant, target_id, target_dist, profile),
        CombatRole::Ranged => {
            choose_ranged_movement(participant, target_id, target_dist, state, profile)
        }
        CombatRole::Flexible => choose_flexible_movement(
            participant,
            target_id,
            target_dist,
            state,
            profile,
        ),
    }
}

/// Melee role movement: close to attack range, shadow targets when aggressive.
/// Ruby: combat_ai_service.rb:576 uses `weapon.pattern.range_in_hexes || 1`.
/// `weapon.reach` only affects segment-compression timing, not AI movement.
fn choose_melee_movement(
    participant: &Participant,
    target_id: u64,
    target_dist: i32,
    profile: &AiProfileConfig,
) -> MovementAction {
    let attack_range = participant
        .melee_weapon
        .as_ref()
        .map_or(1, |w| w.attack_range_hexes);

    if target_dist as u32 <= attack_range {
        // Already in range
        if profile.attack_weight >= 0.8 {
            // Aggressive profile: shadow chase (stay on top of target)
            MovementAction::TowardsPerson(target_id)
        } else {
            MovementAction::StandStill
        }
    } else {
        // Out of range: close the gap
        MovementAction::TowardsPerson(target_id)
    }
}

/// Ranged role movement: maintain optimal distance, retreat if too close.
fn choose_ranged_movement(
    participant: &Participant,
    target_id: u64,
    target_dist: i32,
    state: &FightState,
    _profile: &AiProfileConfig,
) -> MovementAction {
    let optimal = state.config.ai_positioning.optimal_ranged_distance;
    let min_range = state.config.ai_positioning.min_ranged_distance;

    // Get weapon range for max distance check
    let weapon_range = participant
        .ranged_weapon
        .as_ref()
        .and_then(|w| w.range_hexes)
        .unwrap_or(10);

    if target_dist < min_range as i32 {
        // Too close: retreat to optimal distance
        MovementAction::MaintainDistance {
            target_id,
            range: optimal as u8,
        }
    } else if target_dist > weapon_range as i32 {
        // Out of weapon range: approach
        MovementAction::TowardsPerson(target_id)
    } else if target_dist > optimal as i32 + 2 {
        // A bit too far but still in range: approach
        MovementAction::TowardsPerson(target_id)
    } else {
        // In the sweet spot: hold position
        MovementAction::StandStill
    }
}

/// Flexible role movement: adapts based on target cover and distance.
fn choose_flexible_movement(
    participant: &Participant,
    target_id: u64,
    target_dist: i32,
    state: &FightState,
    profile: &AiProfileConfig,
) -> MovementAction {
    // Check if target is behind cover from our position
    let target_behind_cover = state
        .participants
        .iter()
        .find(|p| p.id == target_id)
        .map(|t| {
            crate::battle_map::shot_passes_through_cover(
                &state.hex_map,
                &participant.position,
                &t.position,
            )
        })
        .unwrap_or(false);

    let attack_range = participant
        .melee_weapon
        .as_ref()
        .map_or(1, |w| w.attack_range_hexes);

    if target_behind_cover && target_dist as u32 <= attack_range + 3 {
        // Target behind cover and melee reachable: close for melee approach
        MovementAction::TowardsPerson(target_id)
    } else if target_behind_cover {
        // Target behind cover but far: still approach (melee will be better)
        MovementAction::TowardsPerson(target_id)
    } else {
        // No cover: use ranged behavior
        choose_ranged_movement(participant, target_id, target_dist, state, profile)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::config::AiProfileConfig;
    use crate::types::hex::{CoverType, HexCell};

    fn make_participant(id: u64, x: i32, y: i32) -> Participant {
        Participant {
            id,
            position: HexCoord { x, y, z: 0 },
            ..Default::default()
        }
    }

    fn default_profile() -> AiProfileConfig {
        AiProfileConfig::default()
    }

    fn aggressive_profile() -> AiProfileConfig {
        AiProfileConfig {
            attack_weight: 0.8,
            defend_weight: 0.1,
            ability_weight: 0.4,
            flee_threshold: 0.1,
            target_strategy: "weakest".to_string(),
            hazard_avoidance: "low".to_string(),
            terrain_caution: 0.2,
        }
    }

    fn make_bow() -> Weapon {
        Weapon {
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
        }
    }

    fn make_sword() -> Weapon {
        Weapon {
            id: 2,
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
        }
    }

    #[test]
    fn test_no_target_stands_still() {
        let p = make_participant(1, 0, 0);
        let state = FightState::default();
        let movement = choose_movement(&p, None, &default_profile(), &state);
        assert!(matches!(movement, MovementAction::StandStill));
    }

    #[test]
    fn test_melee_in_range_stands_still() {
        let p = make_participant(1, 0, 0);
        let target = make_participant(2, 1, 2); // dist 1, within default reach 2
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        assert!(matches!(movement, MovementAction::StandStill));
    }

    #[test]
    fn test_melee_out_of_range_approaches() {
        let p = make_participant(1, 0, 0);
        let target = make_participant(2, 4, 8); // dist 4, beyond reach 2
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        assert!(matches!(movement, MovementAction::TowardsPerson(2)));
    }

    #[test]
    fn test_ranged_too_close_maintains_distance() {
        let mut p = make_participant(1, 0, 0);
        p.ranged_weapon = Some(make_bow());
        let target = make_participant(2, 1, 2); // dist 1, below min_ranged_distance (5)
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        assert!(matches!(
            movement,
            MovementAction::MaintainDistance {
                target_id: 2,
                range: 6
            }
        ));
    }

    #[test]
    fn test_ranged_too_far_approaches() {
        let mut p = make_participant(1, 0, 0);
        p.ranged_weapon = Some(make_bow());
        // Place target far away: optimal is 6, so > 6+2=8 triggers approach
        // hex_distance(0,0, 10,20) = 10
        let target = make_participant(2, 10, 20);
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        assert!(matches!(movement, MovementAction::TowardsPerson(2)));
    }

    #[test]
    fn test_ranged_at_optimal_stands_still() {
        let mut p = make_participant(1, 0, 0);
        p.ranged_weapon = Some(make_bow());
        // Place target at distance 6 (optimal). hex_distance(0,0, 6,12) = 6
        let target = make_participant(2, 6, 12);
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        assert!(matches!(movement, MovementAction::StandStill));
    }

    // --- Role assessment tests ---

    #[test]
    fn test_assess_melee_role() {
        let mut p = Participant::default();
        p.melee_weapon = Some(make_sword());
        assert_eq!(assess_combat_role(&p), CombatRole::Melee);
    }

    #[test]
    fn test_assess_ranged_role() {
        let mut p = Participant::default();
        p.ranged_weapon = Some(make_bow());
        assert_eq!(assess_combat_role(&p), CombatRole::Ranged);
    }

    #[test]
    fn test_assess_flexible_role() {
        let mut p = Participant::default();
        p.melee_weapon = Some(make_sword());
        p.ranged_weapon = Some(make_bow());
        assert_eq!(assess_combat_role(&p), CombatRole::Flexible);
    }

    #[test]
    fn test_assess_unarmed_defaults_melee() {
        let p = Participant::default();
        assert_eq!(assess_combat_role(&p), CombatRole::Melee);
    }

    // --- Aggressive melee shadow chase ---

    #[test]
    fn test_aggressive_melee_in_range_chases() {
        let mut p = make_participant(1, 0, 0);
        p.melee_weapon = Some(make_sword());
        let target = make_participant(2, 1, 2); // dist 1, within reach
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &aggressive_profile(), &state);
        // Aggressive profile (attack_weight 0.8) should shadow chase
        assert!(matches!(movement, MovementAction::TowardsPerson(2)));
    }

    // --- Flexible role tests ---

    #[test]
    fn test_flexible_approaches_melee_when_target_behind_cover() {
        let mut p = make_participant(1, 0, 0);
        p.melee_weapon = Some(make_sword());
        p.ranged_weapon = Some(make_bow());
        // Target further away so cover is not adjacent to attacker
        let target = make_participant(2, 0, 16);

        let mut map = crate::types::hex::HexMap::default();
        // Cover not adjacent to attacker (at (0,8), 2 hexes away)
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
            participants: vec![p.clone(), target],
            hex_map: map,
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        // Target behind cover -> approach for melee
        assert!(matches!(movement, MovementAction::TowardsPerson(2)));
    }

    #[test]
    fn test_flexible_uses_ranged_when_no_cover() {
        let mut p = make_participant(1, 0, 0);
        p.melee_weapon = Some(make_sword());
        p.ranged_weapon = Some(make_bow());
        // Place target at optimal ranged distance
        let target = make_participant(2, 6, 12); // dist 6

        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        // No cover -> use ranged behavior -> at optimal -> stand still
        assert!(matches!(movement, MovementAction::StandStill));
    }

    // --- Flee behavior ---

    #[test]
    fn test_flee_at_low_hp() {
        let mut p = make_participant(1, 0, 0);
        p.current_hp = 1;
        p.max_hp = 6; // ~16.7% HP
        let target = make_participant(2, 1, 2);
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let profile = AiProfileConfig {
            flee_threshold: 0.2,
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &profile, &state);
        assert!(matches!(movement, MovementAction::AwayFrom(2)));
    }

    #[test]
    fn test_no_flee_above_threshold() {
        let mut p = make_participant(1, 0, 0);
        p.current_hp = 4;
        p.max_hp = 6; // ~66.7% HP
        let target = make_participant(2, 1, 2);
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let profile = AiProfileConfig {
            flee_threshold: 0.2,
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &profile, &state);
        // Should not flee (HP is well above threshold)
        assert!(!matches!(movement, MovementAction::AwayFrom(_)));
    }

    // --- Ranged out of weapon range ---

    #[test]
    fn test_ranged_beyond_weapon_range_approaches() {
        let mut p = make_participant(1, 0, 0);
        p.ranged_weapon = Some(Weapon {
            id: 1,
            name: "short_bow".into(),
            dice_count: 1,
            dice_sides: 6,
            damage_type: DamageType::Physical,
            reach: 1,
            speed: 5,
            is_ranged: true,
            range_hexes: Some(5), // short range
            attack_range_hexes: 1,
            is_unarmed: false,
        });
        // Place target at dist ~10 (well beyond range 5)
        let target = make_participant(2, 10, 20);
        let state = FightState {
            participants: vec![p.clone(), target],
            ..Default::default()
        };
        let movement = choose_movement(&p, Some(2), &default_profile(), &state);
        assert!(matches!(movement, MovementAction::TowardsPerson(2)));
    }
}
