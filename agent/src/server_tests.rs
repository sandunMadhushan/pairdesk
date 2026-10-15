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
    tokio::spawn(crate::server::run(listener, state.clone(), input));
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
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(5), ws.next())
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
    assert_eq!(welcome["features"], json!(["combo", "power", "apps"]));
    assert_eq!(
        welcome["allow"],
        json!({"power": true, "session": true, "apps": true})
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
            "/bin/sh",
            &format!("-c \"touch '{}'\"", marker.display()),
        )
        .unwrap();
    let (mut ws, _) = signed_in(&agent, 23).await;

    send(&mut ws, json!({"t":"apps","id":7})).await;
    let list = recv(&mut ws).await;
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
    for _ in 0..50 {
        if marker.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
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
        got.push(recv(&mut ws).await["t"].as_str().unwrap().to_string());
    }
    got.sort();
    assert_eq!(got, vec!["apps", "pong"]);
    assert_eq!(
        agent.input.recv_timeout(Duration::from_secs(2)).unwrap(),
        InputCmd::Move { dx: 1, dy: 1 }
    );
}
