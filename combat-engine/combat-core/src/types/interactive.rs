//! Interactive-object model for element tactics (break / detonate / ignite).
//!
//! Mirrors Ruby's two parallel models:
//!   - `FightHex` (table `fight_hexes`) — per-fight overlay hexes for hazards
//!     and environmental effects (oil, sharp_ground, fire, puddle, long_fall,
//!     open_window). See `backend/app/models/fight_hex.rb`.
//!   - `BattleMapElement` (table `battle_map_elements`) — placed interactive
//!     objects (water_barrel, oil_barrel, munitions_crate, vase, ...). See
//!     `backend/app/models/battle_map_element.rb`.
//!
//! Element tactics (`FightHexEffectService`) transform these:
//!   - break: barrel/vase → spreads FightHex overlay to center + 6 neighbors
//!     and marks element `state='broken'`.
//!   - detonate: munitions_crate → ring damage + chain reactions; element
//!     state → 'detonated'.
//!   - ignite: oil FightHex → fire FightHex.

use serde::{Deserialize, Serialize};

use super::hex::HazardType;

/// Interactive-object kind. Mirrors Ruby `BattleMapElement::ELEMENT_TYPES`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ElementType {
    WaterBarrel,
    OilBarrel,
    MunitionsCrate,
    ToxicMushrooms,
    LotusPollen,
    Vase,
    CliffEdge,
}

impl Default for ElementType {
    fn default() -> Self {
        ElementType::Vase
    }
}

/// Interactive-object lifecycle state. Mirrors Ruby `BattleMapElement::STATES`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ElementState {
    Intact,
    Broken,
    Ignited,
    Detonated,
}

impl Default for ElementState {
    fn default() -> Self {
        ElementState::Intact
    }
}

/// A placed interactive object. Corresponds one-to-one with a row in the
/// Ruby `battle_map_elements` table.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct InteractiveObject {
    pub id: u64,
    pub element_type: ElementType,
    pub state: ElementState,
    pub hex_x: i32,
    pub hex_y: i32,
    /// Only populated for `ElementType::CliffEdge` (one of "north", "south",
    /// "east", "west"). None for all other element types.
    pub edge_side: Option<String>,
}

impl Default for InteractiveObject {
    fn default() -> Self {
        Self {
            id: 0,
            element_type: ElementType::Vase,
            state: ElementState::Intact,
            hex_x: 0,
            hex_y: 0,
            edge_side: None,
        }
    }
}

/// Kind of FightHex overlay. Mirrors Ruby `FightHex::HEX_TYPES`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FightHexType {
    Oil,
    SharpGround,
    Fire,
    Puddle,
    LongFall,
    OpenWindow,
}

impl Default for FightHexType {
    fn default() -> Self {
        FightHexType::Oil
    }
}

/// A per-fight overlay hex. Corresponds to a row in Ruby `fight_hexes`.
///
/// `id == 0` marks a row created during round resolution that Ruby must
/// insert into the DB during writeback (assigning a real DB id). Non-zero
/// ids are pre-existing rows Rust may mutate in place.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct FightHexOverlay {
    pub id: u64,
    pub hex_x: i32,
    pub hex_y: i32,
    pub hex_type: FightHexType,
    pub hazard_type: Option<HazardType>,
    pub hazard_damage_per_round: i32,
}

impl Default for FightHexOverlay {
    fn default() -> Self {
        Self {
            id: 0,
            hex_x: 0,
            hex_y: 0,
            hex_type: FightHexType::Oil,
            hazard_type: None,
            hazard_damage_per_round: 0,
        }
    }
}
