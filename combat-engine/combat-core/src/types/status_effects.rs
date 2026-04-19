use serde::{Deserialize, Serialize};

use super::weapons::DamageType;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActiveEffect {
    pub effect_name: String,
    pub effect_type: EffectType,
    pub remaining_rounds: i32,
    pub stack_count: u32,
    pub max_stacks: u32,
    pub stack_behavior: StackBehavior,
    pub flat_reduction: i32,
    pub flat_protection: i32,
    pub damage_types: Vec<DamageType>,
    pub dot_damage: Option<String>,
    pub dot_damage_type: Option<DamageType>,
    pub shield_hp: i32,
    pub value: i32,
    pub damage_mult: Option<f32>,
    #[serde(default)]
    pub healing_accumulator: f32,
    /// Source participant for taunt/fear/grapple effects (who is taunting us, etc.).
    #[serde(default)]
    pub source_id: Option<u64>,
    /// Participant ID this holder cannot target (sanctuary / targeting_restriction).
    /// Ruby: `StatusEffectService.cannot_target_ids` at
    /// status_effect_service.rb:583; enforced in `resolve_attack_target`.
    #[serde(default)]
    pub cannot_target_id: Option<u64>,
}

impl Default for ActiveEffect {
    fn default() -> Self {
        Self {
            effect_name: String::new(),
            effect_type: EffectType::Buff,
            remaining_rounds: 0,
            stack_count: 1,
            max_stacks: 1,
            stack_behavior: StackBehavior::Refresh,
            flat_reduction: 0,
            flat_protection: 0,
            damage_types: Vec::new(),
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EffectType {
    DamageReduction,
    Protection,
    Shield,
    DamageOverTime,
    Buff,
    Debuff,
    CrowdControl,
    Vulnerability,
    Regeneration,
    /// Prevents or slows movement (Ruby 'movement' with prone/slow/root mechanics).
    MovementBlock,
    /// Prevents main or tactical actions (Ruby 'action_restriction').
    ActionRestriction,
    /// Taunt / protection: redirects attacks to a forced target (source_id = taunter).
    TargetingRestriction,
    /// Forces AwayFrom movement away from source_id; attack penalty vs source.
    Fear,
    /// Forces StandStill; source_id is the grappler.
    Grapple,
    /// Scales heal_amount received (value = % modifier, e.g. 50 = +50%).
    HealingModifier,
    /// Incoming damage modifier stack.
    IncomingDamage,
    /// Outgoing damage modifier stack.
    OutgoingDamage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StackBehavior {
    Refresh,
    Stack,
    Duration,
    Ignore,
}

/// Blueprint for status effects that Rust can apply by name (e.g. poisoned,
/// intoxicated). Ruby's `StatusEffectService.apply_by_name` looks these up in
/// the `status_effects` DB table; Rust gets them pre-serialized so it can
/// apply statuses without DB access. Only a small allowlist is serialized
/// (the set Rust needs for on-hex-entry / hazard effects).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct StatusEffectTemplate {
    pub effect_name: String,
    pub effect_type: EffectType,
    pub default_duration_rounds: i32,
    pub stack_behavior: StackBehavior,
    pub max_stacks: u32,
    pub value: i32,
    pub dot_damage: Option<String>,
    pub dot_damage_type: Option<DamageType>,
}

impl Default for StatusEffectTemplate {
    fn default() -> Self {
        Self {
            effect_name: String::new(),
            effect_type: EffectType::Buff,
            default_duration_rounds: 0,
            stack_behavior: StackBehavior::Refresh,
            max_stacks: 1,
            value: 0,
            dot_damage: None,
            dot_damage_type: None,
        }
    }
}
