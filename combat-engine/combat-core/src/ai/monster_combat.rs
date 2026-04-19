//! Monster-combat AI branch.
//!
//! Mirrors Ruby `CombatAiService#decide_monster_combat!` and its helpers
//! (backend/app/services/combat/combat_ai_service.rb:998-1442). Dispatched
//! from `ai::mod::generate_decision` when the fight has an active monster.
//!
//! Decision tree:
//! - Critical HP: dismount if mounted → defend and move away from monster
//! - Already mounted:
//!   - at_weak_point → attack
//!   - climbing → cling (if HP low / crowded) or continue climbing
//!   - mounted → cling (if hurt) or start climbing
//! - Not mounted + adjacent + roll passes → mount
//! - Otherwise → ground attack targeting best segment

use rand::Rng;

use crate::hex_grid;
use crate::types::actions::{MainAction, MovementAction, PlayerAction};
use crate::types::config::AiProfileConfig;
use crate::types::fight_state::FightState;
use crate::types::monsters::{MonsterData, MonsterStatus, MonsterSegment, MountStatus, SegmentStatus};
use crate::types::participant::Participant;

/// Return the first active monster, if any. Ruby: `active_monster` returns
/// the monster participant.targeting_monster_id points to or falls back to
/// the first active monster on the fight.
pub fn active_monster<'a>(
    state: &'a FightState,
    participant: &Participant,
) -> Option<&'a MonsterData> {
    if let Some(id) = participant.mount_target_id {
        if let Some(m) = state.monsters.iter().find(|m| m.id == id) {
            return Some(m);
        }
    }
    state
        .monsters
        .iter()
        .find(|m| m.status == MonsterStatus::Active)
}

/// True when the fight has at least one active monster. Ruby:
/// `fight_has_active_monster?`.
pub fn fight_has_active_monster(state: &FightState) -> bool {
    state
        .monsters
        .iter()
        .any(|m| m.status == MonsterStatus::Active)
}

/// Port of Ruby `decide_monster_combat!` (combat_ai_service.rb:998-1021).
pub fn decide_monster_combat(
    state: &FightState,
    participant: &Participant,
    profile: &AiProfileConfig,
    rng: &mut impl Rng,
) -> PlayerAction {
    let monster = match active_monster(state, participant) {
        Some(m) => m,
        None => {
            // No monster — caller (ai::mod) will fall through to standard combat.
            return PlayerAction {
                participant_id: participant.id,
                ..Default::default()
            };
        }
    };

    let hp_pct = participant.hp_percent();

    // Critically wounded branch.
    if hp_pct <= profile.flee_threshold {
        return handle_critical_hp(participant, monster);
    }

    if participant.is_mounted {
        return plan_mounted_actions(state, participant, monster, profile);
    }

    if should_attempt_mount(participant, monster, profile, rng) {
        return plan_mounting_strategy(participant, monster);
    }

    plan_ground_attack(participant, monster, profile)
}

fn handle_critical_hp(participant: &Participant, monster: &MonsterData) -> PlayerAction {
    if participant.is_mounted {
        return PlayerAction {
            participant_id: participant.id,
            main_action: MainAction::Defend,
            movement: MovementAction::Dismount,
            ..Default::default()
        };
    }
    PlayerAction {
        participant_id: participant.id,
        main_action: MainAction::Defend,
        movement: move_away_from_monster(participant, monster),
        ..Default::default()
    }
}

fn mount_state_for<'a>(
    monster: &'a MonsterData,
    participant: &Participant,
) -> Option<&'a crate::types::monsters::MountState> {
    monster
        .mount_states
        .iter()
        .find(|ms| ms.participant_id == participant.id)
}

fn plan_mounted_actions(
    state: &FightState,
    participant: &Participant,
    monster: &MonsterData,
    profile: &AiProfileConfig,
) -> PlayerAction {
    let mount_state = match mount_state_for(monster, participant) {
        Some(ms) => ms,
        None => return plan_ground_attack(participant, monster, profile),
    };
    let hp_pct = participant.hp_percent();

    match mount_state.mount_status {
        MountStatus::AtWeakPoint => {
            // Always attack when at weak point.
            let weak = monster
                .segments
                .iter()
                .find(|s| s.is_weak_point && s.status != SegmentStatus::Destroyed);
            PlayerAction {
                participant_id: participant.id,
                main_action: MainAction::Attack {
                    target_id: 0,
                    monster_id: Some(monster.id),
                    segment_id: weak.map(|s| s.id),
                },
                movement: MovementAction::Climb, // "attack" mount action
                ..Default::default()
            }
        }
        MountStatus::Climbing => {
            if should_cling(state, participant, monster, profile) {
                PlayerAction {
                    participant_id: participant.id,
                    main_action: MainAction::Defend,
                    movement: MovementAction::Cling,
                    ..Default::default()
                }
            } else {
                PlayerAction {
                    participant_id: participant.id,
                    main_action: MainAction::Attack {
                        target_id: 0,
                        monster_id: Some(monster.id),
                        segment_id: Some(mount_state.segment_id).filter(|&s| s != 0),
                    },
                    movement: MovementAction::Climb,
                    ..Default::default()
                }
            }
        }
        MountStatus::Mounted => {
            if hp_pct < 0.5 {
                PlayerAction {
                    participant_id: participant.id,
                    main_action: MainAction::Defend,
                    movement: MovementAction::Cling,
                    ..Default::default()
                }
            } else {
                // Start climbing.
                PlayerAction {
                    participant_id: participant.id,
                    main_action: MainAction::Attack {
                        target_id: 0,
                        monster_id: Some(monster.id),
                        segment_id: None,
                    },
                    movement: MovementAction::Climb,
                    ..Default::default()
                }
            }
        }
        _ => PlayerAction {
            participant_id: participant.id,
            main_action: MainAction::Defend,
            movement: MovementAction::Dismount,
            ..Default::default()
        },
    }
}

fn plan_mounting_strategy(participant: &Participant, monster: &MonsterData) -> PlayerAction {
    let closest = find_closest_segment(participant, monster);
    PlayerAction {
        participant_id: participant.id,
        main_action: MainAction::Attack {
            target_id: 0,
            monster_id: Some(monster.id),
            segment_id: closest.map(|s| s.id),
        },
        movement: MovementAction::Mount {
            monster_id: monster.id,
        },
        ..Default::default()
    }
}

fn plan_ground_attack(
    participant: &Participant,
    monster: &MonsterData,
    profile: &AiProfileConfig,
) -> PlayerAction {
    let seg = select_target_segment(participant, monster, profile);
    let ranged_only =
        participant.ranged_weapon.is_some() && participant.melee_weapon.is_none();

    let movement = if ranged_only {
        MovementAction::StandStill
    } else {
        move_towards_monster(participant, monster)
    };

    PlayerAction {
        participant_id: participant.id,
        main_action: MainAction::Attack {
            target_id: 0,
            monster_id: Some(monster.id),
            segment_id: seg.map(|s| s.id),
        },
        movement,
        ..Default::default()
    }
}

fn select_target_segment<'a>(
    participant: &Participant,
    monster: &'a MonsterData,
    profile: &AiProfileConfig,
) -> Option<&'a MonsterSegment> {
    let alive: Vec<&MonsterSegment> = monster
        .segments
        .iter()
        .filter(|s| s.status != SegmentStatus::Destroyed)
        .collect();
    if alive.is_empty() {
        return None;
    }

    // Aggressive profiles finish off damaged segments.
    if profile.target_strategy == "weakest" {
        let damaged: Vec<&&MonsterSegment> = alive
            .iter()
            .filter(|s| s.status == SegmentStatus::Damaged)
            .collect();
        if let Some(seg) = damaged.iter().min_by_key(|s| s.current_hp) {
            return Some(**seg);
        }
    }

    // Mobility segments: pick the most damaged to collapse the monster.
    let mobility: Vec<&&MonsterSegment> = alive
        .iter()
        .filter(|s| s.required_for_mobility)
        .collect();
    if let Some(seg) = mobility.iter().min_by_key(|s| s.current_hp) {
        return Some(**seg);
    }

    find_closest_segment(participant, monster)
}

fn find_closest_segment<'a>(
    participant: &Participant,
    monster: &'a MonsterData,
) -> Option<&'a MonsterSegment> {
    let pos = participant.position;
    monster
        .segments
        .iter()
        .filter(|s| s.status != SegmentStatus::Destroyed)
        .min_by_key(|s| {
            hex_grid::hex_distance(pos.x, pos.y, s.position.x, s.position.y) as i32
        })
}

fn should_attempt_mount(
    participant: &Participant,
    monster: &MonsterData,
    profile: &AiProfileConfig,
    rng: &mut impl Rng,
) -> bool {
    // Must be adjacent to some segment.
    if !adjacent_to_monster(participant, monster) {
        return false;
    }

    let mut likelihood = match profile.target_strategy.as_str() {
        "weakest" => 0.8_f32,
        "closest" => 0.5,
        "threat" => 0.4,
        "random" => 0.2,
        _ => 0.5,
    };

    // Berserker-ish profile (flee_threshold 0.0).
    if profile.flee_threshold == 0.0 {
        likelihood = 0.95;
    }

    let hp_pct = participant.hp_percent();
    if hp_pct < 0.7 {
        likelihood *= hp_pct;
    }

    rng.gen::<f32>() < likelihood
}

fn should_cling(
    _state: &FightState,
    participant: &Participant,
    monster: &MonsterData,
    profile: &AiProfileConfig,
) -> bool {
    if participant.hp_percent() < 0.4 {
        return true;
    }

    if profile.defend_weight > 0.4 {
        let mounted_count = monster
            .mount_states
            .iter()
            .filter(|ms| {
                matches!(
                    ms.mount_status,
                    MountStatus::Mounted | MountStatus::Climbing | MountStatus::AtWeakPoint
                )
            })
            .count() as i32;
        if mounted_count >= monster.shake_off_threshold {
            return true;
        }
    }

    false
}

fn adjacent_to_monster(participant: &Participant, monster: &MonsterData) -> bool {
    let pos = participant.position;
    monster.segments.iter().any(|s| {
        s.status != SegmentStatus::Destroyed
            && hex_grid::hex_distance(pos.x, pos.y, s.position.x, s.position.y) <= 1
    })
}

fn move_towards_monster(participant: &Participant, monster: &MonsterData) -> MovementAction {
    if let Some(seg) = find_closest_segment(participant, monster) {
        MovementAction::MoveToHex(seg.position)
    } else {
        MovementAction::StandStill
    }
}

fn move_away_from_monster(participant: &Participant, monster: &MonsterData) -> MovementAction {
    let pos = participant.position;
    let dx = pos.x - monster.center.x;
    let dy = pos.y - monster.center.y;
    let sx = if dx == 0 && dy == 0 { 1 } else { dx.signum() };
    let sy = dy.signum();
    let steps = 3_i32;
    MovementAction::MoveToHex(crate::types::hex::HexCoord {
        x: pos.x + sx * steps,
        y: pos.y + sy * steps * 2,
        z: pos.z,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::hex::HexCoord;
    use crate::types::monsters::{MountState, MountStatus};
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn aggressive() -> AiProfileConfig {
        AiProfileConfig {
            defend_weight: 0.1,
            flee_threshold: 0.1,
            target_strategy: "weakest".to_string(),
            ..Default::default()
        }
    }

    fn participant_at(id: u64, x: i32, y: i32, hp: u8) -> Participant {
        Participant {
            id,
            side: 0,
            current_hp: hp,
            max_hp: 6,
            position: HexCoord { x, y, z: 0 },
            ..Default::default()
        }
    }

    fn simple_monster() -> MonsterData {
        MonsterData {
            id: 100,
            status: MonsterStatus::Active,
            center: HexCoord { x: 5, y: 5, z: 0 },
            shake_off_threshold: 2,
            segments: vec![
                MonsterSegment {
                    id: 1,
                    is_weak_point: true,
                    position: HexCoord { x: 5, y: 5, z: 0 },
                    status: SegmentStatus::Healthy,
                    ..Default::default()
                },
                MonsterSegment {
                    id: 2,
                    required_for_mobility: true,
                    current_hp: 3,
                    max_hp: 10,
                    status: SegmentStatus::Damaged,
                    position: HexCoord { x: 6, y: 5, z: 0 },
                    ..Default::default()
                },
                MonsterSegment {
                    id: 3,
                    position: HexCoord { x: 4, y: 5, z: 0 },
                    status: SegmentStatus::Healthy,
                    ..Default::default()
                },
            ],
            ..Default::default()
        }
    }

    fn state_with(monster: MonsterData, participants: Vec<Participant>) -> FightState {
        FightState {
            monsters: vec![monster],
            participants,
            ..Default::default()
        }
    }

    #[test]
    fn critical_hp_mounted_dismounts() {
        let mut p = participant_at(1, 4, 5, 1);
        p.is_mounted = true;
        let monster = simple_monster();
        let action = handle_critical_hp(&p, &monster);
        assert!(matches!(action.movement, MovementAction::Dismount));
        assert!(matches!(action.main_action, MainAction::Defend));
    }

    #[test]
    fn adjacent_participant_can_attempt_mount() {
        let p = participant_at(1, 4, 5, 6);
        let monster = simple_monster();
        let profile = aggressive();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        // seed-deterministic but we just check no panic + adjacency gate
        let _ = should_attempt_mount(&p, &monster, &profile, &mut rng);
        assert!(adjacent_to_monster(&p, &monster));
    }

    #[test]
    fn non_adjacent_never_mounts() {
        let p = participant_at(1, 20, 20, 6);
        let monster = simple_monster();
        let profile = aggressive();
        let mut rng = ChaCha8Rng::seed_from_u64(1);
        assert!(!should_attempt_mount(&p, &monster, &profile, &mut rng));
    }

    #[test]
    fn target_segment_weakest_picks_damaged() {
        let p = participant_at(1, 4, 5, 6);
        let monster = simple_monster();
        let seg = select_target_segment(&p, &monster, &aggressive());
        // Damaged mobility segment wins for aggressive profile.
        assert_eq!(seg.map(|s| s.id), Some(2));
    }

    #[test]
    fn mounted_at_weak_point_attacks_weak_segment() {
        let mut p = participant_at(1, 5, 5, 6);
        p.is_mounted = true;
        let mut monster = simple_monster();
        monster.mount_states.push(MountState {
            participant_id: 1,
            monster_id: 100,
            segment_id: 1,
            mount_status: MountStatus::AtWeakPoint,
            climb_progress: 10,
            is_at_weak_point: true,
        });
        let state = state_with(monster, vec![p.clone()]);
        let action = plan_mounted_actions(&state, &p, &state.monsters[0], &aggressive());
        if let MainAction::Attack { monster_id, segment_id, .. } = action.main_action {
            assert_eq!(monster_id, Some(100));
            assert_eq!(segment_id, Some(1));
        } else {
            panic!("expected Attack action");
        }
    }

    #[test]
    fn mounted_climbing_cling_when_hurt() {
        let mut p = participant_at(1, 5, 5, 2); // ~33% hp
        p.is_mounted = true;
        let mut monster = simple_monster();
        monster.mount_states.push(MountState {
            participant_id: 1,
            monster_id: 100,
            segment_id: 1,
            mount_status: MountStatus::Climbing,
            climb_progress: 5,
            is_at_weak_point: false,
        });
        let state = state_with(monster, vec![p.clone()]);
        let action = plan_mounted_actions(&state, &p, &state.monsters[0], &aggressive());
        // HP 2/6 ~ 0.33 < 0.4 → cling.
        assert!(matches!(action.movement, MovementAction::Cling));
    }

    #[test]
    fn ground_attack_moves_towards_monster_when_not_ranged_only() {
        let p = participant_at(1, 0, 0, 6);
        let monster = simple_monster();
        let action = plan_ground_attack(&p, &monster, &aggressive());
        assert!(matches!(action.movement, MovementAction::MoveToHex(_)));
    }

    #[test]
    fn decide_defers_to_standard_without_monster() {
        let p = participant_at(1, 0, 0, 6);
        let state = FightState {
            participants: vec![p.clone()],
            monsters: vec![],
            ..Default::default()
        };
        let mut rng = ChaCha8Rng::seed_from_u64(0);
        let action = decide_monster_combat(&state, &p, &aggressive(), &mut rng);
        // No monster → fallback Pass action (caller fans out to standard AI).
        assert!(matches!(action.main_action, MainAction::Pass));
    }
}
