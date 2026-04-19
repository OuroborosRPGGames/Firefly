use serde::{Deserialize, Serialize};

use super::hex::HexCoord;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerAction {
    pub participant_id: u64,
    pub movement: MovementAction,
    pub main_action: MainAction,
    pub tactic: TacticChoice,
    pub qi_attack: u8,
    pub qi_defense: u8,
    pub qi_ability: u8,
    pub qi_movement: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MovementAction {
    TowardsPerson(u64),
    AwayFrom(u64),
    MaintainDistance { target_id: u64, range: u8 },
    MoveToHex(HexCoord),
    StandStill,
    Flee {
        /// Room cardinal direction ("north", "south", "east", "west", "up", "down").
        /// Ruby `RoomAdjacencyService.resolve_direction_movement` expects these strings.
        direction: String,
        exit_id: Option<u64>,
    },
    WallFlip {
        /// Wall hex the participant is flipping off of. Optional for backward
        /// compatibility with existing serialized payloads.
        #[serde(default)]
        wall_x: Option<i32>,
        #[serde(default)]
        wall_y: Option<i32>,
    },
    Mount { monster_id: u64 },
    Climb,
    Cling,
    Dismount,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MainAction {
    Attack {
        target_id: u64,
        /// Optional: targeting a specific large monster instance.
        #[serde(default)]
        monster_id: Option<u64>,
        /// Optional: targeting a specific segment on that monster.
        #[serde(default)]
        segment_id: Option<u64>,
    },
    Defend,
    Ability { ability_id: u64, target_id: Option<u64> },
    Dodge,
    Sprint,
    Surrender,
    Pass,
    Stand,
    StandUp,
    Extinguish,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TacticChoice {
    None,
    AreaDenial,
    QiAura,
    QiLightness { mode: QiLightnessMode },
    Guard { ally_id: u64 },
    BackToBack { ally_id: u64 },
    TacticalAbility { ability_id: u64, target_id: Option<u64> },
    /// Break a target. If `element_id` is present, breaks a BattleMapElement
    /// (water_barrel/oil_barrel/vase) and spreads the appropriate FightHex.
    /// If `element_id` is None and `target_x`/`target_y` are set, breaks a
    /// RoomHex window at that position (Ruby break_window path).
    Break {
        #[serde(default)]
        element_id: Option<u64>,
        #[serde(default)]
        target_x: Option<i32>,
        #[serde(default)]
        target_y: Option<i32>,
    },
    /// Detonate a munitions_crate — ring damage + chain reactions.
    Detonate { element_id: u64 },
    /// Ignite an oil FightHex at (target_x, target_y) — converts to fire.
    Ignite { target_x: i32, target_y: i32 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum QiLightnessMode {
    WallRun,
    WallBounce,
    TreeLeap,
}

impl Default for PlayerAction {
    fn default() -> Self {
        Self {
            participant_id: 0,
            movement: MovementAction::StandStill,
            main_action: MainAction::Pass,
            tactic: TacticChoice::None,
            qi_attack: 0,
            qi_defense: 0,
            qi_ability: 0,
            qi_movement: 0,
        }
    }
}
