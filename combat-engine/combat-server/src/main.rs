mod protocol;

use protocol::{Format, Request, Response};
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;
use std::path::Path;
use tokio::net::UnixListener;

const DEFAULT_SOCKET_PATH: &str = "/tmp/combat-engine.sock";

#[tokio::main]
async fn main() {
    let socket_path = std::env::var("COMBAT_ENGINE_SOCKET")
        .unwrap_or_else(|_| DEFAULT_SOCKET_PATH.to_string());
    let format = Format::from_env();

    // Clean up stale socket file from a previous run.
    if Path::new(&socket_path).exists() {
        let _ = std::fs::remove_file(&socket_path);
    }

    let listener = UnixListener::bind(&socket_path).unwrap_or_else(|e| {
        eprintln!("[combat-server] Failed to bind {socket_path}: {e}");
        std::process::exit(1);
    });

    eprintln!(
        "[combat-server] Combat engine listening on {socket_path} (format: {format:?})"
    );

    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                eprintln!("[combat-server] Connection accepted");
                tokio::spawn(handle_connection(stream, format));
            }
            Err(e) => {
                eprintln!("[combat-server] Accept error: {e}");
            }
        }
    }
}

async fn handle_connection(mut stream: tokio::net::UnixStream, format: Format) {
    loop {
        // Read a frame; None means clean EOF (client disconnected).
        let payload = match protocol::read_frame(&mut stream).await {
            Ok(Some(p)) => p,
            Ok(None) => {
                eprintln!("[combat-server] Connection closed");
                return;
            }
            Err(e) => {
                eprintln!("[combat-server] Read error: {e}");
                return;
            }
        };

        // Deserialize the request.
        let response = match format.deserialize_request(&payload) {
            Ok(request) => dispatch(request),
            Err(msg) => {
                eprintln!("[combat-server] Bad request: {msg}");
                Response::Error {
                    code: "bad_request".into(),
                    message: msg,
                }
            }
        };

        // Serialize the response.
        let response_bytes = match format.serialize_response(&response) {
            Ok(b) => b,
            Err(msg) => {
                eprintln!("[combat-server] Serialize error: {msg}");
                // Last-resort error frame so the client gets something back.
                let fallback = Response::Error {
                    code: "internal".into(),
                    message: "failed to serialize response".into(),
                };
                match format.serialize_response(&fallback) {
                    Ok(b) => b,
                    Err(_) => return, // Nothing we can do; drop connection.
                }
            }
        };

        if let Err(e) = protocol::write_frame(&mut stream, &response_bytes).await {
            eprintln!("[combat-server] Write error: {e}");
            return;
        }
    }
}

fn dispatch(request: Request) -> Response {
    match request {
        Request::ResolveRound {
            state,
            actions,
            seed,
            trace_rng,
        } => {
            let result = match (seed, trace_rng) {
                (Some(s), true) => {
                    let mut rng = ChaCha8Rng::seed_from_u64(s);
                    combat_core::resolve_round_traced(&state, &actions, &mut rng)
                }
                (Some(s), false) => {
                    let mut rng = ChaCha8Rng::seed_from_u64(s);
                    combat_core::resolve_round(&state, &actions, &mut rng)
                }
                (None, _) => {
                    let mut rng = rand::thread_rng();
                    combat_core::resolve_round(&state, &actions, &mut rng)
                }
            };
            Response::RoundResult(result)
        }
        Request::GenerateAiActions {
            state,
            participant_ids,
            seed,
        } => {
            let actions = match seed {
                Some(s) => {
                    let mut rng = ChaCha8Rng::seed_from_u64(s);
                    combat_core::generate_ai_actions(&state, &participant_ids, &mut rng)
                }
                None => {
                    let mut rng = rand::thread_rng();
                    combat_core::generate_ai_actions(&state, &participant_ids, &mut rng)
                }
            };
            Response::AiActions { actions }
        }
        Request::Ping => Response::Pong,
    }
}
