use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Weapon {
    pub id: u64,
    pub name: String,
    pub dice_count: u32,
    pub dice_sides: u32,
    pub damage_type: DamageType,
    pub reach: u32,
    pub speed: u32,
    pub is_ranged: bool,
    pub range_hexes: Option<u32>,
    /// Maximum hex distance at which an attack can land. Ruby uses
    /// `weapon.pattern.range_in_hexes || 1` for melee (combat_ai_service.rb:576).
    /// `reach` above only controls segment-compression timing, not attack range.
    #[serde(default = "default_attack_range_hexes")]
    pub attack_range_hexes: u32,
    /// True when this is a synthetic unarmed fallback (no real weapon equipped).
    /// Ruby combat_resolution_service.rb:1165 classifies this as weapon_type=:unarmed,
    /// so rules gated on 'melee' (e.g. back_to_wall) must skip it.
    #[serde(default)]
    pub is_unarmed: bool,
}

fn default_attack_range_hexes() -> u32 {
    1
}

impl Default for Weapon {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            dice_count: 0,
            dice_sides: 0,
            damage_type: DamageType::default(),
            reach: 0,
            speed: 0,
            is_ranged: false,
            range_hexes: None,
            attack_range_hexes: 1,
            is_unarmed: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NaturalAttack {
    pub name: String,
    pub dice_count: u32,
    pub dice_sides: u32,
    pub damage_type: DamageType,
    pub reach: u32,
    pub is_ranged: bool,
    pub range_hexes: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DamageType {
    Physical,
    Fire,
    Ice,
    Lightning,
    Poison,
    Psychic,
    Holy,
    Dark,
    Wind,
    Earth,
    Water,
}

impl Default for DamageType {
    fn default() -> Self {
        Self::Physical
    }
}
