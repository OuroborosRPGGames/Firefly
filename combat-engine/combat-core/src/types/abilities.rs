use serde::{Deserialize, Serialize};

use super::hex::Direction;
use super::weapons::DamageType;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Ability {
    pub id: u64,
    pub name: String,
    pub base_damage_dice: Option<String>,
    pub damage_modifier: i32,
    pub damage_multiplier: f32,
    pub damage_type: DamageType,
    pub damage_stat: Option<String>,
    pub target_type: TargetType,
    pub aoe_shape: Option<AoEShape>,
    pub aoe_radius: Option<u32>,
    pub aoe_length: Option<u32>,
    pub aoe_angle: Option<u32>,
    pub aoe_hits_allies: bool,
    pub range_hexes: u32,
    pub cooldown_rounds: u32,
    pub qi_cost: u32,
    pub health_cost: i32,
    pub is_healing: bool,
    pub lifesteal_max: Option<i32>,
    pub status_effects: Vec<AbilityStatusEffect>,
    pub has_chain: bool,
    pub chain_max_targets: u32,
    pub chain_range: u32,
    pub chain_damage_falloff: f32,
    pub chain_friendly_fire: bool,
    pub execute_threshold: Option<f32>,
    pub execute_effect: Option<ExecuteEffect>,
    pub has_forced_movement: bool,
    pub forced_movement: Option<ForcedMovement>,
    pub bypasses_resistances: bool,
    pub use_chance: u32,
    pub applies_prone: bool,
    pub apply_timing_coefficient: bool,
    pub activation_segment: Option<u32>,
    pub global_cooldown_rounds: u32,
    pub conditional_damage: Vec<ConditionalDamage>,
    pub combo_condition: Option<ComboCondition>,
    pub damage_types: Vec<DamageSplit>,
    pub status_duration_scaling: Option<u32>,
}

impl Default for Ability {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            base_damage_dice: None,
            damage_modifier: 0,
            damage_multiplier: 1.0,
            damage_type: DamageType::Physical,
            damage_stat: None,
            target_type: TargetType::Single,
            aoe_shape: None,
            aoe_radius: None,
            aoe_length: None,
            aoe_angle: None,
            aoe_hits_allies: false,
            range_hexes: 1,
            cooldown_rounds: 0,
            qi_cost: 0,
            health_cost: 0,
            is_healing: false,
            lifesteal_max: None,
            status_effects: Vec::new(),
            has_chain: false,
            chain_max_targets: 1,
            chain_range: 0,
            chain_damage_falloff: 1.0,
            chain_friendly_fire: false,
            execute_threshold: None,
            execute_effect: None,
            has_forced_movement: false,
            forced_movement: None,
            bypasses_resistances: false,
            use_chance: 100,
            applies_prone: false,
            apply_timing_coefficient: false,
            activation_segment: None,
            global_cooldown_rounds: 0,
            conditional_damage: Vec::new(),
            combo_condition: None,
            damage_types: Vec::new(),
            status_duration_scaling: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TargetType {
    Single,
    #[serde(rename = "Self")]
    Self_,
    Ally,
    Enemy,
    Circle,
    Cone,
    Line,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AoEShape {
    Circle,
    Cone,
    Line,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AbilityStatusEffect {
    pub effect_name: String,
    pub duration_rounds: u32,
    pub chance: f32,
    pub value: i32,
    pub damage_mult: Option<f32>,
    /// Minimum base roll required for this effect to apply.
    pub threshold: Option<i32>,
    /// Effect type from StatusEffect definition (e.g., "DamageReduction", "Protection").
    pub effect_type: Option<String>,
    pub flat_reduction: i32,
    pub flat_protection: i32,
    pub shield_hp: i32,
    /// DOT damage dice notation (e.g., "2d6").
    pub dot_damage: Option<String>,
    pub dot_damage_type: Option<String>,
    /// Damage type filter for the effect.
    pub damage_types: Vec<String>,
    /// Stack behavior from StatusEffect definition.
    pub stack_behavior: Option<String>,
    pub max_stacks: u32,
}

impl Default for AbilityStatusEffect {
    fn default() -> Self {
        Self {
            effect_name: String::new(),
            duration_rounds: 1,
            chance: 1.0,
            value: 0,
            damage_mult: None,
            threshold: None,
            effect_type: None,
            flat_reduction: 0,
            flat_protection: 0,
            shield_hp: 0,
            dot_damage: None,
            dot_damage_type: None,
            damage_types: Vec::new(),
            stack_behavior: None,
            max_stacks: 1,
        }
    }
}

/// Execute mechanic: triggered when target HP% <= execute_threshold.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ExecuteEffect {
    pub instant_kill: bool,
    pub damage_multiplier: Option<f32>,
}

impl Default for ExecuteEffect {
    fn default() -> Self {
        Self {
            instant_kill: false,
            damage_multiplier: None,
        }
    }
}

/// Conditional damage bonus: triggered when a condition is met.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ConditionalDamage {
    pub condition: String,
    pub bonus_dice: Option<String>,
    pub bonus_damage: Option<i32>,
    /// For target_has_status condition.
    pub status: Option<String>,
}

impl Default for ConditionalDamage {
    fn default() -> Self {
        Self {
            condition: String::new(),
            bonus_dice: None,
            bonus_damage: None,
            status: None,
        }
    }
}

/// Combo damage: bonus when target has a required status effect.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ComboCondition {
    pub requires_status: String,
    pub bonus_dice: Option<String>,
    pub consumes_status: bool,
}

impl Default for ComboCondition {
    fn default() -> Self {
        Self {
            requires_status: String::new(),
            bonus_dice: None,
            consumes_status: false,
        }
    }
}

/// Split damage: portion of total damage dealt as a specific type.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DamageSplit {
    pub damage_type: DamageType,
    /// Fraction of total damage (0.0-1.0), e.g., 0.5 = 50%.
    pub percent: f32,
}

/// Forced movement configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForcedMovement {
    pub direction: ForcedMovementDirection,
    pub distance: u32,
}

/// Direction for forced movement.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ForcedMovementDirection {
    Away,
    Toward,
    Compass(Direction),
}
