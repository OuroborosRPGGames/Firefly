use serde::{Deserialize, Serialize};

use super::hex::HexCoord;
use super::weapons::DamageType;

/// Detailed roll breakdown for attack events, mirroring Ruby's emit_attack_event details.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttackRollDetail {
    /// Base weapon dice roll total (before modifiers).
    pub base_roll: i32,
    /// Individual dice values from the weapon roll.
    pub roll_dice: Vec<u32>,
    /// Whether any dice exploded.
    pub roll_exploded: bool,
    /// Stat modifier (Strength/Dexterity value).
    pub stat_mod: i16,
    /// Wound penalty applied to attacker.
    pub wound_penalty: i32,
    /// All-roll penalty (e.g., from multi-attack).
    pub all_roll_penalty: i16,
    /// Number of attacks this roll is divided across.
    pub attack_count: u32,
    /// Per-attack share of the base roll (roll_total / attack_count).
    pub per_attack_roll: i32,
    /// Qi attack bonus (if any).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub qi_attack_bonus: Option<i32>,
    /// Qi attack dice values (if any).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub qi_attack_dice: Option<Vec<u32>>,
    /// Full roll total (base + qi + modifiers, before defense).
    pub total_before_defense: i32,
}

/// Weapon info attached to attack events.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttackWeaponDetail {
    /// "melee", "ranged", "natural_melee", "natural_ranged", "unarmed".
    pub weapon_type: String,
    /// Weapon or natural attack name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weapon_name: Option<String>,
    /// Damage type dealt.
    pub damage_type: DamageType,
}

/// Defense pipeline breakdown for attack events.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefenseDetail {
    /// How much shields absorbed.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub shield_absorbed: i32,
    /// How much armor/damage_reduction reduced.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub armor_reduced: i32,
    /// How much qi aura reduced.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub qi_aura_reduced: i32,
    /// How much protection reduced.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub protection_reduced: i32,
    /// How much qi defense reduced.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub qi_defense_reduced: i32,
    /// Observer effect damage multiplier (1.0 = no effect).
    #[serde(skip_serializing_if = "is_one_f32")]
    pub observer_multiplier: f32,
    /// Observer flat bonus.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub observer_flat_bonus: i32,
    /// Whether back-to-wall applied.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub back_to_wall: bool,
    /// Defend action modifier on target.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub incoming_modifier: i32,
    /// Outgoing damage modifier on attacker.
    #[serde(skip_serializing_if = "is_zero_i32")]
    pub outgoing_modifier: i32,
    /// Damage after full defense pipeline (what goes into threshold calc).
    /// f64 because Ruby accumulates float per-attack damage.
    pub final_damage: f64,
}

/// Per-target result for ability events.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AbilityTargetResult {
    pub target_id: u64,
    pub damage: i32,
    pub hp_lost: i32,
    pub is_primary: bool,
    pub damage_multiplier: f32,
}

fn is_zero_i32(v: &i32) -> bool {
    *v == 0
}

fn is_one_f32(v: &f32) -> bool {
    (*v - 1.0).abs() < f32::EPSILON
}

/// Why a participant was removed from the fight. Ruby distinguishes these
/// to route to the right service: PrisonerService for surrender/defeat,
/// NpcSpawnService for hostile NPC death.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum KoReason {
    /// Standard defeat — PC or non-hostile NPC reduced to 0 HP / touch-out.
    /// Ruby: PrisonerService.process_knockout! for PCs.
    #[default]
    Defeat,
    /// Voluntary surrender. Ruby: fight_participant.process_surrender!
    /// (invokes PrisonerService.process_surrender!).
    Surrender,
    /// Hostile NPC killed outright. Ruby: NpcSpawnService.kill_npc!.
    Died,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum CombatEvent {
    AttackHit {
        attacker_id: u64,
        target_id: u64,
        /// Raw damage before defense pipeline.
        raw_damage: i32,
        /// Damage after defense pipeline (for threshold calc).
        damage: i32,
        hp_lost: i32,
        segment: u32,
        /// Roll breakdown.
        #[serde(skip_serializing_if = "Option::is_none")]
        roll: Option<AttackRollDetail>,
        /// Weapon info.
        #[serde(skip_serializing_if = "Option::is_none")]
        weapon: Option<AttackWeaponDetail>,
        /// Defense pipeline breakdown.
        #[serde(skip_serializing_if = "Option::is_none")]
        defense: Option<DefenseDetail>,
    },
    AttackMiss {
        attacker_id: u64,
        target_id: u64,
        /// Raw damage that was calculated (but didn't cross threshold).
        raw_damage: i32,
        /// Damage after defense pipeline.
        damage: i32,
        segment: u32,
        /// Roll breakdown.
        #[serde(skip_serializing_if = "Option::is_none")]
        roll: Option<AttackRollDetail>,
        /// Weapon info.
        #[serde(skip_serializing_if = "Option::is_none")]
        weapon: Option<AttackWeaponDetail>,
        /// Defense pipeline breakdown.
        #[serde(skip_serializing_if = "Option::is_none")]
        defense: Option<DefenseDetail>,
    },
    AbilityUsed {
        caster_id: u64,
        ability_id: u64,
        ability_name: String,
        targets: Vec<AbilityTargetResult>,
        /// Total damage across all targets.
        total_damage: i32,
        segment: u32,
        /// Pre-rolled ability base (2d8 exploding).
        #[serde(skip_serializing_if = "Option::is_none")]
        ability_base_roll: Option<i32>,
        /// Qi ability bonus roll.
        #[serde(skip_serializing_if = "Option::is_none")]
        qi_ability_roll: Option<i32>,
        /// Stat modifier used.
        stat_mod: i16,
    },
    Moved {
        participant_id: u64,
        from: HexCoord,
        to: HexCoord,
        segment: u32,
    },
    StatusApplied {
        target_id: u64,
        effect_name: String,
        duration: i32,
        source_id: Option<u64>,
    },
    StatusExpired {
        target_id: u64,
        effect_name: String,
    },
    DotTick {
        target_id: u64,
        effect_name: String,
        damage: i32,
        hp_lost: i32,
        segment: u32,
    },
    KnockedOut {
        participant_id: u64,
        by_id: Option<u64>,
        /// Why the participant was taken out of the fight. Ruby dispatches to
        /// different services based on this: Surrender → PrisonerService
        /// surrender flow, Died → NpcSpawnService.kill_npc!, Defeat →
        /// PrisonerService.process_knockout! for PCs.
        #[serde(default)]
        reason: KoReason,
    },
    AttackRedirected {
        attacker_id: u64,
        original_target_id: u64,
        new_target_id: u64,
        redirect_type: String,
    },
    Healed {
        target_id: u64,
        amount: i32,
        source_id: Option<u64>,
    },
    AbilityHeal {
        caster_id: u64,
        target_id: u64,
        ability_name: String,
        heal_amount: i32,
        actual_heal: i32,
        segment: u32,
    },
    AbilityExecute {
        caster_id: u64,
        target_id: u64,
        ability_name: String,
        instant_kill: bool,
        threshold: f32,
        segment: u32,
    },
    ForcedMovementEvent {
        target_id: u64,
        from: HexCoord,
        to: HexCoord,
        direction: String,
        distance: u32,
        source_id: u64,
    },
    ShieldAbsorbed {
        target_id: u64,
        absorbed: i32,
    },
    /// A destructible cover hex was reduced to debris.
    /// Ruby: `BattleMapCombatService#damage_cover` emits no structured event,
    /// but the underlying `RoomHex#destroy_cover!` transitions state. We emit
    /// this so the fight log and clients can observe the destruction.
    CoverDestroyed {
        hex_x: i32,
        hex_y: i32,
        destroyer_id: Option<u64>,
        segment: u32,
    },
    TacticActivated {
        participant_id: u64,
        tactic: String,
    },
    QiUsed {
        participant_id: u64,
        category: String,
        dice_count: u8,
        roll_total: i32,
    },
    MonsterAttack {
        monster_id: u64,
        segment_name: String,
        target_id: u64,
        damage: i32,
        segment: u32,
    },
    MountAction {
        participant_id: u64,
        monster_id: u64,
        action: String,
    },
    MonsterSegmentDamage {
        monster_id: u64,
        segment_name: String,
        damage: i32,
        segment_destroyed: bool,
    },
    MonsterCollapsed {
        monster_id: u64,
    },
    MonsterDefeated {
        monster_id: u64,
    },
    WeakPointHit {
        monster_id: u64,
        attacker_id: u64,
        total_damage: i32,
        segment: u32,
    },
    PlayerShakeOff {
        monster_id: u64,
        participant_id: u64,
        thrown: bool,
        landing_x: i32,
        landing_y: i32,
    },
    ClimbProgress {
        participant_id: u64,
        monster_id: u64,
        progress: u32,
        at_weak_point: bool,
    },
    FightEnded {
        winner_side: Option<u8>,
    },
    FleeSuccess {
        participant_id: u64,
        direction: String,
        exit_id: Option<u64>,
    },
    FleeFailed {
        participant_id: u64,
        direction: String,
        damage_taken: f64,
    },
    MeleeBlockedQiLightness {
        attacker_id: u64,
        target_id: u64,
        target_mode: Option<String>,
        segment: u32,
    },
    WallFlip {
        participant_id: u64,
        from: HexCoord,
        to: HexCoord,
        segment: u32,
        /// Pursuer forced to the launch hex during the flip, if any.
        /// Ruby: `find_wall_flip_pursuer` / `with_pursuer` flag on
        /// combat_resolution_service.rb:2216,2223. `None` for solo flips.
        #[serde(default)]
        pursuer_id: Option<u64>,
    },
    HazardDamage {
        participant_id: u64,
        hazard_type: String,
        damage: i32,
        hp_lost: i32,
        segment: u32,
    },
    MonsterTurn {
        monster_id: u64,
        segment: u32,
    },
    MonsterMove {
        monster_id: u64,
        from: HexCoord,
        to: HexCoord,
        segment: u32,
    },
    MonsterShakeOff {
        monster_id: u64,
        segment: u32,
        thrown: Vec<u64>,
    },
    ClimbBack {
        participant_id: u64,
        monster_id: u64,
        segment: u32,
    },
    OilIgnite {
        participant_id: u64,
        hex_x: i32,
        hex_y: i32,
        segment: u32,
    },
    ElementBreak {
        participant_id: u64,
        element_type: String,
        hex_x: i32,
        hex_y: i32,
        segment: u32,
    },
    ElementDetonate {
        participant_id: u64,
        hex_x: i32,
        hex_y: i32,
        segment: u32,
    },
    ExplosionDamage {
        target_id: u64,
        actor_id: u64,
        raw_damage: i32,
        damage_after_shield: i32,
        hp_lost: i32,
        segment: u32,
    },
    WindowBreak {
        participant_id: u64,
        hex_x: i32,
        hex_y: i32,
        segment: u32,
    },
    MonsterSegmentAttack {
        attacker_id: u64,
        monster_id: u64,
        segment_id: u64,
        damage: i32,
        segment_number: u32,
        weak_point_hit: bool,
    },
    /// RNG trace entry for debugging parity. Only emitted when trace mode is enabled.
    RngTrace {
        participant_id: u64,
        label: String,
        value: i32,
        sequence: u32,
    },
    /// Attack was canceled because the target is protected from this attacker
    /// by a targeting_restriction effect (e.g. sanctuary). Ruby mirror:
    /// `create_event(segment, actor, target, 'action', reason:
    /// 'invalid_target_protected')` at combat_resolution_service.rb:2873.
    InvalidTarget {
        attacker_id: u64,
        target_id: u64,
        reason: String,
        segment: u32,
    },
    /// A queued combat-style switch has been applied at end of round. Ruby
    /// parity: `FightParticipant#apply_style_switch!`. Ruby writeback uses
    /// this event to call apply_style_switch! on the live DB record
    /// (variant_lock cleanup, character_instance preference, etc.).
    StyleSwitched {
        participant_id: u64,
        old_style: Option<String>,
        new_style: String,
    },
    /// Attack attempt fired at its segment but the target had moved out of
    /// reach (melee: dist > 1 without melee-catch-up budget; ranged: dist >
    /// weapon range). Ruby mirror: `out_of_range` event in
    /// combat_resolution_service.rb. Emitted so the event stream doesn't go
    /// silent when a defender retreats mid-round; prior to this, Rust would
    /// drop the attack with no event, causing a per-round event-count
    /// divergence from Ruby (the "1v1_defend pursuit-stalemate" symptom).
    AttackOutOfRange {
        attacker_id: u64,
        target_id: u64,
        segment: u32,
        distance: u32,
    },
}
