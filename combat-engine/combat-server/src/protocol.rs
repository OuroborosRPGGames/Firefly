use combat_core::types::{FightState, PlayerAction, RoundResult};
use serde::{Deserialize, Serialize};
use std::io;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

// ---------------------------------------------------------------------------
// Request / Response enums (internally tagged via `type` field)
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum Request {
    #[serde(rename = "resolve_round")]
    ResolveRound {
        state: FightState,
        actions: Vec<PlayerAction>,
        seed: Option<u64>,
        #[serde(default)]
        trace_rng: bool,
    },
    #[serde(rename = "generate_ai_actions")]
    GenerateAiActions {
        state: FightState,
        participant_ids: Vec<u64>,
        seed: Option<u64>,
    },
    #[serde(rename = "ping")]
    Ping,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum Response {
    #[serde(rename = "round_result")]
    RoundResult(RoundResult),
    #[serde(rename = "ai_actions")]
    AiActions { actions: Vec<PlayerAction> },
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "error")]
    Error { code: String, message: String },
}

// ---------------------------------------------------------------------------
// Wire format (JSON vs MessagePack)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    MsgPack,
    Json,
}

impl Format {
    pub fn from_env() -> Self {
        // Default matches the Ruby client's default (JSON) so operators only
        // need to flip one environment variable to switch both sides.
        match std::env::var("COMBAT_ENGINE_FORMAT").as_deref() {
            Ok("msgpack") => Format::MsgPack,
            _ => Format::Json,
        }
    }

    pub fn deserialize_request(&self, buf: &[u8]) -> Result<Request, String> {
        match self {
            Format::Json => {
                serde_json::from_slice(buf).map_err(|e| format!("JSON decode error: {e}"))
            }
            Format::MsgPack => {
                rmp_serde::from_slice(buf).map_err(|e| format!("MsgPack decode error: {e}"))
            }
        }
    }

    pub fn serialize_response(&self, resp: &Response) -> Result<Vec<u8>, String> {
        match self {
            Format::Json => {
                serde_json::to_vec(resp).map_err(|e| format!("JSON encode error: {e}"))
            }
            Format::MsgPack => {
                rmp_serde::to_vec_named(resp).map_err(|e| format!("MsgPack encode error: {e}"))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Length-prefixed frame I/O
// ---------------------------------------------------------------------------

/// Read a single length-prefixed frame. Returns `Ok(None)` on clean EOF.
pub async fn read_frame(stream: &mut UnixStream) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match stream.read_exact(&mut len_buf).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len_buf) as usize;

    // Sanity cap: reject frames larger than 64 MiB
    if len > 64 * 1024 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame too large: {len} bytes"),
        ));
    }

    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;
    Ok(Some(payload))
}

/// Write a single length-prefixed frame.
pub async fn write_frame(stream: &mut UnixStream, data: &[u8]) -> io::Result<()> {
    let len = (data.len() as u32).to_be_bytes();
    stream.write_all(&len).await?;
    stream.write_all(data).await?;
    stream.flush().await?;
    Ok(())
}
