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

/// 32×32 RGBA tray icon: a phone outline on a blue rounded square.
fn icon_rgba() -> (Vec<u8>, u32) {
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
            let (r, g, b, a) = if white {
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

fn open(url: &str) {
    if let Err(e) = webbrowser::open(url) {
        log::warn!("cannot open the browser: {e}");
    }
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
        PeekMessageW, PostQuitMessage, PostThreadMessageW, TranslateMessage, WM_QUIT, WM_USER,
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

    pub fn run(_rt: &tokio::runtime::Runtime, state: Arc<AppState>, url: String, no_tray: bool) {
        let open_item = MenuItem::new("Open PairDesk", true, None);
        let pair_item = MenuItem::new("Pair a phone…", true, None);
        let quit_item = MenuItem::new("Stop PairDesk", true, None);
        let tray = if no_tray {
            None
        } else {
            let menu = Menu::new();
            let built = menu
                .append_items(&[
                    &open_item,
                    &pair_item,
                    &PredefinedMenuItem::separator(),
                    &quit_item,
                ])
                .map_err(|e| e.to_string())
                .and_then(|_| {
                    let (rgba, n) = icon_rgba();
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
                TranslateMessage(&msg);
                DispatchMessageW(&msg);

                while let Ok(ev) = MenuEvent::receiver().try_recv() {
                    if ev.id == open_item.id() {
                        open(&url);
                    } else if ev.id == pair_item.id() {
                        open(&format!("{url}?pair=1"));
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
                        open(&url);
                    }
                }
            }
        }
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

    pub fn request_quit() {
        *QUIT.0.lock().unwrap_or_else(|p| p.into_inner()) = true;
        QUIT.1.notify_all();
    }

    pub fn show_error(_msg: &str) {}

    #[cfg(target_os = "linux")]
    struct Tray {
        url: String,
        name: String,
    }

    #[cfg(target_os = "linux")]
    impl ksni::Tray for Tray {
        fn id(&self) -> String {
            "pairdesk".into()
        }
        fn title(&self) -> String {
            format!("PairDesk – {}", self.name)
        }
        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            let (mut data, n) = icon_rgba();
            for p in data.chunks_exact_mut(4) {
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
            };
            rt.spawn(async move {
                match tray.spawn().await {
                    Ok(handle) => {
                        // Keep the tray alive until the agent stops.
                        std::future::pending::<()>().await;
                        drop(handle);
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
