pub mod ability_power;
pub mod ability_selection;
pub mod monster_combat;
pub mod movement_decision;
pub mod target_selection;

use rand::Rng;

use crate::types::*;

/// Generate AI actions for the given participant IDs.
///
/// Skips knocked-out participants entirely (they produce no action).
/// For each active participant, decides movement, main action, and qi
/// allocation based on the participant's AI profile and current state.
pub fn decide_actions(
    state: &FightState,
    participant_ids: &[u64],
    rng: &mut impl Rng,
) -> Vec<PlayerAction> {
    participant_ids
        .iter()
        .filter_map(|&id| {
            let participant = state.participants.iter().find(|p| p.id == id)?;
            if participant.is_knocked_out {
                return None;
            }
            Some(generate_decision(state, participant, rng))
        })
        .collect()
}

fn generate_decision(
    state: &FightState,
    participant: &Participant,
    rng: &mut impl Rng,
) -> PlayerAction {
    // Stunned participants pass their turn
    if crate::status_effects::has_effect(&participant.status_effects, "stunned") {
        return PlayerAction {
            participant_id: participant.id,
            ..Default::default()
        };
    }

    let profile_name = participant.ai_profile.as_deref().unwrap_or("balanced");
    let profile = state
        .config
        .ai_profiles
        .get(profile_name)
        .or_else(|| state.config.ai_profiles.get("balanced"))
        .cloned()
        .unwrap_or_default();

    // Monster combat branch. Ruby: combat_ai_service.rb:103-107 — routes to
    // decide_monster_combat! whenever fight_has_active_monster?.
    if monster_combat::fight_has_active_monster(state) {
        return monster_combat::decide_monster_combat(state, participant, &profile, rng);
    }

    let enemies: Vec<&Participant> = state
        .participants
        .iter()
        .filter(|p| p.side != participant.side && p.is_active())
        .collect();
    let allies: Vec<&Participant> = state
        .participants
        .iter()
        .filter(|p| p.side == participant.side && p.id != participant.id && p.is_active())
        .collect();

    // Check forced target from observer effects. Ruby applies this only to
    // NPC attackers (combat_resolution_service.rb:533).
    let forced = crate::observer_effects::forced_target(
        &state.observer_effects,
        participant.id,
        participant.is_npc,
    );

    let target_id = forced.or_else(|| {
        target_selection::select_best_target(
            participant,
            &enemies,
            state,
            &profile.target_strategy,
        )
        .or_else(|| {
            target_selection::select_target(
                participant,
                &enemies,
                &profile.target_strategy,
                state,
                rng,
            )
        })
    });

    let hp_pct = participant.hp_percent();

    // Flee at low HP based on profile threshold.
    // Ruby: combat_ai_service.rb:362 — choose_main_action returns 'defend'
    // when hp_percent <= flee_threshold.
    if hp_pct <= profile.flee_threshold {
        return PlayerAction {
            participant_id: participant.id,
            main_action: MainAction::Defend,
            movement: match target_id {
                Some(tid) => MovementAction::AwayFrom(tid),
                None => MovementAction::StandStill,
            },
            ..Default::default()
        };
    }

    // Ability selection runs BEFORE the wounded-defend roll. Ruby orders:
    // flee → try ability (use_chance per-ability) → wounded-defend → attack
    // (combat_ai_service.rb:358-383). ability_weight on the profile is
    // declared but unused by Ruby; per-ability use_chance is the real gate
    // and lives inside select_ability (via the serialized Ability.use_chance).
    let has_usable_abilities = participant.global_cooldown == 0
        && !participant.abilities.is_empty()
        && participant.abilities.iter().any(|a| {
            let cd = participant.cooldowns.get(&a.id).copied().unwrap_or(0);
            cd <= 0 && a.qi_cost <= participant.available_qi_dice()
        });

    if has_usable_abilities {
        if let Some((ability_id, ability_target)) =
            ability_selection::select_ability(participant, &enemies, &allies, state, rng)
        {
            return PlayerAction {
                participant_id: participant.id,
                main_action: MainAction::Ability {
                    ability_id,
                    target_id: ability_target,
                },
                movement: movement_decision::choose_movement(
                    participant, target_id, &profile, state,
                ),
                // Ruby AI never allocates qi (combat_ai_service.rb:147-149)
                qi_ability: 0,
                ..Default::default()
            };
        }
    }

    // Wounded-defend roll runs AFTER ability attempt. Ruby line 377:
    //   if hp_percent <= HP_THRESHOLDS[:wounded] (0.5) && rand < defend_weight
    if hp_pct <= 0.5 && rng.gen::<f32>() < profile.defend_weight {
        return PlayerAction {
            participant_id: participant.id,
            main_action: MainAction::Defend,
            movement: movement_decision::choose_movement(
                participant, target_id, &profile, state,
            ),
            ..Default::default()
        };
    }

    // Default: attack (Ruby AI never allocates qi — combat_ai_service.rb:147-149)
    PlayerAction {
        participant_id: participant.id,
        main_action: match target_id {
            Some(tid) => MainAction::Attack { target_id: tid, monster_id: None, segment_id: None },
            None => MainAction::Defend,
        },
        movement: movement_decision::choose_movement(
            participant, target_id, &profile, state,
        ),
        qi_attack: 0,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::status_effects::{ActiveEffect, EffectType, StackBehavior};
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
    fn test_stunned_skips() {
        let mut p = make_participant(1, 0, 6, 6);
        p.status_effects.push(ActiveEffect {
            effect_name: "stunned".into(),
            effect_type: EffectType::CrowdControl,
            remaining_rounds: 1,
            stack_count: 1,
            max_stacks: 1,
            stack_behavior: StackBehavior::Refresh,
            ..Default::default()
        });
        let state = simple_state(vec![p, make_participant(2, 1, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        assert!(matches!(actions[0].main_action, MainAction::Pass));
    }

    #[test]
    fn test_flee_at_low_hp() {
        let state =
            simple_state(vec![make_participant(1, 0, 1, 6), make_participant(2, 1, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        assert!(matches!(actions[0].main_action, MainAction::Defend));
    }

    #[test]
    fn test_attack_default() {
        let state =
            simple_state(vec![make_participant(1, 0, 6, 6), make_participant(2, 1, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        assert!(matches!(actions[0].main_action, MainAction::Attack { .. }));
    }

    #[test]
    fn test_no_action_for_knocked_out() {
        let mut p = make_participant(1, 0, 0, 6);
        p.is_knocked_out = true;
        let state = simple_state(vec![p, make_participant(2, 1, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert!(actions.is_empty());
    }

    #[test]
    fn test_target_selection_weakest() {
        let p1 = make_participant(1, 0, 6, 6);
        let e1 = make_participant(2, 1, 3, 6); // weaker
        let e2 = make_participant(3, 1, 5, 6); // stronger
        let state = simple_state(vec![p1.clone(), e1.clone(), e2.clone()]);
        let enemies: Vec<&Participant> = vec![&e1, &e2];
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let target =
            target_selection::select_target(&p1, &enemies, "weakest", &state, &mut rng);
        assert_eq!(target, Some(2)); // weakest
    }

    #[test]
    fn test_multiple_participants() {
        let state = simple_state(vec![
            make_participant(1, 0, 6, 6),
            make_participant(2, 0, 6, 6),
            make_participant(3, 1, 6, 6),
        ]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1, 2], &mut rng);
        assert_eq!(actions.len(), 2);
    }

    #[test]
    fn test_no_enemies_defends() {
        // All on same side -> no enemies -> defends
        let state = simple_state(vec![
            make_participant(1, 0, 6, 6),
            make_participant(2, 0, 6, 6),
        ]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        assert!(matches!(actions[0].main_action, MainAction::Defend));
    }

    #[test]
    fn test_qi_allocation_on_attack() {
        // Ruby AI never allocates qi (combat_ai_service.rb:147-149)
        let mut p = make_participant(1, 0, 6, 6);
        p.qi_dice = 2.0;
        let state = simple_state(vec![p, make_participant(2, 1, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        if matches!(actions[0].main_action, MainAction::Attack { .. }) {
            assert_eq!(actions[0].qi_attack, 0);
        }
    }

    #[test]
    fn test_forced_target_overrides_strategy() {
        use crate::types::fight_state::ObserverEffect;

        // Ruby parity: forced_target retargets only NPC attackers, so the
        // participant must be flagged is_npc.
        let mut p = make_participant(1, 0, 6, 6);
        p.is_npc = true;
        let e1 = make_participant(2, 1, 2, 6); // weaker, would be chosen by "weakest"
        let e2 = make_participant(3, 1, 6, 6); // forced target

        let mut state = simple_state(vec![p, e1, e2]);
        state.observer_effects.push(ObserverEffect {
            effect_type: "forced_target".to_string(),
            source_id: 0,
            target_id: 1,         // participant 1 is forced
            forced_target_id: 3,  // to attack participant 3
            multiplier: 1.0,
            value: 0,
        });

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        match &actions[0].main_action {
            MainAction::Attack { target_id, .. } => assert_eq!(*target_id, 3),
            _ => panic!("expected Attack action targeting forced target 3"),
        }
    }

    #[test]
    fn test_unknown_participant_id_skipped() {
        let state = simple_state(vec![make_participant(1, 0, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[99], &mut rng);
        assert!(actions.is_empty());
    }

    #[test]
    fn test_flee_movement_away_from_enemy() {
        let state =
            simple_state(vec![make_participant(1, 0, 1, 6), make_participant(2, 1, 6, 6)]);
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let actions = decide_actions(&state, &[1], &mut rng);
        assert_eq!(actions.len(), 1);
        assert!(matches!(actions[0].movement, MovementAction::AwayFrom(2)));
    }
}
