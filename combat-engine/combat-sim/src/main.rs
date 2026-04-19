mod balancer;
mod scenario;

use clap::{Parser, Subcommand};
use std::time::Instant;

#[derive(Parser)]
#[command(name = "combat-sim")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Run N simulations of a scenario
    Run {
        #[arg(long)]
        scenario: String,
        #[arg(long, default_value = "100")]
        count: u32,
        #[arg(long)]
        seed: Option<u64>,
    },
    /// Auto-balance a scenario
    Balance {
        #[arg(long)]
        scenario: String,
        #[arg(long, default_value = "100")]
        sims_per_iteration: u32,
        #[arg(long, default_value = "10")]
        max_iterations: u32,
    },
    /// Benchmark simulation throughput
    Bench {
        #[arg(long)]
        scenario: String,
        #[arg(long, default_value = "10")]
        seconds: u64,
    },
    /// Run parity simulations: outputs per-seed JSON lines for comparison
    Parity {
        #[arg(long)]
        scenario: String,
        #[arg(long, default_value = "20")]
        count: u32,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Run {
            scenario,
            count,
            seed: _,
        } => {
            let sc = if scenario == "default" {
                scenario::default_scenario()
            } else {
                scenario::load_scenario(&scenario).expect("Failed to load scenario")
            };
            let results = balancer::run_simulations(&sc.fight_state, count);
            let wins = results.iter().filter(|r| r.pc_won).count();
            let avg_rounds: f64 =
                results.iter().map(|r| r.rounds as f64).sum::<f64>() / results.len() as f64;
            println!(
                "Results: {}/{} PC wins ({:.1}%), avg {:.1} rounds",
                wins,
                count,
                wins as f64 / count as f64 * 100.0,
                avg_rounds
            );
        }
        Commands::Balance {
            scenario,
            sims_per_iteration,
            max_iterations,
        } => {
            let sc = if scenario == "default" {
                scenario::default_scenario()
            } else {
                scenario::load_scenario(&scenario).expect("Failed to load scenario")
            };
            let result = balancer::run_balance(
                &sc.fight_state,
                sims_per_iteration,
                max_iterations,
                1.0,
                30.0,
                80.0,
            );
            let json = serde_json::to_string_pretty(&result).unwrap();
            println!("{}", json);
        }
        Commands::Parity { scenario, count } => {
            let sc = if scenario == "default" {
                scenario::default_scenario()
            } else {
                scenario::load_scenario(&scenario).expect("Failed to load scenario")
            };
            let results = balancer::run_parity(&sc.fight_state, count);
            for r in &results {
                let json = serde_json::to_string(r).unwrap();
                println!("{}", json);
            }
        }
        Commands::Bench {
            scenario,
            seconds,
        } => {
            let sc = if scenario == "default" {
                scenario::default_scenario()
            } else {
                scenario::load_scenario(&scenario).expect("Failed to load scenario")
            };
            let start = Instant::now();
            let mut total = 0u64;
            while start.elapsed().as_secs() < seconds {
                balancer::run_simulations(&sc.fight_state, 100);
                total += 100;
            }
            let elapsed = start.elapsed().as_secs_f64();
            println!(
                "{:.0} sims/sec ({} sims in {:.2}s)",
                total as f64 / elapsed,
                total,
                elapsed
            );
        }
    }
}
