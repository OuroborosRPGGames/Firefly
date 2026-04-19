pub mod ability_resolution;
pub mod ai;
pub mod battle_map;
pub mod damage;
pub mod defense;
pub mod dice;
pub mod hex_grid;
pub mod interactive_objects;
pub mod monster_combat;
pub mod movement;
pub mod observer_effects;
pub mod pathfinding;
pub mod qi_lightness_paths;
pub mod resolution;
pub mod segments;
pub mod status_effects;
pub mod tactics;
pub mod types;
pub mod weapon_resolution;

use rand::Rng;

/// Resolve one round of combat given the current fight state and each
/// participant's chosen action.  Returns the resulting state, all combat
/// events that occurred, knockout list, and fight-end status.
pub fn resolve_round(
    state: &types::FightState,
    actions: &[types::PlayerAction],
    rng: &mut impl Rng,
) -> types::RoundResult {
    resolution::resolve_round_inner(state, actions, rng)
}

/// Like `resolve_round` but also emits `RngTrace` events for every random
/// value consumed, for parity debugging between Ruby and Rust engines.
pub fn resolve_round_traced(
    state: &types::FightState,
    actions: &[types::PlayerAction],
    rng: &mut impl Rng,
) -> types::RoundResult {
    resolution::resolve_round_traced(state, actions, rng)
}

/// Generate AI-driven actions for the given participant IDs based on their
/// AI profiles and the current fight state.
pub fn generate_ai_actions(
    state: &types::FightState,
    participant_ids: &[u64],
    rng: &mut impl Rng,
) -> Vec<types::PlayerAction> {
    ai::decide_actions(state, participant_ids, rng)
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn simple_1v1() -> types::FightState {
        use types::*;
        let p1 = Participant {
            id: 1,
            side: 0,
            current_hp: 6,
            max_hp: 6,
            position: HexCoord { x: 0, y: 0, z: 0 },
            melee_weapon: Some(Weapon {
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
            }),
            stat_modifier: 10,
            ..Default::default()
        };
        let p2 = Participant {
            id: 2,
            side: 1,
            current_hp: 6,
            max_hp: 6,
            position: HexCoord { x: 1, y: 2, z: 0 },
            melee_weapon: Some(Weapon {
                id: 2,
                name: "Spear".into(),
                dice_count: 2,
                dice_sides: 6,
                damage_type: DamageType::Physical,
                reach: 3,
                speed: 5,
                is_ranged: false,
                range_hexes: None,
                attack_range_hexes: 1,
                is_unarmed: false,
            }),
            stat_modifier: 8,
            ..Default::default()
        };
        FightState {
            round: 0,
            participants: vec![p1, p2],
            ..Default::default()
        }
    }

    #[test]
    fn test_resolve_round_1v1() {
        let state = simple_1v1();
        let actions = vec![
            types::PlayerAction {
                participant_id: 1,
                main_action: types::MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                movement: types::MovementAction::TowardsPerson(2),
                ..Default::default()
            },
            types::PlayerAction {
                participant_id: 2,
                main_action: types::MainAction::Attack { target_id: 1, monster_id: None, segment_id: None },
                movement: types::MovementAction::TowardsPerson(1),
                ..Default::default()
            },
        ];
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = resolve_round(&state, &actions, &mut rng);

        assert_eq!(result.next_state.round, 1);
        assert!(!result.events.is_empty());
        assert_eq!(result.next_state.participants.len(), 2);
    }

    #[test]
    fn test_resolve_round_deterministic() {
        let state = simple_1v1();
        let actions = vec![
            types::PlayerAction {
                participant_id: 1,
                main_action: types::MainAction::Attack { target_id: 2, monster_id: None, segment_id: None },
                ..Default::default()
            },
            types::PlayerAction {
                participant_id: 2,
                main_action: types::MainAction::Attack { target_id: 1, monster_id: None, segment_id: None },
                ..Default::default()
            },
        ];
        let mut rng1 = ChaCha8Rng::seed_from_u64(42);
        let mut rng2 = ChaCha8Rng::seed_from_u64(42);
        let r1 = resolve_round(&state, &actions, &mut rng1);
        let r2 = resolve_round(&state, &actions, &mut rng2);
        assert_eq!(r1.next_state.round, r2.next_state.round);
        assert_eq!(r1.events.len(), r2.events.len());
        assert_eq!(r1.knockouts, r2.knockouts);
        assert_eq!(r1.fight_ended, r2.fight_ended);
    }

    #[test]
    fn test_generate_ai_actions() {
        let mut state = simple_1v1();
        state.participants[0].ai_profile = Some("aggressive".into());
        state.participants[1].ai_profile = Some("defensive".into());
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = generate_ai_actions(&state, &[1, 2], &mut rng);
        assert_eq!(actions.len(), 2);
        // Both should have valid actions targeting the other
        for action in &actions {
            assert!(action.participant_id == 1 || action.participant_id == 2);
        }
    }

    #[test]
    fn test_full_ai_combat_loop() {
        let mut state = simple_1v1();
        state.participants[0].ai_profile = Some("aggressive".into());
        state.participants[1].ai_profile = Some("balanced".into());
        let mut rng = ChaCha8Rng::seed_from_u64(42);

        for _ in 0..50 {
            let all_ids: Vec<u64> = state.participants.iter().map(|p| p.id).collect();
            let actions = generate_ai_actions(&state, &all_ids, &mut rng);
            let result = resolve_round(&state, &actions, &mut rng);
            state = result.next_state;
            if result.fight_ended {
                break;
            }
        }
        // Fight should have progressed (some HP lost or ended)
        let total_hp: u8 = state.participants.iter().map(|p| p.current_hp).sum();
        assert!(
            total_hp < 12 || state.participants.iter().any(|p| p.is_knocked_out),
            "Fight should have caused damage or knockout"
        );
    }
}
