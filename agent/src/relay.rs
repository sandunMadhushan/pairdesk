// SPDX-License-Identifier: GPL-3.0-or-later
//! Reaching this computer through a PairDesk relay, when a phone can't
//! reach it directly (another network, no Tailscale).
//!
//! The computer keeps one connection open to each relay it is set to use.
//! When a phone asks a relay for this computer, the relay says so, the
//! computer opens a second connection for that phone, and the relay joins
//! the two. The phone then talks TLS to this computer exactly as on Wi-Fi,
//! with the certificate pinned: the relay only passes encrypted bytes along.
//! See `relay/src/main.rs` for the relay's side.
//!
//! The computer's connections to the relay use TLS (checked against the
//! usual public certificate authorities) when the relay offers it, so
//! firewalls that only let TLS through on port 443 pass them and the
//! computer's secret isn't sent in the clear. A relay that doesn't speak TLS
//! (an older one) is used as before.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use log::{info, warn};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

use crate::server::{Incoming, Via};
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;
use tokio_rustls::rustls::pki_types::ServerName;
use tokio_rustls::rustls::{self, ClientConfig, RootCertStore};

/// The relay PairDesk uses unless the owner picks another (Settings).
pub const DEFAULT_RELAY: &str = "relay.pairdesk.madhushan.me:443";

/// Relays one computer registers with at most.
const MAX_RELAYS: usize = 4;

const TOKEN_FILE: &str = "relay-token";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A relay that doesn't speak TLS never answers a TLS hello; this long is
/// enough to tell.
const TLS_TIMEOUT: Duration = Duration::from_secs(5);
/// After falling back to a plain connection, try TLS again this often.
const TLS_RETRY_AFTER: Duration = Duration::from_secs(600);
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

/// One relay, with what is known about the connection to it.
struct Entry {
    address: String,
    status: Status,
    /// Whether the connection uses TLS (None until one was made).
    tls: Option<bool>,
    /// Why TLS wasn't used, when the relay was reached without it.
    tls_error: Option<String>,
    ips: Vec<String>,
    connect_ms: Option<u64>,
    online_since: Option<Instant>,
    last_ping: Option<Instant>,
    last_error: Option<(String, Instant)>,
    failures: u32,
}

impl Entry {
    fn new(address: &str) -> Self {
        Self {
            address: address.to_string(),
            status: Status::Connecting,
            tls: None,
            tls_error: None,
            ips: Vec::new(),
            connect_ms: None,
            online_since: None,
            last_ping: None,
            last_error: None,
            failures: 0,
        }
    }
}

/// One relay as the settings page shows it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Detail {
    pub address: String,
    pub status: &'static str,
    pub route: Option<String>,
    pub error: Option<String>,
    pub error_secs: Option<u64>,
    pub tls: Option<bool>,
    pub tls_error: Option<String>,
    pub ips: Vec<String>,
    pub connect_ms: Option<u64>,
    pub online_secs: Option<u64>,
    pub ping_secs: Option<u64>,
    pub failures: u32,
}

/// One step of a connection check.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Step {
    pub name: &'static str,
    pub ok: bool,
    pub ms: u64,
    pub note: String,
}

/// The outcome of checking one relay by hand.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Check {
    pub address: String,
    pub ok: bool,
    /// What to tell the owner, in plain words.
    pub summary: String,
    pub steps: Vec<Step>,
}

/// The "Check now" button's state.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum CheckState {
    Idle,
    Running,
    Done { results: Vec<Check> },
}

/// Shared between the relay tasks, the settings page and pairing links.
pub struct Shared {
    entries: Mutex<Vec<Entry>>,
    check: Mutex<CheckState>,
    /// Bumped when the owner changes the relay settings.
    changed: tokio::sync::watch::Sender<u64>,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            entries: Mutex::new(Vec::new()),
            check: Mutex::new(CheckState::Idle),
            changed: tokio::sync::watch::channel(0).0,
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

fn secs(since: Instant) -> u64 {
    since.elapsed().as_secs()
}

impl Shared {
    /// How the relays stand together: connected if any is, else trying, else
    /// the first failure.
    pub fn status(&self) -> Status {
        let entries = lock(&self.entries);
        if let Some(online) = entries
            .iter()
            .find(|e| matches!(e.status, Status::Online { .. }))
        {
            return online.status.clone();
        }
        if entries.iter().any(|e| e.status == Status::Connecting) {
            return Status::Connecting;
        }
        entries
            .iter()
            .find(|e| matches!(e.status, Status::Failed { .. }))
            .map_or(Status::Off, |e| e.status.clone())
    }

    /// `host:port/id` while this computer is reachable through a relay (the
    /// first one that is, in the order they were entered).
    pub fn route(&self) -> Option<String> {
        self.routes().into_iter().next()
    }

    /// Every relay route this computer is reachable through now.
    pub fn routes(&self) -> Vec<String> {
        lock(&self.entries)
            .iter()
            .filter_map(|e| match &e.status {
                Status::Online { route } => Some(route.clone()),
                _ => None,
            })
            .collect()
    }

    /// What the settings page shows for each relay.
    pub fn details(&self) -> Vec<Detail> {
        lock(&self.entries)
            .iter()
            .map(|e| Detail {
                address: e.address.clone(),
                status: match e.status {
                    Status::Off => "off",
                    Status::Connecting => "connecting",
                    Status::Online { .. } => "online",
                    Status::Failed { .. } => "failed",
                },
                route: match &e.status {
                    Status::Online { route } => Some(route.clone()),
                    _ => None,
                },
                error: e.last_error.as_ref().map(|(m, _)| m.clone()),
                error_secs: e.last_error.as_ref().map(|(_, t)| secs(*t)),
                tls: e.tls,
                tls_error: e.tls_error.clone(),
                ips: e.ips.clone(),
                connect_ms: e.connect_ms,
                online_secs: e.online_since.map(secs),
                ping_secs: e.last_ping.map(secs),
                failures: e.failures,
            })
            .collect()
    }

    /// The owner changed the settings: reconnect.
    pub fn settings_changed(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    /// Starts again with these relays, all still connecting.
    fn configure(&self, addresses: &[String]) {
        *lock(&self.entries) = addresses.iter().map(|a| Entry::new(a)).collect();
    }

    fn update(&self, address: &str, f: impl FnOnce(&mut Entry)) {
        if let Some(e) = lock(&self.entries)
            .iter_mut()
            .find(|e| e.address == address)
        {
            f(e);
        }
    }

    pub fn check_state(&self) -> CheckState {
        lock(&self.check).clone()
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

/// Splits the relay setting into addresses: `host:port` separated by commas,
/// semicolons or spaces. Repeats are dropped; at most [`MAX_RELAYS`] are used.
pub fn parse_list(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in text
        .split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .map(str::trim)
        .filter(|a| !a.is_empty())
    {
        if !out.iter().any(|o| o == a) && out.len() < MAX_RELAYS {
            out.push(a.to_string());
        }
    }
    out
}

/// The host part of `host:port` (without the brackets of an IPv6 address).
fn host_of(address: &str) -> &str {
    let host = address.rsplit_once(':').map_or(address, |(h, _)| h);
    host.trim_start_matches('[').trim_end_matches(']')
}

/// A connection to a relay: plain, or inside TLS.
enum Wire {
    Plain(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
}

impl AsyncRead for Wire {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Wire::Plain(s) => Pin::new(s).poll_read(cx, buf),
            Wire::Tls(s) => Pin::new(s.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Wire {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            Wire::Plain(s) => Pin::new(s).poll_write(cx, buf),
            Wire::Tls(s) => Pin::new(s.as_mut()).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Wire::Plain(s) => Pin::new(s).poll_flush(cx),
            Wire::Tls(s) => Pin::new(s.as_mut()).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Wire::Plain(s) => Pin::new(s).poll_shutdown(cx),
            Wire::Tls(s) => Pin::new(s.as_mut()).poll_shutdown(cx),
        }
    }
}

/// TLS towards a relay, trusting the usual public certificate authorities.
fn tls_connector() -> &'static TlsConnector {
    static CONNECTOR: OnceLock<TlsConnector> = OnceLock::new();
    CONNECTOR.get_or_init(|| {
        let roots = RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        };
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("the TLS versions ring supports")
            .with_root_certificates(roots)
            .with_no_client_auth();
        TlsConnector::from(Arc::new(config))
    })
}

/// A relay's addresses, as the name resolves now.
async fn resolve(address: &str) -> Result<Vec<String>, String> {
    let found = tokio::time::timeout(CONNECT_TIMEOUT, tokio::net::lookup_host(address))
        .await
        .map_err(|_| "looking up the relay's name took too long (no internet?)".to_string())?
        .map_err(|e| format!("can't find the relay's address ({e})"))?;
    let mut ips: Vec<String> = Vec::new();
    for a in found {
        let ip = a.ip().to_string();
        if !ips.contains(&ip) {
            ips.push(ip);
        }
    }
    if ips.is_empty() {
        return Err("the relay's name has no address".into());
    }
    Ok(ips)
}

/// Opens one connection to the relay, with TLS or without.
async fn open(
    address: &str,
    tls: Option<(&TlsConnector, Duration)>,
) -> Result<(Wire, u64), String> {
    let started = Instant::now();
    let tcp = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(address))
        .await
        .map_err(|_| "no answer (is the relay reachable from this network?)".to_string())?
        .map_err(|e| e.to_string())?;
    let ms = started.elapsed().as_millis() as u64;
    let _ = tcp.set_nodelay(true);
    let Some((connector, limit)) = tls else {
        return Ok((Wire::Plain(tcp), ms));
    };
    let name = ServerName::try_from(host_of(address).to_string())
        .map_err(|e| format!("not a name TLS can check: {e}"))?;
    let stream = tokio::time::timeout(limit, connector.connect(name, tcp))
        .await
        .map_err(|_| "the relay didn't answer a TLS hello".to_string())?
        .map_err(|e| e.to_string())?;
    Ok((Wire::Tls(Box::new(stream)), ms))
}

/// A connection to the relay and how it was made.
struct Link {
    wire: Wire,
    ips: Vec<String>,
    connect_ms: u64,
    /// Set when TLS was tried and failed, and this one is plain.
    tls_error: Option<String>,
}

/// Connects to the relay: TLS if `try_tls` and the relay is a name (a
/// certificate can't vouch for a bare address), else plain. A TLS attempt
/// that fails falls back to plain, which an older relay needs.
async fn connect(
    address: &str,
    try_tls: bool,
    connector: &TlsConnector,
    tls_limit: Duration,
) -> Result<Link, String> {
    let ips = resolve(address).await?;
    let tls_possible = try_tls && host_of(address).parse::<std::net::IpAddr>().is_err();
    let mut tls_error = None;
    if tls_possible {
        match open(address, Some((connector, tls_limit))).await {
            Ok((wire, connect_ms)) => {
                return Ok(Link {
                    wire,
                    ips,
                    connect_ms,
                    tls_error: None,
                });
            }
            Err(e) => {
                info!("relay {address}: TLS didn't work ({e}); trying without");
                tls_error = Some(e);
            }
        }
    }
    let (wire, connect_ms) = open(address, None).await?;
    Ok(Link {
        wire,
        ips,
        connect_ms,
        tls_error,
    })
}

/// Reads one line without reading past it (what follows belongs to TLS).
async fn read_line_exact<R: AsyncRead + Unpin>(stream: &mut R) -> io::Result<String> {
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    while line.len() < 256 {
        stream.read_exact(&mut b).await?;
        if b[0] == b'\n' {
            return Ok(String::from_utf8_lossy(&line).trim().to_string());
        }
        line.push(b[0]);
    }
    Err(io::Error::other("line too long"))
}

/// Keeps this computer registered with the relays it is set to use, and
/// hands each phone's joined connection to `incoming`.
pub async fn run(
    state: Arc<crate::state::AppState>,
    token: String,
    incoming: mpsc::Sender<Incoming>,
) {
    let mut changed = state.relay.changed.subscribe();
    loop {
        let addresses = {
            let p = state.prefs();
            if p.get().relay_on {
                parse_list(&p.get().relay)
            } else {
                Vec::new()
            }
        };
        state.relay.configure(&addresses);
        // Dropping the set at the end of the round stops these tasks.
        let mut tasks = tokio::task::JoinSet::new();
        for address in addresses {
            tasks.spawn(keep_registered(
                state.clone(),
                address,
                token.clone(),
                incoming.clone(),
            ));
        }
        let _ = changed.changed().await;
    }
}

/// Registers with one relay, again and again.
async fn keep_registered(
    state: Arc<crate::state::AppState>,
    address: String,
    token: String,
    incoming: mpsc::Sender<Incoming>,
) {
    let mut backoff = FIRST_RETRY;
    // Set after TLS failed and a plain connection worked.
    let mut plain_since: Option<Instant> = None;
    loop {
        state.relay.update(&address, |e| {
            e.status = Status::Connecting;
            e.online_since = None;
            e.last_ping = None;
        });
        let try_tls = plain_since.is_none_or(|t| t.elapsed() >= TLS_RETRY_AFTER);
        let started = Instant::now();
        let result = session(
            &state,
            &address,
            &token,
            &incoming,
            try_tls,
            &mut plain_since,
        )
        .await;
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
        state.relay.update(&address, |e| {
            e.status = Status::Failed { msg: msg.clone() };
            e.failures += 1;
            e.last_error = Some((msg, Instant::now()));
            e.online_since = None;
            e.last_ping = None;
        });
        tokio::time::sleep(backoff).await;
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
    incoming: &mpsc::Sender<Incoming>,
    try_tls: bool,
    plain_since: &mut Option<Instant>,
) -> Result<Ended, String> {
    // Shown in the details even when the connection that follows fails.
    if let Ok(ips) = resolve(address).await {
        state.relay.update(address, |e| e.ips = ips);
    }
    let link = connect(address, try_tls, tls_connector(), TLS_TIMEOUT).await?;
    let tls = matches!(link.wire, Wire::Tls(_));
    if link.tls_error.is_some() {
        *plain_since = Some(Instant::now());
    } else if tls {
        *plain_since = None;
    }
    state.relay.update(address, |e| {
        e.tls = Some(tls);
        e.tls_error = link.tls_error.clone();
        e.ips = link.ips.clone();
        e.connect_ms = Some(link.connect_ms);
    });
    let mut control = link.wire;
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
    info!(
        "reachable through the relay {address}{}",
        if tls { " (TLS)" } else { "" }
    );
    state.relay.update(address, |e| {
        e.status = Status::Online { route };
        e.online_since = Some(Instant::now());
        e.last_ping = Some(Instant::now());
    });

    let (read, mut write) = tokio::io::split(control);
    let serve = control_loop(read, &mut write, DEAD_AFTER, |event| match event {
        Event::Ping => state
            .relay
            .update(address, |e| e.last_ping = Some(Instant::now())),
        Event::Incoming(nonce) => {
            let (address, token, incoming, state) = (
                address.to_string(),
                token.to_string(),
                incoming.clone(),
                state.clone(),
            );
            tokio::spawn(async move {
                match answer(&address, &token, &nonce, tls).await {
                    Ok(stream) => {
                        // The phone may open a direct path first.
                        if let Some((stream, direct)) =
                            crate::direct::take(stream, &state, &address).await
                        {
                            let via = direct.map_or(Via::Relay, Via::Direct);
                            let _ = incoming.send(Incoming { stream, via }).await;
                        }
                    }
                    Err(e) => warn!("relay: couldn't take a phone's connection: {e}"),
                }
            });
        }
    });
    tokio::select! {
        r = serve => r.map(|()| Ended::Closed),
        () = watch_for_move() => Ok(Ended::Moved),
    }
}

/// What the relay says on the control connection.
enum Event {
    Ping,
    Incoming(String),
}

/// Answers the relay's pings and reports each ping and each
/// `INCOMING <nonce>` until the relay closes the connection, or says nothing
/// for `dead_after`.
async fn control_loop<R, W>(
    read: R,
    write: &mut W,
    dead_after: Duration,
    mut event: impl FnMut(Event),
) -> Result<(), String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
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
            event(Event::Ping);
            write
                .write_all(b"PONG\n")
                .await
                .map_err(|e| e.to_string())?;
        } else if let Some(nonce) = line.strip_prefix("INCOMING ") {
            event(Event::Incoming(nonce.to_string()));
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

/// Opens this computer's side of one phone's connection. The phone's
/// connection is handed on as an ordinary TCP stream: through TLS to the
/// relay, a local pipe carries it.
async fn answer(address: &str, token: &str, nonce: &str, tls: bool) -> Result<TcpStream, String> {
    let (mut wire, _) = open(address, tls.then(|| (tls_connector(), TLS_TIMEOUT))).await?;
    wire.write_all(format!("PDR1 ACCEPT {token} {nonce}\n").as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let reply = tokio::time::timeout(CONNECT_TIMEOUT, read_line_exact(&mut wire))
        .await
        .map_err(|_| "no answer".to_string())?
        .map_err(|e| e.to_string())?;
    if reply != "OK" {
        return Err(reply);
    }
    match wire {
        Wire::Plain(tcp) => Ok(tcp),
        Wire::Tls(stream) => pipe(*stream).await,
    }
}

/// Turns a connection inside TLS into a plain local TCP stream, with a task
/// copying between the two.
async fn pipe(
    mut outer: impl AsyncRead + AsyncWrite + Unpin + Send + 'static,
) -> Result<TcpStream, String> {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|e| e.to_string())?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;
    let (client, accepted) =
        tokio::try_join!(TcpStream::connect(addr), listener.accept()).map_err(|e| e.to_string())?;
    let (mut inner, from) = accepted;
    // Another program on this computer could have connected first.
    if client.local_addr().ok() != Some(from) {
        return Err("the local pipe was taken by another program".into());
    }
    tokio::spawn(async move {
        let _ = tokio::io::copy_bidirectional(&mut outer, &mut inner).await;
    });
    Ok(client)
}

/// Checks each relay by hand (the "Check now" button), in the background;
/// the result shows in [`Shared::check_state`]. Does nothing if a check is
/// already running.
pub fn start_check(state: Arc<crate::state::AppState>) {
    {
        let mut c = lock(&state.relay.check);
        if *c == CheckState::Running {
            return;
        }
        *c = CheckState::Running;
    }
    let addresses = {
        let p = state.prefs();
        parse_list(&p.get().relay)
    };
    // The web server answers one request at a time, so this must not keep
    // it waiting: it gets its own thread and its own small runtime.
    std::thread::spawn(move || {
        let results = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt.block_on(async {
                let mut out = Vec::new();
                for a in &addresses {
                    let online = state
                        .relay
                        .routes()
                        .iter()
                        .any(|r| r.starts_with(&format!("{a}/")));
                    out.push(check(a, online).await);
                }
                out
            }),
            Err(e) => vec![Check {
                address: String::new(),
                ok: false,
                summary: format!("couldn't run the check: {e}"),
                steps: Vec::new(),
            }],
        };
        *lock(&state.relay.check) = CheckState::Done { results };
    });
}

/// Walks the path to one relay step by step, so the owner can see where it
/// stops. It asks for a computer that doesn't exist, so it changes nothing
/// on the relay; a relay that answers "offline" is a working relay.
async fn check(address: &str, registered: bool) -> Check {
    let mut steps = Vec::new();
    let done = |steps: Vec<Step>, ok: bool, summary: &str| Check {
        address: address.to_string(),
        ok,
        summary: summary.to_string(),
        steps,
    };

    let t = Instant::now();
    let ips = match resolve(address).await {
        Ok(ips) => {
            steps.push(Step {
                name: "Find the relay's address",
                ok: true,
                ms: t.elapsed().as_millis() as u64,
                note: ips.join(", "),
            });
            ips
        }
        Err(e) => {
            steps.push(Step {
                name: "Find the relay's address",
                ok: false,
                ms: t.elapsed().as_millis() as u64,
                note: e,
            });
            return done(
                steps,
                false,
                "This computer can't find the relay's address. Check its internet connection and DNS.",
            );
        }
    };
    let _ = ips;

    let mut link = match open(address, None).await {
        Ok((wire, ms)) => {
            steps.push(Step {
                name: "Connect to the relay",
                ok: true,
                ms,
                note: String::new(),
            });
            Some(wire)
        }
        Err(e) => {
            steps.push(Step {
                name: "Connect to the relay",
                ok: false,
                ms: 0,
                note: e,
            });
            None
        }
    };
    let Some(plain) = link.take() else {
        return done(
            steps,
            false,
            "The relay doesn't answer. A firewall may block this network, or the relay is down.",
        );
    };
    drop(plain);

    let mut over_tls = false;
    if host_of(address).parse::<std::net::IpAddr>().is_err() {
        let t = Instant::now();
        match open(address, Some((tls_connector(), TLS_TIMEOUT))).await {
            Ok((wire, _)) => {
                over_tls = true;
                steps.push(Step {
                    name: "Secure connection (TLS)",
                    ok: true,
                    ms: t.elapsed().as_millis() as u64,
                    note: String::new(),
                });
                link = Some(wire);
            }
            Err(e) => steps.push(Step {
                name: "Secure connection (TLS)",
                ok: false,
                ms: t.elapsed().as_millis() as u64,
                note: format!("{e}. Plain connections still work."),
            }),
        }
    }
    let mut wire = match link {
        Some(w) => w,
        None => match open(address, None).await {
            Ok((w, _)) => w,
            Err(e) => {
                return done(steps, false, &format!("The relay stopped answering: {e}"));
            }
        },
    };

    let t = Instant::now();
    let asked = async {
        wire.write_all(format!("PDR1 CONNECT {}\n", "0".repeat(32)).as_bytes())
            .await?;
        read_line_exact(&mut wire).await
    };
    match tokio::time::timeout(CONNECT_TIMEOUT, asked).await {
        Ok(Ok(reply)) if reply == "ERR offline" => steps.push(Step {
            name: "Ask the relay",
            ok: true,
            ms: t.elapsed().as_millis() as u64,
            note: "It answers like a PairDesk relay".into(),
        }),
        Ok(Ok(reply)) => {
            steps.push(Step {
                name: "Ask the relay",
                ok: false,
                ms: t.elapsed().as_millis() as u64,
                note: format!("It said: {reply}"),
            });
            return done(
                steps,
                false,
                "Something answers there, but it isn't a PairDesk relay.",
            );
        }
        Ok(Err(e)) => {
            steps.push(Step {
                name: "Ask the relay",
                ok: false,
                ms: t.elapsed().as_millis() as u64,
                note: e.to_string(),
            });
            return done(steps, false, "The relay closed the connection when asked.");
        }
        Err(_) => {
            steps.push(Step {
                name: "Ask the relay",
                ok: false,
                ms: t.elapsed().as_millis() as u64,
                note: "no answer".into(),
            });
            return done(steps, false, "The relay didn't answer when asked.");
        }
    }

    let summary = match (registered, over_tls) {
        (true, true) => "The relay works, and this computer is registered with it over TLS.",
        (true, false) => "The relay works, and this computer is registered with it.",
        (false, _) => {
            "The relay works, but this computer isn't registered with it right now. It tries again on its own."
        }
    };
    done(steps, registered, summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_silent_relay_is_given_up_on() {
        let (mine, _relay) = tokio::io::duplex(1024);
        let (read, mut write) = tokio::io::split(mine);
        let started = Instant::now();
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
        let (mut nonces, mut pings) = (Vec::new(), 0);
        let result = control_loop(read, &mut write, Duration::from_secs(5), |e| match e {
            Event::Ping => pings += 1,
            Event::Incoming(n) => nonces.push(n),
        })
        .await;
        // The relay closing the connection is a clean end, not an error.
        assert_eq!(result, Ok(()));
        assert_eq!(nonces, ["abc123"]);
        assert_eq!(pings, 2);
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
    fn relay_lists_are_split_and_limited() {
        assert_eq!(parse_list("a.example:443"), ["a.example:443"]);
        assert_eq!(
            parse_list(" a.example:443, b.example:443;a.example:443  c.example:1 "),
            ["a.example:443", "b.example:443", "c.example:1"]
        );
        assert!(parse_list("  ").is_empty());
        assert_eq!(parse_list("a:1 b:1 c:1 d:1 e:1 f:1").len(), MAX_RELAYS);
        assert_eq!(host_of("relay.example.org:443"), "relay.example.org");
        assert_eq!(host_of("[::1]:443"), "::1");
    }

    #[test]
    fn relays_together_are_online_if_any_is() {
        let shared = Shared::default();
        shared.configure(&["a:1".into(), "b:1".into()]);
        assert_eq!(shared.status(), Status::Connecting);
        shared.update("a", |_| {});
        shared.update("a:1", |e| e.status = Status::Failed { msg: "down".into() });
        assert_eq!(shared.status(), Status::Connecting, "b is still trying");
        shared.update("b:1", |e| {
            e.status = Status::Online {
                route: "b:1/abc".into(),
            }
        });
        assert_eq!(
            shared.status(),
            Status::Online {
                route: "b:1/abc".into()
            }
        );
        assert_eq!(shared.routes(), ["b:1/abc"]);
        assert_eq!(shared.route().as_deref(), Some("b:1/abc"));
        shared.update("b:1", |e| e.status = Status::Failed { msg: "gone".into() });
        assert_eq!(shared.status(), Status::Failed { msg: "down".into() });
        shared.configure(&[]);
        assert_eq!(shared.status(), Status::Off);
        assert!(shared.route().is_none());
    }

    /// A relay that only speaks the plain protocol: the TLS hello gets no
    /// answer, so the computer falls back and says why.
    #[tokio::test]
    async fn falls_back_to_plain_for_an_older_relay() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let (mut s, _) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    // Reads and says nothing, like a relay waiting for a line.
                    let mut buf = [0u8; 64];
                    let _ = s.read(&mut buf).await;
                    tokio::time::sleep(Duration::from_secs(5)).await;
                });
            }
        });
        let address = format!("localhost:{port}");
        let link = connect(&address, true, tls_connector(), Duration::from_millis(300))
            .await
            .unwrap();
        assert!(matches!(link.wire, Wire::Plain(_)));
        assert!(link.tls_error.is_some());
        assert!(!link.ips.is_empty());
        // Without TLS asked for, there is nothing to explain.
        let link = connect(&address, false, tls_connector(), Duration::from_millis(300))
            .await
            .unwrap();
        assert!(link.tls_error.is_none());
    }

    /// A relay with TLS, signed by an authority this computer trusts.
    #[tokio::test]
    async fn talks_tls_to_a_relay_that_offers_it() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let server_config = rustls::ServerConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![cert.cert.der().clone()],
                rustls::pki_types::PrivateKeyDer::Pkcs8(
                    rustls::pki_types::PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der()),
                ),
            )
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server_config));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut tls = acceptor.accept(tcp).await.unwrap();
            let line = read_line_exact(&mut tls).await.unwrap();
            tls.write_all(format!("GOT {line}\n").as_bytes())
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_secs(1)).await;
        });

        let mut roots = RootCertStore::empty();
        roots.add(cert.cert.der().clone()).unwrap();
        let config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
        let connector = TlsConnector::from(Arc::new(config));
        let link = connect(
            &format!("localhost:{port}"),
            true,
            &connector,
            Duration::from_secs(5),
        )
        .await
        .unwrap();
        assert!(link.tls_error.is_none());
        let mut wire = link.wire;
        assert!(matches!(wire, Wire::Tls(_)));
        wire.write_all(b"hello\n").await.unwrap();
        assert_eq!(read_line_exact(&mut wire).await.unwrap(), "GOT hello");
    }

    #[tokio::test]
    async fn a_tls_connection_is_handed_on_as_plain_tcp() {
        let (outer, relay_side) = tokio::io::duplex(4096);
        let mut phone = pipe(outer).await.unwrap();
        let (mut relay_read, mut relay_write) = tokio::io::split(relay_side);
        relay_write.write_all(b"from the phone").await.unwrap();
        let mut buf = [0u8; 14];
        phone.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"from the phone");
        phone.write_all(b"to the phone").await.unwrap();
        let mut buf = [0u8; 12];
        relay_read.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"to the phone");
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
