use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HexCoord {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct HexMap {
    pub width: u32,
    pub height: u32,
    /// Hex cells indexed by (x, y) coordinate.
    /// Custom serde: serializes keys as "x,y" strings for JSON compatibility.
    #[serde(
        deserialize_with = "deserialize_hex_cells",
        serialize_with = "serialize_hex_cells",
        default
    )]
    pub cells: HashMap<(i32, i32), HexCell>,
}

/// Custom deserializer for hex cells map that handles string-encoded keys
/// from JSON (Ruby serializes array keys as "[2, 4]" strings).
fn deserialize_hex_cells<'de, D>(
    deserializer: D,
) -> Result<HashMap<(i32, i32), HexCell>, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::Error;

    // Try to deserialize as HashMap<String, HexCell> (JSON string keys)
    let raw: HashMap<String, HexCell> = HashMap::deserialize(deserializer)?;
    let mut cells = HashMap::new();

    for (key, cell) in raw {
        // Parse key formats: "[2, 4]" or "2,4" or "[2,4]"
        let cleaned = key.trim_start_matches('[').trim_end_matches(']');
        let parts: Vec<&str> = cleaned.split(',').map(|s| s.trim()).collect();
        if parts.len() == 2 {
            let x = parts[0].parse::<i32>().map_err(D::Error::custom)?;
            let y = parts[1].parse::<i32>().map_err(D::Error::custom)?;
            cells.insert((x, y), cell);
        } else {
            return Err(D::Error::custom(format!(
                "invalid hex cell key: '{}', expected '[x, y]' or 'x,y'",
                key
            )));
        }
    }

    Ok(cells)
}

/// Custom serializer for hex cells map — writes keys as "x,y" strings for JSON.
fn serialize_hex_cells<S>(
    cells: &HashMap<(i32, i32), HexCell>,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    use serde::ser::SerializeMap;
    let mut map = serializer.serialize_map(Some(cells.len()))?;
    for ((x, y), cell) in cells {
        map.serialize_entry(&format!("{},{}", x, y), cell)?;
    }
    map.end()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct HexCell {
    pub x: i32,
    pub y: i32,
    pub elevation_level: i32,
    pub blocks_movement: bool,
    pub blocks_los: bool,
    pub is_difficult_terrain: bool,
    pub cover_type: Option<CoverType>,
    pub hazard_type: Option<HazardType>,
    pub hazard_damage: i32,
    pub is_ramp: bool,
    pub is_stairs: bool,
    pub is_ladder: bool,
    pub is_concealment: bool,
    pub passable_edges: Option<HashMap<Direction, bool>>,
    /// Vertical extent of cover at this hex (used for elevation-aware LoS).
    /// Ruby: `RoomHex#cover_height`. LoS is blocked when
    /// `viewer_z < elevation_level + cover_height`.
    #[serde(default)]
    pub cover_height: u8,
    /// Water terrain category. None = no water (dry floor).
    /// Ruby: `RoomHex#water_type`; drives movement-cost multiplier.
    #[serde(default)]
    pub water_type: Option<WaterType>,
    /// HP remaining on destructible cover; `None` = indestructible or no cover.
    /// Ruby: `RoomHex#hit_points`.
    #[serde(default)]
    pub hit_points: Option<i32>,
    /// Structural wall/tree feature at this hex. Drives Qi Lightness path
    /// selection and pixel→hex door lookup. Ruby: `RoomHex#wall_feature`.
    #[serde(default)]
    pub wall_feature: Option<WallFeature>,
    /// Runtime door state. Green pixels in the wall mask block LoS unless
    /// the door is open. Ruby: derived from `RoomHex#hex_type == 'door'`
    /// plus per-fight door state.
    #[serde(default)]
    pub door_open: bool,
    /// Runtime window state. A broken window stops blocking melee.
    #[serde(default)]
    pub window_broken: bool,
    /// Explicit traversable flag. Ruby keeps this distinct from
    /// `blocks_movement` (a non-traversable floor is still not a wall).
    #[serde(default = "default_true")]
    pub traversable: bool,
    /// Base tile kind. Ruby: `RoomHex#hex_type` — 'normal', 'wall', 'door',
    /// 'pit', 'water', etc. Overlay hazards live on `FightHex` (see
    /// `types::interactive::FightHexType`), not here.
    #[serde(default)]
    pub hex_kind: HexKind,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Direction {
    N,
    NE,
    SE,
    S,
    SW,
    NW,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CoverType {
    Half,
    Full,
    Destructible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HazardType {
    Fire,
    Pit,
    Poison,
    Spikes,
}

/// Water terrain category. Movement-cost multipliers match Ruby's
/// `RoomHex#water_movement_cost`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum WaterType {
    Puddle,
    Wading,
    Swimming,
    Deep,
}

/// Structural wall/tree feature tag. Drives Qi Lightness wall_run /
/// wall_bounce / tree_leap path selection and door-state lookups for
/// pixel-mask LoS.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WallFeature {
    Wall,
    WallCorner,
    Tree,
    Door,
    Window,
    Furniture,
    Other(String),
}

/// Base tile kind on a combat hex. Mirrors `RoomHex#hex_type`; overlay
/// hazards (oil, fire pools, etc.) live in `types::interactive::FightHexType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HexKind {
    Normal,
    Wall,
    Door,
    Window,
    Pit,
    Fire,
    Water,
    Trap,
    Cover,
    Debris,
    OffMap,
}

impl Default for HexKind {
    fn default() -> Self {
        HexKind::Normal
    }
}

// ---------------------------------------------------------------------------
// Default implementations
// ---------------------------------------------------------------------------

impl Default for HexCoord {
    fn default() -> Self {
        Self { x: 0, y: 0, z: 0 }
    }
}

impl Default for HexMap {
    fn default() -> Self {
        Self {
            width: 10,
            height: 10,
            cells: HashMap::new(),
        }
    }
}

impl Default for HexCell {
    fn default() -> Self {
        Self {
            x: 0,
            y: 0,
            elevation_level: 0,
            blocks_movement: false,
            blocks_los: false,
            is_difficult_terrain: false,
            cover_type: None,
            hazard_type: None,
            hazard_damage: 0,
            is_ramp: false,
            is_stairs: false,
            is_ladder: false,
            is_concealment: false,
            passable_edges: None,
            cover_height: 0,
            water_type: None,
            hit_points: None,
            wall_feature: None,
            door_open: false,
            window_broken: false,
            traversable: true,
            hex_kind: HexKind::Normal,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_coord_default() {
        let coord = HexCoord::default();
        assert_eq!(coord.x, 0);
        assert_eq!(coord.y, 0);
        assert_eq!(coord.z, 0);
    }

    #[test]
    fn test_hex_coord_equality() {
        let a = HexCoord { x: 1, y: 2, z: 3 };
        let b = HexCoord { x: 1, y: 2, z: 3 };
        let c = HexCoord { x: 4, y: 5, z: 6 };
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn test_hex_map_default() {
        let map = HexMap::default();
        assert_eq!(map.width, 10);
        assert_eq!(map.height, 10);
        assert!(map.cells.is_empty());
    }

    #[test]
    fn test_hex_cell_default_new_fields() {
        let cell = HexCell::default();
        assert_eq!(cell.cover_height, 0);
        assert!(cell.water_type.is_none());
        assert!(cell.hit_points.is_none());
        assert!(cell.wall_feature.is_none());
        assert!(!cell.door_open);
        assert!(!cell.window_broken);
        assert!(cell.traversable);
        assert_eq!(cell.hex_kind, HexKind::Normal);
    }

    #[test]
    fn test_hex_cell_serde_roundtrip_new_fields() {
        let cell = HexCell {
            cover_height: 3,
            water_type: Some(WaterType::Wading),
            hit_points: Some(12),
            wall_feature: Some(WallFeature::Tree),
            door_open: true,
            window_broken: true,
            traversable: false,
            hex_kind: HexKind::Debris,
            ..Default::default()
        };
        let json = serde_json::to_string(&cell).unwrap();
        let back: HexCell = serde_json::from_str(&json).unwrap();
        assert_eq!(back.cover_height, 3);
        assert_eq!(back.water_type, Some(WaterType::Wading));
        assert_eq!(back.hit_points, Some(12));
        assert_eq!(back.wall_feature, Some(WallFeature::Tree));
        assert!(back.door_open);
        assert!(back.window_broken);
        assert!(!back.traversable);
        assert_eq!(back.hex_kind, HexKind::Debris);
    }

    #[test]
    fn test_hex_cell_deserialize_legacy_omits_new_fields() {
        // Legacy payloads (from prior Rust builds) may lack the new fields.
        // serde defaults must keep us backwards-compatible.
        let legacy = r#"{"x":1,"y":2,"elevation_level":0,
            "blocks_movement":false,"blocks_los":false,
            "is_difficult_terrain":false,"cover_type":null,
            "hazard_type":null,"hazard_damage":0,
            "is_ramp":false,"is_stairs":false,"is_ladder":false,
            "is_concealment":false,"passable_edges":null}"#;
        let cell: HexCell = serde_json::from_str(legacy).unwrap();
        assert_eq!(cell.cover_height, 0);
        assert!(cell.traversable, "default_true must apply");
        assert_eq!(cell.hex_kind, HexKind::Normal);
    }

    #[test]
    fn test_wall_feature_other_roundtrip() {
        let wf = WallFeature::Other("trellis".to_string());
        let json = serde_json::to_string(&wf).unwrap();
        let back: WallFeature = serde_json::from_str(&json).unwrap();
        assert_eq!(back, WallFeature::Other("trellis".to_string()));
    }
}
