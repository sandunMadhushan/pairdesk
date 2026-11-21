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
//!
//! With `--tls-cert` and `--tls-key` the relay also accepts TLS on the same
//! ports. A connection that starts with a TLS handshake is unwrapped and then
//! speaks the protocol above; one that doesn't is served as before. So
//! firewalls that only let TLS through on 443 pass it, the token isn't sent
//! in the clear, and older programs keep working.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use log::{info, warn};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use tokio_rustls::rustls::{self, ServerConfig};

/// Time to send the first line.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// Time a computer gets to answer an incoming phone.
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(10);
/// A joined connection with no bytes either way for this long is closed
/// (phones ping every 3 s).
const IDLE: Duration = Duration::from_secs(90);
const PING_EVERY: Duration = Duration::from_secs(25);
/// Connections from one address at once. Each computer holds one control
/// connection and each phone one joined connection, and a mobile carrier or
/// an office puts many people behind one address, so this must be generous.
const PER_IP: usize = 512;
const MAX_LINE: usize = 256;

/// A connection, with or without TLS around it.
trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
type Conn = Box<dyn Io>;

#[derive(Default)]
struct Relay {
    /// Online computers: id → control channel.
    hosts: Mutex<HashMap<String, Host>>,
    /// Phones waiting for their computer: nonce → (computer id, hand-over).
    waiting: Mutex<HashMap<String, (String, oneshot::Sender<Conn>)>>,
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

async fn read_line(stream: &mut BufReader<Conn>) -> Option<String> {
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

/// Whether the connection starts with a TLS handshake (record type 22).
async fn starts_with_tls(tcp: &TcpStream) -> bool {
    let mut first = [0u8; 1];
    matches!(
        tokio::time::timeout(HELLO_TIMEOUT, tcp.peek(&mut first)).await,
        Ok(Ok(1)) if first[0] == 0x16
    )
}

async fn handle(relay: Arc<Relay>, tcp: TcpStream, peer: SocketAddr, tls: Option<TlsAcceptor>) {
    let Some(_slot) = relay.take_slot(peer.ip()) else {
        return;
    };
    let _ = tcp.set_nodelay(true);
    let conn: Conn = match &tls {
        Some(acceptor) if starts_with_tls(&tcp).await => {
            match tokio::time::timeout(HELLO_TIMEOUT, acceptor.accept(tcp)).await {
                Ok(Ok(stream)) => Box::new(stream),
                _ => return,
            }
        }
        _ => Box::new(tcp),
    };
    let mut stream = BufReader::new(conn);
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
async fn host(relay: Arc<Relay>, stream: BufReader<Conn>, id: String, peer: SocketAddr) {
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
    let (read, mut write) = tokio::io::split(stream.into_inner());
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
async fn phone(relay: Arc<Relay>, mut stream: BufReader<Conn>, id: &str, peer: SocketAddr) {
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
async fn accept(relay: Arc<Relay>, mut stream: BufReader<Conn>, token: &str, nonce: &str) {
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
async fn join(phone: Conn, early: Vec<u8>, computer: Conn) {
    let (mut pr, mut pw) = tokio::io::split(phone);
    let (mut cr, mut cw) = tokio::io::split(computer);
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

/// Reads a certificate chain and private key (PEM) for [`TlsAcceptor`].
fn load_tls(cert: &str, key: &str) -> Result<TlsAcceptor, String> {
    let certs = CertificateDer::pem_file_iter(cert)
        .map_err(|e| format!("can't read {cert}: {e}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("can't read {cert}: {e}"))?;
    let key = PrivateKeyDer::from_pem_file(key).map_err(|e| format!("can't read {key}: {e}"))?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| format!("the certificate and key don't fit: {e}"))?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

fn usage() -> ! {
    eprintln!(
        "PairDesk relay {}\n\nUsage: pairdesk-relay [--listen ADDRESS:PORT]... \
         [--tls-cert FILE --tls-key FILE]\n\n\
         Default: --listen 0.0.0.0:47900. Listen on several, e.g. 443 as well, for\n\
         networks that block other ports. With a certificate and key (PEM) the relay\n\
         also accepts TLS on the same ports. Log detail: RUST_LOG=info (default) or debug.",
        env!("CARGO_PKG_VERSION")
    );
    std::process::exit(2);
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let mut listens = Vec::new();
    let (mut cert, mut key) = (None, None);
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--listen" => listens.push(args.next().unwrap_or_else(|| usage())),
            "--tls-cert" => cert = Some(args.next().unwrap_or_else(|| usage())),
            "--tls-key" => key = Some(args.next().unwrap_or_else(|| usage())),
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
    let tls = match (cert, key) {
        (Some(cert), Some(key)) => match load_tls(&cert, &key) {
            Ok(acceptor) => {
                info!("TLS is on: connections that start with a TLS handshake are accepted");
                Some(acceptor)
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        },
        (None, None) => None,
        _ => usage(),
    };
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
        let tls = tls.clone();
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((s, peer)) => {
                        tokio::spawn(handle(relay.clone(), s, peer, tls.clone()));
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
        start_with(None).await
    }

    async fn start_with(tls: Option<TlsAcceptor>) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let relay = Arc::new(Relay::default());
        tokio::spawn(async move {
            loop {
                let (s, peer) = listener.accept().await.unwrap();
                tokio::spawn(handle(relay.clone(), s, peer, tls.clone()));
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

    /// A computer that talks TLS to the relay and a phone that doesn't
    /// (the phone's own TLS runs inside, end to end): both are served on the
    /// same port.
    #[tokio::test]
    async fn serves_tls_and_plain_on_one_port() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
        let dir = std::env::temp_dir().join(format!("pairdesk-relay-tls-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (cert_file, key_file) = (dir.join("cert.pem"), dir.join("key.pem"));
        std::fs::write(&cert_file, cert.cert.pem()).unwrap();
        std::fs::write(&key_file, cert.key_pair.serialize_pem()).unwrap();
        let acceptor = load_tls(cert_file.to_str().unwrap(), key_file.to_str().unwrap()).unwrap();
        let addr = start_with(Some(acceptor)).await;

        let mut roots = rustls::RootCertStore::empty();
        roots.add(cert.cert.der().clone()).unwrap();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
        let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
        let name = rustls::pki_types::ServerName::try_from("localhost").unwrap();
        let tcp = TcpStream::connect(addr).await.unwrap();
        let mut control = BufReader::new(connector.connect(name, tcp).await.unwrap());
        let token = "a-secret-token-over-tls-123";
        control
            .get_mut()
            .write_all(format!("PDR1 HOST {token}\n").as_bytes())
            .await
            .unwrap();
        let mut ok = String::new();
        control.read_line(&mut ok).await.unwrap();
        assert_eq!(ok.trim(), format!("OK {}", host_id(token)));

        // A plain phone finds the computer that registered over TLS.
        let id = host_id(token);
        let phone = tokio::spawn(async move {
            let mut phone = BufReader::new(TcpStream::connect(addr).await.unwrap());
            phone
                .get_mut()
                .write_all(format!("PDR1 CONNECT {id}\n").as_bytes())
                .await
                .unwrap();
            line(&mut phone).await
        });
        let mut incoming = String::new();
        control.read_line(&mut incoming).await.unwrap();
        assert!(incoming.starts_with("INCOMING "), "{incoming}");
        let nonce = incoming
            .trim()
            .strip_prefix("INCOMING ")
            .unwrap()
            .to_string();
        let tcp = TcpStream::connect(addr).await.unwrap();
        let name = rustls::pki_types::ServerName::try_from("localhost").unwrap();
        let mut accept = BufReader::new(connector.connect(name, tcp).await.unwrap());
        accept
            .get_mut()
            .write_all(format!("PDR1 ACCEPT {token} {nonce}\n").as_bytes())
            .await
            .unwrap();
        let mut reply = String::new();
        accept.read_line(&mut reply).await.unwrap();
        assert_eq!(reply.trim(), "OK");
        assert_eq!(phone.await.unwrap(), "OK");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ids_are_stable_and_short() {
        assert_eq!(host_id("abc").len(), 32);
        assert_eq!(host_id("abc"), host_id("abc"));
        assert_ne!(host_id("abc"), host_id("abd"));
    }
}
