//! Observer-placed combat modifiers. Ruby parity: all reads flatten onto
//! the observed combatant, so `ObserverEffect.target_id` is the id of the
//! participant the observer is watching (the "observed"), and `source_id`
//! identifies the observer. Ruby `apply_observer_combat_modifiers`
//! (combat_resolution_service.rb:574) reads effects in two buckets:
//!   - `actor_effects`: effects where the actor is the observed
//!   - `target_effects`: effects where the attack's target is the observed
//!
//! Several modifiers are gated on `actor.is_npc` to preserve Ruby's
//! NPC-vs-PC asymmetry (aggro_boost, npc_damage_boost).

use crate::types::fight_state::ObserverEffect;

/// Check if a participant has a forced target override. Ruby retargets only
/// NPC attackers, so the caller supplies `is_npc` and we short-circuit here
/// rather than at each call site. Returns the forced target id if an
/// observer effect of type `"forced_target"` targets the participant.
pub fn forced_target(
    effects: &[ObserverEffect],
    participant_id: u64,
    participant_is_npc: bool,
) -> Option<u64> {
    if !participant_is_npc {
        return None;
    }
    effects
        .iter()
        .find(|e| e.effect_type == "forced_target" && e.target_id == participant_id)
        .map(|e| e.forced_target_id)
}

/// Calculate combined damage multiplier from observer effects.
///
/// Ruby parity (`combat_resolution_service.rb:582-624`):
/// - Actor bucket (effect observes the attacker):
///   - `damage_dealt_mult`: always applies
///   - `expose_targets`: unrelated bonus tracked in `expose_targets_bonus`
/// - Target bucket (effect observes the defender):
///   - `damage_dealt_mult`: applies only when actor is NPC ("npc_damage_boost")
///   - `damage_taken_mult`: always applies
///   - `block_damage`: always applies (×0.75)
///   - `aggro_boost`: applies only when actor is NPC (×1.25)
///   - `halve_damage_from`: ×0.5 when the effect also names the attacker as source
///
/// Multiple matching effects stack multiplicatively.
pub fn damage_multiplier(
    effects: &[ObserverEffect],
    attacker_id: u64,
    defender_id: u64,
    attacker_is_npc: bool,
) -> f32 {
    let mut mult = 1.0f32;
    for effect in effects {
        let observes_attacker = effect.target_id == attacker_id;
        let observes_defender = effect.target_id == defender_id;
        match effect.effect_type.as_str() {
            // Target bucket, always applies
            "halve_damage_from" if observes_defender && effect.source_id == attacker_id => {
                mult *= 0.5;
            }
            "block_damage" if observes_defender => {
                mult *= 0.75;
            }
            "damage_taken_mult" if observes_defender => {
                mult *= effect.multiplier;
            }
            // Target bucket, is_npc gated
            "aggro_boost" if observes_defender && attacker_is_npc => {
                mult *= 1.25;
            }
            "damage_dealt_mult" if observes_defender && attacker_is_npc => {
                // Ruby calls this "npc_damage_boost" (line 595-601).
                mult *= effect.multiplier;
            }
            // Actor bucket, always applies
            "damage_dealt_mult" if observes_attacker => {
                mult *= effect.multiplier;
            }
            _ => {}
        }
    }
    mult
}

/// Flat damage bonus from `expose_targets` effects observing the ATTACKER
/// (Ruby reads this from `actor_effects`, combat_resolution_service.rb:582).
/// +2 per matching effect.
pub fn expose_targets_bonus(effects: &[ObserverEffect], attacker_id: u64) -> i32 {
    effects
        .iter()
        .filter(|e| e.effect_type == "expose_targets" && e.target_id == attacker_id)
        .count() as i32
        * 2
}

/// Threat modifier from `aggro_boost` for AI target selection. Ruby flattens
/// this onto the potential target (the observed participant); higher-threat
/// targets draw NPC aggression. +5 per effect.
pub fn aggro_threat_modifier(effects: &[ObserverEffect], participant_id: u64) -> i32 {
    effects
        .iter()
        .filter(|e| e.effect_type == "aggro_boost" && e.target_id == participant_id)
        .count() as i32
        * 5
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::fight_state::ObserverEffect;

    fn effect(effect_type: &str, source_id: u64, target_id: u64) -> ObserverEffect {
        ObserverEffect {
            effect_type: effect_type.to_string(),
            source_id,
            target_id,
            forced_target_id: 0,
            multiplier: 1.0,
            value: 0,
        }
    }

    fn effect_with_forced(
        effect_type: &str,
        target_id: u64,
        forced_target_id: u64,
    ) -> ObserverEffect {
        ObserverEffect {
            effect_type: effect_type.to_string(),
            source_id: 0,
            target_id,
            forced_target_id,
            multiplier: 1.0,
            value: 0,
        }
    }

    fn effect_with_mult(
        effect_type: &str,
        source_id: u64,
        target_id: u64,
        multiplier: f32,
    ) -> ObserverEffect {
        ObserverEffect {
            effect_type: effect_type.to_string(),
            source_id,
            target_id,
            forced_target_id: 0,
            multiplier,
            value: 0,
        }
    }

    // --- forced_target (NPC-only gate) ---

    #[test]
    fn forced_target_applies_to_npc_only() {
        let effects = vec![effect_with_forced("forced_target", 1, 99)];
        assert_eq!(forced_target(&effects, 1, true), Some(99));
        assert_eq!(forced_target(&effects, 1, false), None);
    }

    #[test]
    fn forced_target_not_found() {
        let effects = vec![effect_with_forced("forced_target", 2, 99)];
        assert_eq!(forced_target(&effects, 1, true), None);
    }

    // --- aggro_boost (is_npc gated, observes DEFENDER) ---

    #[test]
    fn aggro_boost_applies_to_npc_attacker() {
        // Effect observes the defender (id=20). NPC attacker hits → ×1.25.
        let effects = vec![effect("aggro_boost", 0, 20)];
        let mult = damage_multiplier(&effects, 10, 20, true);
        assert!((mult - 1.25).abs() < f32::EPSILON);
    }

    #[test]
    fn aggro_boost_ignored_for_pc_attacker() {
        // Same setup but attacker is PC → no multiplier.
        let effects = vec![effect("aggro_boost", 0, 20)];
        let mult = damage_multiplier(&effects, 10, 20, false);
        assert!((mult - 1.0).abs() < f32::EPSILON);
    }

    // --- npc_damage_boost (target bucket damage_dealt_mult, is_npc gated) ---

    #[test]
    fn target_damage_dealt_mult_only_for_npc_attacker() {
        // Observer on defender (target_id=20) places damage_dealt_mult.
        let effects = vec![effect_with_mult("damage_dealt_mult", 0, 20, 1.5)];
        assert!((damage_multiplier(&effects, 10, 20, true) - 1.5).abs() < f32::EPSILON);
        assert!((damage_multiplier(&effects, 10, 20, false) - 1.0).abs() < f32::EPSILON);
    }

    // --- actor-bucket damage_dealt_mult (unconditional) ---

    #[test]
    fn actor_damage_dealt_mult_always_applies() {
        // Observer on attacker (target_id=10) places damage_dealt_mult.
        let effects = vec![effect_with_mult("damage_dealt_mult", 0, 10, 2.0)];
        assert!((damage_multiplier(&effects, 10, 20, true) - 2.0).abs() < f32::EPSILON);
        assert!((damage_multiplier(&effects, 10, 20, false) - 2.0).abs() < f32::EPSILON);
    }

    // --- block_damage (target bucket, unconditional) ---

    #[test]
    fn block_damage_unconditional() {
        let effects = vec![effect("block_damage", 0, 20)];
        assert!((damage_multiplier(&effects, 10, 20, true) - 0.75).abs() < f32::EPSILON);
        assert!((damage_multiplier(&effects, 10, 20, false) - 0.75).abs() < f32::EPSILON);
    }

    // --- damage_taken_mult (target bucket, unconditional) ---

    #[test]
    fn target_damage_taken_mult_unconditional() {
        let effects = vec![effect_with_mult("damage_taken_mult", 0, 20, 2.0)];
        assert!((damage_multiplier(&effects, 10, 20, false) - 2.0).abs() < f32::EPSILON);
    }

    // --- halve_damage_from ---

    #[test]
    fn halve_damage_from_requires_matching_source_and_target() {
        let effects = vec![effect("halve_damage_from", 10, 20)];
        assert!((damage_multiplier(&effects, 10, 20, false) - 0.5).abs() < f32::EPSILON);
        // Wrong attacker — no match.
        assert!((damage_multiplier(&effects, 99, 20, false) - 1.0).abs() < f32::EPSILON);
    }

    // --- expose_targets ---

    #[test]
    fn expose_targets_counts_observer_effects_on_attacker() {
        // Ruby reads from actor_effects (observer watches attacker).
        let effects = vec![
            effect("expose_targets", 1, 10),
            effect("expose_targets", 2, 10),
            effect("expose_targets", 3, 99), // different attacker
        ];
        assert_eq!(expose_targets_bonus(&effects, 10), 4);
    }

    #[test]
    fn expose_targets_zero_when_none_watch_attacker() {
        let effects = vec![effect("expose_targets", 0, 99)];
        assert_eq!(expose_targets_bonus(&effects, 10), 0);
    }

    // --- aggro_threat_modifier (unchanged) ---

    #[test]
    fn aggro_threat_modifier_counts_effects() {
        let effects = vec![
            effect("aggro_boost", 1, 10),
            effect("aggro_boost", 2, 10),
        ];
        assert_eq!(aggro_threat_modifier(&effects, 10), 10);
    }

    // --- stacking ---

    #[test]
    fn multiple_effects_stack_multiplicatively() {
        let effects = vec![
            effect("halve_damage_from", 10, 20), // 0.5
            effect("block_damage", 0, 20),       // 0.75
            effect("aggro_boost", 0, 20),        // 1.25 when is_npc
        ];
        let mult = damage_multiplier(&effects, 10, 20, true);
        let expected = 0.5 * 0.75 * 1.25;
        assert!((mult - expected).abs() < 0.001, "expected {}, got {}", expected, mult);
    }
}
