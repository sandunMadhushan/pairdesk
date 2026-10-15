// SPDX-License-Identifier: GPL-3.0-or-later
//! The settings page, served only to this computer on 127.0.0.1.
//!
//! The page shows the pairing QR code and the paired phones. Its address
//! contains a random secret, so other programs and websites can't use it:
//! - it listens on 127.0.0.1 only;
//! - every path must start with the secret;
//! - the `Host` header must be exactly 127.0.0.1:<port> (blocks DNS rebinding);
//! - changes need a custom header, which browsers won't send cross-site
//!   without a CORS preflight this server never approves.

use std::io::Read;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::json;
use tiny_http::{Header, Method, Request, Response, Server};

use crate::state::AppState;

const PAGE: &str = include_str!("settings.html");
/// Largest request body read, in bytes.
const MAX_BODY: u64 = 4096;

pub struct Settings {
    /// Full address of the page, including the secret.
    pub url: String,
}

/// Starts the settings server on a background thread.
pub fn start(
    state: Arc<AppState>,
    on_quit: Arc<dyn Fn() + Send + Sync>,
) -> Result<Settings, String> {
    let server = Server::http("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = server
        .server_addr()
        .to_ip()
        .ok_or("settings server has no address")?
        .port();
    let secret = crate::config::b64(&crate::config::random_bytes::<16>());
    let url = format!("http://127.0.0.1:{port}/{secret}/");
    let host = format!("127.0.0.1:{port}");

    std::thread::Builder::new()
        .name("settings-page".into())
        .spawn(move || {
            for request in server.incoming_requests() {
                handle(request, &state, &secret, &host, &on_quit);
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(Settings { url })
}

fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).expect("valid header")
}

fn respond<R: Read>(request: Request, mut response: Response<R>, content_type: &str) {
    for (k, v) in [
        ("Content-Type", content_type),
        ("Cache-Control", "no-store"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Frame-Options", "DENY"),
        ("X-Content-Type-Options", "nosniff"),
        (
            "Content-Security-Policy",
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; \
             img-src data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'",
        ),
    ] {
        response.add_header(header(k, v));
    }
    let _ = request.respond(response);
}

fn status(request: Request, code: u16, msg: &str) {
    respond(
        request,
        Response::from_string(msg).with_status_code(code),
        "text/plain; charset=utf-8",
    );
}

fn header_value<'a>(request: &'a Request, name: &str) -> Option<&'a str> {
    request
        .headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

fn handle(
    mut request: Request,
    state: &AppState,
    secret: &str,
    host: &str,
    on_quit: &Arc<dyn Fn() + Send + Sync>,
) {
    // Read the (small) body first, so even a refusal is a clean reply.
    let mut body = String::new();
    if request
        .as_reader()
        .take(MAX_BODY)
        .read_to_string(&mut body)
        .is_err()
    {
        return status(request, 400, "bad request");
    }
    if header_value(&request, "Host") != Some(host) {
        return status(request, 403, "forbidden");
    }
    let url = request.url().to_string();
    let path = url.split('?').next().unwrap_or("");
    let Some(rest) = path.strip_prefix('/').and_then(|p| p.strip_prefix(secret)) else {
        return status(request, 404, "not found");
    };

    let method = request.method().clone();
    if method == Method::Post {
        let origin_ok =
            header_value(&request, "Origin").is_none_or(|o| o == format!("http://{host}"));
        if header_value(&request, "X-PairDesk") != Some("1") || !origin_ok {
            return status(request, 403, "forbidden");
        }
    }

    match (method, rest) {
        (Method::Get, "/") => respond(
            request,
            Response::from_string(PAGE),
            "text/html; charset=utf-8",
        ),
        (Method::Get, "/api/state") => send_state(request, state),
        (Method::Post, "/api/pair") => {
            state.start_pairing();
            send_state(request, state)
        }
        (Method::Post, "/api/cancel-pair") => {
            state.cancel_pairing();
            send_state(request, state)
        }
        (Method::Post, "/api/remove") => {
            #[derive(Deserialize)]
            struct Body {
                id: String,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => match state.remove_phone(&b.id) {
                    Ok(_) => send_state(request, state),
                    Err(e) => status(request, 500, &format!("could not remove the phone: {e}")),
                },
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/autostart") => {
            #[derive(Deserialize)]
            struct Body {
                enabled: bool,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => match crate::autostart::set_enabled(b.enabled) {
                    Ok(()) => send_state(request, state),
                    Err(e) => status(
                        request,
                        500,
                        &format!("could not change start at sign-in: {e}"),
                    ),
                },
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/permissions") => {
            #[derive(Deserialize)]
            struct Body {
                power: bool,
                session: bool,
                apps: bool,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => {
                    let saved = state.prefs().set_permissions(b.power, b.session, b.apps);
                    match saved {
                        Ok(()) => send_state(request, state),
                        Err(e) => status(request, 500, &format!("could not save: {e}")),
                    }
                }
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/shortcuts/add") => {
            #[derive(Deserialize)]
            struct Body {
                name: String,
                kind: crate::prefs::ShortcutKind,
                target: String,
                #[serde(default)]
                args: String,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => {
                    let added = state
                        .prefs()
                        .add_shortcut(&b.name, b.kind, &b.target, &b.args);
                    match added {
                        Ok(()) => send_state(request, state),
                        Err(e) => status(request, 422, &e),
                    }
                }
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/shortcuts/remove") => {
            #[derive(Deserialize)]
            struct Body {
                id: String,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => {
                    let removed = state.prefs().remove_shortcut(&b.id);
                    match removed {
                        Ok(_) => send_state(request, state),
                        Err(e) => status(request, 500, &format!("could not save: {e}")),
                    }
                }
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/keep-awake") => {
            #[derive(Deserialize)]
            struct Body {
                enabled: bool,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => {
                    let result = state.awake.set(b.enabled).and_then(|()| {
                        state
                            .prefs()
                            .set_keep_awake(b.enabled)
                            .map_err(|e| e.to_string())
                    });
                    match result {
                        Ok(()) => send_state(request, state),
                        Err(e) => status(request, 500, &e),
                    }
                }
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/refresh-remote") => {
            state.tailscale.refresh(std::time::Duration::ZERO);
            send_state(request, state)
        }
        (Method::Post, "/api/quit") => {
            status(request, 200, "stopping");
            on_quit();
        }
        _ => status(request, 404, "not found"),
    }
}

fn send_state(request: Request, state: &AppState) {
    let prefs = state.prefs().get().clone();
    let shortcuts: Vec<_> = prefs
        .shortcuts
        .iter()
        .map(|s| json!({ "id": s.id, "name": s.name, "kind": s.kind, "target": s.target, "args": s.args }))
        .collect();
    let sessions = state.sessions();
    let phones: Vec<_> = state
        .phones()
        .list()
        .iter()
        .map(|p| {
            let connected = sessions.iter().find(|s| s.phone_id == p.id);
            json!({
                "id": p.id,
                "name": p.name,
                "paired_at": p.paired_at,
                "last_seen": p.last_seen,
                "connected": connected.is_some(),
                "address": connected.map(|s| s.address.clone()),
            })
        })
        .collect();

    let pairing = state.pairing_link().map(|(link, remaining)| {
        let svg = qrcode::QrCode::with_error_correction_level(&link, qrcode::EcLevel::M)
            .map(|code| {
                code.render::<qrcode::render::svg::Color>()
                    .min_dimensions(260, 260)
                    .quiet_zone(true)
                    .build()
            })
            .unwrap_or_default();
        json!({ "link": link, "svg": svg, "expires_in": remaining.as_secs() })
    });

    let addrs = crate::net::addresses();
    let addresses: Vec<String> = addrs
        .iter()
        .filter(|a| a.kind == crate::net::Kind::Lan)
        .map(|a| a.ip.to_string())
        .collect();
    let remote = match state.tailscale.peek() {
        None => json!({ "status": "checking" }),
        Some(crate::tailscale::Status::NotInstalled) => {
            // No command, but maybe an adapter (e.g. a portable install).
            let ips: Vec<String> = addrs
                .iter()
                .filter(|a| a.kind == crate::net::Kind::Tailscale)
                .map(|a| a.ip.to_string())
                .collect();
            if ips.is_empty() {
                json!({ "status": "not_installed" })
            } else {
                json!({ "status": "running", "ips": ips })
            }
        }
        Some(crate::tailscale::Status::NotConnected { reason }) => {
            json!({ "status": "not_connected", "reason": reason })
        }
        Some(crate::tailscale::Status::Running {
            ips,
            dns_name,
            tailnet,
        }) => json!({ "status": "running", "ips": ips, "dns_name": dns_name, "tailnet": tailnet }),
        Some(crate::tailscale::Status::Unknown { reason }) => {
            json!({ "status": "unknown", "reason": reason })
        }
    };
    let body = json!({
        "name": state.name,
        "version": env!("CARGO_PKG_VERSION"),
        "os": std::env::consts::OS,
        "fingerprint": state.identity.fingerprint_display(),
        "port": state.port,
        "addresses": addresses,
        "autostart": crate::autostart::is_enabled(),
        "pairing": pairing,
        "phones": phones,
        "permissions": {
            "power": prefs.allow_power,
            "session": prefs.allow_session,
            "apps": prefs.allow_apps,
        },
        "shortcuts": shortcuts,
        "remote": remote,
        "keep_awake": state.awake.is_on(),
    });
    respond(
        request,
        Response::from_string(body.to_string()),
        "application/json",
    );
}
