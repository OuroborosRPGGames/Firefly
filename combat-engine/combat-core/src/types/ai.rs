use serde::{Deserialize, Serialize};

/// AI target selection strategy used at runtime.
/// Profile weights and thresholds live in `CombatConfig::ai_profiles`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TargetStrategy {
    Weakest,
    Closest,
    Strongest,
    Threat,
    Random,
}
