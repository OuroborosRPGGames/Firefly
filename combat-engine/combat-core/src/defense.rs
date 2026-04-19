use std::collections::HashMap;

use crate::status_effects;
use crate::types::fight_state::CombatStyle;
use crate::types::status_effects::ActiveEffect;
use crate::types::weapons::DamageType;

/// Result of applying the defense pipeline.
#[derive(Debug, Clone)]
pub struct DefenseResult {
    /// Final cumulative damage after all reductions (for threshold calculation).
    /// Uses f64 because Ruby accumulates per-attack float damage across hits.
    pub final_damage: f64,
    /// How much shields absorbed.
    pub shield_absorbed: i32,
    /// How much armor reduced (total across all attackers).
    pub armor_reduced: i32,
    /// How much qi aura reduced.
    pub qi_aura_reduced: i32,
    /// How much protection reduced.
    pub protection_reduced: i32,
    /// How much qi defense reduced.
    pub qi_defense_reduced: i32,
    /// Whether back-to-wall applies.
    pub back_to_wall: bool,
    /// Threshold shift from back-to-wall (3 if true, 0 if false).
    pub threshold_shift: i32,
}

/// Per-attacker damage entry (before defense pipeline).
#[derive(Debug, Clone)]
pub struct AttackDamage {
    pub attacker_id: u64,
    pub raw_damage: i32,
    pub damage_type: DamageType,
}

// ---------------------------------------------------------------------------
// Round-level cumulative damage tracking (matches Ruby's @round_state)
// ---------------------------------------------------------------------------

/// Tracks cumulative raw damage per defender across all hits in a round.
/// Ruby accumulates `raw_by_attacker` and `raw_by_attacker_type`, then
/// runs `calculate_effective_cumulative()` on each hit to determine the
/// effective damage after armor/qi-aura/protection/qi-defense.
#[derive(Debug, Clone)]
pub struct RoundDamageState {
    /// Per-attacker raw damage accumulation (before any defenses except shields).
    /// Uses f64 because Ruby's per-attack damage is float (round_total / attack_count)
    /// and the fractional parts must accumulate correctly across hits.
    pub raw_by_attacker: HashMap<u64, f64>,
    /// Per-(attacker, damage_type) raw damage accumulation.
    pub raw_by_attacker_type: HashMap<(u64, DamageType), f64>,
    /// Cumulative ability damage (bypasses armor/protection).
    pub ability_cumulative: i32,
    /// Cumulative DOT damage (bypasses all defenses except shields).
    pub dot_cumulative: i32,
    /// Total shield damage absorbed this round.
    pub shield_absorbed: i32,
    /// Qi defense roll total (set once per round from pre-rolls).
    pub qi_defense_total: i32,
}

impl RoundDamageState {
    pub fn new(qi_defense_total: i32) -> Self {
        Self {
            raw_by_attacker: HashMap::new(),
            raw_by_attacker_type: HashMap::new(),
            ability_cumulative: 0,
            dot_cumulative: 0,
            shield_absorbed: 0,
            qi_defense_total,
        }
    }

    /// Record a weapon attack hit (post-shield, pre-armor).
    /// Takes f64 because Ruby keeps per-attack damage as a float.
    pub fn accumulate_attack(&mut self, attacker_id: u64, damage_type: DamageType, raw_damage: f64) {
        *self.raw_by_attacker.entry(attacker_id).or_insert(0.0) += raw_damage;
        *self.raw_by_attacker_type.entry((attacker_id, damage_type)).or_insert(0.0) += raw_damage;
    }

    /// Record ability damage.
    pub fn accumulate_ability(&mut self, damage: i32) {
        self.ability_cumulative += damage;
    }

    /// Record DOT damage.
    pub fn accumulate_dot(&mut self, damage: i32) {
        self.dot_cumulative += damage;
    }
}

/// Calculate effective cumulative damage after all defenses, matching Ruby's
/// `calculate_effective_cumulative()` method.
///
/// This runs the full defense pipeline against the CUMULATIVE raw damage
/// from all hits in the round, not per-hit. Called after each new hit to
/// get the updated effective total for threshold calculation.
pub fn calculate_effective_cumulative(
    round_state: &RoundDamageState,
    qi_aura_active: bool,
    combat_style: Option<&CombatStyle>,
    effects: &[ActiveEffect],
) -> DefenseResult {
    // Step 1: Armor (flat_damage_reduction) per-attacker, per-damage-type
    // Uses f64 accumulators to preserve fractional per-attack damage across hits.
    // Ruby's cumulative damage is a float and threshold comparison uses the float
    // (e.g., 9.2 > 9 threshold = not a miss).
    let mut attack_after_armor = 0.0f64;
    let mut total_armor_reduced = 0i32;
    let mut post_armor_by_attacker: HashMap<u64, f64> = HashMap::new();
    let mut post_armor_by_type: HashMap<DamageType, f64> = HashMap::new();

    for (&(attacker_id, damage_type), &raw_damage) in &round_state.raw_by_attacker_type {
        let armor = status_effects::flat_damage_reduction(effects, &damage_type) as f64;
        let reduced = (raw_damage - armor).max(0.0);
        attack_after_armor += reduced;
        *post_armor_by_attacker.entry(attacker_id).or_insert(0.0) += reduced;
        *post_armor_by_type.entry(damage_type).or_insert(0.0) += reduced;
        total_armor_reduced += (raw_damage - reduced) as i32;
    }

    // Step 1.5: Qi Aura — flat reduction per individual attacker (after armor)
    let mut qi_aura_reduced = 0i32;
    if qi_aura_active {
        let qi_per = 5.0f64; // GameConfig::Tactics::QI_AURA_REDUCTION_PER_ATTACKER
        for (_attacker_id, &after_armor_amount) in &post_armor_by_attacker {
            let reduction = qi_per.min(after_armor_amount);
            qi_aura_reduced += reduction as i32;
            attack_after_armor -= reduction;
        }
        attack_after_armor = attack_after_armor.max(0.0);
    }

    // Step 1.75: Style defense/vulnerability
    if let Some(style) = combat_style {
        // Defense bonus
        if let Some(ref bonus_type) = style.bonus_type {
            let typed_damage: f64 = round_state.raw_by_attacker_type.iter()
                .filter(|&(&(_, dt), _)| dt == *bonus_type)
                .map(|(_, &v)| v)
                .sum();
            if typed_damage > 0.0 {
                let reduction = (style.bonus_amount as f64).min(attack_after_armor);
                attack_after_armor = (attack_after_armor - reduction).max(0.0);
            }
        }
        // Vulnerability
        if let Some(ref vuln_type) = style.vulnerability_type {
            let typed_damage: f64 = round_state.raw_by_attacker_type.iter()
                .filter(|&(&(_, dt), _)| dt == *vuln_type)
                .map(|(_, &v)| v)
                .sum();
            if typed_damage > 0.0 && attack_after_armor > 0.0 {
                attack_after_armor += style.vulnerability_amount as f64;
            }
        }
    }

    // Step 2: Protection — use actual damage types from round state.
    // Ruby (lines 238-260): single type = simple lookup; mixed types = separate
    // universal from type-specific to prevent double-counting.
    let damage_types: Vec<DamageType> = post_armor_by_type.keys().copied().collect();
    let (attack_after_protection, protection_reduced) = if damage_types.len() <= 1 {
        // Single damage type (or no damage): simple lookup
        let dt = damage_types.first().unwrap_or(&DamageType::Physical);
        let protection = status_effects::overall_protection(effects, dt) as f64;
        let after = (attack_after_armor - protection).max(0.0);
        (after, (attack_after_armor - after) as i32)
    } else {
        // Mixed damage types: separate universal from type-specific protection
        // Universal = effects with empty damage_types (match all types)
        let universal = status_effects::universal_protection(effects) as f64;

        let mut specific_applied = 0.0f64;
        for dt in &damage_types {
            let total_for_type = status_effects::overall_protection(effects, dt) as f64;
            let specific_for_type = (total_for_type - universal).max(0.0);
            let typed_damage = post_armor_by_type.get(dt).copied().unwrap_or(0.0);
            specific_applied += specific_for_type.min(typed_damage);
        }

        let after_specific = (attack_after_armor - specific_applied).max(0.0);
        let universal_applied = universal.min(after_specific);
        let total_protection = specific_applied + universal_applied;
        let after = (attack_after_armor - total_protection).max(0.0);
        (after, total_protection as i32)
    };

    // Step 2.5: Add ability damage (bypasses armor/protection)
    let combined = attack_after_protection + round_state.ability_cumulative.max(0) as f64;

    // Step 3: Qi Defense roll (reduces combined attack + ability damage)
    let qi_def = round_state.qi_defense_total as f64;
    let after_qi = if qi_def > 0.0 && combined > 0.0 {
        (combined - qi_def).max(0.0)
    } else {
        combined
    };
    let qi_defense_reduced = (combined - after_qi) as i32;

    // Step 4: DOT damage (bypasses all defenses)
    let effective = after_qi + round_state.dot_cumulative.max(0) as f64;

    DefenseResult {
        final_damage: effective,
        shield_absorbed: round_state.shield_absorbed,
        armor_reduced: total_armor_reduced,
        qi_aura_reduced,
        protection_reduced,
        qi_defense_reduced,
        back_to_wall: false, // set by caller
        threshold_shift: 0,  // set by caller
    }
}

/// Apply the full 9-step defense pipeline.
///
/// - `attack_damages`: per-attacker raw damage from weapon attacks
/// - `ability_damage`: damage from abilities (bypasses steps 2-6, reduced by step 8)
/// - `dot_damage`: damage from DOTs (bypasses steps 2-8, only shields block)
/// - `qi_defense_roll`: one roll per round from qi dice (reduces combined damage)
/// - `qi_aura_active`: whether the target is using Qi Aura tactic
/// - `combat_style`: target's active combat style (for vulnerability/defense)
/// - `back_to_wall`: whether the target is against a wall
/// - `effects`: target's current status effects (modified in-place for shield depletion)
pub fn apply_defense_pipeline(
    attack_damages: &[AttackDamage],
    ability_damage: i32,
    dot_damage: i32,
    qi_defense_roll: Option<i32>,
    qi_aura_active: bool,
    combat_style: Option<&CombatStyle>,
    back_to_wall: bool,
    effects: &mut Vec<ActiveEffect>,
) -> DefenseResult {
    let mut result = DefenseResult {
        final_damage: 0.0,
        shield_absorbed: 0,
        armor_reduced: 0,
        qi_aura_reduced: 0,
        protection_reduced: 0,
        qi_defense_reduced: 0,
        back_to_wall,
        threshold_shift: if back_to_wall { 3 } else { 0 },
    };

    let mut cumulative_attack_damage = 0i32;

    // Process each attacker's damage through steps 1-4
    for attack in attack_damages {
        let mut dmg = attack.raw_damage;

        // Step 1: Shield absorption (per-hit)
        if dmg > 0 {
            let before = dmg;
            dmg = status_effects::shield_absorb(effects, dmg);
            result.shield_absorbed += before - dmg;
        }

        // Step 2: Armor / damage_reduction (per-attacker, per-type)
        let armor = status_effects::flat_damage_reduction(effects, &attack.damage_type);
        if armor > 0 {
            let reduced = dmg.min(armor);
            dmg -= reduced;
            result.armor_reduced += reduced;
        }

        // Step 3: Qi Aura (-5 per attacker)
        if qi_aura_active && dmg > 0 {
            let qi_aura_reduction = dmg.min(5);
            dmg -= qi_aura_reduction;
            result.qi_aura_reduced += qi_aura_reduction;
        }

        // Step 4: Style defense/vulnerability
        if let Some(style) = combat_style {
            // Vulnerability: take MORE damage of this type
            if let Some(ref vuln_type) = style.vulnerability_type {
                if *vuln_type == attack.damage_type {
                    dmg += style.vulnerability_amount as i32;
                }
            }
            // Defense bonus: take LESS damage of the bonus type
            if let Some(ref bonus_type) = style.bonus_type {
                if *bonus_type == attack.damage_type {
                    dmg = (dmg - style.bonus_amount).max(0);
                }
            }
        }

        // Also apply vulnerability from status effects
        let vuln_mult = status_effects::damage_type_multiplier(effects, &attack.damage_type);
        if (vuln_mult - 1.0).abs() > f32::EPSILON {
            dmg = (dmg as f32 * vuln_mult) as i32;
        }

        cumulative_attack_damage += dmg.max(0);
    }

    // Step 5: Back-to-wall (threshold shift handled by caller when checking thresholds)
    // Just record it in the result

    // Step 6: Protection (cumulative, attack damage only)
    let protection = status_effects::overall_protection(effects, &DamageType::Physical);
    if protection > 0 && cumulative_attack_damage > 0 {
        let reduced = cumulative_attack_damage.min(protection);
        cumulative_attack_damage -= reduced;
        result.protection_reduced = reduced;
    }

    // Step 7: Ability damage injection (bypasses armor and protection)
    let mut combined = cumulative_attack_damage + ability_damage.max(0);

    // Step 8: Qi Defense roll (reduces combined attack + ability damage)
    if let Some(qi_def) = qi_defense_roll {
        if qi_def > 0 && combined > 0 {
            let reduced = combined.min(qi_def);
            combined -= reduced;
            result.qi_defense_reduced = reduced;
        }
    }

    // Step 9: DOT damage (bypasses everything except shields)
    // DOT shield absorption
    let mut dot_after_shield = dot_damage;
    if dot_after_shield > 0 {
        let before = dot_after_shield;
        dot_after_shield = status_effects::shield_absorb(effects, dot_after_shield);
        result.shield_absorbed += before - dot_after_shield;
    }
    combined += dot_after_shield.max(0);

    result.final_damage = combined as f64;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::status_effects::*;
    use crate::types::weapons::DamageType;

    fn make_attack(attacker_id: u64, damage: i32) -> AttackDamage {
        AttackDamage {
            attacker_id,
            raw_damage: damage,
            damage_type: DamageType::Physical,
        }
    }

    fn make_shield(hp: i32) -> ActiveEffect {
        ActiveEffect {
            effect_name: "shield".to_string(),
            effect_type: EffectType::Shield,
            shield_hp: hp,
            remaining_rounds: 5,
            stack_count: 1,
            max_stacks: 1,
            stack_behavior: StackBehavior::Refresh,
            ..Default::default()
        }
    }

    fn make_armor(reduction: i32) -> ActiveEffect {
        ActiveEffect {
            effect_name: "armor".to_string(),
            effect_type: EffectType::DamageReduction,
            flat_reduction: reduction,
            remaining_rounds: 5,
            stack_count: 1,
            max_stacks: 3,
            stack_behavior: StackBehavior::Stack,
            damage_types: vec![], // all types
            ..Default::default()
        }
    }

    fn make_protection(amount: i32) -> ActiveEffect {
        ActiveEffect {
            effect_name: "protected".to_string(),
            effect_type: EffectType::Protection,
            flat_protection: amount,
            remaining_rounds: 5,
            stack_count: 1,
            max_stacks: 1,
            stack_behavior: StackBehavior::Refresh,
            damage_types: vec![],
            ..Default::default()
        }
    }

    // Step 1: Shields
    #[test]
    fn test_shield_absorbs_attack() {
        let mut effects = vec![make_shield(10)];
        let result = apply_defense_pipeline(
            &[make_attack(1, 7)],
            0,
            0,
            None,
            false,
            None,
            false,
            &mut effects,
        );
        assert_eq!(result.shield_absorbed, 7);
        assert_eq!(result.final_damage, 0.0);
    }

    #[test]
    fn test_shield_partial_absorb() {
        let mut effects = vec![make_shield(5)];
        let result = apply_defense_pipeline(
            &[make_attack(1, 12)],
            0,
            0,
            None,
            false,
            None,
            false,
            &mut effects,
        );
        assert_eq!(result.shield_absorbed, 5);
        assert_eq!(result.final_damage, 7.0); // 12-5=7
    }

    // Step 2: Armor
    #[test]
    fn test_armor_reduces_damage() {
        let mut effects = vec![make_armor(3)];
        let result = apply_defense_pipeline(
            &[make_attack(1, 10)],
            0,
            0,
            None,
            false,
            None,
            false,
            &mut effects,
        );
        assert_eq!(result.armor_reduced, 3);
        assert_eq!(result.final_damage, 7.0);
    }

    // Step 3: Qi Aura
    #[test]
    fn test_qi_aura_reduces_per_attacker() {
        let mut effects = vec![];
        let attacks = vec![make_attack(1, 10), make_attack(2, 8)];
        let result =
            apply_defense_pipeline(&attacks, 0, 0, None, true, None, false, &mut effects);
        assert_eq!(result.qi_aura_reduced, 10); // -5 from each attacker
        assert_eq!(result.final_damage, 8.0); // (10-5)+(8-5) = 5+3 = 8
    }

    // Step 5: Back-to-wall
    #[test]
    fn test_back_to_wall_threshold_shift() {
        let mut effects = vec![];
        let result = apply_defense_pipeline(
            &[make_attack(1, 10)],
            0,
            0,
            None,
            false,
            None,
            true,
            &mut effects,
        );
        assert!(result.back_to_wall);
        assert_eq!(result.threshold_shift, 3);
    }

    // Step 6: Protection
    #[test]
    fn test_protection_reduces_cumulative() {
        let mut effects = vec![make_protection(5)];
        let result = apply_defense_pipeline(
            &[make_attack(1, 10), make_attack(2, 8)],
            0,
            0,
            None,
            false,
            None,
            false,
            &mut effects,
        );
        assert_eq!(result.protection_reduced, 5);
        assert_eq!(result.final_damage, 13.0); // 18-5=13
    }

    // Step 7: Ability damage injection
    #[test]
    fn test_ability_bypasses_armor_and_protection() {
        let mut effects = vec![make_armor(5), make_protection(5)];
        let result =
            apply_defense_pipeline(&[], 20, 0, None, false, None, false, &mut effects);
        // Ability damage bypasses armor (step 2) and protection (step 6)
        assert_eq!(result.final_damage, 20.0);
        assert_eq!(result.armor_reduced, 0);
        assert_eq!(result.protection_reduced, 0);
    }

    // Step 8: Qi Defense
    #[test]
    fn test_qi_defense_reduces_combined() {
        let mut effects = vec![];
        let result = apply_defense_pipeline(
            &[make_attack(1, 15)],
            5,
            0,
            Some(8),
            false,
            None,
            false,
            &mut effects,
        );
        // Combined = 15 + 5 = 20, qi defense = 8
        assert_eq!(result.qi_defense_reduced, 8);
        assert_eq!(result.final_damage, 12.0);
    }

    // Step 9: DOT bypasses everything except shields
    #[test]
    fn test_dot_bypasses_armor_protection_qi() {
        let mut effects = vec![make_armor(5), make_protection(5)];
        let result =
            apply_defense_pipeline(&[], 0, 10, Some(8), false, None, false, &mut effects);
        // DOT bypasses armor, protection, AND qi defense
        assert_eq!(result.final_damage, 10.0);
        assert_eq!(result.armor_reduced, 0);
        assert_eq!(result.protection_reduced, 0);
        assert_eq!(result.qi_defense_reduced, 0);
    }

    #[test]
    fn test_dot_blocked_by_shield() {
        let mut effects = vec![make_shield(6)];
        let result =
            apply_defense_pipeline(&[], 0, 10, None, false, None, false, &mut effects);
        assert_eq!(result.shield_absorbed, 6);
        assert_eq!(result.final_damage, 4.0); // 10-6=4
    }

    // Full pipeline test
    #[test]
    fn test_full_pipeline() {
        let mut effects = vec![make_shield(3), make_armor(2), make_protection(4)];
        let attacks = vec![make_attack(1, 20)];
        let result = apply_defense_pipeline(
            &attacks,
            5,
            3,
            Some(6),
            true,
            None,
            false,
            &mut effects,
        );
        // Step 1: 20 - 3 shield = 17
        // Step 2: 17 - 2 armor = 15
        // Step 3: 15 - 5 qi_aura = 10
        // Step 6: 10 - 4 protection = 6
        // Step 7: 6 + 5 ability = 11
        // Step 8: 11 - 6 qi_defense = 5
        // Step 9: 5 + 3 DOT = 8
        assert_eq!(result.final_damage, 8.0);
    }
}
