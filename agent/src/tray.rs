// SPDX-License-Identifier: GPL-3.0-or-later
//! Tray icon and the main thread's wait-for-quit loop.
//!
//! Windows: a native notification-area icon (needs a Win32 message loop on
//! the main thread). Mac: a menu-bar icon and the PairDesk window, in the
//! AppKit event loop on the main thread. Linux: a StatusNotifierItem over
//! D-Bus, shown by KDE,
//! most other desktops and GNOME with the AppIndicator extension. Where no
//! tray is available the agent keeps running and the settings page is
//! still reachable by starting PairDesk again.

use std::sync::Arc;

use crate::state::AppState;

/// 32×32 RGBA tray icon: a lime phone outline on an ink rounded square (the
/// app's colours), with a red dot while a phone is viewing the screen.
fn icon_rgba(viewing: bool) -> (Vec<u8>, u32) {
    const N: i32 = 32;
    let mut px = vec![0u8; (N * N * 4) as usize];
    let inside_rounded = |x: i32, y: i32, x0: i32, y0: i32, x1: i32, y1: i32, r: i32| {
        if x < x0 || x > x1 || y < y0 || y > y1 {
            return false;
        }
        let cx = x.clamp(x0 + r, x1 - r);
        let cy = y.clamp(y0 + r, y1 - r);
        (x - cx).pow(2) + (y - cy).pow(2) <= r * r
    };
    for y in 0..N {
        for x in 0..N {
            let i = ((y * N + x) * 4) as usize;
            let bg = inside_rounded(x, y, 0, 0, N - 1, N - 1, 7);
            let outer = inside_rounded(x, y, 10, 5, 21, 26, 3);
            let inner = inside_rounded(x, y, 13, 8, 18, 21, 1);
            let dot = (x - 15).pow(2) * 4 + (y - 23).pow(2) * 4 <= 5;
            let lime = (outer && !inner) || dot;
            let red_ring = viewing && (x - 25).pow(2) + (y - 6).pow(2) <= 49;
            let red = viewing && (x - 25).pow(2) + (y - 6).pow(2) <= 30;
            let (r, g, b, a) = if red {
                (0xe5, 0x2b, 0x2b, 255)
            } else if red_ring {
                (255, 255, 255, 255)
            } else if lime {
                (0xd2, 0xf3, 0x4c, 255)
            } else if bg {
                (0x11, 0x11, 0x11, 255)
            } else {
                (0, 0, 0, 0)
            };
            px[i..i + 4].copy_from_slice(&[r, g, b, a]);
        }
    }
    (px, N as u32)
}

#[cfg(windows)]
fn tooltip(state: &AppState) -> String {
    let screen = !state.viewing_phones().is_empty();
    let mic = state.listening_phones().iter().any(|l| l.2);
    match (screen, mic) {
        (true, true) => format!(
            "PairDesk – {} – your screen and microphone are in use",
            state.name
        ),
        (true, false) => format!("PairDesk – {} – your screen is being viewed", state.name),
        (false, true) => format!("PairDesk – {} – your microphone is being heard", state.name),
        (false, false) => format!("PairDesk – {}", state.name),
    }
}

fn open(url: &str) {
    #[cfg(target_os = "linux")]
    if open_app_window(url) {
        return;
    }
    if let Err(e) = webbrowser::open(url) {
        log::warn!("cannot open the browser: {e}");
    }
}

/// Linux: the page in a window of its own, without tabs or an address bar,
/// when a Chromium-based browser is installed (its "app" mode). Otherwise
/// the default browser.
#[cfg(target_os = "linux")]
fn open_app_window(url: &str) -> bool {
    // Flatpak can't start them; and someone who set $BROWSER chose theirs.
    if std::env::var_os("FLATPAK_ID").is_some() || std::env::var_os("BROWSER").is_some() {
        return false;
    }
    const BROWSERS: [&str; 7] = [
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
        "microsoft-edge",
        "microsoft-edge-stable",
        "brave-browser",
    ];
    BROWSERS.iter().any(|b| {
        std::process::Command::new(b)
            .arg(format!("--app={url}"))
            .arg("--window-size=1040,740")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map(|mut child| {
                // Reaped when the launcher exits (usually at once).
                std::thread::spawn(move || child.wait());
            })
            .is_ok()
    })
}

/// The settings page's address, and whether this PairDesk may show it
/// (not the sign-in screen server, which runs as SYSTEM).
static PAGE: std::sync::OnceLock<(String, bool)> = std::sync::OnceLock::new();

/// Set once at start-up, before anything is shown.
pub fn set_page(url: String, allowed: bool) {
    let _ = PAGE.set((url, allowed));
}

fn page_url(pair: bool) -> Option<String> {
    let (url, allowed) = PAGE.get()?;
    if !allowed {
        return None;
    }
    Some(if pair {
        format!("{url}?pair=1")
    } else {
        url.clone()
    })
}

/// Shows PairDesk (`pair`: on the pairing code). From any thread.
/// Windows: the PairDesk window (the browser without WebView2). Linux:
/// an app window of a Chromium-based browser, or the browser.
pub fn show(pair: bool) {
    platform::show(pair);
}

// ----------------------------------------------------------------- Windows

#[cfg(windows)]
mod platform {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    use windows_sys::Win32::System::Console::{ATTACH_PARENT_PROCESS, AttachConsole};
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        DispatchMessageW, GetMessageW, MB_ICONERROR, MB_OK, MSG, MessageBoxW, PM_NOREMOVE,
        PeekMessageW, PostQuitMessage, PostThreadMessageW, TranslateMessage, WM_APP, WM_QUIT,
        WM_USER,
    };

    static MAIN_THREAD: AtomicU32 = AtomicU32::new(0);

    /// Called first thing in `main`: lets `--help` print to the terminal
    /// it was started from, and prepares the main thread's message queue
    /// so a quit request can always reach it.
    pub fn attach_console() {
        unsafe {
            AttachConsole(ATTACH_PARENT_PROCESS);
            let mut msg: MSG = std::mem::zeroed();
            PeekMessageW(
                &mut msg,
                std::ptr::null_mut(),
                WM_USER,
                WM_USER,
                PM_NOREMOVE,
            );
            MAIN_THREAD.store(GetCurrentThreadId(), Ordering::SeqCst);
        }
    }

    pub fn request_quit() {
        let tid = MAIN_THREAD.load(Ordering::SeqCst);
        if tid == 0 || unsafe { PostThreadMessageW(tid, WM_QUIT, 0, 0) } == 0 {
            std::process::exit(0);
        }
    }

    pub fn show_error(msg: &str) {
        let text: Vec<u16> = msg.encode_utf16().chain(Some(0)).collect();
        let title: Vec<u16> = "PairDesk".encode_utf16().chain(Some(0)).collect();
        unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                text.as_ptr(),
                title.as_ptr(),
                MB_OK | MB_ICONERROR,
            );
        }
    }

    /// Posted to the main thread when screen viewers change.
    const WM_VIEWERS: u32 = WM_APP + 1;
    /// Posted to the main thread to show the window (wparam 1: pairing).
    const WM_SHOW: u32 = WM_APP + 2;

    pub fn show(pair: bool) {
        let tid = MAIN_THREAD.load(Ordering::SeqCst);
        let posted = tid != 0 && unsafe { PostThreadMessageW(tid, WM_SHOW, pair as usize, 0) } != 0;
        if !posted && let Some(url) = page_url(pair) {
            open(&url);
        }
    }

    /// On the main thread: the window, or the browser if it can't be shown.
    fn show_here(pair: bool) {
        let Some(url) = page_url(pair) else { return };
        let home = page_url(false).unwrap_or_default();
        if !crate::window::show(&url, &home) {
            open(&url);
        }
    }

    pub fn run(rt: &tokio::runtime::Runtime, state: Arc<AppState>, url: String, no_tray: bool) {
        {
            let mut rx = state.subscribe_viewers();
            let tid = MAIN_THREAD.load(Ordering::SeqCst);
            rt.spawn(async move {
                while rx.changed().await.is_ok() {
                    unsafe { PostThreadMessageW(tid, WM_VIEWERS, 0, 0) };
                }
            });
        }
        let open_item = MenuItem::new("Open PairDesk", true, None);
        let pair_item = MenuItem::new("Pair a phone…", true, None);
        let browser_item = MenuItem::new("Open in the browser", true, None);
        let quit_item = MenuItem::new("Stop PairDesk", true, None);
        let tray = if no_tray {
            None
        } else {
            let menu = Menu::new();
            let built = menu
                .append_items(&[
                    &open_item,
                    &pair_item,
                    &browser_item,
                    &PredefinedMenuItem::separator(),
                    &quit_item,
                ])
                .map_err(|e| e.to_string())
                .and_then(|_| {
                    let (rgba, n) = icon_rgba(false);
                    let icon = Icon::from_rgba(rgba, n, n).map_err(|e| e.to_string())?;
                    TrayIconBuilder::new()
                        .with_menu(Box::new(menu))
                        .with_menu_on_left_click(false)
                        .with_tooltip(format!("PairDesk – {}", state.name))
                        .with_icon(icon)
                        .build()
                        .map_err(|e| e.to_string())
                });
            match built {
                Ok(t) => Some(t),
                Err(e) => {
                    log::warn!("no tray icon: {e}");
                    None
                }
            }
        };

        unsafe {
            let mut msg: MSG = std::mem::zeroed();
            loop {
                let r = GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0);
                if r == 0 || r == -1 {
                    break;
                }
                if msg.message == WM_VIEWERS {
                    if let Some(t) = &tray {
                        let viewing = state.watched();
                        let (rgba, n) = icon_rgba(viewing);
                        if let Ok(icon) = Icon::from_rgba(rgba, n, n) {
                            let _ = t.set_icon(Some(icon));
                        }
                        let _ = t.set_tooltip(Some(tooltip(&state)));
                    }
                    continue;
                }
                if msg.message == WM_SHOW && msg.hwnd.is_null() {
                    show_here(msg.wParam == 1);
                    continue;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);

                while let Ok(ev) = MenuEvent::receiver().try_recv() {
                    if ev.id == open_item.id() {
                        show_here(false);
                    } else if ev.id == pair_item.id() {
                        show_here(true);
                    } else if ev.id == browser_item.id() {
                        open(&url);
                    } else if ev.id == quit_item.id() {
                        PostQuitMessage(0);
                    }
                }
                while let Ok(ev) = TrayIconEvent::receiver().try_recv() {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = ev
                    {
                        show_here(false);
                    }
                }
            }
        }
        crate::window::close();
        drop(tray);
    }
}

// ------------------------------------------------------------------- Linux

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use std::sync::{Condvar, Mutex};

    static QUIT: (Mutex<bool>, Condvar) = (Mutex::new(false), Condvar::new());

    pub fn attach_console() {}

    pub fn show(pair: bool) {
        if let Some(url) = page_url(pair) {
            open(&url);
        }
    }

    pub fn request_quit() {
        *QUIT.0.lock().unwrap_or_else(|p| p.into_inner()) = true;
        QUIT.1.notify_all();
    }

    pub fn show_error(_msg: &str) {}

    struct Tray {
        url: String,
        name: String,
        viewing: bool,
    }

    impl ksni::Tray for Tray {
        fn id(&self) -> String {
            "pairdesk".into()
        }
        fn title(&self) -> String {
            if self.viewing {
                format!(
                    "PairDesk – {} – your screen or microphone is in use",
                    self.name
                )
            } else {
                format!("PairDesk – {}", self.name)
            }
        }
        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            let (mut data, n) = icon_rgba(self.viewing);
            for p in data.as_chunks_mut::<4>().0 {
                p.rotate_right(1); // RGBA → ARGB
            }
            vec![ksni::Icon {
                width: n as i32,
                height: n as i32,
                data,
            }]
        }
        fn activate(&mut self, _x: i32, _y: i32) {
            open(&self.url);
        }
        fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
            use ksni::menu::StandardItem;
            vec![
                StandardItem {
                    label: "Open PairDesk".into(),
                    activate: Box::new(|t: &mut Self| open(&t.url)),
                    ..Default::default()
                }
                .into(),
                StandardItem {
                    label: "Pair a phone…".into(),
                    activate: Box::new(|t: &mut Self| open(&format!("{}?pair=1", t.url))),
                    ..Default::default()
                }
                .into(),
                ksni::MenuItem::Separator,
                StandardItem {
                    label: "Stop PairDesk".into(),
                    activate: Box::new(|_| request_quit()),
                    ..Default::default()
                }
                .into(),
            ]
        }
    }

    pub fn run(rt: &tokio::runtime::Runtime, state: Arc<AppState>, url: String, no_tray: bool) {
        if !no_tray {
            use ksni::TrayMethods;
            let tray = Tray {
                url,
                name: state.name.clone(),
                viewing: false,
            };
            let state = state.clone();
            rt.spawn(async move {
                // In the Flatpak sandbox the tray can't own a well-known
                // D-Bus name; it registers by its connection instead.
                let sandboxed = std::env::var_os("FLATPAK_ID").is_some();
                match tray.disable_dbus_name(sandboxed).spawn().await {
                    Ok(handle) => {
                        // Lives until the agent stops; shows screen viewers.
                        let mut rx = state.subscribe_viewers();
                        while rx.changed().await.is_ok() {
                            let viewing = state.watched();
                            handle.update(|t| t.viewing = viewing).await;
                        }
                        std::future::pending::<()>().await;
                    }
                    Err(e) => {
                        log::warn!("no tray icon ({e}); run pairdesk-agent again to open settings")
                    }
                }
            });
        }
        let mut quit = QUIT.0.lock().unwrap_or_else(|p| p.into_inner());
        while !*quit {
            quit = QUIT.1.wait(quit).unwrap_or_else(|p| p.into_inner());
        }
    }
}

// --------------------------------------------------------------------- Mac

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::sync::{Condvar, Mutex};
    use tao::dpi::LogicalSize;
    use tao::event::{Event, StartCause, WindowEvent};
    use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy, EventLoopWindowTarget};
    use tao::platform::macos::{
        ActivationPolicy, EventLoopExtMacOS, EventLoopWindowTargetExtMacOS,
    };
    use tao::platform::run_return::EventLoopExtRunReturn;
    use tao::window::{Window, WindowBuilder};
    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
    use tray_icon::{Icon, TrayIcon, TrayIconBuilder};
    use wry::{WebView, WebViewBuilder};

    enum UserEvent {
        Show(bool),
        Quit,
        Viewers,
        Menu(MenuEvent),
    }

    static PROXY: Mutex<Option<EventLoopProxy<UserEvent>>> = Mutex::new(None);
    /// A "show" asked for before the event loop runs.
    static PENDING: Mutex<Option<bool>> = Mutex::new(None);
    /// Without a menu-bar icon (`--no-tray`) there is no event loop.
    static QUIT: (Mutex<bool>, Condvar) = (Mutex::new(false), Condvar::new());

    fn send(event: UserEvent) -> bool {
        PROXY
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .as_ref()
            .is_some_and(|p| p.send_event(event).is_ok())
    }

    pub fn attach_console() {}

    pub fn request_quit() {
        send(UserEvent::Quit);
        *QUIT.0.lock().unwrap_or_else(|p| p.into_inner()) = true;
        QUIT.1.notify_all();
    }

    pub fn show(pair: bool) {
        if !send(UserEvent::Show(pair)) {
            *PENDING.lock().unwrap_or_else(|p| p.into_inner()) = Some(pair);
        }
    }

    pub fn show_error(msg: &str) {
        let quoted = format!("\"{}\"", msg.replace('\\', "\\\\").replace('"', "\\\""));
        let _ = std::process::Command::new("/usr/bin/osascript")
            .arg("-e")
            .arg(format!(
                "display alert \"PairDesk\" message {quoted} as critical"
            ))
            .status();
    }

    /// Menu-bar icons are "templates": black shapes macOS tints to fit the
    /// menu bar. While a phone watches, the full-colour icon stands out.
    fn menu_bar_icon(viewing: bool) -> Option<Icon> {
        let (mut rgba, n) = icon_rgba(viewing);
        if !viewing {
            for p in rgba.as_chunks_mut::<4>().0 {
                let lime = p[0] == 0xd2 && p[1] == 0xf3;
                *p = if lime { [0, 0, 0, 255] } else { [0, 0, 0, 0] };
            }
        }
        Icon::from_rgba(rgba, n, n).ok()
    }

    struct Shown {
        window: Window,
        view: WebView,
    }

    /// Shows the PairDesk window (`pair`: on the pairing code).
    fn show_here(target: &EventLoopWindowTarget<UserEvent>, shown: &mut Option<Shown>, pair: bool) {
        let Some(url) = page_url(pair) else { return };
        target.set_activation_policy_at_runtime(ActivationPolicy::Regular);
        if let Some(s) = shown {
            if pair {
                let _ = s.view.load_url(&url);
            }
            s.window.set_visible(true);
            s.window.set_focus();
            return;
        }
        let home = page_url(false).unwrap_or_default();
        let home_for_popups = home.clone();
        let window = match WindowBuilder::new()
            .with_title("PairDesk")
            .with_inner_size(LogicalSize::new(1040.0, 740.0))
            .with_min_inner_size(LogicalSize::new(760.0, 560.0))
            .build(target)
        {
            Ok(w) => w,
            Err(e) => {
                log::warn!("window: {e}; opening the browser");
                open(&url);
                return;
            }
        };
        let built = WebViewBuilder::new()
            .with_url(&url)
            .with_navigation_handler(move |to| {
                if to.starts_with(&home) || to == "about:blank" {
                    return true;
                }
                open(&to);
                false
            })
            .with_new_window_req_handler(move |to, _| {
                if !to.starts_with(&home_for_popups) {
                    open(&to);
                }
                wry::NewWindowResponse::Deny
            })
            .build(&window);
        match built {
            Ok(view) => {
                window.set_focus();
                *shown = Some(Shown { window, view });
                log::info!("window: page loaded");
            }
            Err(e) => {
                log::warn!("window: {e}; opening the browser");
                open(&url);
            }
        }
    }

    /// The Mac's menu bar while the window is open: Edit makes Cmd+C, V, X,
    /// A and Z work in the page's text boxes.
    fn app_menu(stop: &MenuItem) -> Option<Menu> {
        let app = Submenu::with_items(
            "PairDesk",
            true,
            &[
                &PredefinedMenuItem::hide(None),
                &PredefinedMenuItem::hide_others(None),
                &PredefinedMenuItem::separator(),
                &PredefinedMenuItem::close_window(None),
                &PredefinedMenuItem::separator(),
                stop,
            ],
        )
        .ok()?;
        let edit = Submenu::with_items(
            "Edit",
            true,
            &[
                &PredefinedMenuItem::undo(None),
                &PredefinedMenuItem::redo(None),
                &PredefinedMenuItem::separator(),
                &PredefinedMenuItem::cut(None),
                &PredefinedMenuItem::copy(None),
                &PredefinedMenuItem::paste(None),
                &PredefinedMenuItem::select_all(None),
            ],
        )
        .ok()?;
        let menu = Menu::new();
        menu.append_items(&[&app, &edit]).ok()?;
        Some(menu)
    }

    pub fn run(rt: &tokio::runtime::Runtime, state: Arc<AppState>, url: String, no_tray: bool) {
        if no_tray {
            if let Some(pair) = PENDING.lock().unwrap_or_else(|p| p.into_inner()).take()
                && let Some(u) = page_url(pair)
            {
                open(&u);
            }
            let mut quit = QUIT.0.lock().unwrap_or_else(|p| p.into_inner());
            while !*quit {
                quit = QUIT.1.wait(quit).unwrap_or_else(|p| p.into_inner());
            }
            return;
        }

        let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
        // A menu-bar app: no Dock icon until the window opens.
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
        *PROXY.lock().unwrap_or_else(|p| p.into_inner()) = Some(event_loop.create_proxy());
        MenuEvent::set_event_handler(Some(|e| {
            send(UserEvent::Menu(e));
        }));
        {
            let mut rx = state.subscribe_viewers();
            rt.spawn(async move {
                while rx.changed().await.is_ok() {
                    send(UserEvent::Viewers);
                }
            });
        }

        let open_item = MenuItem::new("Open PairDesk", true, None);
        let pair_item = MenuItem::new("Pair a phone…", true, None);
        let browser_item = MenuItem::new("Open in the browser", true, None);
        let quit_item = MenuItem::new("Stop PairDesk", true, None);
        let stop_item = MenuItem::new("Stop PairDesk", true, None);
        let mut tray: Option<TrayIcon> = None;
        let mut menu_bar: Option<Menu> = None;
        let mut shown: Option<Shown> = None;

        event_loop.run_return(|event, target, control_flow| {
            *control_flow = ControlFlow::Wait;
            match event {
                Event::NewEvents(StartCause::Init) => {
                    menu_bar = app_menu(&stop_item);
                    if let Some(m) = &menu_bar {
                        m.init_for_nsapp();
                    }
                    let menu = Menu::new();
                    let built = menu
                        .append_items(&[
                            &open_item,
                            &pair_item,
                            &browser_item,
                            &PredefinedMenuItem::separator(),
                            &quit_item,
                        ])
                        .map_err(|e| e.to_string())
                        .and_then(|_| {
                            let mut b = TrayIconBuilder::new()
                                .with_menu(Box::new(menu))
                                .with_tooltip(format!("PairDesk – {}", state.name))
                                .with_icon_as_template(true);
                            if let Some(icon) = menu_bar_icon(false) {
                                b = b.with_icon(icon);
                            }
                            b.build().map_err(|e| e.to_string())
                        });
                    match built {
                        Ok(t) => tray = Some(t),
                        Err(e) => log::warn!("no menu-bar icon: {e}"),
                    }
                    if let Some(pair) = PENDING.lock().unwrap_or_else(|p| p.into_inner()).take() {
                        show_here(target, &mut shown, pair);
                    }
                }
                Event::UserEvent(UserEvent::Show(pair)) => show_here(target, &mut shown, pair),
                Event::UserEvent(UserEvent::Viewers) => {
                    if let Some(t) = &tray {
                        let viewing = state.watched();
                        let _ = t.set_icon_with_as_template(menu_bar_icon(viewing), !viewing);
                    }
                }
                Event::UserEvent(UserEvent::Menu(ev)) => {
                    if ev.id == open_item.id() {
                        show_here(target, &mut shown, false);
                    } else if ev.id == pair_item.id() {
                        show_here(target, &mut shown, true);
                    } else if ev.id == browser_item.id() {
                        open(&url);
                    } else if ev.id == quit_item.id() || ev.id == stop_item.id() {
                        *control_flow = ControlFlow::Exit;
                    }
                }
                Event::UserEvent(UserEvent::Quit) => *control_flow = ControlFlow::Exit,
                Event::WindowEvent {
                    event: WindowEvent::CloseRequested,
                    ..
                } => {
                    // Closing the window keeps PairDesk running in the menu bar.
                    shown = None;
                    target.set_activation_policy_at_runtime(ActivationPolicy::Accessory);
                }
                _ => {}
            }
        });
        *PROXY.lock().unwrap_or_else(|p| p.into_inner()) = None;
        drop(shown);
        drop(tray);
        drop(menu_bar);
    }
}

pub use platform::{attach_console, request_quit, run, show_error};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icon_shows_a_red_dot_only_while_viewed() {
        let px = |img: &[u8], x: usize, y: usize| -> [u8; 4] {
            img[(y * 32 + x) * 4..][..4].try_into().unwrap()
        };
        let (idle, n) = icon_rgba(false);
        let (viewed, _) = icon_rgba(true);
        assert_eq!(n, 32);
        assert_eq!(px(&viewed, 25, 6), [0xe5, 0x2b, 0x2b, 255], "red dot");
        assert_ne!(px(&idle, 25, 6), [0xe5, 0x2b, 0x2b, 255]);
        assert_eq!(px(&idle, 15, 15), px(&viewed, 15, 15), "same phone outline");
    }
}
