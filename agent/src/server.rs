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
use crate::protocol::{
    AckCode, ClientMsg, ErrorCode, MouseButton, PROTOCOL_VERSION, PowerAction, ServerMsg,
};
use crate::state::{AppState, Session};

/// Optional features announced in `welcome`.
const FEATURES: &[&str] = &["combo", "power", "apps", "screen"];
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
    state: &Arc<AppState>,
    input: InputHandle,
) -> Result<(), String> {
    let (mut sink, mut source) = ws.split();
    let allow = state.prefs().get().allow();
    let addrs = state.phone_addresses();
    send(
        &mut sink,
        &ServerMsg::Welcome {
            name: state.name.clone(),
            os: std::env::consts::OS.into(),
            v: PROTOCOL_VERSION,
            paired: who.just_paired,
            features: FEATURES.to_vec(),
            allow,
            addrs,
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
    // Replies from slow requests (app list, launching) arrive here, so the
    // touchpad keeps working while they run.
    let (reply_tx, mut reply_rx) = tokio::sync::mpsc::unbounded_channel::<ServerMsg>();
    // Screen frames, as binary messages. At most two are ever waiting.
    let (frame_tx, mut frame_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let mut viewer: Option<crate::screen::Viewer> = None;

    let result = async {
        loop {
            let frame = tokio::select! {
                frame = source.next() => frame,
                Some(reply) = reply_rx.recv() => {
                    if matches!(reply, ServerMsg::ScreenStopped { .. }) {
                        stop_viewer(&mut viewer, state, session);
                    }
                    send(&mut sink, &reply).await?;
                    continue;
                }
                Some(frame) = frame_rx.recv() => {
                    sink.send(Message::binary(frame)).await.map_err(|e| e.to_string())?;
                    continue;
                }
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
                ClientMsg::Combo { mods, k, c } => input.send(InputCmd::Combo {
                    mods,
                    key: k,
                    ch: c,
                }),
                ClientMsg::Power { id, a } => power_request(state, id, a, reply_tx.clone()),
                ClientMsg::Apps { id } => apps_request(state, id, reply_tx.clone()),
                ClientMsg::Launch { id, app } => launch_request(state, id, app, reply_tx.clone()),
                ClientMsg::ScreenStart {
                    id,
                    monitor,
                    quality,
                } => {
                    stop_viewer(&mut viewer, state, session);
                    if !state.prefs().get().allow_screen {
                        send(
                            &mut sink,
                            &ack(id, Err((AckCode::NotAllowed, NOT_ALLOWED.into()))),
                        )
                        .await?;
                        continue;
                    }
                    let quality = crate::screen::encode::Quality::preset(
                        quality.as_deref().unwrap_or("medium"),
                    );
                    let (frames, notes) = (frame_tx.clone(), reply_tx.clone());
                    let started = tokio::task::spawn_blocking(move || {
                        crate::screen::Viewer::start(monitor, quality, move |out| match out {
                            crate::screen::Out::Frame(f) => frames.send(f).is_ok(),
                            crate::screen::Out::Stopped(msg) => {
                                notes.send(ServerMsg::ScreenStopped { msg }).is_ok()
                            }
                        })
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                    match started {
                        Ok((v, monitors)) => {
                            info!("{peer}: \"{}\" is viewing {}", who.name, v.monitor.name);
                            state.add_viewer(
                                session,
                                crate::state::ScreenViewer {
                                    phone_id: who.id.clone(),
                                    stop: v.stop_flag(),
                                    notify: reply_tx.clone(),
                                },
                            );
                            // Sent before any frame, which waits in frame_rx.
                            send(
                                &mut sink,
                                &ServerMsg::Screen {
                                    id,
                                    monitors: monitors
                                        .iter()
                                        .map(|m| crate::protocol::MonitorInfo {
                                            index: m.index,
                                            name: m.name.clone(),
                                            width: m.width,
                                            height: m.height,
                                            primary: m.primary,
                                        })
                                        .collect(),
                                    monitor: v.monitor.index,
                                    width: v.size.0,
                                    height: v.size.1,
                                },
                            )
                            .await?;
                            viewer = Some(v);
                        }
                        Err(e) => send(&mut sink, &ack(id, Err((AckCode::Failed, e)))).await?,
                    }
                }
                ClientMsg::ScreenAck { seq } => {
                    if let Some(v) = &viewer {
                        v.ack(seq);
                    }
                }
                ClientMsg::ScreenRefresh => {
                    if let Some(v) = &viewer {
                        v.refresh();
                    }
                }
                ClientMsg::ScreenStop => stop_viewer(&mut viewer, state, session),
                ClientMsg::MoveTo { x, y } => {
                    if let Some(v) = &viewer {
                        let (dx, dy) = v.to_desktop(x, y);
                        input.send(InputCmd::MoveTo { x: dx, y: dy });
                    }
                }
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

    stop_viewer(&mut viewer, state, session);
    for b in held {
        input.send(InputCmd::Up(b));
    }
    state.close_session(session);
    info!("{peer}: \"{}\" disconnected", who.name);
    result
}

type Replies = tokio::sync::mpsc::UnboundedSender<ServerMsg>;

/// Ends this phone's screen view, if any. The capture thread is joined
/// off the async runtime.
fn stop_viewer(viewer: &mut Option<crate::screen::Viewer>, state: &AppState, session: u64) {
    if let Some(v) = viewer.take() {
        state.remove_viewer(session);
        tokio::task::spawn_blocking(move || drop(v));
    }
}

const NOT_ALLOWED: &str = "This is turned off in PairDesk settings on the computer.";

fn ack(id: Option<u64>, result: Result<(), (AckCode, String)>) -> ServerMsg {
    match result {
        Ok(()) => ServerMsg::Ack {
            id,
            ok: true,
            code: None,
            msg: None,
        },
        Err((code, msg)) => ServerMsg::Ack {
            id,
            ok: false,
            code: Some(code),
            msg: Some(msg),
        },
    }
}

fn power_request(state: &AppState, id: Option<u64>, action: PowerAction, replies: Replies) {
    if !state.prefs().get().allows(action) {
        let _ = replies.send(ack(id, Err((AckCode::NotAllowed, NOT_ALLOWED.into()))));
        return;
    }
    tokio::spawn(async move {
        if matches!(action, PowerAction::Lock | PowerAction::ScreenOff) {
            // Quick, and the computer stays up: report the real result.
            let result = tokio::task::spawn_blocking(move || crate::power::run(action))
                .await
                .unwrap_or_else(|e| Err(e.to_string()));
            let _ = replies.send(ack(id, result.map_err(|e| (AckCode::Failed, e))));
        } else {
            // The computer is about to go away: answer first, then act.
            let _ = replies.send(ack(id, Ok(())));
            tokio::time::sleep(Duration::from_millis(400)).await;
            let result = tokio::task::spawn_blocking(move || crate::power::run(action)).await;
            if let Ok(Err(e)) = result {
                warn!("{action:?} failed: {e}");
            }
        }
    });
}

fn apps_request(state: &Arc<AppState>, id: Option<u64>, replies: Replies) {
    if !state.prefs().get().allow_apps {
        let _ = replies.send(ack(id, Err((AckCode::NotAllowed, NOT_ALLOWED.into()))));
        return;
    }
    let state = state.clone();
    tokio::task::spawn_blocking(move || {
        let prefs = state.prefs().get().clone();
        let shortcuts = crate::apps::shortcuts(&prefs)
            .iter()
            .map(|a| a.entry())
            .collect();
        let apps = state.apps.installed().iter().map(|a| a.entry()).collect();
        let _ = replies.send(ServerMsg::Apps {
            id,
            shortcuts,
            apps,
        });
    });
}

fn launch_request(state: &Arc<AppState>, id: Option<u64>, app: String, replies: Replies) {
    if !state.prefs().get().allow_apps {
        let _ = replies.send(ack(id, Err((AckCode::NotAllowed, NOT_ALLOWED.into()))));
        return;
    }
    let state = state.clone();
    tokio::task::spawn_blocking(move || {
        let prefs = state.prefs().get().clone();
        let result = match state.apps.find(&app, &prefs) {
            None => Err((
                AckCode::NotFound,
                "That app isn't on the computer any more.".to_string(),
            )),
            Some(found) => crate::apps::launch(&found).map_err(|e| (AckCode::Failed, e)),
        };
        let _ = replies.send(ack(id, result));
    });
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
