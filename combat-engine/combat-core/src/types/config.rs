use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Top-level combat configuration. All values are passed per-request from Ruby;
/// the `Default` impl mirrors the Ruby `GameConfig` constants so callers can
/// omit fields they haven't overridden.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CombatConfig {
    pub damage_thresholds: DamageThresholds,
    pub high_damage_base_hp: u8,
    pub high_damage_band_size: u16,
    pub segments: SegmentConfig,
    pub reach: ReachConfig,
    pub movement: MovementConfig,
    pub qi: QiConfig,
    pub cooldowns: CooldownConfig,
    pub ai_profiles: HashMap<String, AiProfileConfig>,
    pub ai_positioning: AiPositioningConfig,
    pub threat_weights: ThreatWeightConfig,
    pub simulator: SimulatorConfig,
    /// Damage bonus when a guard redirects an attack to themselves.
    pub guard_redirect_damage_bonus: i32,
    /// Damage bonus when a mutual back-to-back partner redirects.
    pub btb_mutual_damage_bonus: i32,
    /// Per-guard redirect chance (percent). Ruby pools all eligible guards and
    /// caps the combined chance at 100%. (game_config.rb:515)
    pub guard_redirect_chance: u32,
    /// Back-to-back mutual redirect chance (percent). (game_config.rb:517)
    pub btb_mutual_chance: u32,
    /// Back-to-back single-sided redirect chance (percent). (game_config.rb:518)
    pub btb_single_chance: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DamageThresholds {
    pub miss: i32,
    pub one_hp: i32,
    pub two_hp: i32,
    pub three_hp: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SegmentConfig {
    pub total: u32,
    pub movement_base: u32,
    pub movement_variance: u32,
    pub movement_randomization: f32,
    pub attack_randomization: f32,
    pub tactical_fallback: u32,
    pub melee_catchup_window: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ReachConfig {
    pub unarmed_reach: u32,
    pub segment_compression: f32,
    pub long_weapon_start: u32,
    pub long_weapon_end: u32,
    pub short_weapon_start: u32,
    pub short_weapon_end: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MovementConfig {
    pub base: u32,
    pub sprint_bonus: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct QiConfig {
    pub initial_dice: f32,
    pub gain_per_hp_lost: f32,
    pub max_dice: f32,
    pub bonus_per_die: u32,
    pub max_spend_per_action: u32,
    pub die_sides: u8,
    pub explode_on: u8,
    pub regen_per_round: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CooldownConfig {
    pub ability_penalty: i32,
    pub decay_per_round: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AiProfileConfig {
    pub attack_weight: f32,
    pub defend_weight: f32,
    pub ability_weight: f32,
    pub flee_threshold: f32,
    pub target_strategy: String,
    pub hazard_avoidance: String,
    pub terrain_caution: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AiPositioningConfig {
    pub optimal_ranged_distance: u32,
    pub min_ranged_distance: u32,
    pub cover_seek_priority: u32,
    pub los_clear_priority: u32,
    pub reposition_threshold: u32,
    pub max_reposition_hexes: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ThreatWeightConfig {
    pub targeted_by_enemy: i32,
    pub max_proximity_bonus: i32,
    pub no_cover_bonus: i32,
    pub elevation_advantage: i32,
    pub cover_penalty: i32,
    pub inactive_penalty: i32,
    pub ranged_vs_cover_penalty: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SimulatorConfig {
    pub max_rounds: u32,
    pub base_movement: u32,
    pub arena_width: u32,
    pub arena_height: u32,
}

// ---------------------------------------------------------------------------
// Default implementations -- values match Ruby GameConfig
// ---------------------------------------------------------------------------

impl Default for DamageThresholds {
    fn default() -> Self {
        Self {
            miss: 9,
            one_hp: 17,
            two_hp: 29,
            three_hp: 99,
        }
    }
}

impl Default for SegmentConfig {
    fn default() -> Self {
        Self {
            total: 100,
            movement_base: 50,
            movement_variance: 2,
            movement_randomization: 0.1,
            attack_randomization: 0.1,
            tactical_fallback: 20,
            melee_catchup_window: 15,
        }
    }
}

impl Default for ReachConfig {
    fn default() -> Self {
        Self {
            unarmed_reach: 2,
            segment_compression: 0.66,
            long_weapon_start: 1,
            long_weapon_end: 66,
            short_weapon_start: 34,
            short_weapon_end: 100,
        }
    }
}

impl Default for MovementConfig {
    fn default() -> Self {
        Self {
            base: 6,
            sprint_bonus: 5,
        }
    }
}

impl Default for QiConfig {
    fn default() -> Self {
        Self {
            initial_dice: 1.0,
            gain_per_hp_lost: 0.5,
            max_dice: 3.0,
            bonus_per_die: 2,
            max_spend_per_action: 2,
            die_sides: 8,
            explode_on: 8,
            regen_per_round: 0.34,
        }
    }
}

impl Default for CooldownConfig {
    fn default() -> Self {
        Self {
            ability_penalty: -6,
            decay_per_round: 2,
        }
    }
}

impl Default for AiProfileConfig {
    fn default() -> Self {
        // Matches Ruby CombatAIService::AI_PROFILES['balanced']
        // (combat_ai_service.rb:42-50)
        Self {
            attack_weight: 0.6,
            defend_weight: 0.3,
            ability_weight: 0.3,
            flee_threshold: 0.2,
            target_strategy: "closest".to_string(),
            hazard_avoidance: "moderate".to_string(),
            terrain_caution: 0.4,
        }
    }
}

impl Default for AiPositioningConfig {
    fn default() -> Self {
        Self {
            optimal_ranged_distance: 6,
            min_ranged_distance: 5,
            cover_seek_priority: 3,
            los_clear_priority: 4,
            reposition_threshold: 2,
            max_reposition_hexes: 5,
        }
    }
}

impl Default for ThreatWeightConfig {
    fn default() -> Self {
        Self {
            targeted_by_enemy: 5,
            max_proximity_bonus: 10,
            no_cover_bonus: 3,
            elevation_advantage: 2,
            cover_penalty: 5,
            inactive_penalty: 1,
            ranged_vs_cover_penalty: 6,
        }
    }
}

impl Default for SimulatorConfig {
    fn default() -> Self {
        Self {
            max_rounds: 50,
            base_movement: 4,
            arena_width: 10,
            arena_height: 10,
        }
    }
}

impl Default for CombatConfig {
    fn default() -> Self {
        let mut ai_profiles = HashMap::new();
        // All six profile definitions mirror Ruby CombatAIService::AI_PROFILES
        // at backend/app/services/combat/combat_ai_service.rb:23-78.
        ai_profiles.insert(
            "aggressive".to_string(),
            AiProfileConfig {
                attack_weight: 0.8,
                defend_weight: 0.1,
                ability_weight: 0.4,
                flee_threshold: 0.1,
                target_strategy: "weakest".to_string(),
                hazard_avoidance: "low".to_string(),
                terrain_caution: 0.2,
            },
        );
        ai_profiles.insert(
            "defensive".to_string(),
            AiProfileConfig {
                attack_weight: 0.4,
                defend_weight: 0.5,
                ability_weight: 0.3,
                flee_threshold: 0.3,
                target_strategy: "threat".to_string(),
                hazard_avoidance: "high".to_string(),
                terrain_caution: 0.7,
            },
        );
        ai_profiles.insert(
            "balanced".to_string(),
            AiProfileConfig {
                attack_weight: 0.6,
                defend_weight: 0.3,
                ability_weight: 0.3,
                flee_threshold: 0.2,
                target_strategy: "closest".to_string(),
                hazard_avoidance: "moderate".to_string(),
                terrain_caution: 0.4,
            },
        );
        ai_profiles.insert(
            "berserker".to_string(),
            AiProfileConfig {
                attack_weight: 0.95,
                defend_weight: 0.0,
                ability_weight: 0.2,
                flee_threshold: 0.0,
                target_strategy: "weakest".to_string(),
                hazard_avoidance: "ignore".to_string(),
                terrain_caution: 0.0,
            },
        );
        ai_profiles.insert(
            "coward".to_string(),
            AiProfileConfig {
                attack_weight: 0.3,
                defend_weight: 0.4,
                ability_weight: 0.2,
                flee_threshold: 0.5,
                target_strategy: "random".to_string(),
                hazard_avoidance: "high".to_string(),
                terrain_caution: 0.8,
            },
        );
        ai_profiles.insert(
            "guardian".to_string(),
            AiProfileConfig {
                attack_weight: 0.5,
                defend_weight: 0.6,
                ability_weight: 0.4,
                flee_threshold: 0.15,
                target_strategy: "threat".to_string(),
                hazard_avoidance: "low".to_string(),
                terrain_caution: 0.3,
            },
        );

        Self {
            damage_thresholds: DamageThresholds::default(),
            high_damage_base_hp: 4,
            high_damage_band_size: 100,
            segments: SegmentConfig::default(),
            reach: ReachConfig::default(),
            movement: MovementConfig::default(),
            qi: QiConfig::default(),
            cooldowns: CooldownConfig::default(),
            ai_profiles,
            ai_positioning: AiPositioningConfig::default(),
            threat_weights: ThreatWeightConfig::default(),
            simulator: SimulatorConfig::default(),
            guard_redirect_damage_bonus: 2,
            // Ruby GameConfig::Tactics::PROTECTION[:btb_mutual_damage_mod] = -1
            // (backend/config/game_config.rb:519)
            btb_mutual_damage_bonus: -1,
            guard_redirect_chance: 50,
            btb_mutual_chance: 50,
            btb_single_chance: 25,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_damage_thresholds() {
        let dt = DamageThresholds::default();
        assert_eq!(dt.miss, 9);
        assert_eq!(dt.one_hp, 17);
        assert_eq!(dt.two_hp, 29);
        assert_eq!(dt.three_hp, 99);
    }

    #[test]
    fn test_default_qi_config() {
        let qi = QiConfig::default();
        assert!((qi.initial_dice - 1.0).abs() < f32::EPSILON);
        assert!((qi.gain_per_hp_lost - 0.5).abs() < f32::EPSILON);
        assert!((qi.max_dice - 3.0).abs() < f32::EPSILON);
        assert_eq!(qi.die_sides, 8);
        assert!((qi.regen_per_round - 0.34).abs() < f32::EPSILON);
    }

    #[test]
    fn test_default_segments() {
        let seg = SegmentConfig::default();
        assert_eq!(seg.total, 100);
        assert_eq!(seg.movement_base, 50);
    }

    #[test]
    fn test_default_simulator() {
        let sim = SimulatorConfig::default();
        assert_eq!(sim.max_rounds, 50);
    }
}
