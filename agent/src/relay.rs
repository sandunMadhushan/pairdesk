// SPDX-License-Identifier: GPL-3.0-or-later
//! Reaching this computer through a PairDesk relay, when a phone can't
//! reach it directly (another network, no Tailscale).
//!
//! The computer keeps one connection open to the relay. When a phone asks
//! the relay for this computer, the relay says so, the computer opens a
//! second connection for that phone, and the relay joins the two. The
//! phone then talks TLS to this computer exactly as on Wi-Fi, with the
//! certificate pinned: the relay only passes encrypted bytes along. See
//! `relay/src/main.rs` for the relay's side.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use log::{info, warn};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

/// The relay PairDesk uses unless the owner picks another (Settings).
pub const DEFAULT_RELAY: &str = "relay.pairdesk.madhushan.me:443";

const TOKEN_FILE: &str = "relay-token";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// What the settings page shows.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Status {
    Off,
    Connecting,
    Online { route: String },
    Failed { msg: String },
}

/// Shared between the relay task, the settings page and pairing links.
pub struct Shared {
    status: Mutex<Status>,
    /// Bumped when the owner changes the relay settings.
    changed: tokio::sync::watch::Sender<u64>,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            status: Mutex::new(Status::Off),
            changed: tokio::sync::watch::channel(0).0,
        }
    }
}

impl Shared {
    pub fn status(&self) -> Status {
        self.status
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    fn set(&self, s: Status) {
        *self.status.lock().unwrap_or_else(|p| p.into_inner()) = s;
    }

    /// `host:port/id` while this computer is reachable through the relay.
    pub fn route(&self) -> Option<String> {
        match self.status() {
            Status::Online { route } => Some(route),
            _ => None,
        }
    }

    /// The owner changed the settings: reconnect.
    pub fn settings_changed(&self) {
        self.changed.send_modify(|n| *n += 1);
    }
}

/// This computer's relay identity: a random secret; the relay knows it by
/// a hash of it, so only this computer can claim its id.
pub fn load_token(data_dir: &std::path::Path) -> std::io::Result<String> {
    let path = data_dir.join(TOKEN_FILE);
    if let Ok(t) = std::fs::read_to_string(&path) {
        let t = t.trim().to_string();
        if t.len() >= 16 {
            return Ok(t);
        }
    }
    let t = crate::config::b64(&crate::config::random_bytes::<32>());
    crate::config::write_private(&path, t.as_bytes())?;
    Ok(t)
}

pub fn host_id(token: &str) -> String {
    Sha256::digest(token.as_bytes())[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Reads one line without reading past it (what follows belongs to TLS).
async fn read_line_exact(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    while line.len() < 256 {
        stream.read_exact(&mut b).await?;
        if b[0] == b'\n' {
            return Ok(String::from_utf8_lossy(&line).trim().to_string());
        }
        line.push(b[0]);
    }
    Err(std::io::Error::other("line too long"))
}

/// Keeps this computer registered with the relay while relaying is on,
/// and hands each phone's joined connection to `incoming`.
pub async fn run(
    state: Arc<crate::state::AppState>,
    token: String,
    incoming: mpsc::Sender<TcpStream>,
) {
    let shared = &state.relay;
    let mut changed = shared.changed.subscribe();
    let mut backoff = Duration::from_secs(2);
    loop {
        let (on, address) = {
            let p = state.prefs();
            (p.get().relay_on, p.get().relay.clone())
        };
        if !on || address.trim().is_empty() {
            shared.set(Status::Off);
            let _ = changed.changed().await;
            continue;
        }
        shared.set(Status::Connecting);
        let result = tokio::select! {
            r = session(&state, &address, &token, &incoming) => r,
            _ = changed.changed() => {
                backoff = Duration::from_secs(2);
                continue;
            }
        };
        let msg = match result {
            Ok(()) => "the relay closed the connection".to_string(),
            Err(e) => e,
        };
        warn!(
            "relay {address}: {msg}; trying again in {}s",
            backoff.as_secs()
        );
        shared.set(Status::Failed { msg });
        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            _ = changed.changed() => {}
        }
        backoff = (backoff * 2).min(Duration::from_secs(60));
    }
}

/// One registration, until the connection drops.
async fn session(
    state: &Arc<crate::state::AppState>,
    address: &str,
    token: &str,
    incoming: &mpsc::Sender<TcpStream>,
) -> Result<(), String> {
    let mut control = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(address))
        .await
        .map_err(|_| "no answer".to_string())?
        .map_err(|e| e.to_string())?;
    let _ = control.set_nodelay(true);
    control
        .write_all(format!("PDR1 HOST {token}\n").as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let first = tokio::time::timeout(CONNECT_TIMEOUT, read_line_exact(&mut control))
        .await
        .map_err(|_| "no answer".to_string())?
        .map_err(|e| e.to_string())?;
    let id = first
        .strip_prefix("OK ")
        .ok_or_else(|| format!("refused: {first}"))?
        .to_string();
    if id != host_id(token) {
        return Err("the relay answered with the wrong id".into());
    }
    let route = format!("{address}/{id}");
    info!("reachable through the relay {address}");
    state.relay.set(Status::Online { route });

    let (read, mut write) = control.into_split();
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await.map_err(|e| e.to_string())? {
        if line == "PING" {
            write
                .write_all(b"PONG\n")
                .await
                .map_err(|e| e.to_string())?;
        } else if let Some(nonce) = line.strip_prefix("INCOMING ") {
            let (address, token, nonce, incoming) = (
                address.to_string(),
                token.to_string(),
                nonce.to_string(),
                incoming.clone(),
            );
            tokio::spawn(async move {
                match answer(&address, &token, &nonce).await {
                    Ok(stream) => {
                        let _ = incoming.send(stream).await;
                    }
                    Err(e) => warn!("relay: couldn't take a phone's connection: {e}"),
                }
            });
        }
    }
    Ok(())
}

/// Opens this computer's side of one phone's connection.
async fn answer(address: &str, token: &str, nonce: &str) -> Result<TcpStream, String> {
    let mut s = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(address))
        .await
        .map_err(|_| "no answer".to_string())?
        .map_err(|e| e.to_string())?;
    let _ = s.set_nodelay(true);
    s.write_all(format!("PDR1 ACCEPT {token} {nonce}\n").as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let reply = tokio::time::timeout(CONNECT_TIMEOUT, read_line_exact(&mut s))
        .await
        .map_err(|_| "no answer".to_string())?
        .map_err(|e| e.to_string())?;
    if reply != "OK" {
        return Err(reply);
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_kept_and_id_matches_the_relay() {
        let dir = tempfile::tempdir().unwrap();
        let a = load_token(dir.path()).unwrap();
        let b = load_token(dir.path()).unwrap();
        assert_eq!(a, b);
        assert!(a.len() >= 40);
        // Same derivation as relay/src/main.rs.
        assert_eq!(host_id("abc"), "ba7816bf8f01cfea414140de5dae2223");
    }
}
