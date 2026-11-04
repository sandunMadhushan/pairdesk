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
/// Largest request body read, in bytes (file uploads are streamed instead).
const MAX_BODY: u64 = 64 * 1024;

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

/// Same checks as every change request: our Host, our secret, POST with
/// the PairDesk header and no foreign Origin.
fn is_our_post(request: &Request, secret: &str, host: &str, route: &str) -> bool {
    let url = request.url();
    let path = url.split('?').next().unwrap_or("");
    let origin_ok = header_value(request, "Origin").is_none_or(|o| o == format!("http://{host}"));
    *request.method() == Method::Post
        && header_value(request, "Host") == Some(host)
        && path.strip_prefix('/').and_then(|p| p.strip_prefix(secret)) == Some(route)
        && header_value(request, "X-PairDesk") == Some("1")
        && origin_ok
}

fn handle(
    mut request: Request,
    state: &Arc<AppState>,
    secret: &str,
    host: &str,
    on_quit: &Arc<dyn Fn() + Send + Sync>,
) {
    // A file for the phone: streamed to disk on its own thread, so the page
    // keeps answering meanwhile.
    if request
        .url()
        .split('?')
        .next()
        .unwrap_or("")
        .ends_with("/api/upload")
    {
        if !is_our_post(&request, secret, host, "/api/upload") {
            return status(request, 403, "forbidden");
        }
        let state = state.clone();
        let _ = std::thread::Builder::new()
            .name("upload".into())
            .spawn(move || upload(request, &state));
        return;
    }
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
            #[derive(Deserialize, Default)]
            struct Body {
                #[serde(default)]
                help: bool,
            }
            let b: Body = serde_json::from_str(&body).unwrap_or_default();
            if b.help {
                state.start_help();
            } else {
                state.start_pairing();
            }
            send_state(request, state)
        }
        (Method::Post, "/api/relay") => {
            #[derive(Deserialize)]
            struct Body {
                on: bool,
                address: String,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) if !b.on || valid_relay(&b.address) => {
                    let saved = state.prefs().set_relay(b.on, &b.address);
                    state.relay.settings_changed();
                    match saved {
                        Ok(()) => send_state(request, state),
                        Err(e) => status(request, 500, &format!("could not save: {e}")),
                    }
                }
                Some(_) => status(
                    request,
                    400,
                    "Enter the relay as host:port, e.g. relay.example.org:443.",
                ),
                None => status(request, 400, "bad request"),
            }
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
                #[serde(default)]
                screen: Option<bool>,
                #[serde(default)]
                clipboard: Option<bool>,
                #[serde(default)]
                files: Option<bool>,
                #[serde(default)]
                audio: Option<bool>,
                #[serde(default)]
                mic: Option<bool>,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => {
                    let mut prefs = state.prefs();
                    let mut saved = prefs.set_permissions(b.power, b.session, b.apps);
                    if let (Ok(()), Some(screen)) = (&saved, b.screen) {
                        saved = prefs.set_allow_screen(screen);
                    }
                    if let (Ok(()), Some(on)) = (&saved, b.clipboard) {
                        saved = prefs.set_allow_clipboard(on);
                    }
                    if let (Ok(()), Some(on)) = (&saved, b.files) {
                        saved = prefs.set_allow_files(on);
                    }
                    if let (Ok(()), Some(on)) = (&saved, b.audio) {
                        saved = prefs.set_allow_audio(on);
                    }
                    if let (Ok(()), Some(on)) = (&saved, b.mic) {
                        saved = prefs.set_allow_mic(on);
                    }
                    drop(prefs);
                    if b.screen == Some(false) {
                        state.stop_viewing(None);
                    }
                    const OFF: &str = "This was turned off in PairDesk settings on the computer.";
                    if b.audio == Some(false) {
                        state.stop_listening(None, false, OFF);
                    } else if b.mic == Some(false) {
                        state.stop_listening(None, true, OFF);
                    }
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
        (Method::Post, "/api/update-check") => {
            if let Some(u) = crate::update::global() {
                // The answer is in the state either way.
                let _ = u.check();
            }
            send_state(request, state)
        }
        (Method::Post, "/api/update-install") => {
            let Some(u) = crate::update::global() else {
                return status(request, 404, "not found");
            };
            match u.install(on_quit.clone()) {
                Ok(()) => send_state(request, state),
                Err(e) => status(request, 409, &e),
            }
        }
        (Method::Post, "/api/check-updates") => {
            #[derive(Deserialize)]
            struct Body {
                enabled: bool,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => match state.prefs().set_check_updates(b.enabled) {
                    Ok(()) => send_state(request, state),
                    Err(e) => status(request, 500, &format!("could not save: {e}")),
                },
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/secure-desktop") => {
            #[derive(Deserialize)]
            struct Body {
                enabled: bool,
            }
            match serde_json::from_str::<Body>(&body).ok() {
                Some(b) => {
                    crate::winsys::set_enabled(b.enabled);
                    send_state(request, state)
                }
                None => status(request, 400, "bad request"),
            }
        }
        (Method::Post, "/api/allow-firewall") => {
            #[cfg(windows)]
            crate::winsys::firewall::request();
            send_state(request, state)
        }
        (Method::Post, "/api/wayland-allow") => {
            #[cfg(target_os = "linux")]
            if let Some(remote) = crate::wayland::global() {
                remote.allow_now();
            }
            send_state(request, state)
        }
        (Method::Post, "/api/send-paths") => {
            #[derive(Deserialize)]
            struct Body {
                paths: Vec<String>,
                #[serde(default)]
                phone: Option<String>,
            }
            let Some(b) = serde_json::from_str::<Body>(&body).ok() else {
                return status(request, 400, "bad request");
            };
            if state.sessions().is_empty() {
                return status(
                    request,
                    409,
                    "No phone is connected. Open PairDesk on your phone first.",
                );
            }
            let mut sent = 0;
            let mut errors = Vec::new();
            for p in &b.paths {
                match crate::files::Outbound::from_path(std::path::Path::new(p)) {
                    Ok(f) => sent += state.send_file(b.phone.as_deref(), Arc::new(f)).min(1),
                    Err(e) => errors.push(e),
                }
            }
            if sent == 0 {
                return status(request, 400, &errors.join("; "));
            }
            respond(
                request,
                Response::from_string(json!({ "sent": sent, "errors": errors }).to_string()),
                "application/json",
            )
        }
        (Method::Post, "/api/reveal") => {
            #[derive(Deserialize)]
            struct Body {
                id: u64,
            }
            match serde_json::from_str::<Body>(&body)
                .ok()
                .and_then(|b| state.transfer_path(b.id))
            {
                Some(path) if path.exists() => {
                    reveal(&path);
                    send_state(request, state)
                }
                _ => status(request, 404, "That file isn't there any more."),
            }
        }
        (Method::Post, "/api/open-downloads") => {
            let dir = crate::files::downloads_dir();
            let _ = std::fs::create_dir_all(&dir);
            if let Err(e) = open::that_detached(&dir) {
                return status(request, 500, &format!("can't open {}: {e}", dir.display()));
            }
            send_state(request, state)
        }
        (Method::Post, "/api/stop-screen") => {
            #[derive(Deserialize)]
            struct Body {
                #[serde(default)]
                id: Option<String>,
            }
            let target = serde_json::from_str::<Body>(&body).ok().and_then(|b| b.id);
            state.stop_viewing(target.as_deref());
            send_state(request, state)
        }
        (Method::Post, "/api/stop-audio") => {
            #[derive(Deserialize)]
            struct Body {
                #[serde(default)]
                id: Option<String>,
            }
            let target = serde_json::from_str::<Body>(&body).ok().and_then(|b| b.id);
            state.stop_listening(
                target.as_deref(),
                false,
                "Listening was stopped on the computer.",
            );
            send_state(request, state)
        }
        (Method::Post, "/api/refresh-remote") => {
            state.tailscale.refresh(std::time::Duration::ZERO);
            send_state(request, state)
        }
        (Method::Post, "/api/show") => {
            // Started again: show the window of the PairDesk already running.
            crate::tray::show(false);
            status(request, 200, "shown");
        }
        (Method::Post, "/api/quit") => {
            status(request, 200, "stopping");
            on_quit();
        }
        _ => status(request, 404, "not found"),
    }
}

/// Linux Wayland: the remote desktop permission. `null` elsewhere.
fn wayland_state() -> serde_json::Value {
    #[cfg(target_os = "linux")]
    if let Some(remote) = crate::wayland::global() {
        let mut v = serde_json::to_value(remote.status()).unwrap_or_default();
        v["saved"] = json!(remote.is_remembered());
        return v;
    }
    serde_json::Value::Null
}

fn send_state(request: Request, state: &AppState) {
    let prefs = state.prefs().get().clone();
    let shortcuts: Vec<_> = prefs
        .shortcuts
        .iter()
        .map(|s| json!({ "id": s.id, "name": s.name, "kind": s.kind, "target": s.target, "args": s.args }))
        .collect();
    let sessions = state.sessions();
    let viewing = state.viewing_phones();
    let listening = state.listening_phones();
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
                "viewing": viewing.contains(&p.id),
                "helping_until": p.help_until,
                "listening": listening.iter().find(|l| l.0 == p.id).map(|l| json!({ "sound": l.1, "mic": l.2 })),
                "address": connected.map(|s| s.address.clone()),
            })
        })
        .collect();

    let pairing = state.pairing_links().map(|l| {
        let link = l.qr;
        let svg = qrcode::QrCode::with_error_correction_level(&link, qrcode::EcLevel::M)
            .map(|code| {
                code.render::<qrcode::render::svg::Color>()
                    .min_dimensions(260, 260)
                    .quiet_zone(true)
                    .build()
            })
            .unwrap_or_default();
        json!({
            "link": link,
            "share": l.share,
            "help": l.help,
            "relay": l.relay,
            "svg": svg,
            "expires_in": l.remaining.as_secs(),
        })
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
            "screen": prefs.allow_screen,
            "clipboard": prefs.allow_clipboard,
            "files": prefs.allow_files,
            "audio": prefs.allow_audio,
            "mic": prefs.allow_mic,
        },
        "shortcuts": shortcuts,
        "remote": remote,
        "relay": {
            "on": prefs.relay_on,
            "address": prefs.relay,
            "default": crate::relay::DEFAULT_RELAY,
            "state": state.relay.status(),
        },
        "keep_awake": state.awake.is_on(),
        "transfers": state.transfers(),
        "downloads": crate::files::downloads_dir().display().to_string(),
        "wayland": wayland_state(),
        "update": crate::update::global().map(|u| {
            let mut v = u.snapshot();
            v["auto"] = json!(prefs.check_updates);
            v
        }),
        "autostart_managed": crate::autostart::managed_by(),
        "secure_desktop": crate::winsys::settings_state(),
        "firewall": firewall_state(),
    });
    respond(
        request,
        Response::from_string(body.to_string()),
        "application/json",
    );
}

/// Whether phones can reach this computer through Windows Firewall on
/// every kind of network (Tailscale's adapter is usually a "public" one).
fn firewall_state() -> serde_json::Value {
    #[cfg(windows)]
    {
        crate::winsys::firewall::status()
    }
    #[cfg(not(windows))]
    {
        serde_json::Value::Null
    }
}

/// `%XX` decoding for query values (encodeURIComponent output).
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && i + 2 < b.len()
            && let Some(v) = std::str::from_utf8(&b[i + 1..i + 3])
                .ok()
                .and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(v);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query(url: &str, key: &str) -> Option<String> {
    url.split_once('?')?
        .1
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .find(|(k, _)| *k == key)
        .map(|(_, v)| percent_decode(v))
}

/// `POST api/upload?name=…&phone=…` with the file as the body: saved to a
/// temporary file, sent to the phone(s), deleted when they have it.
fn upload(mut request: Request, state: &Arc<AppState>) {
    let url = request.url().to_string();
    let Some(name) = query(&url, "name").filter(|n| !n.is_empty()) else {
        return status(request, 400, "missing file name");
    };
    let phone = query(&url, "phone").filter(|p| !p.is_empty());
    let connected = state
        .sessions()
        .iter()
        .any(|s| phone.as_deref().is_none_or(|p| p == s.phone_id));
    if !connected {
        return status(
            request,
            409,
            "No phone is connected. Open PairDesk on your phone first.",
        );
    }
    let dir = std::env::temp_dir().join("pairdesk-outgoing");
    let path = dir.join(crate::config::b64(&crate::config::random_bytes::<9>()));
    let saved = std::fs::create_dir_all(&dir)
        .and_then(|_| std::fs::File::create(&path))
        .and_then(|mut f| {
            std::io::copy(
                &mut request.as_reader().take(crate::files::MAX_SIZE),
                &mut f,
            )
        });
    let size = match saved {
        Ok(n) => n,
        Err(e) => {
            let _ = std::fs::remove_file(&path);
            return status(request, 500, &format!("can't read the file: {e}"));
        }
    };
    let file = Arc::new(crate::files::Outbound {
        path,
        name: crate::files::safe_name(&name),
        size,
        temporary: true,
    });
    let sent = state.send_file(phone.as_deref(), file);
    if sent == 0 {
        return status(request, 409, "The phone disconnected.");
    }
    respond(
        request,
        Response::from_string(json!({ "sent": sent }).to_string()),
        "application/json",
    )
}

/// Shows a file in the file manager, selected where that's possible.
fn reveal(path: &std::path::Path) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("explorer.exe")
            .raw_arg(format!("/select,\"{}\"", path.display()))
            .spawn();
    }
    #[cfg(not(windows))]
    {
        let uri = format!("file://{}", path.display());
        let shown = crate::install::host_command("dbus-send")
            .args([
                "--session",
                "--dest=org.freedesktop.FileManager1",
                "--type=method_call",
                "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1.ShowItems",
                &format!("array:string:{uri}"),
                "string:",
            ])
            .status()
            .is_ok_and(|s| s.success());
        if !shown && let Some(dir) = path.parent() {
            let _ = open::that_detached(dir);
        }
    }
}

/// `host:port`, with a sensible host.
fn valid_relay(address: &str) -> bool {
    let a = address.trim();
    let Some((host, port)) = a.rsplit_once(':') else {
        return false;
    };
    !host.is_empty()
        && host.len() < 254
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '[' | ']' | ':'))
        && port.parse::<u16>().is_ok_and(|p| p > 0)
}

#[cfg(test)]
mod tests {
    #[test]
    fn relay_addresses() {
        assert!(super::valid_relay("relay.example.org:443"));
        assert!(super::valid_relay(" 10.0.0.2:47900 "));
        assert!(!super::valid_relay("relay.example.org"));
        assert!(!super::valid_relay("bad host:443"));
        assert!(!super::valid_relay("host:0"));
    }

    use super::*;

    #[test]
    fn reads_query_values() {
        let url = "/s/api/upload?name=My%20photo%20%E0%B6%85.jpg&phone=abc";
        assert_eq!(query(url, "name").as_deref(), Some("My photo අ.jpg"));
        assert_eq!(query(url, "phone").as_deref(), Some("abc"));
        assert_eq!(query(url, "x"), None);
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%zz"), "%zz");
    }
}
