use combat_core::types::*;
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;
use rayon::prelude::*;

#[derive(Debug, serde::Serialize)]
pub struct BalanceResult {
    pub iterations: u32,
    pub final_win_rate: f64,
    pub final_avg_score: f64,
    pub balanced: bool,
}

#[derive(Debug, serde::Serialize)]
pub struct ParityResult {
    pub seed: u64,
    pub pc_won: bool,
    pub rounds: u32,
    pub pc_hp_remaining: i32,
    pub npc_hp_remaining: i32,
    pub participant_hp: Vec<(u64, u8)>,
}

#[derive(Debug)]
pub struct SimResult {
    pub pc_won: bool,
    pub rounds: u32,
    pub pc_hp_remaining: i32,
    pub npc_hp_remaining: i32,
}

pub fn run_balance(
    initial_state: &FightState,
    sims_per_iteration: u32,
    max_iterations: u32,
    target_win_rate: f64,
    target_score_min: f64,
    target_score_max: f64,
) -> BalanceResult {
    let state = initial_state.clone();

    for iteration in 0..max_iterations {
        let results = run_simulations(&state, sims_per_iteration);
        let win_rate =
            results.iter().filter(|r| r.pc_won).count() as f64 / results.len() as f64;
        let avg_score = results
            .iter()
            .map(|r| {
                if r.pc_won {
                    r.pc_hp_remaining as f64 * 10.0
                } else {
                    0.0
                }
            })
            .sum::<f64>()
            / results.len() as f64;

        if win_rate >= target_win_rate
            && avg_score >= target_score_min
            && avg_score <= target_score_max
        {
            return BalanceResult {
                iterations: iteration + 1,
                final_win_rate: win_rate,
                final_avg_score: avg_score,
                balanced: true,
            };
        }

        // TODO: adjust NPC stats based on results
        // For now, just report the current state
    }

    let results = run_simulations(&state, sims_per_iteration);
    let win_rate = results.iter().filter(|r| r.pc_won).count() as f64 / results.len() as f64;
    let avg_score = results
        .iter()
        .map(|r| {
            if r.pc_won {
                r.pc_hp_remaining as f64 * 10.0
            } else {
                0.0
            }
        })
        .sum::<f64>()
        / results.len() as f64;

    BalanceResult {
        iterations: max_iterations,
        final_win_rate: win_rate,
        final_avg_score: avg_score,
        balanced: false,
    }
}

/// Run simulations sequentially (not parallel) and return detailed per-seed results
/// for parity comparison with the Ruby simulator.
pub fn run_parity(state: &FightState, count: u32) -> Vec<ParityResult> {
    (0..count)
        .map(|i| {
            let seed = i as u64;
            let mut rng = ChaCha8Rng::seed_from_u64(seed);
            let mut sim_state = state.clone();
            let max_rounds = sim_state.config.simulator.max_rounds;

            for _ in 0..max_rounds {
                let all_ids: Vec<u64> = sim_state
                    .participants
                    .iter()
                    .filter(|p| !p.is_knocked_out)
                    .map(|p| p.id)
                    .collect();
                if all_ids.len() <= 1 {
                    break;
                }
                let side0 = sim_state.participants.iter().any(|p| p.side == 0 && !p.is_knocked_out);
                let side1 = sim_state.participants.iter().any(|p| p.side == 1 && !p.is_knocked_out);
                if !side0 || !side1 {
                    break;
                }

                let actions = combat_core::generate_ai_actions(&sim_state, &all_ids, &mut rng);
                let result = combat_core::resolve_round(&sim_state, &actions, &mut rng);
                sim_state = result.next_state;
                if result.fight_ended {
                    break;
                }
            }

            let pc_hp: i32 = sim_state.participants.iter().filter(|p| p.side == 0).map(|p| p.current_hp as i32).sum();
            let npc_hp: i32 = sim_state.participants.iter().filter(|p| p.side == 1).map(|p| p.current_hp as i32).sum();
            let pc_won = sim_state.participants.iter().filter(|p| p.side == 1).all(|p| p.is_knocked_out);
            let participant_hp: Vec<(u64, u8)> = sim_state.participants.iter().map(|p| (p.id, p.current_hp)).collect();

            ParityResult { seed, pc_won, rounds: sim_state.round, pc_hp_remaining: pc_hp, npc_hp_remaining: npc_hp, participant_hp }
        })
        .collect()
}

pub fn run_simulations(state: &FightState, count: u32) -> Vec<SimResult> {
    (0..count)
        .into_par_iter()
        .map(|i| {
            let mut rng = ChaCha8Rng::seed_from_u64(i as u64);
            let mut sim_state = state.clone();
            let max_rounds = sim_state.config.simulator.max_rounds;

            for _ in 0..max_rounds {
                let all_ids: Vec<u64> = sim_state
                    .participants
                    .iter()
                    .filter(|p| !p.is_knocked_out)
                    .map(|p| p.id)
                    .collect();
                let actions = combat_core::generate_ai_actions(&sim_state, &all_ids, &mut rng);
                let result = combat_core::resolve_round(&sim_state, &actions, &mut rng);
                sim_state = result.next_state;
                if result.fight_ended {
                    break;
                }
            }

            let pc_hp: i32 = sim_state
                .participants
                .iter()
                .filter(|p| p.side == 0)
                .map(|p| p.current_hp as i32)
                .sum();
            let npc_hp: i32 = sim_state
                .participants
                .iter()
                .filter(|p| p.side == 1)
                .map(|p| p.current_hp as i32)
                .sum();
            let pc_won = sim_state
                .participants
                .iter()
                .filter(|p| p.side == 1)
                .all(|p| p.is_knocked_out);

            SimResult {
                pc_won,
                rounds: sim_state.round,
                pc_hp_remaining: pc_hp,
                npc_hp_remaining: npc_hp,
            }
        })
        .collect()
}
