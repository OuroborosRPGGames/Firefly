//! Parity testing harness for comparing Rust results against Ruby.
//!
//! These tests load scenario trace files (exported from Ruby) and verify
//! that the Rust engine produces the same results with the same RNG seed.
//!
//! Phase 1: Scaffold with self-consistency tests (Rust vs Rust)
//! Phase 2: Full parity tests against Ruby trace files

use combat_core::types::*;
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;

/// Self-consistency test: same input + same seed = same output (always)
#[test]
fn test_self_consistency_determinism() {
    let state = default_test_state();
    let all_ids: Vec<u64> = state.participants.iter().map(|p| p.id).collect();

    // Run 1
    let mut rng1 = ChaCha8Rng::seed_from_u64(42);
    let actions1 = combat_core::generate_ai_actions(&state, &all_ids, &mut rng1);
    let result1 = combat_core::resolve_round(&state, &actions1, &mut rng1);

    // Run 2 (same seed)
    let mut rng2 = ChaCha8Rng::seed_from_u64(42);
    let actions2 = combat_core::generate_ai_actions(&state, &all_ids, &mut rng2);
    let result2 = combat_core::resolve_round(&state, &actions2, &mut rng2);

    // Must be identical
    assert_eq!(result1.next_state.round, result2.next_state.round);
    assert_eq!(result1.events.len(), result2.events.len());
    assert_eq!(result1.knockouts, result2.knockouts);
    assert_eq!(result1.fight_ended, result2.fight_ended);
    for (p1, p2) in result1
        .next_state
        .participants
        .iter()
        .zip(&result2.next_state.participants)
    {
        assert_eq!(
            p1.current_hp, p2.current_hp,
            "HP mismatch for participant {}",
            p1.id
        );
        assert_eq!(p1.is_knocked_out, p2.is_knocked_out);
    }
}

/// Multi-round self-consistency: full combat simulation with same seed
#[test]
fn test_self_consistency_full_combat() {
    let state = default_test_state();

    let run = |seed: u64| -> (Vec<u8>, u32) {
        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        let mut s = state.clone();
        let mut round = 0;
        for _ in 0..50 {
            let ids: Vec<u64> = s
                .participants
                .iter()
                .filter(|p| !p.is_knocked_out)
                .map(|p| p.id)
                .collect();
            if ids.is_empty() {
                break;
            }
            let actions = combat_core::generate_ai_actions(&s, &ids, &mut rng);
            let result = combat_core::resolve_round(&s, &actions, &mut rng);
            s = result.next_state;
            round += 1;
            if result.fight_ended {
                break;
            }
        }
        let hp_state: Vec<u8> = s.participants.iter().map(|p| p.current_hp).collect();
        (hp_state, round)
    };

    let (hp1, rounds1) = run(12345);
    let (hp2, rounds2) = run(12345);
    assert_eq!(hp1, hp2);
    assert_eq!(rounds1, rounds2);

    // Different seed should (usually) produce different results
    let (hp3, _) = run(99999);
    // Not guaranteed to differ, but very likely with different seeds
    // Just verify it runs without panicking
    assert_eq!(hp3.len(), 2);
}

/// Stress test: run many simulations to catch panics/crashes
#[test]
fn test_stress_100_simulations() {
    let state = default_test_state();

    for seed in 0..100u64 {
        let mut rng = ChaCha8Rng::seed_from_u64(seed);
        let mut s = state.clone();
        for _ in 0..50 {
            let ids: Vec<u64> = s
                .participants
                .iter()
                .filter(|p| !p.is_knocked_out)
                .map(|p| p.id)
                .collect();
            if ids.is_empty() {
                break;
            }
            let actions = combat_core::generate_ai_actions(&s, &ids, &mut rng);
            let result = combat_core::resolve_round(&s, &actions, &mut rng);
            s = result.next_state;
            if result.fight_ended {
                break;
            }
        }
    }
}

fn default_test_state() -> FightState {
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
        ai_profile: Some("aggressive".into()),
        ..Default::default()
    };
    let p2 = Participant {
        id: 2,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        position: HexCoord { x: 2, y: 4, z: 0 },
        melee_weapon: Some(Weapon {
            id: 2,
            name: "Axe".into(),
            dice_count: 2,
            dice_sides: 6,
            damage_type: DamageType::Physical,
            reach: 1,
            speed: 6,
            is_ranged: false,
            range_hexes: None,
            attack_range_hexes: 1,
            is_unarmed: false,
        }),
        stat_modifier: 8,
        ai_profile: Some("balanced".into()),
        ..Default::default()
    };
    FightState {
        round: 0,
        participants: vec![p1, p2],
        ..Default::default()
    }
}
