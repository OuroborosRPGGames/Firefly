use combat_core::types::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct Scenario {
    pub fight_state: FightState,
    pub pc_ids: Vec<u64>,
    pub npc_ids: Vec<u64>,
}

pub fn load_scenario(path: &str) -> Result<Scenario, Box<dyn std::error::Error>> {
    let contents = std::fs::read_to_string(path)?;
    let scenario: Scenario = serde_json::from_str(&contents)?;
    Ok(scenario)
}

/// Create a simple test scenario for benchmarking (no file needed).
pub fn default_scenario() -> Scenario {
    let p1 = Participant {
        id: 1,
        side: 0,
        current_hp: 6,
        max_hp: 6,
        position: HexCoord { x: 0, y: 0, z: 0 },
        melee_weapon: Some(Weapon {
            id: 1,
            name: "Sword".into(),
            dice_count: 2,
            dice_sides: 8,
            damage_type: DamageType::Physical,
            reach: 2,
            speed: 5,
            is_ranged: false,
            range_hexes: None,
            attack_range_hexes: 1,
            is_unarmed: false,
        }),
        stat_modifier: 10,
        ai_profile: Some("aggressive".into()),
        ..Default::default()
    };
    let p2 = Participant {
        id: 2,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        position: HexCoord { x: 2, y: 4, z: 0 },
        melee_weapon: Some(Weapon {
            id: 2,
            name: "Axe".into(),
            dice_count: 2,
            dice_sides: 6,
            damage_type: DamageType::Physical,
            reach: 1,
            speed: 6,
            is_ranged: false,
            range_hexes: None,
            attack_range_hexes: 1,
            is_unarmed: false,
        }),
        stat_modifier: 8,
        ai_profile: Some("balanced".into()),
        ..Default::default()
    };
    Scenario {
        fight_state: FightState {
            round: 0,
            participants: vec![p1, p2],
            ..Default::default()
        },
        pc_ids: vec![1],
        npc_ids: vec![2],
    }
}
