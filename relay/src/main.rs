// SPDX-License-Identifier: GPL-3.0-or-later
//! PairDesk relay.
//!
//! Connects a phone to a computer when neither can reach the other
//! directly (different networks, no Tailscale). Both connect *out* to the
//! relay; the relay pairs the two connections and copies bytes between
//! them. PairDesk's own TLS runs end to end inside, with the computer's
//! certificate pinned on the phone, so the relay sees only encrypted
//! bytes: it can't read or change screens, keystrokes or files.
//!
//! Protocol (one line each, then raw bytes):
//!
//! ```text
//! computer → relay   PDR1 HOST <token>            control connection
//! relay → computer   OK <id>                       id = first 16 bytes of SHA-256(token), hex
//! phone → relay      PDR1 CONNECT <id>
//! relay → computer   INCOMING <nonce>              (on the control connection)
//! computer → relay   PDR1 ACCEPT <token> <nonce>   a new connection for this phone
//! relay → both       OK                            then the two are joined
//! relay → computer   PING (every 25 s; answered with PONG)
//! ```
//!
//! Only the holder of a token can register its id, so nobody can pose as
//! someone else's computer (and the phone checks the certificate anyway).

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use log::{info, warn};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};

/// Time to send the first line.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// Time a computer gets to answer an incoming phone.
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(10);
/// A joined connection with no bytes either way for this long is closed
/// (phones ping every 3 s).
const IDLE: Duration = Duration::from_secs(90);
const PING_EVERY: Duration = Duration::from_secs(25);
/// Connections from one address at once.
const PER_IP: usize = 64;
const MAX_LINE: usize = 256;

#[derive(Default)]
struct Relay {
    /// Online computers: id → control channel.
    hosts: Mutex<HashMap<String, Host>>,
    /// Phones waiting for their computer: nonce → (computer id, hand-over).
    waiting: Mutex<HashMap<String, (String, oneshot::Sender<TcpStream>)>>,
    per_ip: Mutex<HashMap<IpAddr, usize>>,
    next_generation: Mutex<u64>,
}

struct Host {
    control: mpsc::Sender<String>,
    generation: u64,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

pub fn host_id(token: &str) -> String {
    Sha256::digest(token.as_bytes())[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn nonce() -> String {
    let mut b = [0u8; 16];
    getrandom::getrandom(&mut b).expect("random numbers");
    b.iter().map(|b| format!("{b:02x}")).collect()
}

/// Counts connections per address; released on drop.
struct Slot {
    relay: Arc<Relay>,
    ip: IpAddr,
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut m = lock(&self.relay.per_ip);
        if let Some(n) = m.get_mut(&self.ip) {
            *n -= 1;
            if *n == 0 {
                m.remove(&self.ip);
            }
        }
    }
}

impl Relay {
    fn take_slot(self: &Arc<Self>, ip: IpAddr) -> Option<Slot> {
        let mut m = lock(&self.per_ip);
        let n = m.entry(ip).or_insert(0);
        if *n >= PER_IP {
            return None;
        }
        *n += 1;
        Some(Slot {
            relay: self.clone(),
            ip,
        })
    }
}

async fn read_line(stream: &mut BufReader<TcpStream>) -> Option<String> {
    let mut line = String::new();
    let read = tokio::time::timeout(HELLO_TIMEOUT, async {
        let mut limited = (&mut *stream).take(MAX_LINE as u64);
        limited.read_line(&mut line).await
    })
    .await;
    match read {
        Ok(Ok(n)) if n > 0 && line.ends_with('\n') => Some(line.trim().to_string()),
        _ => None,
    }
}

async fn handle(relay: Arc<Relay>, stream: TcpStream, peer: SocketAddr) {
    let Some(_slot) = relay.take_slot(peer.ip()) else {
        return;
    };
    let _ = stream.set_nodelay(true);
    let mut stream = BufReader::new(stream);
    let Some(line) = read_line(&mut stream).await else {
        return;
    };
    let parts: Vec<&str> = line.split(' ').collect();
    match parts.as_slice() {
        ["PDR1", "HOST", token] if (16..=128).contains(&token.len()) => {
            host(relay, stream, host_id(token), peer).await
        }
        ["PDR1", "CONNECT", id] if id.len() == 32 => phone(relay, stream, id, peer).await,
        ["PDR1", "ACCEPT", token, nonce] => accept(relay, stream, token, nonce).await,
        _ => {
            let _ = stream.get_mut().write_all(b"ERR bad request\n").await;
        }
    }
}

/// A computer's control connection, for as long as it's open.
async fn host(relay: Arc<Relay>, stream: BufReader<TcpStream>, id: String, peer: SocketAddr) {
    let (tx, mut rx) = mpsc::channel::<String>(32);
    let generation = {
        let mut g = lock(&relay.next_generation);
        *g += 1;
        *g
    };
    lock(&relay.hosts).insert(
        id.clone(),
        Host {
            control: tx,
            generation,
        },
    );
    info!("computer {} online from {peer}", &id[..8]);
    let (read, mut write) = stream.into_inner().into_split();
    let mut lines = BufReader::new(read).lines();
    let welcomed = write
        .write_all(format!("OK {id}\n").as_bytes())
        .await
        .is_ok();
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut last_heard = tokio::time::Instant::now();
    loop {
        if !welcomed {
            break;
        }
        tokio::select! {
            Some(msg) = rx.recv() => {
                if write.write_all(msg.as_bytes()).await.is_err() { break; }
            }
            line = lines.next_line() => match line {
                Ok(Some(_)) => last_heard = tokio::time::Instant::now(),
                _ => break,
            },
            _ = ping.tick() => {
                if last_heard.elapsed() > PING_EVERY * 3 { break; }
                if write.write_all(b"PING\n").await.is_err() { break; }
            }
        }
    }
    // Only remove our own entry (the computer may have reconnected).
    let mut hosts = lock(&relay.hosts);
    if hosts.get(&id).is_some_and(|h| h.generation == generation) {
        hosts.remove(&id);
    }
    info!("computer {} offline", &id[..8]);
}

/// A phone asking for a computer: waits for the computer's connection,
/// then joins the two.
async fn phone(relay: Arc<Relay>, mut stream: BufReader<TcpStream>, id: &str, peer: SocketAddr) {
    let control = lock(&relay.hosts).get(id).map(|h| h.control.clone());
    let Some(control) = control else {
        let _ = stream.get_mut().write_all(b"ERR offline\n").await;
        return;
    };
    let n = nonce();
    let (tx, rx) = oneshot::channel();
    lock(&relay.waiting).insert(n.clone(), (id.to_string(), tx));
    if control.send(format!("INCOMING {n}\n")).await.is_err() {
        lock(&relay.waiting).remove(&n);
        let _ = stream.get_mut().write_all(b"ERR offline\n").await;
        return;
    }
    let computer = tokio::time::timeout(ACCEPT_TIMEOUT, rx).await;
    lock(&relay.waiting).remove(&n);
    let Ok(Ok(computer)) = computer else {
        let _ = stream.get_mut().write_all(b"ERR no answer\n").await;
        return;
    };
    if stream.get_mut().write_all(b"OK\n").await.is_err() {
        return;
    }
    info!("phone {peer} joined to computer {}", &id[..8]);
    let buffered = stream.buffer().to_vec();
    join(stream.into_inner(), buffered, computer).await;
}

/// The computer's connection for one waiting phone.
async fn accept(relay: Arc<Relay>, mut stream: BufReader<TcpStream>, token: &str, nonce: &str) {
    let id = host_id(token);
    let waiting = {
        let mut w = lock(&relay.waiting);
        match w.get(nonce) {
            Some((for_id, _)) if *for_id == id => w.remove(nonce).map(|(_, tx)| tx),
            _ => None,
        }
    };
    let Some(tx) = waiting else {
        let _ = stream.get_mut().write_all(b"ERR unknown\n").await;
        return;
    };
    if stream.get_mut().write_all(b"OK\n").await.is_err() {
        return;
    }
    // Nothing more is read here: the phone's TLS starts on the other side.
    let _ = tx.send(stream.into_inner());
}

/// Copies both ways until either side closes or nothing moves for `IDLE`.
async fn join(phone: TcpStream, early: Vec<u8>, computer: TcpStream) {
    let (mut pr, mut pw) = phone.into_split();
    let (mut cr, mut cw) = computer.into_split();
    if !early.is_empty() && cw.write_all(&early).await.is_err() {
        return;
    }
    let up = async {
        let mut buf = vec![0u8; 32 * 1024];
        loop {
            match tokio::time::timeout(IDLE, pr.read(&mut buf)).await {
                Ok(Ok(n)) if n > 0 => {
                    if cw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        let _ = cw.shutdown().await;
    };
    let down = async {
        let mut buf = vec![0u8; 32 * 1024];
        loop {
            match tokio::time::timeout(IDLE, cr.read(&mut buf)).await {
                Ok(Ok(n)) if n > 0 => {
                    if pw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        let _ = pw.shutdown().await;
    };
    tokio::select! {
        _ = up => {}
        _ = down => {}
    }
}

fn usage() -> ! {
    eprintln!(
        "PairDesk relay {}\n\nUsage: pairdesk-relay [--listen ADDRESS:PORT]...\n\n\
         Default: --listen 0.0.0.0:47900. Listen on several, e.g. 443 as well, for\n\
         networks that block other ports. Log detail: RUST_LOG=info (default) or debug.",
        env!("CARGO_PKG_VERSION")
    );
    std::process::exit(2);
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let mut listens = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listens.push(args.next().unwrap_or_else(|| usage())),
            "--version" => {
                println!("pairdesk-relay {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            _ => usage(),
        }
    }
    if listens.is_empty() {
        listens.push("0.0.0.0:47900".into());
    }
    let relay = Arc::new(Relay::default());
    for addr in listens {
        let listener = match TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                eprintln!("can't listen on {addr}: {e}");
                std::process::exit(1);
            }
        };
        info!(
            "PairDesk relay {} listening on {addr}",
            env!("CARGO_PKG_VERSION")
        );
        let relay = relay.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((s, peer)) => {
                        tokio::spawn(handle(relay.clone(), s, peer));
                    }
                    Err(e) => {
                        warn!("accept: {e}");
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                }
            }
        });
    }
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    async fn start() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let relay = Arc::new(Relay::default());
        tokio::spawn(async move {
            loop {
                let (s, peer) = listener.accept().await.unwrap();
                tokio::spawn(handle(relay.clone(), s, peer));
            }
        });
        addr
    }

    async fn line(r: &mut BufReader<TcpStream>) -> String {
        let mut s = String::new();
        r.read_line(&mut s).await.unwrap();
        s.trim().to_string()
    }

    #[tokio::test]
    async fn joins_a_phone_to_its_computer() {
        let addr = start().await;
        let token = "a-secret-token-of-the-computer";
        let mut control = BufReader::new(TcpStream::connect(addr).await.unwrap());
        control
            .get_mut()
            .write_all(format!("PDR1 HOST {token}\n").as_bytes())
            .await
            .unwrap();
        let ok = line(&mut control).await;
        let id = host_id(token);
        assert_eq!(ok, format!("OK {id}"));

        // A phone asks; the computer is told and answers on a new connection.
        let phone_task = tokio::spawn(async move {
            let mut phone = BufReader::new(TcpStream::connect(addr).await.unwrap());
            phone
                .get_mut()
                .write_all(format!("PDR1 CONNECT {id}\nhello computer").as_bytes())
                .await
                .unwrap();
            assert_eq!(line(&mut phone).await, "OK");
            let mut buf = [0u8; 11];
            phone.read_exact(&mut buf).await.unwrap();
            assert_eq!(&buf, b"hello phone");
        });
        let incoming = line(&mut control).await;
        let nonce = incoming.strip_prefix("INCOMING ").unwrap().to_string();
        let mut conn = BufReader::new(TcpStream::connect(addr).await.unwrap());
        conn.get_mut()
            .write_all(format!("PDR1 ACCEPT {token} {nonce}\n").as_bytes())
            .await
            .unwrap();
        assert_eq!(line(&mut conn).await, "OK");
        // Bytes the phone sent with its request arrive first.
        let mut buf = [0u8; 14];
        conn.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"hello computer");
        conn.get_mut().write_all(b"hello phone").await.unwrap();
        phone_task.await.unwrap();
    }

    #[tokio::test]
    async fn offline_and_impostors_are_refused() {
        let addr = start().await;
        let mut phone = BufReader::new(TcpStream::connect(addr).await.unwrap());
        phone
            .get_mut()
            .write_all(format!("PDR1 CONNECT {}\n", "0".repeat(32)).as_bytes())
            .await
            .unwrap();
        assert_eq!(line(&mut phone).await, "ERR offline");

        // A connection claiming to be the computer without its token.
        let token = "the-real-computers-token-123";
        let mut control = BufReader::new(TcpStream::connect(addr).await.unwrap());
        control
            .get_mut()
            .write_all(format!("PDR1 HOST {token}\n").as_bytes())
            .await
            .unwrap();
        line(&mut control).await;
        let id = host_id(token);
        tokio::spawn(async move {
            let mut phone = BufReader::new(TcpStream::connect(addr).await.unwrap());
            phone
                .get_mut()
                .write_all(format!("PDR1 CONNECT {id}\n").as_bytes())
                .await
                .unwrap();
            let _ = line(&mut phone).await;
        });
        let nonce = line(&mut control).await.replace("INCOMING ", "");
        let mut fake = BufReader::new(TcpStream::connect(addr).await.unwrap());
        fake.get_mut()
            .write_all(format!("PDR1 ACCEPT someone-elses-token-xyz {nonce}\n").as_bytes())
            .await
            .unwrap();
        assert_eq!(line(&mut fake).await, "ERR unknown");
    }

    #[test]
    fn ids_are_stable_and_short() {
        assert_eq!(host_id("abc").len(), 32);
        assert_eq!(host_id("abc"), host_id("abc"));
        assert_ne!(host_id("abc"), host_id("abd"));
    }
}
