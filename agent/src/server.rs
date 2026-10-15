// SPDX-License-Identifier: GPL-3.0-or-later
//! The phone-facing server: TLS, then WebSocket, then pairing or
//! authentication, then input commands.

use std::collections::HashSet;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use ed25519_dalek::VerifyingKey;
use futures_util::{SinkExt, StreamExt};
use log::{info, warn};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio_rustls::TlsAcceptor;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use crate::auth;
use crate::input::{InputCmd, InputHandle};
use crate::protocol::{ClientMsg, ErrorCode, MouseButton, PROTOCOL_VERSION, ServerMsg};
use crate::state::{AppState, Session};

/// Largest WebSocket frame accepted from a phone.
const MAX_FRAME_BYTES: usize = 64 * 1024;
/// Time a phone gets to finish TLS, WebSocket and authentication.
const AUTH_TIMEOUT: Duration = Duration::from_secs(15);
/// Pause before answering a failed attempt, to slow down guessing.
const FAILURE_DELAY: Duration = Duration::from_millis(750);
/// Connections allowed to be in the handshake stage at once.
const MAX_PENDING: usize = 16;

type Ws = WebSocketStream<tokio_rustls::server::TlsStream<TcpStream>>;

pub async fn run(
    listener: TcpListener,
    state: Arc<AppState>,
    input: InputHandle,
) -> std::io::Result<()> {
    let tls = state.identity.tls_config().map_err(std::io::Error::other)?;
    let acceptor = TlsAcceptor::from(tls);
    let pending = Arc::new(Semaphore::new(MAX_PENDING));

    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                warn!("accept failed: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let Ok(permit) = pending.clone().try_acquire_owned() else {
            warn!("{peer}: too many connections waiting, dropping");
            continue;
        };
        let (state, input, acceptor) = (state.clone(), input.clone(), acceptor.clone());
        tokio::spawn(async move {
            let _ = stream.set_nodelay(true);
            let started = tokio::time::timeout(AUTH_TIMEOUT, async {
                let tls = acceptor
                    .accept(stream)
                    .await
                    .map_err(|e| format!("TLS: {e}"))?;
                let config = WebSocketConfig::default()
                    .max_message_size(Some(MAX_FRAME_BYTES))
                    .max_frame_size(Some(MAX_FRAME_BYTES));
                let mut ws = tokio_tungstenite::accept_async_with_config(tls, Some(config))
                    .await
                    .map_err(|e| format!("WebSocket: {e}"))?;
                let who = authenticate(&mut ws, &state, peer).await?;
                Ok::<_, String>((ws, who))
            })
            .await;
            drop(permit);

            match started {
                Ok(Ok((ws, who))) => {
                    if let Err(e) = serve(ws, who, peer, &state, input).await {
                        warn!("{peer}: {e}");
                    }
                }
                Ok(Err(e)) => warn!("{peer}: {e}"),
                Err(_) => warn!("{peer}: took too long to authenticate"),
            }
        });
    }
}

/// A phone that proved who it is.
struct Authenticated {
    id: String,
    name: String,
    just_paired: bool,
}

async fn authenticate(
    ws: &mut Ws,
    state: &AppState,
    peer: SocketAddr,
) -> Result<Authenticated, String> {
    // 1. hello (paired phone) or pair (new phone)
    let first = next_msg(ws).await?;
    let (id, name, token) = match first {
        ClientMsg::Hello { v, id, name } => {
            check_version(ws, v).await?;
            let Some(id) = id else {
                return fail(ws, ErrorCode::NotPaired, "this app needs to pair first").await;
            };
            if !state.is_paired(&id) {
                tokio::time::sleep(FAILURE_DELAY).await;
                return fail(
                    ws,
                    ErrorCode::NotPaired,
                    "this phone isn't paired with this computer; pair it again",
                )
                .await;
            }
            let name = name
                .filter(|n| !n.is_empty())
                .or_else(|| state.phones().get(&id).map(|p| p.name.clone()))
                .unwrap_or_else(|| "Phone".into());
            (id, name, None)
        }
        ClientMsg::Pair { v, token, id, name } => {
            check_version(ws, v).await?;
            if !state.pairing_token_valid(&token) {
                tokio::time::sleep(FAILURE_DELAY).await;
                return fail(
                    ws,
                    ErrorCode::BadToken,
                    "this pairing code is used or expired; show a new one on the computer",
                )
                .await;
            }
            let name = name
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| "Phone".into());
            (id, name, Some(token))
        }
        _ => return fail(ws, ErrorCode::Unexpected, "send hello or pair first").await,
    };

    let Some(key): Option<VerifyingKey> = auth::parse_phone_id(&id) else {
        return fail(ws, ErrorCode::BadSignature, "invalid phone key").await;
    };

    // 2. challenge → auth
    let nonce = crate::config::random_bytes::<32>();
    send(
        ws,
        &ServerMsg::Challenge {
            nonce: crate::config::b64(&nonce),
            v: PROTOCOL_VERSION,
        },
    )
    .await?;
    let sig = match next_msg(ws).await? {
        ClientMsg::Auth { sig } => sig,
        _ => return fail(ws, ErrorCode::Unexpected, "expected auth").await,
    };
    if !auth::verify(&key, state.identity.fingerprint(), &nonce, &sig) {
        tokio::time::sleep(FAILURE_DELAY).await;
        return fail(ws, ErrorCode::BadSignature, "signature check failed").await;
    }

    // 3. store a new pairing
    let just_paired = token.is_some();
    if let Some(token) = token {
        if !state.consume_pairing_token(&token) {
            return fail(
                ws,
                ErrorCode::BadToken,
                "this pairing code was already used",
            )
            .await;
        }
        state
            .add_phone(&id, &name)
            .map_err(|e| format!("could not save the paired phone: {e}"))?;
        info!("{peer}: paired new phone \"{name}\"");
    }
    Ok(Authenticated {
        id,
        name,
        just_paired,
    })
}

async fn check_version(ws: &mut Ws, v: Option<u32>) -> Result<(), String> {
    if v == Some(PROTOCOL_VERSION) {
        Ok(())
    } else {
        fail(
            ws,
            ErrorCode::Version,
            &format!("this computer runs PairDesk protocol v{PROTOCOL_VERSION}; update the app"),
        )
        .await
    }
}

async fn serve(
    ws: Ws,
    who: Authenticated,
    peer: SocketAddr,
    state: &AppState,
    input: InputHandle,
) -> Result<(), String> {
    let (mut sink, mut source) = ws.split();
    send(
        &mut sink,
        &ServerMsg::Welcome {
            name: state.name.clone(),
            os: std::env::consts::OS.into(),
            v: PROTOCOL_VERSION,
            paired: who.just_paired,
        },
    )
    .await?;
    info!("{peer}: \"{}\" connected", who.name);

    let session = state.open_session(Session {
        phone_id: who.id.clone(),
        address: peer.ip().to_string(),
    });
    let mut revocations = state.subscribe_revocations();
    // Buttons this phone is holding, released if it disconnects mid-drag.
    let mut held: HashSet<MouseButton> = HashSet::new();

    let result = async {
        loop {
            let frame = tokio::select! {
                frame = source.next() => frame,
                _ = revocations.changed() => {
                    if state.is_paired(&who.id) { continue; }
                    let _ = send(&mut sink, &ServerMsg::Error {
                        code: ErrorCode::NotPaired,
                        msg: "this phone was removed on the computer".into(),
                    }).await;
                    let _ = sink.close().await;
                    info!("{peer}: \"{}\" was unpaired, disconnecting", who.name);
                    break;
                }
            };
            let Some(frame) = frame else { break };
            let text = match frame.map_err(|e| e.to_string())? {
                Message::Text(t) => t,
                Message::Close(_) => break,
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
                Message::Binary(_) => {
                    send(
                        &mut sink,
                        &error(ErrorCode::BadMessage, "binary frames not supported"),
                    )
                    .await?;
                    continue;
                }
            };
            let msg = match ClientMsg::parse(text.as_str()) {
                Ok(m) => m,
                Err(e) => {
                    warn!("{peer}: bad message: {e}");
                    send(
                        &mut sink,
                        &error(ErrorCode::BadMessage, &format!("bad message: {e}")),
                    )
                    .await?;
                    continue;
                }
            };
            match msg {
                ClientMsg::Ping => send(&mut sink, &ServerMsg::Pong).await?,
                ClientMsg::Move { dx, dy } => input.send(InputCmd::Move { dx, dy }),
                ClientMsg::Click { b } => input.send(InputCmd::Click(b)),
                ClientMsg::Down { b } => {
                    held.insert(b);
                    input.send(InputCmd::Down(b));
                }
                ClientMsg::Up { b } => {
                    held.remove(&b);
                    input.send(InputCmd::Up(b));
                }
                ClientMsg::Scroll { dx, dy } => input.send(InputCmd::Scroll { dx, dy }),
                ClientMsg::Text { s } => input.send(InputCmd::Text(s)),
                ClientMsg::Key { k } => input.send(InputCmd::Key(k)),
                ClientMsg::Hello { .. } | ClientMsg::Pair { .. } | ClientMsg::Auth { .. } => {
                    send(
                        &mut sink,
                        &error(ErrorCode::BadMessage, "already signed in"),
                    )
                    .await?
                }
            }
        }
        Ok::<(), String>(())
    }
    .await;

    for b in held {
        input.send(InputCmd::Up(b));
    }
    state.close_session(session);
    info!("{peer}: \"{}\" disconnected", who.name);
    result
}

fn error(code: ErrorCode, msg: &str) -> ServerMsg {
    ServerMsg::Error {
        code,
        msg: msg.to_string(),
    }
}

/// Sends a fatal error, closes the connection and returns `Err`.
async fn fail<T>(ws: &mut Ws, code: ErrorCode, msg: &str) -> Result<T, String> {
    let _ = send(ws, &error(code, msg)).await;
    let _ = ws.close(None).await;
    Err(format!("refused ({code:?}): {msg}"))
}

/// Reads the next text message during the handshake.
async fn next_msg(ws: &mut Ws) -> Result<ClientMsg, String> {
    loop {
        let frame = ws
            .next()
            .await
            .ok_or("closed during handshake")?
            .map_err(|e| e.to_string())?;
        match frame {
            Message::Text(t) => {
                return match ClientMsg::parse(t.as_str()) {
                    Ok(m) => Ok(m),
                    Err(e) => fail(ws, ErrorCode::Unexpected, &format!("bad message: {e}")).await,
                };
            }
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            Message::Close(_) => return Err("closed during handshake".into()),
            Message::Binary(_) => {
                return fail(ws, ErrorCode::Unexpected, "binary frames not supported").await;
            }
        }
    }
}

async fn send<S>(sink: &mut S, msg: &ServerMsg) -> Result<(), String>
where
    S: SinkExt<Message> + Unpin,
    S::Error: std::fmt::Display,
{
    let json = serde_json::to_string(msg).map_err(|e| e.to_string())?;
    sink.send(Message::text(json))
        .await
        .map_err(|e| e.to_string())
}

#[cfg(test)]
#[path = "server_tests.rs"]
mod tests;
