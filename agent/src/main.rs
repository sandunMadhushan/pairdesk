// SPDX-License-Identifier: GPL-3.0-or-later
//! PairDesk desktop agent.
//!
//! Runs in the background (tray icon), accepts encrypted connections only
//! from phones paired through the QR code on the settings page, and turns
//! their messages into mouse and keyboard input.

// Release builds on Windows run without a console window.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod apps;
mod audio;
mod auth;
mod autostart;
mod awake;
mod bridge;
mod clipboard;
mod config;
mod discovery;
mod files;
mod identity;
mod input;
mod install;
mod instance;
mod net;
mod pairing;
mod power;
mod prefs;
mod protocol;
mod relay;
mod screen;
mod server;
mod shell_menu;
mod state;
mod store;
mod tailscale;
mod tray;
mod update;
#[cfg(target_os = "linux")]
mod wayland;
mod web;
#[cfg(windows)]
mod webview2_loader;
#[cfg(windows)]
mod window;
mod winsys;

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
    /// `--send FILE…`: hand files to the running PairDesk for the phone.
    send: Vec<std::path::PathBuf>,
    /// `--quit`: stop the running PairDesk (used by the setup and uninstaller).
    quit: bool,
    /// Started by an update: like --background, and noted in the log.
    updated: bool,
    /// Windows helper modes (see `winsys`).
    mode: Mode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Normal,
    /// The phone server at the sign-in screen (SYSTEM, started by the helper).
    System,
    #[cfg_attr(not(windows), allow(dead_code))]
    InstallService,
    #[cfg_attr(not(windows), allow(dead_code))]
    UninstallService,
    #[cfg_attr(not(windows), allow(dead_code))]
    Service,
    #[cfg_attr(not(windows), allow(dead_code))]
    SessionHelper,
    /// Writes the Windows Firewall rules (elevated, from the settings page).
    #[cfg_attr(not(windows), allow(dead_code))]
    AllowFirewall,
}

fn usage() -> String {
    format!(
        "PairDesk agent {}\n\n\
         USAGE: pairdesk-agent [OPTIONS]\n\n\
         OPTIONS:\n  \
           --pair          print a pairing QR code in this terminal\n  \
           --background    start quietly (used when starting at sign-in)\n  \
           --no-tray       don't show a tray icon\n  \
           --send FILE...  send files to the connected phone (PairDesk must be running)\n  \
           --quit          stop the running PairDesk\n  \
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
        send: Vec::new(),
        quit: false,
        updated: false,
        mode: Mode::Normal,
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
            "--quit" => a.quit = true,
            #[cfg(windows)]
            "--allow-firewall" => a.mode = Mode::AllowFirewall,
            "--install-service" => a.mode = Mode::InstallService,
            #[cfg(windows)]
            "--uninstall-service" => a.mode = Mode::UninstallService,
            #[cfg(windows)]
            "--service" => a.mode = Mode::Service,
            #[cfg(windows)]
            "--session-helper" => a.mode = Mode::SessionHelper,
            #[cfg(windows)]
            "--system-mode" => {
                a.mode = Mode::System;
                a.background = true;
                a.no_tray = true;
            }
            "--updated" => {
                a.updated = true;
                a.background = true;
            }
            "--send" => {
                a.send.extend(it.by_ref().map(std::path::PathBuf::from));
                if a.send.is_empty() {
                    return Err("--send needs at least one file".into());
                }
            }
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
    // Appended to (starting PairDesk again mustn't wipe the running copy's
    // log), and started afresh once it gets big.
    let path = data_dir.join("agent.log");
    let big = std::fs::metadata(&path).is_ok_and(|m| m.len() > 2 * 1024 * 1024);
    if to_file
        && let Ok(f) = std::fs::OpenOptions::new()
            .create(true)
            .append(!big)
            .write(true)
            .truncate(big)
            .open(&path)
    {
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
    #[cfg(windows)]
    windows_modes(&args);
    let data_dir = match config::data_dir() {
        Ok(d) => d,
        Err(e) => fatal(&format!("cannot create the PairDesk data folder: {e}")),
    };
    if !args.send.is_empty() {
        send_files(&data_dir, &args.send);
    }
    if args.quit {
        quit_running(&data_dir);
    }
    init_logging(&data_dir);
    let install_kind = install::current();
    let system_mode = args.mode == Mode::System;
    #[cfg(windows)]
    if !system_mode {
        // The helper of this session (if the owner turned it on) handles the
        // secure desktop for us. Its address is read when needed, so turning
        // it on later works without a restart.
        let base = winsys::service::program_data();
        let session = winsys::session::current_session();
        winsys::set_bridge(bridge::Client::new(move || {
            winsys::read_endpoint(&winsys::endpoint_file(&base, session?))
        }));
        if winsys::helper_available() {
            info!("the PairDesk helper is on: sign-in screen and admin prompts work");
        }
    }
    if args.updated {
        info!("updated to {}", env!("CARGO_PKG_VERSION"));
    }

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
            let mut last: Option<Vec<String>> = None;
            loop {
                if let tailscale::Status::Running { ips, dns_name, .. } =
                    state.tailscale.refresh(std::time::Duration::from_secs(50))
                {
                    log::debug!("Tailscale: {ips:?} {dns_name:?}");
                }
                // A phone that connected over Wi-Fi keeps whatever addresses
                // it was told. Tell it again whenever they change, so turning
                // Tailscale on (or the relay coming up, or a new Wi-Fi
                // address) reaches phones that are already connected.
                let now = state.phone_addresses();
                if last.as_ref() != Some(&now) {
                    if last.is_some() {
                        let told = state.broadcast_addresses();
                        log::info!("addresses changed to {now:?}; told {told} phone(s)");
                    }
                    last = Some(now);
                }
                std::thread::sleep(std::time::Duration::from_secs(10));
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
        // Phones joined to this computer by a relay arrive here.
        let (relayed_tx, relayed) = tokio::sync::mpsc::channel(8);
        match relay::load_token(&data_dir) {
            Ok(token) => {
                runtime.spawn(relay::run(state.clone(), token, relayed_tx));
            }
            Err(e) => warn!("relay: can't keep this computer's relay id: {e}"),
        }
        // Helpers' access ends on time, or soon after they leave.
        {
            let state = state.clone();
            runtime.spawn(async move {
                let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
                loop {
                    tick.tick().await;
                    for name in state.sweep_helpers() {
                        info!("help from \"{name}\" ended");
                    }
                }
            });
        }
        let (state, input) = (state.clone(), input.clone());
        runtime.spawn(async move {
            if let Err(e) = server::run(listener, state, input, relayed).await {
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

    let updater = update::Updater::new(
        install_kind.clone(),
        update::Source::github(),
        data_dir.clone(),
    );
    update::set_global(updater.clone());
    if !system_mode {
        let state = state.clone();
        updater.run_checks(move || state.prefs().get().check_updates);
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
    if !system_mode {
        autostart::enable_on_first_run(&data_dir);
        // Point start-at-sign-in at this copy, in case it's a new download.
        autostart::refresh();
    }
    if system_mode {
        info!("serving phones at the sign-in screen");
    } else if install_kind.store_updates() {
        // Store and Flathub copies can't add to the file manager's menu
        // (their files live in a sandbox); the settings page's drop zone
        // sends files instead.
        info!("installed from a store ({})", install_kind.label());
    } else {
        shell_menu::install(&data_dir);
    }

    {
        // What a previous update left behind; the old copy may take a
        // moment to exit and free its file.
        let data_dir = data_dir.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(10));
            update::cleanup(&data_dir);
        });
    }

    print_banner(&state, &settings.url);
    tray::set_page(settings.url.clone(), !system_mode);
    #[cfg(windows)]
    window::set_data_dir(data_dir.clone());
    if args.pair {
        state.start_pairing();
        print_terminal_qr(&state);
    } else if !args.background && state.phones().list().is_empty() {
        // First run: go straight to pairing.
        tray::show(true);
    } else if !args.background {
        tray::show(false);
    }

    tray::run(&runtime, state.clone(), settings.url.clone(), args.no_tray);

    info!("shutting down");
    if let Some(a) = announcer {
        a.stop();
    }
    // Only our own address: after a takeover the file is the new copy's.
    let url_file = data_dir.join(SETTINGS_URL_FILE);
    if std::fs::read_to_string(&url_file).is_ok_and(|u| u.trim() == settings.url) {
        let _ = std::fs::remove_file(url_file);
    }
    runtime.shutdown_timeout(std::time::Duration::from_millis(500));
}

/// The port is taken. Replaces an older PairDesk; otherwise shows the
/// running one's settings page and exits.
fn take_over(args: &Args, data_dir: &Path) -> std::net::TcpListener {
    const OURS: &str = env!("CARGO_PKG_VERSION");
    let Some(running) = instance::find(&data_dir.join(SETTINGS_URL_FILE)) else {
        // Right after signing in, the sign-in screen's server (Windows
        // helper) may still hold the port for a moment.
        #[cfg(windows)]
        if args.mode == Mode::Normal && winsys::service::state() == winsys::service::State::Running
        {
            info!("waiting for the sign-in screen server to make way");
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
            while std::time::Instant::now() < deadline {
                std::thread::sleep(std::time::Duration::from_millis(500));
                if let Ok(l) = std::net::TcpListener::bind((args.bind.as_str(), args.port)) {
                    return l;
                }
            }
        }
        fatal(&format!(
            "port {} is used by another program; start PairDesk with --port <another port>",
            args.port
        ));
    };
    // An update hands over to its replacement even if the numbers say
    // otherwise (a re-release, or a manual downgrade).
    let older = running
        .version
        .as_deref()
        .filter(|v| args.updated || instance::is_older(v, OURS));
    let Some(old) = older else {
        if !args.background {
            info!("PairDesk is already running; showing it");
            // Older versions don't know how: their page in the browser.
            if let Err(e) = instance::ask_to_show(&running.url) {
                info!("({e}); opening its page in the browser");
                let _ = webbrowser::open(&running.url);
            }
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

/// Windows helper modes that don't run the normal agent, and the data
/// folder of the sign-in screen server.
#[cfg(windows)]
fn windows_modes(args: &Args) {
    let base = winsys::service::program_data();
    let log_to = |name: &str| {
        let _ = std::fs::create_dir_all(&base);
        if let Ok(f) = std::fs::File::create(base.join(name)) {
            let _ =
                env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
                    .target(env_logger::Target::Pipe(Box::new(f)))
                    .try_init();
        }
    };
    match args.mode {
        Mode::Normal => {}
        Mode::InstallService | Mode::UninstallService => {
            if args.mode == Mode::InstallService {
                log_to("service-setup.log");
            } else if let Ok(f) =
                std::fs::File::create(std::env::temp_dir().join("pairdesk-uninstall.log"))
            {
                // Not in ProgramData\PairDesk, which is being deleted.
                let _ = env_logger::Builder::from_env(
                    env_logger::Env::default().default_filter_or("info"),
                )
                .target(env_logger::Target::Pipe(Box::new(f)))
                .try_init();
            }
            let result = if args.mode == Mode::InstallService {
                winsys::service::install()
            } else {
                winsys::service::uninstall()
            };
            // No dialog: the settings page that asked shows the outcome.
            match result {
                Ok(()) => std::process::exit(0),
                Err(e) => {
                    error!("{e}");
                    eprintln!("PairDesk: {e}");
                    std::process::exit(1);
                }
            }
        }
        Mode::AllowFirewall => {
            #[cfg(windows)]
            {
                log_to("firewall.log");
                match winsys::firewall::allow(args.port) {
                    Ok(()) => std::process::exit(0),
                    Err(e) => {
                        error!("{e}");
                        eprintln!("PairDesk: {e}");
                        std::process::exit(1);
                    }
                }
            }
            #[cfg(not(windows))]
            {
                eprintln!("PairDesk: --allow-firewall is only for Windows.");
                std::process::exit(1);
            }
        }
        Mode::Service => {
            log_to("service.log");
            winsys::service::run();
        }
        Mode::SessionHelper => {
            let session = winsys::session::current_session().unwrap_or(0);
            log_to(&format!("helper-{session}.log"));
            winsys::helper::run(base);
        }
        Mode::System => {
            winsys::set_system_mode();
            let dir = winsys::system_data_dir(&base);
            // SAFETY: still single-threaded at this point.
            unsafe { std::env::set_var("PAIRDESK_HOME", &dir) };
        }
    }
}

/// `--quit`: asks the running PairDesk to stop and waits until it has.
/// Exits 0 when none is running (any more).
fn quit_running(data_dir: &Path) -> ! {
    let file = data_dir.join(SETTINGS_URL_FILE);
    let Some(running) = instance::find(&file) else {
        std::process::exit(0);
    };
    if running.version.is_none() {
        // A leftover address: nothing answers there.
        std::process::exit(0);
    }
    if let Err(e) = instance::ask_to_quit(&running.url) {
        eprintln!("PairDesk: could not ask PairDesk to stop: {e}");
        std::process::exit(1);
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while std::time::Instant::now() < deadline {
        if instance::find(&file).and_then(|r| r.version).is_none() {
            // Give the process a moment to exit and release its files.
            std::thread::sleep(std::time::Duration::from_millis(1500));
            std::process::exit(0);
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    eprintln!("PairDesk: it didn't stop within 20 seconds");
    std::process::exit(1);
}

/// `--send`: from the file manager's "Send to" menu. Errors are shown in a
/// message box, since there's no window otherwise.
fn send_files(data_dir: &Path, paths: &[std::path::PathBuf]) -> ! {
    let paths: Vec<_> = paths
        .iter()
        .map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| p.clone()))
        .collect();
    let result = std::fs::read_to_string(data_dir.join(SETTINGS_URL_FILE))
        .map_err(|_| {
            "PairDesk isn't running. Start PairDesk, open it on your phone, then try again."
                .to_string()
        })
        .and_then(|url| instance::send_paths(url.trim(), &paths));
    match result {
        Ok(_) => {
            println!("Sending {} file(s) to your phone.", paths.len());
            std::process::exit(0);
        }
        Err(e) => {
            eprintln!("PairDesk: {e}");
            tray::show_error(&e);
            std::process::exit(1);
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
