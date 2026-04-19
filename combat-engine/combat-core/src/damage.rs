use crate::types::config::DamageThresholds;
use crate::types::fight_state::CombatStyle;

/// Build the effective thresholds for a participant given their combat style.
/// Ruby fight_participant.rb:661-670: style_bonuses[:threshold_1hp] shifts one_hp
/// up; style_bonuses[:threshold_2_3hp] shifts both two_hp and three_hp.
/// Miss threshold is unaffected.
pub fn effective_thresholds(
    base: &DamageThresholds,
    style: Option<&CombatStyle>,
) -> DamageThresholds {
    let (t1, t23) = style.map(|s| (s.threshold_1hp, s.threshold_2_3hp)).unwrap_or((0, 0));
    if t1 == 0 && t23 == 0 {
        return base.clone();
    }
    DamageThresholds {
        miss: base.miss,
        one_hp: base.one_hp + t1,
        two_hp: base.two_hp + t23,
        three_hp: base.three_hp + t23,
    }
}

/// Calculate HP lost from cumulative raw damage using the threshold system.
///
/// Raw damage is converted to HP loss via configurable thresholds. The
/// `wound_penalty` (HP already lost this fight) shifts all thresholds down,
/// making wounded characters take more damage from the same raw total.
///
/// Default thresholds (wound_penalty=0):
///   0-9   -> 0 HP (miss)
///   10-17 -> 1 HP
///   18-29 -> 2 HP
///   30-99 -> 3 HP
///   100+  -> 4+ HP (in 100-point bands)
/// Calculate HP lost from cumulative damage.
/// Accepts f64 because Ruby's cumulative damage is a float (per-attack totals
/// are `round_total.to_f / attack_count`) and threshold comparison must use
/// the float value: `9.2 <= 9` is false in Ruby, so 9.2 damage = 1 HP.
pub fn calculate_hp_from_damage(
    damage: f64,
    wound_penalty: i32,
    thresholds: &DamageThresholds,
    high_damage_base_hp: u8,
    high_damage_band_size: u16,
) -> i32 {
    let miss = (thresholds.miss - wound_penalty) as f64;
    let one_hp = (thresholds.one_hp - wound_penalty) as f64;
    let two_hp = (thresholds.two_hp - wound_penalty) as f64;
    let three_hp = (thresholds.three_hp - wound_penalty) as f64;

    if damage <= miss {
        return 0;
    }
    if damage <= one_hp {
        return 1;
    }
    if damage <= two_hp {
        return 2;
    }
    if damage <= three_hp {
        return 3;
    }

    let base_high = (thresholds.three_hp + 1 - wound_penalty) as f64;
    if damage >= base_high {
        high_damage_base_hp as i32 + ((damage - base_high) / high_damage_band_size as f64) as i32
    } else {
        3
    }
}

/// Tracks cumulative damage within a round for incremental HP loss.
///
/// Damage accumulates across multiple hits during a round. Each call to
/// [`accumulate`](DamageTracker::accumulate) adds to the cumulative total and
/// returns only the *additional* HP lost from that hit (not the running total).
///
/// The wound_penalty is captured at round start and held constant for parity
/// with the Ruby implementation (which does not update wound_penalty mid-round).
pub struct DamageTracker {
    pub cumulative_damage: f64,
    pub total_hp_lost: i32,
    pub wound_penalty: i32,
}

impl DamageTracker {
    pub fn new(wound_penalty: i32) -> Self {
        Self {
            cumulative_damage: 0.0,
            total_hp_lost: 0,
            wound_penalty,
        }
    }

    /// Add damage and return the ADDITIONAL HP lost from this hit.
    pub fn accumulate(
        &mut self,
        damage: f64,
        thresholds: &DamageThresholds,
        high_damage_base_hp: u8,
        high_damage_band_size: u16,
    ) -> i32 {
        self.cumulative_damage += damage.max(0.0);
        let new_total = calculate_hp_from_damage(
            self.cumulative_damage,
            self.wound_penalty,
            thresholds,
            high_damage_base_hp,
            high_damage_band_size,
        );
        let additional = (new_total - self.total_hp_lost).max(0);
        self.total_hp_lost = new_total;
        additional
    }

    /// Update wound penalty. Exists for flexibility but default behavior uses
    /// the round-start penalty throughout the round for Ruby parity.
    pub fn update_wound_penalty(&mut self, new_penalty: i32) {
        self.wound_penalty = new_penalty;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::config::DamageThresholds;

    fn default_thresholds() -> DamageThresholds {
        DamageThresholds {
            miss: 9,
            one_hp: 17,
            two_hp: 29,
            three_hp: 99,
        }
    }

    // --- calculate_hp_from_damage tests ---

    #[test]
    fn test_miss() {
        assert_eq!(
            calculate_hp_from_damage(0.0, 0, &default_thresholds(), 4, 100),
            0
        );
        assert_eq!(
            calculate_hp_from_damage(5.0, 0, &default_thresholds(), 4, 100),
            0
        );
        assert_eq!(
            calculate_hp_from_damage(9.0, 0, &default_thresholds(), 4, 100),
            0
        );
    }

    #[test]
    fn test_one_hp() {
        assert_eq!(
            calculate_hp_from_damage(10.0, 0, &default_thresholds(), 4, 100),
            1
        );
        assert_eq!(
            calculate_hp_from_damage(17.0, 0, &default_thresholds(), 4, 100),
            1
        );
    }

    #[test]
    fn test_two_hp() {
        assert_eq!(
            calculate_hp_from_damage(18.0, 0, &default_thresholds(), 4, 100),
            2
        );
        assert_eq!(
            calculate_hp_from_damage(29.0, 0, &default_thresholds(), 4, 100),
            2
        );
    }

    #[test]
    fn test_three_hp() {
        assert_eq!(
            calculate_hp_from_damage(30.0, 0, &default_thresholds(), 4, 100),
            3
        );
        assert_eq!(
            calculate_hp_from_damage(99.0, 0, &default_thresholds(), 4, 100),
            3
        );
    }

    #[test]
    fn test_high_damage_bands() {
        assert_eq!(
            calculate_hp_from_damage(100.0, 0, &default_thresholds(), 4, 100),
            4
        );
        assert_eq!(
            calculate_hp_from_damage(199.0, 0, &default_thresholds(), 4, 100),
            4
        );
        assert_eq!(
            calculate_hp_from_damage(200.0, 0, &default_thresholds(), 4, 100),
            5
        );
        assert_eq!(
            calculate_hp_from_damage(300.0, 0, &default_thresholds(), 4, 100),
            6
        );
    }

    #[test]
    fn test_wound_penalty_shifts_thresholds() {
        // wound_penalty=2: miss threshold drops to 7
        assert_eq!(
            calculate_hp_from_damage(7.0, 2, &default_thresholds(), 4, 100),
            0
        );
        assert_eq!(
            calculate_hp_from_damage(8.0, 2, &default_thresholds(), 4, 100),
            1
        );
        // one_hp threshold drops to 15
        assert_eq!(
            calculate_hp_from_damage(15.0, 2, &default_thresholds(), 4, 100),
            1
        );
        assert_eq!(
            calculate_hp_from_damage(16.0, 2, &default_thresholds(), 4, 100),
            2
        );
    }

    #[test]
    fn test_negative_damage_is_miss() {
        assert_eq!(
            calculate_hp_from_damage(-5.0, 0, &default_thresholds(), 4, 100),
            0
        );
    }

    #[test]
    fn test_large_wound_penalty() {
        // wound_penalty=5: miss threshold = 9-5=4
        assert_eq!(
            calculate_hp_from_damage(4.0, 5, &default_thresholds(), 4, 100),
            0
        );
        assert_eq!(
            calculate_hp_from_damage(5.0, 5, &default_thresholds(), 4, 100),
            1
        );
    }

    // --- DamageTracker tests ---

    #[test]
    fn test_tracker_single_hit() {
        let mut tracker = DamageTracker::new(0);
        let additional = tracker.accumulate(12.0, &default_thresholds(), 4, 100);
        assert_eq!(additional, 1); // 12 damage -> 1 HP bracket
        assert!((tracker.cumulative_damage - 12.0).abs() < f64::EPSILON);
        assert_eq!(tracker.total_hp_lost, 1);
    }

    #[test]
    fn test_tracker_accumulation_crosses_threshold() {
        let mut tracker = DamageTracker::new(0);
        assert_eq!(tracker.accumulate(12.0, &default_thresholds(), 4, 100), 1); // cumulative=12, 1HP
        assert_eq!(tracker.accumulate(8.0, &default_thresholds(), 4, 100), 1); // cumulative=20, 2HP, additional=1
        assert_eq!(tracker.total_hp_lost, 2);
    }

    #[test]
    fn test_tracker_hit_within_same_bracket() {
        let mut tracker = DamageTracker::new(0);
        assert_eq!(tracker.accumulate(10.0, &default_thresholds(), 4, 100), 1); // cumulative=10, 1HP
        assert_eq!(tracker.accumulate(3.0, &default_thresholds(), 4, 100), 0); // cumulative=13, still 1HP
        assert_eq!(tracker.total_hp_lost, 1);
    }

    #[test]
    fn test_tracker_with_wound_penalty() {
        let mut tracker = DamageTracker::new(2); // already lost 2 HP
        // thresholds shifted: miss=7, one_hp=15
        assert_eq!(tracker.accumulate(8.0, &default_thresholds(), 4, 100), 1); // would be miss without penalty
    }
}
