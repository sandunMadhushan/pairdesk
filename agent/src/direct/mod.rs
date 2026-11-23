// SPDX-License-Identifier: GPL-3.0-or-later
//! Direct connections: the phone and this computer open a path to each
//! other through their routers (UDP "hole punching"), so the relay only
//! introduces them and the screen doesn't pass through it.
//!
//! How it goes, on a connection the relay has just joined:
//!
//! 1. The phone learns its public UDP address from the relay (STUN) and
//!    sends, before anything else, one line signed with its pairing key:
//!    `PDD1 <phone id> <time> <token> <addresses> <signature>`.
//! 2. This computer checks the signature against its paired phones, learns
//!    its own public address the same way and answers `PDD1 OK <addresses>`
//!    (or `PDD1 NO <reason>`).
//! 3. Both send small PUNCH packets to each other's addresses. Each
//!    router sees traffic going out and lets the answers in.
//! 4. If a path opens, the phone runs its TLS connection over it
//!    ([conn::Conn] makes UDP a reliable stream) and closes the relayed one.
//!    If not, the phone starts TLS on the relayed connection as before.
//!
//! The certificate is pinned and the phone signs in exactly as on any
//! other route, so the direct path is no less private than the relayed one.

pub mod conn;

use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use ed25519_dalek::{Signature, VerifyingKey};
use log::{info, warn};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

use conn::{Conn, State};

/// First bytes of the phone's offer line.
pub const OFFER_PREFIX: &[u8] = b"PDD1 ";
const CONTEXT: &[u8] = b"pairdesk-direct-v1\0";
/// Offers older (or newer) than this are refused: a recorded one can't be
/// used again later.
const OFFER_AGE: u64 = 120;
const MAX_LINE: usize = 1024;
const MAX_CANDIDATES: usize = 8;
const STUN_COOKIE: u32 = 0x2112_A442;
/// How long the phone may take to open the path and start TLS on it.
const PUNCH_WINDOW: Duration = Duration::from_secs(6);
const PUNCH_EVERY: Duration = Duration::from_millis(100);

/// What the settings page shows about direct connections.
#[derive(Default)]
pub struct Shared {
    last: Mutex<Option<(Instant, Outcome)>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Direct,
    Relayed(String),
}

impl Shared {
    fn record(&self, outcome: Outcome) {
        *self.last.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), outcome));
    }

    /// The last phone that came through the relay: did it go direct?
    /// (seconds ago, outcome)
    pub fn last(&self) -> Option<(u64, Outcome)> {
        self.last
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|(at, o)| (at.elapsed().as_secs(), o.clone()))
    }
}

/// A phone's offer, as sent.
#[derive(Debug, Clone, PartialEq)]
pub struct Offer {
    pub phone: String,
    pub time: u64,
    pub token: [u8; 8],
    pub candidates: Vec<SocketAddr>,
    pub signature: String,
}

fn hex8(token: &[u8; 8]) -> String {
    token.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex8(s: &str) -> Option<[u8; 8]> {
    if s.len() != 16 {
        return None;
    }
    let mut out = [0u8; 8];
    for (i, o) in out.iter_mut().enumerate() {
        *o = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

pub fn format_candidates(list: &[SocketAddr]) -> String {
    if list.is_empty() {
        return "-".into();
    }
    list.iter()
        .map(|a| a.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

/// IPv4 `ip:port` addresses, at most [MAX_CANDIDATES]. Loopback,
/// unspecified and multicast addresses are dropped: nobody should be made
/// to send packets there.
pub fn parse_candidates(s: &str) -> Vec<SocketAddr> {
    if s == "-" {
        return Vec::new();
    }
    s.split(',')
        .filter_map(|a| a.parse::<SocketAddrV4>().ok())
        .filter(|a| {
            let ip = a.ip();
            !ip.is_unspecified()
                && !ip.is_multicast()
                && !ip.is_broadcast()
                && a.port() != 0
                && (!ip.is_loopback() || cfg!(test) || std::env::var_os("PAIRDESK_E2E").is_some())
        })
        .map(SocketAddr::V4)
        .take(MAX_CANDIDATES)
        .collect()
}

impl Offer {
    pub fn parse(line: &str) -> Option<Offer> {
        let mut parts = line.strip_prefix("PDD1 ")?.split(' ');
        let phone = parts.next()?.to_string();
        let time = parts.next()?.parse().ok()?;
        let token = unhex8(parts.next()?)?;
        let candidates = parse_candidates(parts.next()?);
        let signature = parts.next()?.to_string();
        if parts.next().is_some() {
            return None;
        }
        Some(Offer {
            phone,
            time,
            token,
            candidates,
            signature,
        })
    }

    /// What the phone signs: ties the offer to this computer (its
    /// certificate) and to this moment.
    pub fn signed_bytes(
        fingerprint: &[u8; 32],
        time: u64,
        token: &[u8; 8],
        candidates: &str,
    ) -> Vec<u8> {
        let mut m = CONTEXT.to_vec();
        m.extend_from_slice(fingerprint);
        m.extend_from_slice(format!("{time} {} {candidates}", hex8(token)).as_bytes());
        m
    }

    pub fn verify(&self, key: &VerifyingKey, fingerprint: &[u8; 32], now: u64) -> bool {
        if self.time.abs_diff(now) > OFFER_AGE {
            return false;
        }
        let Some(sig) = crate::config::unb64(&self.signature)
            .and_then(|b| <[u8; 64]>::try_from(b.as_slice()).ok())
        else {
            return false;
        };
        let msg = Self::signed_bytes(
            fingerprint,
            self.time,
            &self.token,
            &format_candidates(&self.candidates),
        );
        key.verify_strict(&msg, &Signature::from_bytes(&sig))
            .is_ok()
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Asks a STUN server which address it sees this socket coming from.
pub async fn stun(socket: &UdpSocket, server: SocketAddr) -> Option<SocketAddr> {
    let txid: [u8; 12] = crate::config::random_bytes::<12>();
    let mut req = vec![0, 1, 0, 0];
    req.extend_from_slice(&STUN_COOKIE.to_be_bytes());
    req.extend_from_slice(&txid);
    let mut buf = [0u8; 600];
    for attempt in 0..3u32 {
        socket.send_to(&req, server).await.ok()?;
        let wait = Duration::from_millis(250 * (attempt as u64 + 1));
        let deadline = tokio::time::Instant::now() + wait;
        while let Ok(Ok((n, from))) =
            tokio::time::timeout_at(deadline, socket.recv_from(&mut buf)).await
        {
            if from != server {
                continue;
            }
            if let Some(a) = parse_stun_answer(&buf[..n], &txid) {
                return Some(a);
            }
        }
    }
    None
}

fn parse_stun_answer(p: &[u8], txid: &[u8; 12]) -> Option<SocketAddr> {
    if p.len() < 20
        || p[0..2] != [1, 1]
        || p[4..8] != STUN_COOKIE.to_be_bytes()
        || &p[8..20] != txid
    {
        return None;
    }
    let mut i = 20;
    while i + 4 <= p.len() {
        let kind = u16::from_be_bytes([p[i], p[i + 1]]);
        let len = u16::from_be_bytes([p[i + 2], p[i + 3]]) as usize;
        let v = p.get(i + 4..i + 4 + len)?;
        if kind == 0x0020 && len >= 8 && v[1] == 1 {
            let port = u16::from_be_bytes([v[2], v[3]]) ^ (STUN_COOKIE >> 16) as u16;
            let ip = u32::from_be_bytes([v[4], v[5], v[6], v[7]]) ^ STUN_COOKIE;
            return Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip)), port));
        }
        i += 4 + len.div_ceil(4) * 4;
    }
    None
}

/// Where this socket can be reached: as the internet sees it (STUN through
/// the relay), then on the home network.
async fn candidates(socket: &UdpSocket, relay: &str) -> Vec<SocketAddr> {
    let port = socket.local_addr().map(|a| a.port()).unwrap_or(0);
    let mut out = Vec::new();
    if let Ok(mut addrs) = tokio::net::lookup_host(relay).await
        && let Some(server) = addrs.find(|a| a.is_ipv4())
        && let Some(mapped) = stun(socket, server).await
    {
        out.push(mapped);
    }
    for a in crate::net::addresses() {
        if a.kind == crate::net::Kind::Lan {
            let c = SocketAddr::new(IpAddr::V4(a.ip), port);
            if !out.contains(&c) {
                out.push(c);
            }
        }
    }
    if std::env::var_os("PAIRDESK_E2E").is_some() {
        out.push(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port));
    }
    out.truncate(MAX_CANDIDATES);
    out
}

async fn read_line(stream: &mut TcpStream) -> Option<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while line.len() < MAX_LINE {
        if stream.read(&mut byte).await.ok()? == 0 {
            return None;
        }
        if byte[0] == b'\n' {
            return String::from_utf8(line).ok();
        }
        line.push(byte[0]);
    }
    None
}

/// A phone's connection through the relay that may turn into a direct one.
/// Returns the stream to serve (the relayed one, or a local pipe to the
/// direct path) and whether it went direct; None if the phone left.
pub async fn take(
    mut relayed: TcpStream,
    state: &Arc<crate::state::AppState>,
    relay: &str,
) -> Option<(TcpStream, Option<SocketAddr>)> {
    // An offer starts with "PDD1 "; TLS starts with byte 22.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let mut first = [0u8; 5];
        let n = match tokio::time::timeout_at(deadline, relayed.peek(&mut first)).await {
            Ok(Ok(n)) if n > 0 => n,
            _ => return None,
        };
        if first[..n] != OFFER_PREFIX[..n] {
            // An older phone, or one that didn't try: TLS straight away.
            return Some((relayed, None));
        }
        if n == OFFER_PREFIX.len() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let line = tokio::time::timeout(Duration::from_secs(5), read_line(&mut relayed))
        .await
        .ok()
        .flatten()?;
    match offer_answer(&line, state, relay).await {
        Err(reason) => {
            let _ = relayed
                .write_all(format!("PDD1 NO {reason}\n").as_bytes())
                .await;
            state.direct.record(Outcome::Relayed(reason.into()));
            Some((relayed, None))
        }
        Ok((socket, offer, ours)) => {
            relayed
                .write_all(format!("PDD1 OK {}\n", format_candidates(&ours)).as_bytes())
                .await
                .ok()?;
            match race(relayed, socket, offer).await {
                Raced::Relayed(stream) => {
                    state.direct.record(Outcome::Relayed(
                        "the phone couldn't open a direct path".into(),
                    ));
                    Some((stream, None))
                }
                Raced::Direct(stream, peer) => {
                    state.direct.record(Outcome::Direct);
                    Some((stream, Some(peer)))
                }
                Raced::Gone => None,
            }
        }
    }
}

async fn offer_answer(
    line: &str,
    state: &Arc<crate::state::AppState>,
    relay: &str,
) -> Result<(UdpSocket, Offer, Vec<SocketAddr>), &'static str> {
    let offer = Offer::parse(line).ok_or("bad-offer")?;
    if !state.prefs().get().direct {
        return Err("off");
    }
    if !state.is_paired(&offer.phone) {
        return Err("not-paired");
    }
    let key = crate::auth::parse_phone_id(&offer.phone).ok_or("bad-offer")?;
    if !offer.verify(&key, state.identity.fingerprint(), unix_now()) {
        return Err("bad-signature");
    }
    if offer.candidates.is_empty() {
        return Err("no-addresses");
    }
    let socket = UdpSocket::bind("0.0.0.0:0")
        .await
        .map_err(|_| "no-socket")?;
    let ours = candidates(&socket, relay).await;
    if ours.is_empty() {
        return Err("no-addresses");
    }
    Ok((socket, offer, ours))
}

enum Raced {
    Relayed(TcpStream),
    Direct(TcpStream, SocketAddr),
    Gone,
}

/// Punches towards the phone while watching the relayed connection: the
/// phone either starts TLS there (it gave up on the direct path) or sends
/// its first data over the direct path.
async fn race(relayed: TcpStream, socket: UdpSocket, offer: Offer) -> Raced {
    let token = offer.token;
    let mut punch = conn::header(conn::PUNCH, &token);
    punch.push(1);
    let mut ack = conn::header(conn::PUNCH_ACK, &token);
    ack.push(1);
    let deadline = tokio::time::Instant::now() + PUNCH_WINDOW;
    let mut tick = tokio::time::interval(PUNCH_EVERY);
    let mut buf = vec![0u8; 2048];
    let mut peek = [0u8; 1];
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                // Still nothing: whatever the phone does next, it's on the relay.
                return Raced::Relayed(relayed);
            }
            r = relayed.peek(&mut peek) => {
                return match r {
                    Ok(n) if n > 0 => Raced::Relayed(relayed),
                    // The relayed connection closed: the phone may already be
                    // sending over the direct path. Keep waiting for that.
                    _ => match wait_for_data(&socket, &token, &ack, deadline).await {
                        Some((peer, packet)) => match start(socket, peer, token, packet).await {
                            Some(s) => Raced::Direct(s, peer),
                            None => Raced::Gone,
                        },
                        None => Raced::Gone,
                    },
                };
            }
            _ = tick.tick() => {
                for c in &offer.candidates {
                    let _ = socket.send_to(&punch, c).await;
                }
            }
            r = socket.recv_from(&mut buf) => {
                let Ok((n, from)) = r else { continue };
                match conn::kind_of(&buf[..n], &token) {
                    Some(conn::PUNCH) => {
                        let _ = socket.send_to(&ack, from).await;
                    }
                    Some(conn::DATA) => {
                        let packet = buf[..n].to_vec();
                        drop(relayed);
                        return match start(socket, from, token, packet).await {
                            Some(s) => Raced::Direct(s, from),
                            None => Raced::Gone,
                        };
                    }
                    _ => {}
                }
            }
        }
    }
}

async fn wait_for_data(
    socket: &UdpSocket,
    token: &[u8; 8],
    ack: &[u8],
    deadline: tokio::time::Instant,
) -> Option<(SocketAddr, Vec<u8>)> {
    let mut buf = vec![0u8; 2048];
    loop {
        let (n, from) = tokio::time::timeout_at(deadline, socket.recv_from(&mut buf))
            .await
            .ok()?
            .ok()?;
        match conn::kind_of(&buf[..n], token) {
            Some(conn::PUNCH) => {
                let _ = socket.send_to(ack, from).await;
            }
            Some(conn::DATA) => return Some((from, buf[..n].to_vec())),
            _ => {}
        }
    }
}

/// Starts the stream on an open path; the server gets a local TCP stream
/// whose other end a task copies to and from the direct path.
async fn start(
    socket: UdpSocket,
    peer: SocketAddr,
    token: [u8; 8],
    first: Vec<u8>,
) -> Option<TcpStream> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.ok()?;
    let addr = listener.local_addr().ok()?;
    let (client, accepted) = tokio::try_join!(TcpStream::connect(addr), listener.accept()).ok()?;
    let (inner, from) = accepted;
    if client.local_addr().ok() != Some(from) {
        return None;
    }
    let mut c = Conn::new(token, Instant::now());
    c.on_packet(&first, Instant::now());
    info!("direct path to {peer} is open");
    tokio::spawn(drive(socket, peer, c, inner, 1));
    Some(client)
}

/// Copies between a local TCP stream and the direct path until either
/// side ends. `side` is 0 on the phone, 1 here (for PUNCH answers).
pub async fn drive(
    socket: UdpSocket,
    mut peer: SocketAddr,
    mut c: Conn,
    local: TcpStream,
    side: u8,
) {
    let token = c.token();
    let mut ack = conn::header(conn::PUNCH_ACK, &token);
    ack.push(side);
    let (mut rd, mut wr) = local.into_split();
    let (tx, mut from_engine) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    let mut to_local = Some(tx);
    let writer = tokio::spawn(async move {
        while let Some(chunk) = from_engine.recv().await {
            if wr.write_all(&chunk).await.is_err() {
                break;
            }
        }
        let _ = wr.shutdown().await;
    });
    let mut buf = vec![0u8; 2048];
    let mut local_buf = vec![0u8; 64 * 1024];
    let mut local_done = false;
    loop {
        let now = Instant::now();
        while let Some(p) = c.poll_transmit(now) {
            let _ = socket.send_to(&p, peer).await;
        }
        if let Some(tx) = &to_local {
            while c.has_ready() {
                let Ok(permit) = tx.try_reserve() else { break };
                permit.send(c.read(64 * 1024));
            }
        }
        // The other side finished: end the local stream's reading side too.
        if c.peer_finished() {
            to_local = None;
        }
        if c.state() != State::Open {
            break;
        }
        // The engine may owe an ACK after reading.
        while let Some(p) = c.poll_transmit(Instant::now()) {
            let _ = socket.send_to(&p, peer).await;
        }
        let wake = tokio::time::Instant::from_std(c.next_timeout(Instant::now()));
        let can_read = !local_done && c.send_space() >= conn::MAX_PAYLOAD;
        let blocked_on_local = c.has_ready() && to_local.is_some();
        tokio::select! {
            r = socket.recv_from(&mut buf) => {
                let Ok((n, from)) = r else { continue };
                match conn::kind_of(&buf[..n], &token) {
                    Some(conn::PUNCH) => { let _ = socket.send_to(&ack, from).await; }
                    Some(conn::PUNCH_ACK) | None => {}
                    Some(_) => {
                        if c.on_packet(&buf[..n], Instant::now()) {
                            // Follow the other side if its router moved it.
                            peer = from;
                        }
                    }
                }
            }
            r = rd.read(&mut local_buf), if can_read => match r {
                Ok(0) | Err(_) => { local_done = true; c.close(); }
                Ok(n) => { c.write(&local_buf[..n]); }
            },
            _ = tokio::time::sleep_until(wake) => c.on_timeout(Instant::now()),
            _ = tokio::time::sleep(Duration::from_millis(5)), if blocked_on_local => {}
        }
    }
    if c.state() == State::Failed {
        warn!("direct path to {peer} ended");
        let _ = socket.send_to(&c.reset(), peer).await;
    }
    // Whatever was delivered still reaches the local side.
    if let Some(tx) = to_local {
        while c.has_ready() {
            if tx.send(c.read(64 * 1024)).await.is_err() {
                break;
            }
        }
    }
    let _ = writer.await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    #[test]
    fn offers_round_trip_and_are_checked() {
        let key = SigningKey::from_bytes(&[7; 32]);
        let fp = [3u8; 32];
        let token = [1, 2, 3, 4, 5, 6, 7, 8];
        let cands = "203.0.113.5:4000,192.168.1.20:4000";
        let now = unix_now();
        let sig = key.sign(&Offer::signed_bytes(&fp, now, &token, cands));
        let id = crate::config::b64(key.verifying_key().as_bytes());
        let line = format!(
            "PDD1 {id} {now} {} {cands} {}",
            hex8(&token),
            crate::config::b64(&sig.to_bytes())
        );
        let offer = Offer::parse(&line).unwrap();
        assert_eq!(offer.candidates.len(), 2);
        let vk = key.verifying_key();
        assert!(offer.verify(&vk, &fp, now));
        assert!(!offer.verify(&vk, &[4u8; 32], now), "another computer");
        assert!(!offer.verify(&vk, &fp, now + 500), "too old");
        let other = SigningKey::from_bytes(&[8; 32]).verifying_key();
        assert!(!offer.verify(&other, &fp, now), "another phone");
        assert!(Offer::parse("PDD1 x 1 zz - y").is_none());
    }

    #[test]
    fn candidates_skip_addresses_nobody_should_get_packets() {
        let c = parse_candidates(
            "0.0.0.0:5,224.0.0.1:5,255.255.255.255:9,1.2.3.4:0,1.2.3.4:5,junk,[::1]:5",
        );
        assert_eq!(c, vec!["1.2.3.4:5".parse().unwrap()]);
        assert!(parse_candidates("-").is_empty());
    }

    #[tokio::test]
    async fn stun_answers_are_understood() {
        // A tiny STUN server like the relay's.
        let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let saddr = server.local_addr().unwrap();
        tokio::spawn(async move {
            let mut buf = [0u8; 100];
            let (n, from) = server.recv_from(&mut buf).await.unwrap();
            let mut out = vec![1, 1, 0, 12];
            out.extend_from_slice(&buf[4..20]);
            out.extend_from_slice(&[0, 0x20, 0, 8, 0, 1]);
            out.extend_from_slice(&(from.port() ^ 0x2112).to_be_bytes());
            let SocketAddr::V4(v4) = from else { panic!() };
            out.extend_from_slice(&(u32::from(*v4.ip()) ^ STUN_COOKIE).to_be_bytes());
            let _ = n;
            server.send_to(&out, from).await.unwrap();
        });
        let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let got = stun(&client, saddr).await.unwrap();
        assert_eq!(got, client.local_addr().unwrap());
    }

    /// Both ends of a direct path on this computer: bytes go both ways.
    #[tokio::test]
    async fn a_stream_runs_over_udp() {
        let a = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (aa, ba) = (a.local_addr().unwrap(), b.local_addr().unwrap());
        let token = [9; 8];
        let la = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let lb = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (pa, pb) = (la.local_addr().unwrap(), lb.local_addr().unwrap());
        let mut app_a = TcpStream::connect(pa).await.unwrap();
        let (inner_a, _) = la.accept().await.unwrap();
        let mut app_b = TcpStream::connect(pb).await.unwrap();
        let (inner_b, _) = lb.accept().await.unwrap();
        tokio::spawn(drive(a, ba, Conn::new(token, Instant::now()), inner_a, 0));
        tokio::spawn(drive(b, aa, Conn::new(token, Instant::now()), inner_b, 1));
        let data: Vec<u8> = (0..400_000u32).map(|i| (i % 251) as u8).collect();
        let d2 = data.clone();
        let w = tokio::spawn(async move {
            app_a.write_all(&d2).await.unwrap();
            app_a.shutdown().await.unwrap();
            let mut back = Vec::new();
            app_a.read_to_end(&mut back).await.unwrap();
            back
        });
        let mut got = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), app_b.read_to_end(&mut got))
            .await
            .unwrap()
            .unwrap();
        assert!(got == data);
        app_b.write_all(b"thanks").await.unwrap();
        app_b.shutdown().await.unwrap();
        let back = tokio::time::timeout(Duration::from_secs(10), w)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(back, b"thanks");
    }
}
