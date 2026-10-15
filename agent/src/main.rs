// SPDX-License-Identifier: GPL-3.0-or-later
//! PairDesk desktop agent.
//!
//! Runs in the background (tray icon), accepts encrypted connections only
//! from phones paired through the QR code on the settings page, and turns
//! their messages into mouse and keyboard input.

// Release builds on Windows run without a console window.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod apps;
mod auth;
mod autostart;
mod awake;
mod config;
mod discovery;
mod identity;
mod input;
mod instance;
mod net;
mod pairing;
mod power;
mod prefs;
mod protocol;
mod screen;
mod server;
mod state;
mod store;
mod tailscale;
mod tray;
#[cfg(target_os = "linux")]
mod wayland;
mod web;

use std::io::ErrorKind;
use std::path::Path;
use std::sync::Arc;

use log::{error, info, warn};

use state::AppState;

const DEFAULT_PORT: u16 = 47800;
const SETTINGS_URL_FILE: &str = "settings-url.txt";

struct Args {
    bind: String,
    port: u16,
    /// Started at sign-in: don't open the settings page.
    background: bool,
    /// Print a pairing QR code in the terminal.
    pair: bool,
    no_tray: bool,
}

fn usage() -> String {
    format!(
        "PairDesk agent {}\n\n\
         USAGE: pairdesk-agent [OPTIONS]\n\n\
         OPTIONS:\n  \
           --pair          print a pairing QR code in this terminal\n  \
           --background    start quietly (used when starting at sign-in)\n  \
           --no-tray       don't show a tray icon\n  \
           --port <PORT>   port for phones (default {DEFAULT_PORT})\n  \
           --bind <ADDR>   address to listen on (default 0.0.0.0)\n  \
           --version       print the version\n\n\
         Settings and data: {}",
        env!("CARGO_PKG_VERSION"),
        config::data_dir()
            .map(|d| d.display().to_string())
            .unwrap_or_else(|e| format!("unavailable ({e})"))
    )
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        bind: "0.0.0.0".into(),
        port: DEFAULT_PORT,
        background: false,
        pair: false,
        no_tray: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--port" | "-p" => {
                let v = it.next().ok_or("--port needs a value")?;
                a.port = v.parse().map_err(|_| format!("invalid port: {v}"))?;
            }
            "--bind" => a.bind = it.next().ok_or("--bind needs an address")?,
            "--background" => a.background = true,
            "--pair" => a.pair = true,
            "--no-tray" => a.no_tray = true,
            "--version" | "-V" => {
                println!("pairdesk-agent {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--help" | "-h" => {
                println!("{}", usage());
                std::process::exit(0);
            }
            other => return Err(format!("unknown option: {other} (try --help)")),
        }
    }
    Ok(a)
}

fn init_logging(data_dir: &Path) {
    let mut builder = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info,rustls=error"),
    );
    // Without a console (Windows release, or started at sign-in) log to a file.
    let to_file = cfg!(all(windows, not(debug_assertions)));
    if to_file && let Ok(f) = std::fs::File::create(data_dir.join("agent.log")) {
        builder.target(env_logger::Target::Pipe(Box::new(f)));
    }
    builder.init();
}

fn main() {
    tray::attach_console();
    // Real pixels everywhere (screen view, pointer position, monitor sizes).
    screen::capture::set_dpi_aware();
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let data_dir = match config::data_dir() {
        Ok(d) => d,
        Err(e) => fatal(&format!("cannot create the PairDesk data folder: {e}")),
    };
    init_logging(&data_dir);

    // Only one agent per computer. If the port is taken it's most likely
    // PairDesk already running: an older release gives way to this one,
    // otherwise its settings page is shown.
    let listener = match std::net::TcpListener::bind((args.bind.as_str(), args.port)) {
        Ok(l) => l,
        Err(e) if e.kind() == ErrorKind::AddrInUse => take_over(&args, &data_dir),
        Err(e) => fatal(&format!(
            "cannot listen on {}:{}: {e}",
            args.bind, args.port
        )),
    };

    let identity = match identity::Identity::load_or_create(&data_dir) {
        Ok(i) => i,
        Err(e) => fatal(&format!("cannot load this computer's identity: {e}")),
    };
    let phones = match store::PhoneStore::load(&data_dir) {
        Ok(p) => p,
        Err(e) => fatal(&format!("cannot load paired phones: {e}")),
    };
    let prefs = match prefs::PrefsStore::load(&data_dir) {
        Ok(p) => p,
        Err(e) => fatal(&format!("cannot load settings: {e}")),
    };
    let state = Arc::new(AppState::new(
        identity,
        phones,
        prefs,
        config::device_name(),
        args.port,
    ));

    // Scan installed apps now, so the phone's app list opens instantly.
    {
        let state = state.clone();
        std::thread::spawn(move || {
            state.apps.installed();
        });
    }
    // Check Tailscale now and then, so phones learn this computer's
    // Tailscale address without anyone waiting for the command.
    {
        let state = state.clone();
        std::thread::spawn(move || {
            loop {
                if let tailscale::Status::Running { ips, dns_name, .. } =
                    state.tailscale.refresh(std::time::Duration::from_secs(50))
                {
                    log::debug!("Tailscale: {ips:?} {dns_name:?}");
                }
                std::thread::sleep(std::time::Duration::from_secs(60));
            }
        });
    }
    let keep_awake = state.prefs().get().keep_awake;
    if keep_awake && let Err(e) = state.awake.set(true) {
        warn!("cannot keep this computer awake: {e}");
    }

    let runtime = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => fatal(&format!("cannot start: {e}")),
    };

    // Wayland: pointer, keyboard and screen go through the desktop's
    // remote desktop portal.
    #[cfg(target_os = "linux")]
    if wayland::is_wayland_session() {
        let remote = wayland::Remote::init(
            data_dir.clone(),
            runtime.handle().clone(),
            state.notices.clone(),
        );
        info!("Wayland session: using the remote desktop portal");
        // Started by the owner at the computer: ask now, not when the
        // phone first connects.
        if !args.background && !remote.is_remembered() {
            remote.start_in_background();
        }
    }

    let input = match input::InputHandle::spawn() {
        Ok(h) => h,
        Err(e) => fatal(&e),
    };
    {
        let _guard = runtime.enter();
        if let Err(e) = listener.set_nonblocking(true) {
            fatal(&format!("cannot listen: {e}"));
        }
        let listener = match tokio::net::TcpListener::from_std(listener) {
            Ok(l) => l,
            Err(e) => fatal(&format!("cannot listen: {e}")),
        };
        let (state, input) = (state.clone(), input.clone());
        runtime.spawn(async move {
            if let Err(e) = server::run(listener, state, input).await {
                error!("phone server stopped: {e}");
            }
        });
        runtime.spawn(async {
            if tokio::signal::ctrl_c().await.is_ok() {
                info!("stopping");
                tray::request_quit();
            }
        });
    }

    let settings = match web::start(state.clone(), Arc::new(tray::request_quit)) {
        Ok(s) => s,
        Err(e) => fatal(&format!("cannot start the settings page: {e}")),
    };
    if let Err(e) =
        config::write_private(&data_dir.join(SETTINGS_URL_FILE), settings.url.as_bytes())
    {
        warn!("could not save the settings address: {e}");
    }

    let announcer =
        match discovery::Announcer::start(&state.name, &state.identity.short_id(), args.port) {
            Ok(a) => Some(a),
            Err(e) => {
                warn!("network discovery is off ({e}); phones will use the last known address");
                None
            }
        };
    autostart::enable_on_first_run(&data_dir);
    // Point start-at-sign-in at this copy, in case it's a new download.
    autostart::refresh();

    print_banner(&state, &settings.url);
    if args.pair {
        state.start_pairing();
        print_terminal_qr(&state);
    } else if !args.background && state.phones().list().is_empty() {
        // First run: go straight to pairing.
        let _ = webbrowser::open(&format!("{}?pair=1", settings.url));
    } else if !args.background {
        let _ = webbrowser::open(&settings.url);
    }

    tray::run(&runtime, state.clone(), settings.url.clone(), args.no_tray);

    info!("shutting down");
    if let Some(a) = announcer {
        a.stop();
    }
    let _ = std::fs::remove_file(data_dir.join(SETTINGS_URL_FILE));
    runtime.shutdown_timeout(std::time::Duration::from_millis(500));
}

/// The port is taken. Replaces an older PairDesk; otherwise shows the
/// running one's settings page and exits.
fn take_over(args: &Args, data_dir: &Path) -> std::net::TcpListener {
    const OURS: &str = env!("CARGO_PKG_VERSION");
    let Some(running) = instance::find(&data_dir.join(SETTINGS_URL_FILE)) else {
        fatal(&format!(
            "port {} is used by another program; start PairDesk with --port <another port>",
            args.port
        ));
    };
    let older = running
        .version
        .as_deref()
        .filter(|v| instance::is_older(v, OURS));
    let Some(old) = older else {
        if !args.background {
            info!("PairDesk is already running; opening its settings");
            let _ = webbrowser::open(&running.url);
        }
        std::process::exit(0);
    };

    info!("PairDesk {old} is running; replacing it with {OURS}");
    if let Err(e) = instance::ask_to_quit(&running.url) {
        warn!("could not ask PairDesk {old} to stop: {e}");
    }
    // It closes within a second or so; give it plenty of time.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        match std::net::TcpListener::bind((args.bind.as_str(), args.port)) {
            Ok(l) => {
                info!("took over from PairDesk {old}");
                return l;
            }
            Err(e) if e.kind() == ErrorKind::AddrInUse && std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
            Err(_) => fatal(&format!(
                "an older PairDesk ({old}) is still running. Stop it from its tray icon \
                 (Stop PairDesk), then open PairDesk {OURS} again."
            )),
        }
    }
}

fn fatal(msg: &str) -> ! {
    error!("{msg}");
    eprintln!("PairDesk: {msg}");
    tray::show_error(msg);
    std::process::exit(1);
}

fn print_banner(state: &AppState, settings_url: &str) {
    println!(
        "PairDesk agent {} on \"{}\"",
        env!("CARGO_PKG_VERSION"),
        state.name
    );
    println!("Paired phones: {}", state.phones().list().len());
    let addrs = net::addresses();
    if addrs.is_empty() {
        println!("No network address found. Is Wi-Fi connected?");
    } else {
        let list: Vec<String> = addrs
            .iter()
            .map(|a| match a.kind {
                net::Kind::Lan => format!("{}:{}", a.ip, state.port),
                net::Kind::Tailscale => format!("{}:{} (Tailscale)", a.ip, state.port),
            })
            .collect();
        println!("Listening on {}", list.join(", "));
    }
    println!("Settings: {settings_url}");
    println!("Press Ctrl+C to stop.");
}

fn print_terminal_qr(state: &AppState) {
    let Some((link, remaining)) = state.pairing_link() else {
        return;
    };
    match qrcode::QrCode::with_error_correction_level(&link, qrcode::EcLevel::L) {
        Ok(code) => {
            let text = code
                .render::<qrcode::render::unicode::Dense1x2>()
                .dark_color(qrcode::render::unicode::Dense1x2::Light)
                .light_color(qrcode::render::unicode::Dense1x2::Dark)
                .quiet_zone(true)
                .build();
            println!(
                "\nIn PairDesk on your phone, tap Scan pairing code and scan this:\n\n{text}\n"
            );
        }
        Err(e) => warn!("cannot draw QR code: {e}"),
    }
    println!(
        "The code works once and expires in {} minutes.\nLink: {link}\n",
        remaining.as_secs().div_ceil(60)
    );
}
