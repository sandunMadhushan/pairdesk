// SPDX-License-Identifier: GPL-3.0-or-later
//! PairDesk desktop agent — Phase 0 spike.
//!
//! Listens for the phone app on the local network and turns its messages
//! into mouse and keyboard input. Phase 0 has NO pairing or encryption:
//! anyone on the same network can connect. Only run it on a network you trust.

mod input;
mod protocol;

use std::collections::HashSet;
use std::net::SocketAddr;

use futures_util::{SinkExt, StreamExt};
use log::{error, info, warn};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use input::{InputCmd, InputHandle};
use protocol::{ClientMsg, MouseButton, PROTOCOL_VERSION, ServerMsg};

const DEFAULT_PORT: u16 = 47800;
/// Largest WebSocket frame accepted from a phone.
const MAX_FRAME_BYTES: usize = 64 * 1024;

struct Config {
    bind: String,
    port: u16,
}

fn parse_args() -> Result<Config, String> {
    let mut cfg = Config {
        bind: "0.0.0.0".into(),
        port: DEFAULT_PORT,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" | "-p" => {
                let v = args.next().ok_or("--port needs a value")?;
                cfg.port = v.parse().map_err(|_| format!("invalid port: {v}"))?;
            }
            "--bind" => cfg.bind = args.next().ok_or("--bind needs an address")?,
            "--help" | "-h" => {
                println!(
                    "pairdesk-agent {}\n\nUSAGE: pairdesk-agent [--port {DEFAULT_PORT}] [--bind 0.0.0.0]",
                    env!("CARGO_PKG_VERSION")
                );
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument: {other} (try --help)")),
        }
    }
    Ok(cfg)
}

fn device_name() -> String {
    gethostname::gethostname().to_string_lossy().into_owned()
}

fn print_banner(port: u16) {
    println!(
        "PairDesk agent {} — Phase 0 (no pairing yet)",
        env!("CARGO_PKG_VERSION")
    );
    println!("Device name: {}", device_name());
    println!("In the PairDesk app, enter one of these addresses:");
    let mut any = false;
    if let Ok(ifaces) = local_ip_address::list_afinet_netifas() {
        for (iface, ip) in ifaces {
            if ip.is_ipv4() && !ip.is_loopback() {
                println!("    {ip}:{port}    ({iface})");
                any = true;
            }
        }
    }
    if !any {
        println!("    (no network address found — is Wi-Fi connected?)");
    }
    println!(
        "WARNING: anyone on this network can control this computer until pairing arrives in Phase 1."
    );
    println!("Press Ctrl+C to stop.");
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cfg = match parse_args() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };

    let input = match InputHandle::spawn() {
        Ok(h) => h,
        Err(e) => {
            error!("{e}");
            std::process::exit(1);
        }
    };

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    let listener = match TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            error!("cannot listen on {addr}: {e}");
            std::process::exit(1);
        }
    };
    print_banner(cfg.port);

    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    let input = input.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle(stream, peer, input).await {
                            warn!("{peer}: {e}");
                        }
                    });
                }
                Err(e) => warn!("accept failed: {e}"),
            },
            _ = tokio::signal::ctrl_c() => {
                info!("stopping");
                break;
            }
        }
    }
}

async fn handle(stream: TcpStream, peer: SocketAddr, input: InputHandle) -> Result<(), String> {
    let _ = stream.set_nodelay(true);
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let ws = tokio_tungstenite::accept_async_with_config(stream, Some(config))
        .await
        .map_err(|e| format!("handshake failed: {e}"))?;
    let (mut sink, mut source) = ws.split();
    info!("{peer}: connected");

    // Buttons this phone is holding, released if it disconnects mid-drag.
    let mut held: HashSet<MouseButton> = HashSet::new();

    let result = async {
        while let Some(frame) = source.next().await {
            let frame = frame.map_err(|e| e.to_string())?;
            let text = match frame {
                Message::Text(t) => t,
                Message::Close(_) => break,
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
                Message::Binary(_) => {
                    send(
                        &mut sink,
                        &ServerMsg::Error {
                            msg: "binary frames not supported".into(),
                        },
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
                        &ServerMsg::Error {
                            msg: format!("bad message: {e}"),
                        },
                    )
                    .await?;
                    continue;
                }
            };

            match msg {
                ClientMsg::Hello { name, v } => {
                    info!(
                        "{peer}: hello from {} (protocol v{})",
                        name.as_deref().unwrap_or("unknown phone"),
                        v.unwrap_or(0)
                    );
                    send(
                        &mut sink,
                        &ServerMsg::Hello {
                            name: device_name(),
                            os: std::env::consts::OS.into(),
                            v: PROTOCOL_VERSION,
                        },
                    )
                    .await?;
                }
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
            }
        }
        Ok::<(), String>(())
    }
    .await;

    for b in held {
        input.send(InputCmd::Up(b));
    }
    info!("{peer}: disconnected");
    result
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
