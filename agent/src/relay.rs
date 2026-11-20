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
/// The relay pings every 25 s. Three missed pings in a row means the link
/// is dead even though TCP hasn't said so (a laptop that slept, a router
/// that forgot the connection): the relay has already dropped this
/// computer by then, so register again.
const DEAD_AFTER: Duration = Duration::from_secs(80);
/// How often to look for a wake from sleep or a change of network.
const WATCH_EVERY: Duration = Duration::from_secs(5);
/// More than this beyond [`WATCH_EVERY`] between two looks means the
/// computer was asleep.
const SLEEP_GAP: Duration = Duration::from_secs(20);
/// A registration that lasted this long was a good one, so the next try
/// after it ends starts again at the short delay.
const STABLE_AFTER: Duration = Duration::from_secs(30);
const FIRST_RETRY: Duration = Duration::from_secs(2);
const LAST_RETRY: Duration = Duration::from_secs(60);

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
    let mut backoff = FIRST_RETRY;
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
        let started = tokio::time::Instant::now();
        let result = tokio::select! {
            r = session(&state, &address, &token, &incoming) => r,
            _ = changed.changed() => {
                backoff = FIRST_RETRY;
                continue;
            }
        };
        backoff = backoff_after_session(backoff, started.elapsed());
        let msg = match result {
            Ok(Ended::Moved) => {
                // Woke up or changed network: the old connection is useless,
                // so register again straight away.
                info!("relay {address}: the computer woke up or changed network; reconnecting");
                continue;
            }
            Ok(Ended::Closed) => "the relay closed the connection".to_string(),
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
        backoff = (backoff * 2).min(LAST_RETRY);
    }
}

/// Why a registration ended without an error.
enum Ended {
    /// The relay closed the connection.
    Closed,
    /// The computer woke from sleep or its network changed.
    Moved,
}

/// After a registration that lasted [`STABLE_AFTER`] the delay starts over;
/// otherwise it keeps growing, so a relay that is down isn't hammered.
fn backoff_after_session(backoff: Duration, lasted: Duration) -> Duration {
    if lasted >= STABLE_AFTER {
        FIRST_RETRY
    } else {
        backoff
    }
}

/// One registration, until the connection drops.
async fn session(
    state: &Arc<crate::state::AppState>,
    address: &str,
    token: &str,
    incoming: &mpsc::Sender<TcpStream>,
) -> Result<Ended, String> {
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
    let serve = control_loop(read, &mut write, DEAD_AFTER, |nonce| {
        let (address, token, incoming) = (address.to_string(), token.to_string(), incoming.clone());
        tokio::spawn(async move {
            match answer(&address, &token, &nonce).await {
                Ok(stream) => {
                    let _ = incoming.send(stream).await;
                }
                Err(e) => warn!("relay: couldn't take a phone's connection: {e}"),
            }
        });
    });
    tokio::select! {
        r = serve => r.map(|()| Ended::Closed),
        () = watch_for_move() => Ok(Ended::Moved),
    }
}

/// Answers the relay's pings and passes on each `INCOMING <nonce>` until
/// the relay closes the connection, or says nothing for `dead_after`.
async fn control_loop<R, W>(
    read: R,
    write: &mut W,
    dead_after: Duration,
    mut incoming: impl FnMut(String),
) -> Result<(), String>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let mut lines = BufReader::new(read).lines();
    loop {
        let line = tokio::time::timeout(dead_after, lines.next_line())
            .await
            .map_err(|_| "the relay stopped answering".to_string())?
            .map_err(|e| e.to_string())?;
        let Some(line) = line else {
            return Ok(());
        };
        if line == "PING" {
            write
                .write_all(b"PONG\n")
                .await
                .map_err(|e| e.to_string())?;
        } else if let Some(nonce) = line.strip_prefix("INCOMING ") {
            incoming(nonce.to_string());
        }
    }
}

/// This computer's own addresses, not counting Tailscale's.
fn local_addresses() -> Vec<std::net::Ipv4Addr> {
    let mut v: Vec<_> = crate::net::addresses()
        .into_iter()
        .filter(|a| a.kind != crate::net::Kind::Tailscale)
        .map(|a| a.ip)
        .collect();
    v.sort();
    v
}

/// Returns when the computer has woken from sleep or its addresses have
/// changed. A connection that was open before either is dead, but TCP
/// often doesn't say so for a long time.
async fn watch_for_move() {
    let mut tick = tokio::time::interval(WATCH_EVERY);
    let mut clock = std::time::SystemTime::now();
    let addresses = local_addresses();
    loop {
        tick.tick().await;
        let now = std::time::SystemTime::now();
        let slept = now
            .duration_since(clock)
            .map_or(true, |d| d > WATCH_EVERY + SLEEP_GAP);
        clock = now;
        if slept || local_addresses() != addresses {
            return;
        }
    }
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

    #[tokio::test]
    async fn a_silent_relay_is_given_up_on() {
        let (mine, _relay) = tokio::io::duplex(1024);
        let (read, mut write) = tokio::io::split(mine);
        let started = std::time::Instant::now();
        let result = control_loop(read, &mut write, Duration::from_millis(150), |_| {}).await;
        assert_eq!(result, Err("the relay stopped answering".to_string()));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[tokio::test]
    async fn pings_are_answered_and_phones_passed_on() {
        let (mine, relay) = tokio::io::duplex(1024);
        let (read, mut write) = tokio::io::split(mine);
        let mut relay = relay;
        relay
            .write_all(b"PING\nINCOMING abc123\nPING\n")
            .await
            .unwrap();
        relay.shutdown().await.unwrap();
        let mut nonces = Vec::new();
        let result =
            control_loop(read, &mut write, Duration::from_secs(5), |n| nonces.push(n)).await;
        // The relay closing the connection is a clean end, not an error.
        assert_eq!(result, Ok(()));
        assert_eq!(nonces, ["abc123"]);
        drop(write);
        let mut answered = String::new();
        relay.read_to_string(&mut answered).await.unwrap();
        assert_eq!(answered, "PONG\nPONG\n");
    }

    #[test]
    fn a_good_session_resets_the_delay() {
        let long = Duration::from_secs(60);
        assert_eq!(backoff_after_session(long, STABLE_AFTER), FIRST_RETRY);
        assert_eq!(backoff_after_session(long, Duration::from_secs(29)), long);
    }

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
