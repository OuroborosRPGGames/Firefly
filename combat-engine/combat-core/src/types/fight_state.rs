use serde::{Deserialize, Serialize};

use super::config::CombatConfig;
use super::events::CombatEvent;
use super::hex::HexMap;
use super::interactive::{FightHexOverlay, InteractiveObject};
use super::monsters::MonsterData;
use super::participant::Participant;
use super::status_effects::StatusEffectTemplate;
use super::wall_mask::WallMask;
use super::weapons::DamageType;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct FightState {
    pub round: u32,
    pub fight_mode: FightMode,
    pub participants: Vec<Participant>,
    pub hex_map: HexMap,
    pub observer_effects: Vec<ObserverEffect>,
    pub config: CombatConfig,
    pub monsters: Vec<MonsterData>,
    /// Placed interactive objects (water_barrel, oil_barrel, munitions_crate,
    /// vase, ...). Ruby model: BattleMapElement.
    #[serde(default)]
    pub interactive_objects: Vec<InteractiveObject>,
    /// Per-fight overlay hexes for hazards + environmental effects (oil,
    /// sharp_ground, fire, puddle, long_fall, open_window). Ruby model: FightHex.
    /// `id == 0` marks rows created during round resolution that the Ruby
    /// writeback layer must insert.
    #[serde(default)]
    pub fight_hexes: Vec<FightHexOverlay>,
    /// RoomHex positions with `hex_type == 'window'`. Needed for the window-break
    /// tactic, which targets a RoomHex directly rather than a BattleMapElement.
    #[serde(default)]
    pub window_positions: Vec<(i32, i32)>,
    /// Blueprints for status effects that Rust can apply by name (poisoned /
    /// intoxicated / wet / on_fire). Serialized from Ruby's `status_effects`
    /// table so on-hex-entry and hazard triggers can instantiate ActiveEffects
    /// without DB access.
    #[serde(default)]
    pub status_effect_templates: Vec<StatusEffectTemplate>,
    /// Decoded wall-mask pixel grid used for pixel-level LoS ray-casts.
    /// `None` for rooms without a wall mask — LoS falls back to the hex-level
    /// check. Ruby source: `WallMaskService` (wall_mask_service.rb).
    #[serde(default)]
    pub wall_mask: Option<WallMask>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FightMode {
    Normal,
    Spar,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ObserverEffect {
    pub effect_type: String,
    pub source_id: u64,
    pub target_id: u64,
    pub forced_target_id: u64,
    pub multiplier: f32,
    pub value: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoundResult {
    pub next_state: FightState,
    pub events: Vec<CombatEvent>,
    pub knockouts: Vec<u64>,
    pub fight_ended: bool,
    pub winner_side: Option<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CombatStyle {
    pub id: u64,
    pub name: String,
    pub bonus_type: Option<DamageType>,
    pub bonus_amount: i32,
    /// Attack-damage bonus added to `round_total` when the attacker swings a
    /// melee weapon. Ruby: `style_bonuses[:melee]` applied at
    /// combat_resolution_service.rb:2964-2969.
    #[serde(default)]
    pub melee_bonus: i32,
    /// Attack-damage bonus added to `round_total` when the attacker fires a
    /// ranged weapon. Ruby: `style_bonuses[:ranged]` applied at
    /// combat_resolution_service.rb:2964-2969.
    #[serde(default)]
    pub ranged_bonus: i32,
    pub vulnerability_type: Option<DamageType>,
    pub vulnerability_amount: f32,
    /// Shifts the 1-HP damage threshold up by this amount, making the style's
    /// user harder to wound with small hits. Ruby: style_bonuses[:threshold_1hp].
    #[serde(default)]
    pub threshold_1hp: i32,
    /// Shifts the 2-HP and 3-HP thresholds up. Ruby: style_bonuses[:threshold_2_3hp].
    #[serde(default)]
    pub threshold_2_3hp: i32,
}

impl Default for ObserverEffect {
    fn default() -> Self {
        Self {
            effect_type: String::new(),
            source_id: 0,
            target_id: 0,
            forced_target_id: 0,
            multiplier: 1.0,
            value: 0,
        }
    }
}

impl Default for FightState {
    fn default() -> Self {
        Self {
            round: 0,
            fight_mode: FightMode::Normal,
            participants: Vec::new(),
            hex_map: HexMap::default(),
            observer_effects: Vec::new(),
            config: CombatConfig::default(),
            monsters: Vec::new(),
            interactive_objects: Vec::new(),
            fight_hexes: Vec::new(),
            window_positions: Vec::new(),
            status_effect_templates: Vec::new(),
            wall_mask: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fight_state_default() {
        let state = FightState::default();
        assert_eq!(state.round, 0);
        assert_eq!(state.fight_mode, FightMode::Normal);
        assert!(state.participants.is_empty());
    }

    #[test]
    fn test_msgpack_roundtrip() {
        let state = FightState::default();
        let bytes = rmp_serde::to_vec(&state).expect("serialize");
        let restored: FightState = rmp_serde::from_slice(&bytes).expect("deserialize");
        assert_eq!(restored.round, state.round);
        assert_eq!(restored.fight_mode, state.fight_mode);
        assert!(restored.participants.is_empty());
    }
}
