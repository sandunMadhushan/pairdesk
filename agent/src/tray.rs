// SPDX-License-Identifier: GPL-3.0-or-later
//! Tray icon and the main thread's wait-for-quit loop.
//!
//! Windows: a native notification-area icon (needs a Win32 message loop on
//! the main thread). Linux: a StatusNotifierItem over D-Bus, shown by KDE,
//! most other desktops and GNOME with the AppIndicator extension. Where no
//! tray is available the agent keeps running and the settings page is
//! still reachable by starting PairDesk again.

use std::sync::Arc;

use crate::state::AppState;

/// 32×32 RGBA tray icon: a phone outline on a blue rounded square, with a
/// red dot while a phone is viewing the screen.
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
            let white = (outer && !inner) || dot;
            let red_ring = viewing && (x - 25).pow(2) + (y - 6).pow(2) <= 49;
            let red = viewing && (x - 25).pow(2) + (y - 6).pow(2) <= 30;
            let (r, g, b, a) = if red {
                (0xe5, 0x2b, 0x2b, 255)
            } else if red_ring || white {
                (255, 255, 255, 255)
            } else if bg {
                (0x24, 0x57, 0xd6, 255)
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
    if let Err(e) = webbrowser::open(url) {
        log::warn!("cannot open the browser: {e}");
    }
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
/// the browser.
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

#[cfg(not(windows))]
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

    #[cfg(target_os = "linux")]
    struct Tray {
        url: String,
        name: String,
        viewing: bool,
    }

    #[cfg(target_os = "linux")]
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
        #[cfg(target_os = "linux")]
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
        #[cfg(not(target_os = "linux"))]
        let _ = (rt, state, url, no_tray);

        let mut quit = QUIT.0.lock().unwrap_or_else(|p| p.into_inner());
        while !*quit {
            quit = QUIT.1.wait(quit).unwrap_or_else(|p| p.into_inner());
        }
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
