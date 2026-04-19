use serde::{Deserialize, Serialize};

use super::hex::HexCoord;
use super::weapons::DamageType;

/// Status of the overall monster.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MonsterStatus {
    Active,
    Collapsed,
    Defeated,
}

impl Default for MonsterStatus {
    fn default() -> Self {
        MonsterStatus::Active
    }
}

/// Status of an individual monster segment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SegmentStatus {
    Healthy,
    Damaged,
    Destroyed,
}

impl Default for SegmentStatus {
    fn default() -> Self {
        SegmentStatus::Healthy
    }
}

/// Status of a mounted participant on a monster.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MountStatus {
    Mounted,
    Climbing,
    AtWeakPoint,
    Thrown,
    Dismounted,
}

impl Default for MountStatus {
    fn default() -> Self {
        MountStatus::Mounted
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MonsterData {
    pub id: u64,
    pub name: String,
    pub current_hp: i32,
    pub max_hp: i32,
    pub center: HexCoord,
    pub segments: Vec<MonsterSegment>,
    pub shake_off_threshold: i32,
    pub climb_distance: i32,
    /// Hex direction the monster is facing (0-5).
    pub facing: u8,
    /// Current monster status.
    pub status: MonsterStatus,
    /// Width of the monster in hexes.
    pub hex_width: u32,
    /// Height of the monster in hexes.
    pub hex_height: u32,
    /// Defeat when HP% falls to or below this value.
    pub defeat_threshold_percent: u8,
    /// Per-player mount tracking.
    pub mount_states: Vec<MountState>,
}

impl Default for MonsterData {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            current_hp: 0,
            max_hp: 0,
            center: HexCoord::default(),
            segments: Vec::new(),
            shake_off_threshold: 2,
            climb_distance: 10,
            facing: 0,
            status: MonsterStatus::Active,
            hex_width: 1,
            hex_height: 1,
            defeat_threshold_percent: 0,
            mount_states: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MonsterSegment {
    pub id: u64,
    pub name: String,
    pub current_hp: i32,
    pub max_hp: i32,
    pub attacks_per_round: u32,
    pub dice_count: u32,
    pub dice_sides: u32,
    pub damage_bonus: i32,
    pub damage_type: DamageType,
    pub reach: u32,
    pub is_weak_point: bool,
    pub required_for_mobility: bool,
    pub position: HexCoord,
    /// Current segment status.
    pub status: SegmentStatus,
    /// How many attacks remaining this round.
    pub attacks_remaining: u32,
    /// Damage dice notation (e.g., "2d8").
    pub damage_dice: Option<String>,
    /// Hex offset from monster center (x).
    pub hex_offset_x: i32,
    /// Hex offset from monster center (y).
    pub hex_offset_y: i32,
}

impl Default for MonsterSegment {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            current_hp: 0,
            max_hp: 0,
            attacks_per_round: 0,
            dice_count: 0,
            dice_sides: 0,
            damage_bonus: 0,
            damage_type: DamageType::Physical,
            reach: 1,
            is_weak_point: false,
            required_for_mobility: false,
            position: HexCoord::default(),
            status: SegmentStatus::Healthy,
            attacks_remaining: 0,
            damage_dice: None,
            hex_offset_x: 0,
            hex_offset_y: 0,
        }
    }
}

/// Tracks a participant's mount state on a monster.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MountState {
    pub participant_id: u64,
    pub monster_id: u64,
    pub segment_id: u64,
    pub mount_status: MountStatus,
    pub climb_progress: u32,
    pub is_at_weak_point: bool,
}

impl Default for MountState {
    fn default() -> Self {
        Self {
            participant_id: 0,
            monster_id: 0,
            segment_id: 0,
            mount_status: MountStatus::Mounted,
            climb_progress: 0,
            is_at_weak_point: false,
        }
    }
}
