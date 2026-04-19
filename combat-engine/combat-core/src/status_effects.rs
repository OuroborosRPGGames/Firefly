use crate::types::fight_state::FightState;
use crate::types::status_effects::{ActiveEffect, EffectType, StackBehavior, StatusEffectTemplate};
use crate::types::weapons::DamageType;

/// Apply an effect to a participant's status_effects list.
/// Handles stacking behavior (refresh/stack/duration/ignore).
pub fn apply_effect(effects: &mut Vec<ActiveEffect>, new_effect: ActiveEffect) {
    if let Some(existing) = effects
        .iter_mut()
        .find(|e| e.effect_name == new_effect.effect_name)
    {
        match new_effect.stack_behavior {
            StackBehavior::Refresh => {
                existing.remaining_rounds = new_effect.remaining_rounds;
            }
            StackBehavior::Stack => {
                if existing.stack_count < existing.max_stacks {
                    existing.stack_count += 1;
                }
                existing.remaining_rounds = new_effect.remaining_rounds;
            }
            StackBehavior::Duration => {
                existing.remaining_rounds += new_effect.remaining_rounds;
            }
            StackBehavior::Ignore => {
                // Do nothing
            }
        }
    } else {
        effects.push(new_effect);
    }
}

/// Tick all effect durations down by 1.
pub fn tick_effects(effects: &mut Vec<ActiveEffect>) {
    for effect in effects.iter_mut() {
        effect.remaining_rounds -= 1;
    }
}

/// Remove expired effects (remaining_rounds <= 0).
/// Returns names of expired effects for event generation.
pub fn expire_effects(effects: &mut Vec<ActiveEffect>) -> Vec<String> {
    let mut expired = Vec::new();
    effects.retain(|e| {
        if e.remaining_rounds <= 0 {
            expired.push(e.effect_name.clone());
            false
        } else {
            true
        }
    });
    expired
}

/// Calculate total flat damage reduction for a damage type.
/// Sums all DamageReduction effects that match the type, multiplied by stack_count.
/// An effect with empty damage_types applies to all types.
pub fn flat_damage_reduction(effects: &[ActiveEffect], damage_type: &DamageType) -> i32 {
    effects
        .iter()
        .filter(|e| e.effect_type == EffectType::DamageReduction)
        .filter(|e| e.damage_types.is_empty() || e.damage_types.contains(damage_type))
        .map(|e| e.flat_reduction * e.stack_count as i32)
        .sum()
}

/// Calculate total protection for a damage type.
/// Same logic as damage_reduction but for Protection effects, applied
/// differently in the defense pipeline (after per-attacker reduction).
pub fn overall_protection(effects: &[ActiveEffect], damage_type: &DamageType) -> i32 {
    effects
        .iter()
        .filter(|e| e.effect_type == EffectType::Protection)
        .filter(|e| e.damage_types.is_empty() || e.damage_types.contains(damage_type))
        .map(|e| e.flat_protection * e.stack_count as i32)
        .sum()
}

/// Get universal protection (effects that apply to ALL damage types).
/// These are Protection effects with empty `damage_types` (no type restriction).
/// Used for mixed-type protection split: universal applies once across all types.
pub fn universal_protection(effects: &[ActiveEffect]) -> i32 {
    effects
        .iter()
        .filter(|e| e.effect_type == EffectType::Protection && e.damage_types.is_empty())
        .map(|e| e.flat_protection * e.stack_count as i32)
        .sum()
}

/// Absorb damage with shields. Modifies shield_hp in-place.
/// Multiple shields absorb in order. Depleted shields are removed.
/// Returns remaining damage after absorption.
pub fn shield_absorb(effects: &mut Vec<ActiveEffect>, damage: i32) -> i32 {
    let mut remaining = damage;
    for effect in effects.iter_mut() {
        if effect.effect_type == EffectType::Shield && effect.shield_hp > 0 && remaining > 0 {
            let absorbed = remaining.min(effect.shield_hp);
            effect.shield_hp -= absorbed;
            remaining -= absorbed;
        }
    }
    // Remove depleted shields
    effects.retain(|e| !(e.effect_type == EffectType::Shield && e.shield_hp <= 0));
    remaining
}

/// Get the damage type multiplier from vulnerability effects.
/// Returns the product of all matching damage_mult values. Default 1.0.
pub fn damage_type_multiplier(effects: &[ActiveEffect], damage_type: &DamageType) -> f32 {
    let mut mult = 1.0f32;
    for effect in effects {
        if effect.effect_type == EffectType::Vulnerability {
            if effect.damage_types.is_empty() || effect.damage_types.contains(damage_type) {
                if let Some(dm) = effect.damage_mult {
                    mult *= dm;
                }
            }
        }
    }
    mult
}

/// Check if participant has a named effect.
pub fn has_effect(effects: &[ActiveEffect], name: &str) -> bool {
    effects.iter().any(|e| e.effect_name == name)
}

/// Check if participant has a specific effect type.
pub fn has_effect_type(effects: &[ActiveEffect], effect_type: EffectType) -> bool {
    effects.iter().any(|e| e.effect_type == effect_type)
}

/// Remove the first effect matching the given name. Returns true if found and removed.
/// Used for combo abilities that consume a status effect on the target.
pub fn remove_effect_by_name(effects: &mut Vec<ActiveEffect>, name: &str) -> bool {
    if let Some(idx) = effects.iter().position(|e| e.effect_name == name) {
        effects.remove(idx);
        true
    } else {
        false
    }
}

/// True if any MovementBlock effect is active — participant cannot move.
/// Mirrors Ruby `StatusEffect#blocks_movement?` (status_effect.rb:65), which
/// only matches `effect_type == 'movement'` with `can_move: false` in mechanics —
/// NOT grapple. Ruby's combat_resolution_service never checks grapple for
/// movement gating, so Rust must not either.
pub fn is_movement_blocked(effects: &[ActiveEffect]) -> bool {
    effects.iter().any(|e| matches!(e.effect_type, EffectType::MovementBlock))
}

/// True if any ActionRestriction/CrowdControl effect is active — participant cannot
/// take main or tactical actions. Mirrors Ruby status_effect_service.rb:534.
pub fn is_action_restricted(effects: &[ActiveEffect]) -> bool {
    effects.iter().any(|e| {
        matches!(e.effect_type, EffectType::ActionRestriction | EffectType::CrowdControl)
    })
}

/// Forced target id from TargetingRestriction (taunt) effects.
/// Returns the source_id of the most-recent taunter. Ruby: must_target() line 558.
pub fn forced_target_from_taunt(effects: &[ActiveEffect]) -> Option<u64> {
    effects.iter()
        .rev()
        .find(|e| e.effect_type == EffectType::TargetingRestriction)
        .and_then(|e| e.source_id)
}

/// Collect all participant IDs this effect holder cannot target (sanctuary /
/// targeting_restriction). Ruby mirror:
/// `StatusEffectService.cannot_target_ids` (status_effect_service.rb:583).
pub fn cannot_target_ids(effects: &[ActiveEffect]) -> Vec<u64> {
    effects
        .iter()
        .filter(|e| e.effect_type == EffectType::TargetingRestriction)
        .filter_map(|e| e.cannot_target_id)
        .collect()
}

/// Source of active Fear effect. Ruby: fear_source() line 605.
pub fn fear_source(effects: &[ActiveEffect]) -> Option<u64> {
    effects.iter()
        .find(|e| e.effect_type == EffectType::Fear)
        .and_then(|e| e.source_id)
}

/// Attack penalty from fear (Ruby: fear_attack_penalty status_effect_service.rb:617).
/// Penalty is carried in the effect's `value` field (populated by the Ruby
/// serializer from `mechanics['attack_penalty']`). Returns 0 if no Fear
/// effect is present. Caller should apply only when the feared attacker
/// targets the fear source.
pub fn fear_attack_penalty(effects: &[ActiveEffect]) -> i32 {
    effects.iter()
        .find(|e| e.effect_type == EffectType::Fear)
        .map(|e| e.value)
        .unwrap_or(0)
}

/// Source of active Grapple (the grappler). Ruby: grappler_for() line 642.
pub fn grappler(effects: &[ActiveEffect]) -> Option<u64> {
    effects.iter()
        .find(|e| e.effect_type == EffectType::Grapple)
        .and_then(|e| e.source_id)
}

/// Look up a StatusEffectTemplate by effect_name. Returns `None` if the
/// template wasn't serialized (e.g. missing DB row).
pub fn find_template<'a>(
    templates: &'a [StatusEffectTemplate],
    name: &str,
) -> Option<&'a StatusEffectTemplate> {
    templates.iter().find(|t| t.effect_name == name)
}

/// Apply a named status effect to a participant if not already present.
/// Mirrors Ruby `StatusEffectService.apply_by_name` + `apply_poisoned` /
/// `apply_intoxicated` guard: returns early if the participant already has
/// the named effect (no refresh). Duration is `template.default + wet_bonus`
/// where `wet_bonus = 2` when the participant is currently `wet` AND the
/// effect being applied is poisoned or intoxicated
/// (Ruby `fight_hex_effect_service.rb:330-331, 344-345`).
pub fn apply_status_by_name(
    state: &mut FightState,
    participant_id: u64,
    effect_name: &str,
) -> bool {
    let template = match find_template(&state.status_effect_templates, effect_name) {
        Some(t) => t.clone(),
        None => return false,
    };

    let participant = match state.participants.iter_mut().find(|p| p.id == participant_id) {
        Some(p) => p,
        None => return false,
    };

    if has_effect(&participant.status_effects, effect_name) {
        return false;
    }

    let wet_bonus = if matches!(effect_name, "poisoned" | "intoxicated")
        && has_effect(&participant.status_effects, "wet")
    {
        2
    } else {
        0
    };

    let effect = ActiveEffect {
        effect_name: template.effect_name.clone(),
        effect_type: template.effect_type,
        remaining_rounds: template.default_duration_rounds + wet_bonus,
        stack_count: 1,
        max_stacks: template.max_stacks.max(1),
        stack_behavior: template.stack_behavior,
        flat_reduction: 0,
        flat_protection: 0,
        damage_types: Vec::new(),
        dot_damage: template.dot_damage.clone(),
        dot_damage_type: template.dot_damage_type,
        shield_hp: 0,
        value: template.value,
        damage_mult: None,
        healing_accumulator: 0.0,
        source_id: None,
        cannot_target_id: None,
    };

    apply_effect(&mut participant.status_effects, effect);
    true
}

/// Healing received multiplier from HealingModifier effects.
/// Ruby: healing_modifier() line 749. value is a percent (e.g., 50 = +50% → 1.5).
pub fn healing_scalar(effects: &[ActiveEffect]) -> f32 {
    let mut scalar = 1.0f32;
    for e in effects {
        if e.effect_type == EffectType::HealingModifier {
            scalar *= 1.0 + (e.value as f32 / 100.0);
        }
    }
    scalar.max(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Participant;

    /// Helper to build an ActiveEffect with sensible defaults, overridden as needed.
    fn make_effect(
        name: &str,
        effect_type: EffectType,
        stack_behavior: StackBehavior,
        remaining_rounds: i32,
    ) -> ActiveEffect {
        ActiveEffect {
            effect_name: name.to_string(),
            effect_type,
            remaining_rounds,
            stack_count: 1,
            max_stacks: 3,
            stack_behavior,
            flat_reduction: 0,
            flat_protection: 0,
            damage_types: vec![],
            dot_damage: None,
            dot_damage_type: None,
            shield_hp: 0,
            value: 0,
            damage_mult: None,
            healing_accumulator: 0.0,
            source_id: None,
            cannot_target_id: None,
        }
    }

    // --- apply_effect tests ---

    #[test]
    fn test_apply_effect_new() {
        let mut effects = Vec::new();
        let effect = make_effect("shield_wall", EffectType::Buff, StackBehavior::Refresh, 3);
        apply_effect(&mut effects, effect);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].effect_name, "shield_wall");
        assert_eq!(effects[0].remaining_rounds, 3);
    }

    #[test]
    fn test_apply_effect_refresh() {
        let mut effects = Vec::new();
        let effect = make_effect("shield_wall", EffectType::Buff, StackBehavior::Refresh, 3);
        apply_effect(&mut effects, effect);

        // Apply again with different duration -- should refresh
        let refresh = make_effect("shield_wall", EffectType::Buff, StackBehavior::Refresh, 5);
        apply_effect(&mut effects, refresh);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].remaining_rounds, 5);
    }

    #[test]
    fn test_apply_effect_stack() {
        let mut effects = Vec::new();
        let mut effect =
            make_effect("poison", EffectType::DamageOverTime, StackBehavior::Stack, 3);
        effect.max_stacks = 5;
        apply_effect(&mut effects, effect);
        assert_eq!(effects[0].stack_count, 1);

        let mut stack = make_effect("poison", EffectType::DamageOverTime, StackBehavior::Stack, 4);
        stack.max_stacks = 5;
        apply_effect(&mut effects, stack);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].stack_count, 2);
        assert_eq!(effects[0].remaining_rounds, 4); // duration refreshed
    }

    #[test]
    fn test_apply_effect_stack_max() {
        let mut effects = Vec::new();
        let mut effect =
            make_effect("poison", EffectType::DamageOverTime, StackBehavior::Stack, 3);
        effect.max_stacks = 2;
        effect.stack_count = 1;
        apply_effect(&mut effects, effect);

        // First stack -- goes from 1 to 2
        let mut s1 = make_effect("poison", EffectType::DamageOverTime, StackBehavior::Stack, 3);
        s1.max_stacks = 2;
        apply_effect(&mut effects, s1);
        assert_eq!(effects[0].stack_count, 2);

        // Second stack -- already at max, stays at 2
        let mut s2 = make_effect("poison", EffectType::DamageOverTime, StackBehavior::Stack, 3);
        s2.max_stacks = 2;
        apply_effect(&mut effects, s2);
        assert_eq!(effects[0].stack_count, 2);
    }

    #[test]
    fn test_apply_effect_duration() {
        let mut effects = Vec::new();
        let effect = make_effect("regen", EffectType::Regeneration, StackBehavior::Duration, 3);
        apply_effect(&mut effects, effect);
        assert_eq!(effects[0].remaining_rounds, 3);

        let extend = make_effect("regen", EffectType::Regeneration, StackBehavior::Duration, 2);
        apply_effect(&mut effects, extend);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].remaining_rounds, 5);
    }

    #[test]
    fn test_apply_effect_ignore() {
        let mut effects = Vec::new();
        let effect = make_effect("stun", EffectType::CrowdControl, StackBehavior::Ignore, 2);
        apply_effect(&mut effects, effect);
        assert_eq!(effects[0].remaining_rounds, 2);

        let ignored = make_effect("stun", EffectType::CrowdControl, StackBehavior::Ignore, 5);
        apply_effect(&mut effects, ignored);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].remaining_rounds, 2); // unchanged
    }

    // --- tick / expire tests ---

    #[test]
    fn test_tick_effects() {
        let mut effects = vec![
            make_effect("buff_a", EffectType::Buff, StackBehavior::Refresh, 3),
            make_effect("buff_b", EffectType::Buff, StackBehavior::Refresh, 1),
        ];
        tick_effects(&mut effects);
        assert_eq!(effects[0].remaining_rounds, 2);
        assert_eq!(effects[1].remaining_rounds, 0);
    }

    #[test]
    fn test_expire_effects() {
        let mut effects = vec![
            make_effect("active", EffectType::Buff, StackBehavior::Refresh, 2),
            make_effect("expiring", EffectType::Debuff, StackBehavior::Refresh, 0),
            make_effect("also_expiring", EffectType::Debuff, StackBehavior::Refresh, -1),
        ];
        let expired = expire_effects(&mut effects);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].effect_name, "active");
        assert_eq!(expired.len(), 2);
        assert!(expired.contains(&"expiring".to_string()));
        assert!(expired.contains(&"also_expiring".to_string()));
    }

    // --- damage reduction tests ---

    #[test]
    fn test_flat_damage_reduction_matching_type() {
        let mut effect = make_effect(
            "fire_ward",
            EffectType::DamageReduction,
            StackBehavior::Refresh,
            5,
        );
        effect.flat_reduction = 10;
        effect.damage_types = vec![DamageType::Fire];

        let effects = vec![effect];
        assert_eq!(flat_damage_reduction(&effects, &DamageType::Fire), 10);
        assert_eq!(flat_damage_reduction(&effects, &DamageType::Ice), 0);
    }

    #[test]
    fn test_flat_damage_reduction_all_types() {
        let mut effect = make_effect(
            "armor",
            EffectType::DamageReduction,
            StackBehavior::Refresh,
            5,
        );
        effect.flat_reduction = 5;
        effect.damage_types = vec![]; // empty = all types

        let effects = vec![effect];
        assert_eq!(flat_damage_reduction(&effects, &DamageType::Physical), 5);
        assert_eq!(flat_damage_reduction(&effects, &DamageType::Fire), 5);
        assert_eq!(flat_damage_reduction(&effects, &DamageType::Lightning), 5);
    }

    #[test]
    fn test_flat_damage_reduction_stacks() {
        let mut effect = make_effect(
            "armor",
            EffectType::DamageReduction,
            StackBehavior::Stack,
            5,
        );
        effect.flat_reduction = 4;
        effect.stack_count = 3;

        let effects = vec![effect];
        assert_eq!(flat_damage_reduction(&effects, &DamageType::Physical), 12); // 4 * 3
    }

    // --- protection tests ---

    #[test]
    fn test_overall_protection() {
        let mut prot1 = make_effect(
            "divine_shield",
            EffectType::Protection,
            StackBehavior::Refresh,
            5,
        );
        prot1.flat_protection = 8;
        prot1.damage_types = vec![DamageType::Holy];

        let mut prot2 = make_effect(
            "general_ward",
            EffectType::Protection,
            StackBehavior::Refresh,
            5,
        );
        prot2.flat_protection = 3;
        prot2.damage_types = vec![]; // all types

        let effects = vec![prot1, prot2];
        assert_eq!(overall_protection(&effects, &DamageType::Holy), 11); // 8 + 3
        assert_eq!(overall_protection(&effects, &DamageType::Fire), 3); // only general_ward
    }

    // --- shield tests ---

    #[test]
    fn test_shield_absorb_partial() {
        let mut shield = make_effect(
            "magic_barrier",
            EffectType::Shield,
            StackBehavior::Refresh,
            5,
        );
        shield.shield_hp = 20;

        let mut effects = vec![shield];
        let remaining = shield_absorb(&mut effects, 12);
        assert_eq!(remaining, 0);
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].shield_hp, 8);
    }

    #[test]
    fn test_shield_absorb_depletes() {
        let mut shield = make_effect(
            "magic_barrier",
            EffectType::Shield,
            StackBehavior::Refresh,
            5,
        );
        shield.shield_hp = 10;

        let mut effects = vec![shield];
        let remaining = shield_absorb(&mut effects, 25);
        assert_eq!(remaining, 15);
        assert!(effects.is_empty()); // shield removed
    }

    #[test]
    fn test_shield_absorb_multiple() {
        let mut shield1 = make_effect(
            "barrier_1",
            EffectType::Shield,
            StackBehavior::Refresh,
            5,
        );
        shield1.shield_hp = 10;

        let mut shield2 = make_effect(
            "barrier_2",
            EffectType::Shield,
            StackBehavior::Refresh,
            5,
        );
        shield2.shield_hp = 15;

        let mut effects = vec![shield1, shield2];
        let remaining = shield_absorb(&mut effects, 18);
        assert_eq!(remaining, 0);
        assert_eq!(effects.len(), 1); // first shield depleted, second survives
        assert_eq!(effects[0].effect_name, "barrier_2");
        assert_eq!(effects[0].shield_hp, 7); // 15 - 8
    }

    // --- vulnerability / damage_mult tests ---

    #[test]
    fn test_damage_type_multiplier_vulnerable() {
        let mut vuln = make_effect(
            "fire_vuln",
            EffectType::Vulnerability,
            StackBehavior::Refresh,
            5,
        );
        vuln.damage_mult = Some(2.0);
        vuln.damage_types = vec![DamageType::Fire];

        let effects = vec![vuln];
        let mult = damage_type_multiplier(&effects, &DamageType::Fire);
        assert!((mult - 2.0).abs() < f32::EPSILON);
    }

    #[test]
    fn test_damage_type_multiplier_no_effect() {
        let effects: Vec<ActiveEffect> = vec![];
        let mult = damage_type_multiplier(&effects, &DamageType::Physical);
        assert!((mult - 1.0).abs() < f32::EPSILON);
    }

    // --- has_effect tests ---

    #[test]
    fn test_has_effect() {
        let effects = vec![make_effect(
            "shield_wall",
            EffectType::Buff,
            StackBehavior::Refresh,
            3,
        )];
        assert!(has_effect(&effects, "shield_wall"));
        assert!(!has_effect(&effects, "nonexistent"));
    }

    #[test]
    fn test_has_effect_type() {
        let effects = vec![make_effect(
            "shield_wall",
            EffectType::Buff,
            StackBehavior::Refresh,
            3,
        )];
        assert!(has_effect_type(&effects, EffectType::Buff));
        assert!(!has_effect_type(&effects, EffectType::Debuff));
    }

    // --- apply_status_by_name tests (Phase 8c) ---

    fn make_template(name: &str, effect_type: EffectType, duration: i32) -> StatusEffectTemplate {
        StatusEffectTemplate {
            effect_name: name.to_string(),
            effect_type,
            default_duration_rounds: duration,
            stack_behavior: StackBehavior::Refresh,
            max_stacks: 1,
            value: 0,
            dot_damage: None,
            dot_damage_type: None,
        }
    }

    #[test]
    fn apply_status_by_name_dangling_and_oil_slicked_succeed() {
        // Ruby parity: both templates must ship to Rust so interactive_objects
        // apply_status_with_event("dangling") / ("oil_slicked") actually lands
        // an effect instead of no-op'ing.
        let mut state = FightState {
            participants: vec![Participant {
                id: 1,
                ..Default::default()
            }],
            status_effect_templates: vec![
                make_template("dangling", EffectType::ActionRestriction, 1),
                make_template("oil_slicked", EffectType::Debuff, 99),
            ],
            ..Default::default()
        };

        assert!(apply_status_by_name(&mut state, 1, "dangling"));
        assert!(apply_status_by_name(&mut state, 1, "oil_slicked"));

        let effects = &state.participants[0].status_effects;
        assert!(has_effect(effects, "dangling"));
        assert!(has_effect(effects, "oil_slicked"));

        let dangling = effects.iter().find(|e| e.effect_name == "dangling").unwrap();
        assert_eq!(dangling.remaining_rounds, 1);
        let oil = effects.iter().find(|e| e.effect_name == "oil_slicked").unwrap();
        assert_eq!(oil.remaining_rounds, 99);
    }

    #[test]
    fn apply_status_by_name_fails_when_template_missing() {
        let mut state = FightState {
            participants: vec![Participant {
                id: 1,
                ..Default::default()
            }],
            status_effect_templates: vec![],
            ..Default::default()
        };
        assert!(!apply_status_by_name(&mut state, 1, "dangling"));
        assert!(state.participants[0].status_effects.is_empty());
    }

    // --- cannot_target_ids (Phase 8e) ---

    #[test]
    fn cannot_target_ids_reads_targeting_restriction_field() {
        let mut sanctuary =
            make_effect("sanctuary", EffectType::TargetingRestriction, StackBehavior::Refresh, 3);
        sanctuary.cannot_target_id = Some(42);

        let other_taunt =
            make_effect("taunt", EffectType::TargetingRestriction, StackBehavior::Refresh, 1);
        // taunt uses source_id, not cannot_target_id — should be ignored here
        let effects = vec![sanctuary, other_taunt];
        assert_eq!(cannot_target_ids(&effects), vec![42]);
    }

    #[test]
    fn cannot_target_ids_empty_without_restriction() {
        let effects = vec![make_effect(
            "shield_wall",
            EffectType::Buff,
            StackBehavior::Refresh,
            3,
        )];
        assert!(cannot_target_ids(&effects).is_empty());
    }
}
