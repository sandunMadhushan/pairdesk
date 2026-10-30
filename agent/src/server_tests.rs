// SPDX-License-Identifier: GPL-3.0-or-later
//! End-to-end tests of the phone server: real TLS, real WebSocket, real
//! signatures, with input going to a channel instead of the desktop.

use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::Duration;

use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use rustls::DigitallySignedStruct;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::net::TcpStream;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;

use crate::auth::tests::{phone_key, sign};
use crate::config::{b64, unb64};
use crate::identity::Identity;
use crate::input::{InputCmd, InputHandle};
use crate::state::AppState;
use crate::store::PhoneStore;

/// Accepts exactly one certificate, by SHA-256 fingerprint — what the
/// phone app does.
#[derive(Debug)]
struct Pinned([u8; 32]);

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let fp: [u8; 32] = Sha256::digest(end_entity.as_ref()).into();
        if fp == self.0 {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("fingerprint mismatch".into()))
        }
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

struct Agent {
    state: Arc<AppState>,
    input: Receiver<InputCmd>,
    port: u16,
    _dir: tempfile::TempDir,
}

async fn start_agent() -> Agent {
    let dir = tempfile::tempdir().unwrap();
    let identity = Identity::load_or_create(dir.path()).unwrap();
    let phones = PhoneStore::load(dir.path()).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let prefs = crate::prefs::PrefsStore::load(dir.path()).unwrap();
    let state = Arc::new(AppState::new(
        identity,
        phones,
        prefs,
        "test-pc".into(),
        port,
    ));
    let (input, rx) = InputHandle::recording();
    let (relayed_tx, relayed) = tokio::sync::mpsc::channel(8);
    tokio::spawn(crate::server::run(listener, state.clone(), input, relayed));
    // Keeps the relay channel open for the agent's lifetime.
    std::mem::forget(relayed_tx);
    Agent {
        state,
        input: rx,
        port,
        _dir: dir,
    }
}

type Client = WebSocketStream<tokio_rustls::client::TlsStream<TcpStream>>;

async fn connect(port: u16, fp: [u8; 32]) -> Result<Client, String> {
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(Pinned(fp)))
    .with_no_client_auth();
    let tcp = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let tls = tokio_rustls::TlsConnector::from(Arc::new(config))
        .connect(ServerName::try_from("pairdesk.local").unwrap(), tcp)
        .await
        .map_err(|e| e.to_string())?;
    let (ws, _) = tokio_tungstenite::client_async(format!("wss://127.0.0.1:{port}/"), tls)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ws)
}

async fn send(ws: &mut Client, v: Value) {
    ws.send(Message::text(v.to_string())).await.unwrap();
}

async fn recv(ws: &mut Client) -> Value {
    recv_within(ws, 5).await
}

async fn recv_within(ws: &mut Client, secs: u64) -> Value {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(secs), ws.next())
            .await
            .expect("timed out waiting for the agent")
            .expect("connection closed")
            .expect("read failed");
        if let Message::Text(t) = frame {
            return serde_json::from_str(t.as_str()).unwrap();
        }
    }
}

/// Answers the challenge with a signature from `key`.
async fn answer(ws: &mut Client, key: &SigningKey, fp: &[u8; 32]) {
    let challenge = recv(ws).await;
    assert_eq!(challenge["t"], "challenge", "{challenge}");
    let nonce: [u8; 32] = unb64(challenge["nonce"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    send(ws, json!({"t": "auth", "sig": sign(key, fp, &nonce)})).await;
}

fn id_of(key: &SigningKey) -> String {
    b64(key.verifying_key().as_bytes())
}

fn token_of(state: &AppState) -> String {
    let (link, _) = state.pairing_link().expect("pairing is active");
    link.split("&t=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_string()
}

async fn pair(agent: &Agent, key: &SigningKey) -> Client {
    agent.state.start_pairing();
    let fp = *agent.state.identity.fingerprint();
    let mut ws = connect(agent.port, fp).await.unwrap();
    let token = token_of(&agent.state);
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":token,"id":id_of(key),"name":"Pixel"}),
    )
    .await;
    answer(&mut ws, key, &fp).await;
    ws
}

#[tokio::test]
async fn pairs_then_reconnects_and_sends_input() {
    let agent = start_agent().await;
    let key = phone_key(1);
    let fp = *agent.state.identity.fingerprint();

    let mut ws = pair(&agent, &key).await;
    let welcome = recv(&mut ws).await;
    assert_eq!(welcome["t"], "welcome");
    assert_eq!(welcome["paired"], true);
    assert_eq!(welcome["name"], "test-pc");
    assert_eq!(welcome["version"], env!("CARGO_PKG_VERSION"));
    assert!(agent.state.is_paired(&id_of(&key)));
    assert!(agent.state.pairing_link().is_none(), "code is used up");
    drop(ws);

    // Later: hello + signature, no pairing code needed.
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"hello","v":2,"id":id_of(&key),"name":"Pixel"}),
    )
    .await;
    answer(&mut ws, &key, &fp).await;
    let welcome = recv(&mut ws).await;
    assert_eq!(welcome["t"], "welcome");
    assert_eq!(welcome["paired"], false);

    send(&mut ws, json!({"t":"move","dx":5,"dy":-3})).await;
    send(&mut ws, json!({"t":"ping"})).await;
    assert_eq!(recv(&mut ws).await["t"], "pong");
    assert_eq!(
        agent.input.recv_timeout(Duration::from_secs(2)).unwrap(),
        InputCmd::Move { dx: 5, dy: -3 }
    );
}

#[tokio::test]
async fn refuses_unpaired_phone() {
    let agent = start_agent().await;
    let fp = *agent.state.identity.fingerprint();
    let stranger = phone_key(2);
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(&mut ws, json!({"t":"hello","v":2,"id":id_of(&stranger)})).await;
    let err = recv(&mut ws).await;
    assert_eq!(err["code"], "not_paired");
    assert!(agent.input.try_recv().is_err());
}

#[tokio::test]
async fn refuses_wrong_expired_or_reused_code() {
    let agent = start_agent().await;
    let fp = *agent.state.identity.fingerprint();
    let key = phone_key(3);

    // No pairing window open at all.
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":"guess","id":id_of(&key)}),
    )
    .await;
    assert_eq!(recv(&mut ws).await["code"], "bad_token");

    // Wrong code while a window is open.
    agent.state.start_pairing();
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":"guess","id":id_of(&key)}),
    )
    .await;
    assert_eq!(recv(&mut ws).await["code"], "bad_token");

    // The right code works once; a second phone can't reuse it.
    let token = token_of(&agent.state);
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":token,"id":id_of(&key)}),
    )
    .await;
    answer(&mut ws, &key, &fp).await;
    assert_eq!(recv(&mut ws).await["t"], "welcome");

    let other = phone_key(4);
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":token,"id":id_of(&other)}),
    )
    .await;
    assert_eq!(recv(&mut ws).await["code"], "bad_token");
    assert!(!agent.state.is_paired(&id_of(&other)));
}

#[tokio::test]
async fn refuses_forged_signature_and_keeps_code() {
    let agent = start_agent().await;
    let fp = *agent.state.identity.fingerprint();
    let claimed = phone_key(5);
    let attacker = phone_key(6);
    agent.state.start_pairing();
    let token = token_of(&agent.state);

    // Claims phone 5's key but signs with another key.
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":token,"id":id_of(&claimed)}),
    )
    .await;
    answer(&mut ws, &attacker, &fp).await;
    assert_eq!(recv(&mut ws).await["code"], "bad_signature");
    assert!(!agent.state.is_paired(&id_of(&claimed)));

    // A signature made for a different computer's certificate fails too.
    let mut ws = connect(agent.port, fp).await.unwrap();
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":token,"id":id_of(&claimed)}),
    )
    .await;
    answer(&mut ws, &claimed, &[0u8; 32]).await;
    assert_eq!(recv(&mut ws).await["code"], "bad_signature");
    assert!(
        agent.state.pairing_link().is_some(),
        "failed tries don't burn the code"
    );
}

#[tokio::test]
async fn refuses_input_before_auth_and_old_protocol() {
    let agent = start_agent().await;
    let fp = *agent.state.identity.fingerprint();

    let mut ws = connect(agent.port, fp).await.unwrap();
    send(&mut ws, json!({"t":"move","dx":100,"dy":100})).await;
    assert_eq!(recv(&mut ws).await["code"], "unexpected");

    let mut ws = connect(agent.port, fp).await.unwrap();
    send(&mut ws, json!({"t":"hello","v":1,"name":"old app"})).await;
    assert_eq!(recv(&mut ws).await["code"], "version");
    assert!(agent.input.try_recv().is_err());
}

#[tokio::test]
async fn removing_a_phone_disconnects_it() {
    let agent = start_agent().await;
    let key = phone_key(7);
    let mut ws = pair(&agent, &key).await;
    assert_eq!(recv(&mut ws).await["t"], "welcome");

    // Wait until the agent has registered the session.
    for _ in 0..50 {
        if !agent.state.sessions().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(agent.state.remove_phone(&id_of(&key)).unwrap());
    let err = recv(&mut ws).await;
    assert_eq!(err["code"], "not_paired");
    for _ in 0..50 {
        if agent.state.sessions().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(agent.state.sessions().is_empty());
}

#[tokio::test]
async fn wrong_certificate_is_rejected_by_the_phone() {
    let agent = start_agent().await;
    let err = connect(agent.port, [9u8; 32]).await.err().unwrap();
    assert!(err.contains("fingerprint"), "{err}");
}

/// Paired and signed in; returns the client and the welcome message.
async fn signed_in(agent: &Agent, seed: u8) -> (Client, Value) {
    let mut ws = pair(agent, &phone_key(seed)).await;
    let welcome = recv(&mut ws).await;
    assert_eq!(welcome["t"], "welcome");
    (ws, welcome)
}

#[tokio::test]
async fn welcome_lists_features_and_permissions() {
    let agent = start_agent().await;
    let (_ws, welcome) = signed_in(&agent, 20).await;
    assert_eq!(
        welcome["features"],
        json!([
            "combo",
            "power",
            "apps",
            "screen",
            "clipboard",
            "files",
            "video",
            "audio"
        ])
    );
    // The microphone is off until the owner allows it.
    assert_eq!(
        welcome["allow"],
        json!({"power": true, "session": true, "apps": true, "screen": true, "clipboard": true, "files": true, "audio": true, "mic": false})
    );
}

#[tokio::test]
async fn combo_reaches_the_input_thread() {
    let agent = start_agent().await;
    let (mut ws, _) = signed_in(&agent, 21).await;
    send(
        &mut ws,
        json!({"t":"combo","mods":["ctrl","shift"],"k":"escape"}),
    )
    .await;
    send(&mut ws, json!({"t":"combo","mods":["ctrl"],"c":"v"})).await;
    // Round trip so the agent has handled both before we look.
    send(&mut ws, json!({"t":"ping"})).await;
    assert_eq!(recv(&mut ws).await["t"], "pong");
    use crate::protocol::{Modifier, NamedKey};
    assert_eq!(
        agent.input.recv_timeout(Duration::from_secs(2)).unwrap(),
        InputCmd::Combo {
            mods: vec![Modifier::Ctrl, Modifier::Shift],
            key: Some(NamedKey::Escape),
            ch: None
        }
    );
    assert_eq!(
        agent.input.recv_timeout(Duration::from_secs(2)).unwrap(),
        InputCmd::Combo {
            mods: vec![Modifier::Ctrl],
            key: None,
            ch: Some('v')
        }
    );
}

#[tokio::test]
async fn power_actions_follow_the_owners_permissions() {
    // Never really lock or shut down the machine running the tests.
    unsafe { std::env::set_var("PAIRDESK_POWER_DRY_RUN", "1") };
    let agent = start_agent().await;
    agent
        .state
        .prefs()
        .set_permissions(true, false, true)
        .unwrap();
    let (mut ws, welcome) = signed_in(&agent, 22).await;
    assert_eq!(welcome["allow"]["session"], false);

    send(&mut ws, json!({"t":"power","id":1,"a":"shut_down"})).await;
    let ack = recv(&mut ws).await;
    assert_eq!(
        ack,
        json!({"t":"ack","id":1,"ok":false,"code":"not_allowed","msg":"This is turned off in PairDesk settings on the computer."})
    );

    send(&mut ws, json!({"t":"power","id":2,"a":"lock"})).await;
    assert_eq!(recv(&mut ws).await, json!({"t":"ack","id":2,"ok":true}));

    // The owner turns everything off: even lock is refused now.
    agent
        .state
        .prefs()
        .set_permissions(false, false, false)
        .unwrap();
    send(&mut ws, json!({"t":"power","id":3,"a":"lock"})).await;
    assert_eq!(recv(&mut ws).await["code"], "not_allowed");
}

#[tokio::test]
async fn lists_and_launches_shortcuts_by_id_only() {
    let agent = start_agent().await;
    let dir = tempfile::tempdir().unwrap();
    let marker = dir.path().join("launched");
    agent
        .state
        .prefs()
        .add_shortcut(
            "Make marker",
            crate::prefs::ShortcutKind::Program,
            MARKER_PROGRAM,
            &marker_args(&marker),
        )
        .unwrap();
    let (mut ws, _) = signed_in(&agent, 23).await;

    send(&mut ws, json!({"t":"apps","id":7})).await;
    let list = recv_within(&mut ws, 60).await;
    assert_eq!(list["t"], "apps");
    assert_eq!(list["id"], 7);
    let shortcut = &list["shortcuts"][0];
    assert_eq!(shortcut["name"], "Make marker");
    assert_eq!(shortcut["kind"], "program");
    assert!(list["apps"].is_array());

    send(&mut ws, json!({"t":"launch","id":8,"app":"nope"})).await;
    assert_eq!(recv(&mut ws).await["code"], "not_found");

    send(&mut ws, json!({"t":"launch","id":9,"app":shortcut["id"]})).await;
    assert_eq!(recv(&mut ws).await, json!({"t":"ack","id":9,"ok":true}));
    // A new console window can take a few seconds on a busy Windows machine.
    for _ in 0..300 {
        if marker.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(marker.exists(), "the shortcut ran");

    agent
        .state
        .prefs()
        .set_permissions(true, true, false)
        .unwrap();
    send(&mut ws, json!({"t":"apps","id":10})).await;
    assert_eq!(recv(&mut ws).await["code"], "not_allowed");
    send(&mut ws, json!({"t":"launch","id":11,"app":shortcut["id"]})).await;
    assert_eq!(recv(&mut ws).await["code"], "not_allowed");
}

#[tokio::test]
async fn input_keeps_flowing_while_apps_load() {
    let agent = start_agent().await;
    let (mut ws, _) = signed_in(&agent, 24).await;
    send(&mut ws, json!({"t":"apps","id":1})).await;
    send(&mut ws, json!({"t":"move","dx":1,"dy":1})).await;
    send(&mut ws, json!({"t":"ping"})).await;
    let mut got = Vec::new();
    for _ in 0..2 {
        // Listing Start menu apps asks PowerShell, which is slow on a cold CI machine.
        got.push(
            recv_within(&mut ws, 60).await["t"]
                .as_str()
                .unwrap()
                .to_string(),
        );
    }
    got.sort();
    assert_eq!(got, vec!["apps", "pong"]);
    assert_eq!(
        agent.input.recv_timeout(Duration::from_secs(2)).unwrap(),
        InputCmd::Move { dx: 1, dy: 1 }
    );
}

#[cfg(windows)]
const MARKER_PROGRAM: &str = r"C:\Windows\System32\cmd.exe";
#[cfg(not(windows))]
const MARKER_PROGRAM: &str = "/bin/sh";

/// Arguments that make MARKER_PROGRAM create `marker`.
fn marker_args(marker: &std::path::Path) -> String {
    if cfg!(windows) {
        format!("/c \"type nul > {}\"", marker.display())
    } else {
        format!("-c \"touch '{}'\"", marker.display())
    }
}

/// Next binary message (a screen frame), skipping text messages.
async fn recv_frame(ws: &mut Client) -> Vec<u8> {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("timed out waiting for a screen frame")
            .expect("connection closed")
            .expect("read failed");
        if let Message::Binary(b) = frame {
            return b.to_vec();
        }
    }
}

#[tokio::test]
async fn screen_view_follows_the_permission() {
    let agent = start_agent().await;
    {
        let mut prefs = agent.state.prefs();
        prefs.set_allow_screen(false).unwrap();
    }
    let (mut ws, welcome) = signed_in(&agent, 30).await;
    assert_eq!(welcome["allow"]["screen"], false);
    send(&mut ws, json!({"t":"screen_start","id":1})).await;
    assert_eq!(recv(&mut ws).await["code"], "not_allowed");
}

/// Needs an X display (run under Xvfb); skipped otherwise.
#[tokio::test(flavor = "multi_thread")]
async fn streams_h264_video_to_phones_that_ask_for_it() {
    if std::env::var_os("DISPLAY").is_none() {
        eprintln!("no DISPLAY; skipped");
        return;
    }
    let agent = start_agent().await;
    let (mut ws, welcome) = signed_in(&agent, 33).await;
    assert!(
        welcome["features"]
            .as_array()
            .unwrap()
            .contains(&json!("video"))
    );
    send(
        &mut ws,
        json!({"t":"screen_start","id":6,"quality":"low","codecs":["vp9","h264"]}),
    )
    .await;
    let info = recv(&mut ws).await;
    assert_eq!(info["codec"], "h264", "{info}");
    let (w, h) = (
        info["width"].as_u64().unwrap() as usize,
        info["height"].as_u64().unwrap() as usize,
    );

    // A key frame first; it decodes to a picture of the announced size.
    let mut decoder = openh264::decoder::Decoder::new().unwrap();
    let first = recv_frame(&mut ws).await;
    assert_eq!(&first[..4], b"PDV1");
    assert_eq!(first[16] & 1, 1, "key frame");
    let len = u32::from_le_bytes(first[17..21].try_into().unwrap()) as usize;
    assert_eq!(first.len(), 21 + len);
    {
        use openh264::formats::YUVSource;
        let pic = decoder.decode(&first[21..]).unwrap().expect("a picture");
        assert_eq!(pic.dimensions(), (w, h));
    }
    let seq = u32::from_le_bytes(first[4..8].try_into().unwrap());

    // After a refresh the next picture is a key frame again.
    send(&mut ws, json!({"t":"screen_ack","seq":seq})).await;
    send(&mut ws, json!({"t":"screen_refresh"})).await;
    loop {
        let f = recv_frame(&mut ws).await;
        let seq = u32::from_le_bytes(f[4..8].try_into().unwrap());
        send(&mut ws, json!({"t":"screen_ack","seq":seq})).await;
        let len = u32::from_le_bytes(f[17..21].try_into().unwrap());
        if len > 0 {
            assert_eq!(f[16] & 1, 1, "a refresh starts with a key frame");
            assert!(decoder.decode(&f[21..]).unwrap().is_some());
            break;
        }
    }

    // Phones that don't ask get JPEG, as before.
    send(&mut ws, json!({"t":"screen_start","id":7,"quality":"low"})).await;
    loop {
        let msg = recv(&mut ws).await;
        if msg["t"] == "screen" {
            assert_eq!(msg["codec"], "jpeg");
            break;
        }
    }
    loop {
        let f = recv_frame(&mut ws).await;
        if &f[..4] == b"PDS1" {
            break;
        }
    }
}

/// Needs an X display (run under Xvfb); skipped otherwise.
#[tokio::test(flavor = "multi_thread")]
async fn streams_the_screen_with_acks_and_can_be_stopped() {
    if std::env::var_os("DISPLAY").is_none() {
        eprintln!("no DISPLAY; skipped");
        return;
    }
    let agent = start_agent().await;
    let (mut ws, _) = signed_in(&agent, 31).await;
    send(&mut ws, json!({"t":"screen_start","id":5,"quality":"low"})).await;
    let info = recv(&mut ws).await;
    assert_eq!(info["t"], "screen", "{info}");
    assert_eq!(info["id"], 5);
    let (w, h) = (
        info["width"].as_u64().unwrap(),
        info["height"].as_u64().unwrap(),
    );
    assert!(w <= 960 && w > 0 && h > 0);
    assert!(!info["monitors"].as_array().unwrap().is_empty());

    // The first frame is the whole screen.
    let first = recv_frame(&mut ws).await;
    assert_eq!(&first[..4], b"PDS1");
    let seq = u32::from_le_bytes(first[4..8].try_into().unwrap());
    assert_eq!(
        u16::from_le_bytes(first[8..10].try_into().unwrap()) as u64,
        w
    );
    assert_eq!(
        u16::from_le_bytes(first[16..18].try_into().unwrap()),
        1,
        "one full rect"
    );
    assert_eq!(agent.state.viewing_phones().len(), 1);

    // Pointing at the middle of the shown screen moves the real pointer there.
    send(&mut ws, json!({"t":"move_to","x":0.5,"y":0.5})).await;
    send(&mut ws, json!({"t":"ping"})).await;
    loop {
        if recv(&mut ws).await["t"] == "pong" {
            break;
        }
    }
    match agent.input.recv_timeout(Duration::from_secs(2)).unwrap() {
        InputCmd::MoveTo { x, y } => assert!(x > 0 && y > 0, "({x}, {y})"),
        other => panic!("{other:?}"),
    }

    // Without acks the agent stops after two frames in flight; an ack
    // and a refresh bring the next full frame.
    send(&mut ws, json!({"t":"screen_ack","seq":seq})).await;
    send(&mut ws, json!({"t":"screen_refresh"})).await;
    let again = recv_frame(&mut ws).await;
    assert!(u32::from_le_bytes(again[4..8].try_into().unwrap()) > seq);

    // The computer's owner stops it from the settings page.
    agent.state.stop_viewing(None);
    loop {
        let msg = recv(&mut ws).await;
        if msg["t"] == "screen_stopped" {
            assert!(
                msg["msg"]
                    .as_str()
                    .unwrap()
                    .contains("stopped on the computer")
            );
            break;
        }
    }
    assert!(agent.state.viewing_phones().is_empty());
}

// ---------------------------------------------------------------- Phase 6

/// One downloads folder for this test run (the setting is process-wide).
fn downloads() -> &'static std::path::Path {
    static DIR: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        let d = tempfile::tempdir().unwrap();
        // SAFETY: set once, before any test reads it.
        unsafe { std::env::set_var("PAIRDESK_DOWNLOADS", d.path()) };
        d
    })
    .path()
}

#[tokio::test]
async fn clipboard_both_ways_and_paste() {
    let agent = start_agent().await;
    let (mut ws, _) = signed_in(&agent, 40).await;
    send(
        &mut ws,
        json!({"t":"clip_set","id":1,"text":"from the phone ශ්‍රී"}),
    )
    .await;
    assert_eq!(recv(&mut ws).await, json!({"t":"ack","id":1,"ok":true}));
    send(&mut ws, json!({"t":"clip_get","id":2})).await;
    assert_eq!(
        recv(&mut ws).await,
        json!({"t":"clip","id":2,"text":"from the phone ශ්‍රී"})
    );
    // Paste: set, then Ctrl+V in the active window.
    send(
        &mut ws,
        json!({"t":"clip_set","id":3,"text":"pasted","paste":true}),
    )
    .await;
    assert_eq!(recv(&mut ws).await["ok"], true);
    use crate::protocol::Modifier;
    assert_eq!(
        agent.input.recv_timeout(Duration::from_secs(2)).unwrap(),
        InputCmd::Combo {
            mods: vec![Modifier::Ctrl],
            key: None,
            ch: Some('v')
        }
    );
    // Switched off on the computer.
    agent.state.prefs().set_allow_clipboard(false).unwrap();
    send(&mut ws, json!({"t":"clip_get","id":4})).await;
    assert_eq!(recv(&mut ws).await["code"], "not_allowed");
}

/// Sends `data` the way the phone does; returns the agent's final answer.
async fn phone_sends(
    ws: &mut Client,
    fid: u32,
    name: &str,
    data: &[u8],
    sha: Option<String>,
) -> Value {
    send(
        ws,
        json!({"t":"file_offer","fid":fid,"name":name,"size":data.len()}),
    )
    .await;
    let answer = recv(ws).await;
    if answer["t"] != "file_accept" {
        return answer;
    }
    for (i, c) in data.chunks(crate::files::CHUNK).enumerate() {
        let m = crate::files::chunk_message(fid, (i * crate::files::CHUNK) as u64, c);
        ws.send(Message::binary(m)).await.unwrap();
    }
    let sha = sha.unwrap_or_else(|| crate::files::hex(&Sha256::digest(data)));
    send(ws, json!({"t":"file_end","fid":fid,"sha256":sha})).await;
    loop {
        let m = recv(ws).await;
        if m["t"] != "file_progress" {
            return m;
        }
    }
}

#[tokio::test]
async fn receives_files_from_the_phone() {
    let dir = downloads();
    let agent = start_agent().await;
    let (mut ws, _) = signed_in(&agent, 41).await;
    let data: Vec<u8> = (0..3_000_000u32).map(|i| (i % 251) as u8).collect();
    let done = phone_sends(&mut ws, 1, "../holiday photo.jpg", &data, None).await;
    assert_eq!(done["t"], "file_done");
    assert_eq!(done["ok"], true);
    let name = done["name"].as_str().unwrap().to_string();
    assert!(name.starts_with("holiday photo"), "{name}");
    assert_eq!(std::fs::read(dir.join(&name)).unwrap(), data);

    // A damaged file is refused and nothing is left behind.
    let done = phone_sends(&mut ws, 2, "broken.bin", b"abc", Some("00".repeat(32))).await;
    assert_eq!(done["ok"], false);
    assert!(done["msg"].as_str().unwrap().contains("checksum"));
    assert!(!dir.join("broken.bin").exists());
    assert!(
        std::fs::read_dir(dir).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".part")),
        "no part files"
    );

    // The settings page lists both.
    let list = agent.state.transfers();
    assert_eq!(list[0].state, crate::state::TransferState::Failed);
    assert_eq!(list[1].state, crate::state::TransferState::Done);
    assert_eq!(list[1].path.as_deref(), Some(dir.join(&name).as_path()));

    // Switched off on the computer.
    agent.state.prefs().set_allow_files(false).unwrap();
    let refused = phone_sends(&mut ws, 3, "x.txt", b"x", None).await;
    assert_eq!(refused["t"], "file_cancel");
}

#[tokio::test]
async fn a_phone_that_disconnects_mid_file_leaves_no_part_file() {
    let dir = downloads();
    let agent = start_agent().await;
    let (mut ws, _) = signed_in(&agent, 42).await;
    send(
        &mut ws,
        json!({"t":"file_offer","fid":9,"name":"half.bin","size":1_000_000}),
    )
    .await;
    assert_eq!(recv(&mut ws).await["t"], "file_accept");
    ws.send(Message::binary(crate::files::chunk_message(
        9, 0, &[1; 1000],
    )))
    .await
    .unwrap();
    drop(ws);
    for _ in 0..50 {
        if agent.state.transfers()[0].state == crate::state::TransferState::Failed {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(
        agent.state.transfers()[0].state,
        crate::state::TransferState::Failed
    );
    assert!(!dir.join("half.bin").exists());
    assert!(std::fs::read_dir(dir).unwrap().all(|e| {
        !e.unwrap()
            .file_name()
            .to_string_lossy()
            .contains("pairdesk-")
    }));
}

#[tokio::test]
async fn sends_files_to_the_phone() {
    let agent = start_agent().await;
    let (mut ws, welcome) = signed_in(&agent, 43).await;
    let _ = welcome;
    let src = tempfile::tempdir().unwrap();
    let path = src.path().join("notes.txt");
    let data: Vec<u8> = (0..(crate::files::WINDOW as usize + 300_000))
        .map(|i| (i * 13) as u8)
        .collect();
    std::fs::write(&path, &data).unwrap();
    let file = Arc::new(crate::files::Outbound::from_path(&path).unwrap());
    assert_eq!(agent.state.send_file(None, file), 1);

    let offer = recv(&mut ws).await;
    assert_eq!(offer["t"], "file_offer");
    assert_eq!(offer["name"], "notes.txt");
    assert_eq!(offer["size"], data.len());
    let fid = offer["fid"].as_u64().unwrap();
    assert!(fid >= crate::files::AGENT_FIDS as u64);
    send(&mut ws, json!({"t":"file_accept","fid":fid})).await;

    let mut got = Vec::new();
    let mut acked = 0usize;
    let sha = loop {
        let m = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        match m {
            Message::Binary(b) => {
                let (f, off, bytes) = crate::files::parse_chunk(&b).unwrap();
                assert_eq!((f as u64, off as usize), (fid, got.len()));
                got.extend_from_slice(bytes);
                if got.len() - acked >= crate::files::PROGRESS_EVERY as usize
                    || got.len() == data.len()
                {
                    acked = got.len();
                    send(
                        &mut ws,
                        json!({"t":"file_progress","fid":fid,"received":acked}),
                    )
                    .await;
                }
            }
            Message::Text(t) => {
                let v: Value = serde_json::from_str(&t).unwrap();
                assert_eq!(v["t"], "file_end");
                break v["sha256"].as_str().unwrap().to_string();
            }
            _ => {}
        }
    };
    assert_eq!(got, data);
    assert_eq!(sha, crate::files::hex(&Sha256::digest(&data)));
    send(&mut ws, json!({"t":"file_done","fid":fid,"ok":true})).await;
    for _ in 0..50 {
        if agent.state.transfers()[0].state == crate::state::TransferState::Done {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let t = &agent.state.transfers()[0];
    assert_eq!(
        (t.state, t.incoming, t.done),
        (crate::state::TransferState::Done, false, data.len() as u64)
    );
}

#[tokio::test]
async fn a_helper_gets_limited_temporary_access() {
    let agent = start_agent().await;
    let key = phone_key(40);
    agent.state.start_help();
    assert!(agent.state.pairing_links().unwrap().help);
    let fp = *agent.state.identity.fingerprint();
    let mut ws = connect(agent.port, fp).await.unwrap();
    let token = token_of(&agent.state);
    send(
        &mut ws,
        json!({"t":"pair","v":2,"token":token,"id":id_of(&key),"name":"Friend"}),
    )
    .await;
    answer(&mut ws, &key, &fp).await;
    let welcome = recv(&mut ws).await;
    assert_eq!(welcome["t"], "welcome");
    // The screen, pointer, clipboard and apps; no power, files or sound.
    let allow = &welcome["allow"];
    assert_eq!(allow["screen"], true);
    assert_eq!(allow["clipboard"], true);
    assert_eq!(allow["apps"], true);
    for off in ["power", "session", "files", "audio", "mic"] {
        assert_eq!(allow[off], false, "{off}");
    }
    let id = id_of(&key);
    assert!(agent.state.is_helper(&id));
    let until = agent.state.phones().get(&id).unwrap().help_until.unwrap();
    let left = until - crate::config::unix_now();
    assert!((7100..=7200).contains(&left), "{left}");

    // Power actions are refused even though the owner allows them.
    send(&mut ws, json!({"t":"power","a":"lock","id":7})).await;
    let ack = recv(&mut ws).await;
    assert_eq!(ack["ok"], false);
    assert_eq!(ack["code"], "not_allowed");

    // Still connected: not swept. Time's up: removed and disconnected.
    assert!(agent.state.sweep_helpers().is_empty());
    agent.state.phones().add(&id, "Friend", Some(1)).unwrap();
    assert_eq!(agent.state.sweep_helpers(), vec!["Friend".to_string()]);
    assert!(!agent.state.is_paired(&id));
    let bye = recv(&mut ws).await;
    assert_eq!(bye["code"], "not_paired");
}
