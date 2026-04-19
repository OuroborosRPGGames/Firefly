use rand::Rng;
use serde::{Deserialize, Serialize};

/// Maximum number of explosion re-rolls per original die.
/// Mirrors the Ruby DiceRollService's max_explosions default.
pub const MAX_EXPLOSIONS: usize = 10;

/// Result of a dice roll, tracking base dice, explosions, and totals.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RollResult {
    /// All dice values including explosion re-rolls.
    pub dice: Vec<u32>,
    /// Only the original `count` dice (before any explosions).
    pub base_dice: Vec<u32>,
    /// Flat modifier added to the sum.
    pub modifier: i32,
    /// Final total: sum of all dice + modifier.
    pub total: i32,
    /// Number of dice originally requested.
    pub count: u32,
    /// Number of faces per die.
    pub sides: u32,
    /// The value that triggers an explosion (None if non-exploding).
    pub explode_on: Option<u32>,
}

/// Roll `count` dice with `sides` faces, optionally exploding.
///
/// When `explode_on` is `Some(val)` and a die equals `val`, an additional die
/// is rolled and added to the total. Explosions chain up to [`MAX_EXPLOSIONS`]
/// times per original die.
///
/// The RNG is passed in so callers can use a seeded RNG for deterministic
/// testing or a thread RNG for production use.
pub fn roll(
    count: u32,
    sides: u32,
    explode_on: Option<u32>,
    modifier: i32,
    rng: &mut impl Rng,
) -> RollResult {
    let mut base_dice = Vec::with_capacity(count as usize);
    let mut all_dice = Vec::with_capacity(count as usize);

    for _ in 0..count {
        let result = rng.gen_range(1..=sides);
        base_dice.push(result);
        all_dice.push(result);

        // Handle exploding dice
        if let Some(explode_val) = explode_on {
            if result == explode_val {
                let mut current = result;
                let mut explosion_count = 0;
                while current == explode_val && explosion_count < MAX_EXPLOSIONS {
                    current = rng.gen_range(1..=sides);
                    all_dice.push(current);
                    explosion_count += 1;
                }
            }
        }
    }

    let sum: u32 = all_dice.iter().sum();
    let total = sum as i32 + modifier;

    RollResult {
        dice: all_dice,
        base_dice,
        modifier,
        total,
        count,
        sides,
        explode_on,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use rand_chacha::ChaCha8Rng;

    #[test]
    fn test_roll_basic_count_and_range() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = roll(2, 8, None, 0, &mut rng);
        assert_eq!(result.dice.len(), 2);
        assert_eq!(result.base_dice.len(), 2);
        assert!(result.dice.iter().all(|&d| d >= 1 && d <= 8));
        assert_eq!(result.total, result.dice.iter().sum::<u32>() as i32);
        assert_eq!(result.count, 2);
        assert_eq!(result.sides, 8);
    }

    #[test]
    fn test_roll_with_modifier() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = roll(1, 6, None, 5, &mut rng);
        assert_eq!(result.total, result.dice[0] as i32 + 5);
        assert_eq!(result.modifier, 5);
    }

    #[test]
    fn test_roll_deterministic() {
        let mut rng1 = ChaCha8Rng::seed_from_u64(123);
        let mut rng2 = ChaCha8Rng::seed_from_u64(123);
        let r1 = roll(3, 6, None, 0, &mut rng1);
        let r2 = roll(3, 6, None, 0, &mut rng2);
        assert_eq!(r1.dice, r2.dice);
        assert_eq!(r1.total, r2.total);
    }

    #[test]
    fn test_roll_exploding_produces_extra_dice() {
        // Brute-force find a seed that produces an explosion on d8 exploding on 8
        for seed in 0..10000u64 {
            let mut rng = ChaCha8Rng::seed_from_u64(seed);
            let result = roll(1, 8, Some(8), 0, &mut rng);
            if result.dice.len() > 1 {
                assert_eq!(result.base_dice.len(), 1);
                assert_eq!(result.base_dice[0], 8); // must have rolled max to explode
                assert!(result.total > 8);
                return;
            }
        }
        panic!("No seed produced an explosion in 10000 tries");
    }

    #[test]
    fn test_roll_no_explode_when_not_max() {
        // With explode_on=8, a roll of 7 should NOT explode
        for seed in 0..10000u64 {
            let mut rng = ChaCha8Rng::seed_from_u64(seed);
            let result = roll(1, 8, Some(8), 0, &mut rng);
            if result.base_dice[0] != 8 {
                assert_eq!(result.dice.len(), 1); // no explosion
                return;
            }
        }
        panic!("All seeds produced 8s");
    }

    #[test]
    fn test_roll_explosion_capped_at_max() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = roll(1, 8, Some(8), 0, &mut rng);
        // Even with unlucky streaks, can't exceed 1 + MAX_EXPLOSIONS dice
        assert!(result.dice.len() <= 1 + MAX_EXPLOSIONS);
    }

    #[test]
    fn test_roll_zero_dice() {
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let result = roll(0, 8, None, 3, &mut rng);
        assert_eq!(result.dice.len(), 0);
        assert_eq!(result.total, 3); // just modifier
    }

    #[test]
    fn test_roll_variable_sides() {
        // Qi dice can be d4, d6, d8, d10, d12, d14 etc.
        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let r4 = roll(1, 4, Some(4), 0, &mut rng);
        assert!(r4.base_dice[0] >= 1 && r4.base_dice[0] <= 4);

        let mut rng = ChaCha8Rng::seed_from_u64(42);
        let r12 = roll(1, 12, Some(12), 0, &mut rng);
        assert!(r12.base_dice[0] >= 1 && r12.base_dice[0] <= 12);
    }
}
