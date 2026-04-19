use serde::{Deserialize, Deserializer, Serialize};
use std::collections::HashMap;

use super::abilities::Ability;
use super::fight_state::CombatStyle;
use super::hex::HexCoord;
use super::status_effects::ActiveEffect;
use super::weapons::{NaturalAttack, Weapon};

/// Deserialize `HashMap<u64, i32>` from a JSON object whose keys may be
/// string or number. Serde's default deserializer refuses string keys when
/// the outer enum is internally tagged (`#[serde(tag = "type")]`) because
/// the payload is buffered as `serde_json::Value` first, which erases the
/// `u64`-from-`str` conversion serde_json normally applies. This helper
/// restores that behavior.
///
/// Safe to use as the field's `deserialize_with` target — serialization
/// stays default (HashMap<u64, _> encodes keys as strings per JSON spec).
fn deserialize_u64_map<'de, D>(d: D) -> Result<HashMap<u64, i32>, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::{Error, MapAccess, Visitor};
    use std::fmt;

    struct MapVisitor;
    impl<'de> Visitor<'de> for MapVisitor {
        type Value = HashMap<u64, i32>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a map with u64 keys (string or number)")
        }
        fn visit_map<M: MapAccess<'de>>(self, mut m: M) -> Result<Self::Value, M::Error> {
            let mut out = HashMap::new();
            // Read keys as either string or number via a flexible wrapper.
            #[derive(Deserialize)]
            #[serde(untagged)]
            enum Key {
                Str(String),
                Num(u64),
            }
            while let Some((k, v)) = m.next_entry::<Key, i32>()? {
                let key = match k {
                    Key::Str(s) => s.parse::<u64>().map_err(M::Error::custom)?,
                    Key::Num(n) => n,
                };
                out.insert(key, v);
            }
            Ok(out)
        }
    }
    d.deserialize_map(MapVisitor)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Participant {
    pub id: u64,
    pub side: u8,
    pub current_hp: u8,
    pub max_hp: u8,
    pub touch_count: u8,
    pub qi_dice: f32,
    pub qi_die_sides: u8,
    pub position: HexCoord,
    pub melee_weapon: Option<Weapon>,
    pub ranged_weapon: Option<Weapon>,
    pub natural_attacks: Vec<NaturalAttack>,
    pub abilities: Vec<Ability>,
    #[serde(deserialize_with = "deserialize_u64_map", default)]
    pub cooldowns: HashMap<u64, i32>,
    pub combat_style: Option<CombatStyle>,
    pub stat_modifier: i16,
    pub dexterity_modifier: i16,
    pub all_roll_penalty: i16,
    #[serde(default)]
    pub global_cooldown: u32,
    #[serde(default)]
    pub ability_roll_penalty: i16,
    pub npc_damage_bonus: i16,
    pub npc_defense_bonus: i16,
    pub outgoing_damage_modifier: i16,
    pub incoming_damage_modifier: i16,
    /// Tactic-driven outgoing damage modifier applied in `round_total`.
    /// Ruby: `FightParticipant#tactic_outgoing_damage_modifier`
    /// (fight_participant.rb:370). Stub returns 0 today; wired through so
    /// future tactics can populate without further Rust-side plumbing.
    #[serde(default)]
    pub tactic_outgoing_damage_modifier: i32,
    /// Tactic-driven incoming damage modifier applied in `round_total`.
    /// Ruby: `FightParticipant#tactic_incoming_damage_modifier`
    /// (fight_participant.rb:378).
    #[serde(default)]
    pub tactic_incoming_damage_modifier: i32,
    /// Tactic-driven flat movement-budget bonus. Added to the base +
    /// sprint + dice-derived bonus in `calculate_movement_budget`.
    /// Firefly's `quick` tactic populates +2 here; qi-tactic games
    /// leave it at 0 so the dice-based bonus remains the only source.
    /// Firefly-specific divergence from the upstream combat-engine snapshot.
    #[serde(default)]
    pub tactic_movement_bonus_flat: u32,
    pub status_effects: Vec<ActiveEffect>,
    pub ai_profile: Option<String>,
    pub is_knocked_out: bool,
    pub is_prone: bool,
    pub is_mounted: bool,
    pub mount_target_id: Option<u64>,
    /// Player's current mount intent: "climb", "cling", "dismount", or None.
    /// Matches Ruby FightParticipant#mount_action — used by the shake-off handler
    /// to determine if the player is safely clinging (and immune to being thrown).
    #[serde(default)]
    pub mount_action: Option<String>,
    /// True if this is an NPC with custom damage dice (npc_damage_dice_count/sides set).
    /// Distinct from having natural_attacks. Controls whether pre-rolling uses explosion.
    pub is_npc_custom_dice: bool,
    /// True if this participant is a non-player character. Ruby:
    /// `character.is_npc`. Used to gate observer-effect multipliers and
    /// KO-reason selection (hostile NPC → Died vs Defeat).
    #[serde(default)]
    pub is_npc: bool,
    /// True for hostile NPC (enemy): reaching 0 HP fires
    /// `NpcSpawnService.kill_npc!` rather than the prisoner/defeat flow.
    /// Ruby: `character.is_npc && character.hostile?`.
    #[serde(default)]
    pub is_hostile_npc: bool,
    /// Queued combat-style switch (stored as the new style's name). The UI
    /// writes this mid-round; Ruby applies it at round end via
    /// `FightParticipant#apply_style_switch!`. Rust emits a `StyleSwitched`
    /// event at round end so the writeback can invoke the real Ruby apply.
    #[serde(default)]
    pub pending_style_switch: Option<String>,
    /// Number of attacks made this round (for first_attack_of_round condition).
    #[serde(default)]
    pub attacks_this_round: u32,
    /// Whether this participant has moved this round (for cover stationary check).
    #[serde(default)]
    pub moved_this_round: bool,
    /// Whether this participant has acted (attacked/used ability) this round.
    #[serde(default)]
    pub acted_this_round: bool,
    /// Climb-back destination when participant is dangling. Ruby stores these
    /// on tactic_target_data JSONB; the resolver schedules a dangling_climb_back
    /// event that moves the participant to this hex and clears the dangling
    /// status effect.
    #[serde(default)]
    pub climb_back_x: Option<i32>,
    #[serde(default)]
    pub climb_back_y: Option<i32>,
    /// The enemy this participant is currently targeting (Ruby
    /// `FightParticipant#target_participant_id`). Used by threat selection
    /// to match Ruby's "bonus when enemy is targeting us" rule.
    #[serde(default)]
    pub current_target_id: Option<u64>,
    /// Segment at which this participant's movement completes this round.
    /// Ruby: `FightParticipant#movement_completed_segment` gates
    /// protection_active_at_segment? at fight_participant.rb:446-448.
    /// `None` = protection active all round (no movement this round).
    #[serde(default)]
    pub movement_completed_segment: Option<u32>,
    /// Qi Lightness elevated state, set after the participant's final
    /// movement step when Qi Lightness is the active tactic. Ruby:
    /// `FightParticipant#qi_lightness_elevated` (combat_resolution_service.rb:1761).
    /// Elevated targets are immune to melee from non-Qi-Lightness attackers.
    #[serde(default)]
    pub qi_lightness_elevated: bool,
    /// Elevation bonus granted by the active Qi Lightness mode (wall_run = 4,
    /// wall_bounce/tree_leap = 16). Applied via tactics.rs::qi_lightness_elevation.
    #[serde(default)]
    pub qi_lightness_elevation_bonus: i32,
}

impl Participant {
    pub fn wound_penalty(&self) -> i32 {
        (self.max_hp as i32) - (self.current_hp as i32)
    }

    pub fn hp_percent(&self) -> f32 {
        self.current_hp as f32 / self.max_hp.max(1) as f32
    }

    pub fn available_qi_dice(&self) -> u32 {
        self.qi_dice.floor() as u32
    }

    pub fn is_active(&self) -> bool {
        !self.is_knocked_out
    }

    /// Heal the participant, clamping to max_hp. Returns actual amount healed.
    pub fn heal(&mut self, amount: i32) -> i32 {
        let old_hp = self.current_hp;
        self.current_hp = (self.current_hp as i32 + amount).min(self.max_hp as i32).max(0) as u8;
        (self.current_hp as i32) - (old_hp as i32)
    }
}

impl Default for Participant {
    fn default() -> Self {
        Self {
            id: 0,
            side: 0,
            current_hp: 6,
            max_hp: 6,
            touch_count: 0,
            qi_dice: 1.0,
            qi_die_sides: 8,
            position: HexCoord::default(),
            melee_weapon: None,
            ranged_weapon: None,
            natural_attacks: Vec::new(),
            abilities: Vec::new(),
            cooldowns: HashMap::new(),
            combat_style: None,
            stat_modifier: 0,
            dexterity_modifier: 0,
            all_roll_penalty: 0,
            global_cooldown: 0,
            ability_roll_penalty: 0,
            npc_damage_bonus: 0,
            npc_defense_bonus: 0,
            outgoing_damage_modifier: 0,
            incoming_damage_modifier: 0,
            tactic_outgoing_damage_modifier: 0,
            tactic_incoming_damage_modifier: 0,
            tactic_movement_bonus_flat: 0,
            status_effects: Vec::new(),
            ai_profile: None,
            is_knocked_out: false,
            is_prone: false,
            is_mounted: false,
            mount_target_id: None,
            mount_action: None,
            is_npc_custom_dice: false,
            is_npc: false,
            is_hostile_npc: false,
            pending_style_switch: None,
            attacks_this_round: 0,
            moved_this_round: false,
            acted_this_round: false,
            climb_back_x: None,
            climb_back_y: None,
            current_target_id: None,
            movement_completed_segment: None,
            qi_lightness_elevated: false,
            qi_lightness_elevation_bonus: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wound_penalty() {
        let p = Participant {
            max_hp: 6,
            current_hp: 4,
            ..Default::default()
        };
        assert_eq!(p.wound_penalty(), 2);
    }

    #[test]
    fn test_wound_penalty_full_hp() {
        let p = Participant {
            max_hp: 6,
            current_hp: 6,
            ..Default::default()
        };
        assert_eq!(p.wound_penalty(), 0);
    }

    #[test]
    fn test_hp_percent() {
        let p = Participant {
            max_hp: 6,
            current_hp: 3,
            ..Default::default()
        };
        assert!((p.hp_percent() - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn test_available_qi_dice() {
        let p = Participant {
            qi_dice: 1.34,
            ..Default::default()
        };
        assert_eq!(p.available_qi_dice(), 1);
    }

    #[test]
    fn test_is_active() {
        let mut p = Participant::default();
        assert!(p.is_active());

        p.is_knocked_out = true;
        assert!(!p.is_active());
    }
}
