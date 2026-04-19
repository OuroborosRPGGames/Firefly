use crate::types::*;
use rand::Rng;

use super::ability_power;

/// Select the best usable ability for the AI participant using power ranking.
///
/// Returns `Some((ability_id, target_id))` if an ability passes its use_chance
/// roll and has a valid target. Abilities are ranked by tactical effectiveness
/// (power, AoE potential, execute/combo bonuses, vulnerability exploitation).
pub fn select_ability(
    participant: &Participant,
    enemies: &[&Participant],
    allies: &[&Participant],
    state: &FightState,
    rng: &mut impl Rng,
) -> Option<(u64, Option<u64>)> {
    if participant.abilities.is_empty() {
        return None;
    }

    // Get power-ranked ability scores (sorted best first)
    let scores = ability_power::rank_abilities(participant, enemies, allies, state);

    if scores.is_empty() {
        return None;
    }

    // For each scored option (best first): check use_chance roll
    for score in &scores {
        let ability = match participant.abilities.iter().find(|a| a.id == score.ability_id) {
            Some(a) => a,
            None => continue,
        };

        if rng.gen_range(0..100) < ability.use_chance {
            return Some((score.ability_id, score.target_id));
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    fn make_participant(id: u64, side: u8) -> Participant {
        Participant {
            id,
            side,
            ..Default::default()
        }
    }

    fn make_ability(id: u64, qi_cost: u32, use_chance: u32, target_type: TargetType) -> Ability {
        Ability {
            id,
            name: format!("ability_{}", id),
            qi_cost,
            use_chance,
            target_type,
            ..Default::default()
        }
    }

    #[test]
    fn test_no_abilities_returns_none() {
        let p = make_participant(1, 0);
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert!(select_ability(&p, &[], &[], &state, &mut rng).is_none());
    }

    #[test]
    fn test_ability_on_cooldown_skipped() {
        let mut p = make_participant(1, 0);
        p.abilities.push(make_ability(10, 0, 100, TargetType::Single));
        p.cooldowns.insert(10, 2); // on cooldown
        let e = make_participant(2, 1);
        let enemies: Vec<&Participant> = vec![&e];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert!(select_ability(&p, &enemies, &[], &state, &mut rng).is_none());
    }

    #[test]
    fn test_ability_too_expensive_skipped() {
        let mut p = make_participant(1, 0);
        p.qi_dice = 0.5; // available_qi_dice = 0
        p.abilities.push(make_ability(10, 1, 100, TargetType::Single));
        let e = make_participant(2, 1);
        let enemies: Vec<&Participant> = vec![&e];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert!(select_ability(&p, &enemies, &[], &state, &mut rng).is_none());
    }

    #[test]
    fn test_ability_use_chance_100_always_picked() {
        let mut p = make_participant(1, 0);
        p.abilities
            .push(make_ability(10, 0, 100, TargetType::Single));
        let e = make_participant(2, 1);
        let enemies: Vec<&Participant> = vec![&e];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = select_ability(&p, &enemies, &[], &state, &mut rng);
        assert_eq!(result, Some((10, Some(2))));
    }

    #[test]
    fn test_self_targeting_ability() {
        let mut p = make_participant(1, 0);
        p.abilities
            .push(make_ability(10, 0, 100, TargetType::Self_));
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = select_ability(&p, &[], &[], &state, &mut rng);
        assert_eq!(result, Some((10, Some(1))));
    }

    #[test]
    fn test_ally_targeting_ability() {
        let mut p = make_participant(1, 0);
        p.abilities.push(make_ability(10, 0, 100, TargetType::Ally));
        let ally = make_participant(3, 0);
        let allies: Vec<&Participant> = vec![&ally];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = select_ability(&p, &[], &allies, &state, &mut rng);
        assert_eq!(result, Some((10, Some(3))));
    }

    #[test]
    fn test_ally_targeting_no_allies_falls_back_to_self() {
        // Ruby `valid_targets_for_ability` returns `allies + [participant]`
        // (combat_ai_service.rb:461). With no other allies, self is selected.
        let mut p = make_participant(1, 0);
        p.abilities.push(make_ability(10, 0, 100, TargetType::Ally));
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = select_ability(&p, &[], &[], &state, &mut rng);
        assert_eq!(result, Some((10, Some(1))));
    }

    #[test]
    fn test_use_chance_0_never_picked() {
        let mut p = make_participant(1, 0);
        p.abilities
            .push(make_ability(10, 0, 0, TargetType::Single));
        let e = make_participant(2, 1);
        let enemies: Vec<&Participant> = vec![&e];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        assert!(select_ability(&p, &enemies, &[], &state, &mut rng).is_none());
    }

    #[test]
    fn test_cooldown_zero_is_usable() {
        let mut p = make_participant(1, 0);
        p.abilities
            .push(make_ability(10, 0, 100, TargetType::Single));
        p.cooldowns.insert(10, 0); // cooldown expired
        let e = make_participant(2, 1);
        let enemies: Vec<&Participant> = vec![&e];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = select_ability(&p, &enemies, &[], &state, &mut rng);
        assert_eq!(result, Some((10, Some(2))));
    }

    #[test]
    fn test_power_ranking_picks_stronger_ability() {
        let mut p = make_participant(1, 0);
        // Weak ability first in list
        let mut weak = make_ability(10, 0, 100, TargetType::Single);
        weak.base_damage_dice = Some("1d4".to_string());
        weak.damage_multiplier = 1.0;
        p.abilities.push(weak);

        // Strong ability second in list
        let mut strong = make_ability(11, 0, 100, TargetType::Single);
        strong.base_damage_dice = Some("3d10".to_string());
        strong.damage_multiplier = 2.0;
        p.abilities.push(strong);

        let e = make_participant(2, 1);
        let enemies: Vec<&Participant> = vec![&e];
        let state = FightState::default();
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = select_ability(&p, &enemies, &[], &state, &mut rng);
        // Should pick the stronger ability (id 11) due to power ranking
        assert_eq!(result.unwrap().0, 11);
    }
}
