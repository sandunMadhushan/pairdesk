// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows: the PairDesk window.
//!
//! The settings page, shown in a window of its own instead of a browser
//! tab. It uses WebView2, the web view built into Windows 10 and 11 (the
//! same engine as Edge). Where WebView2 is missing, PairDesk falls back to
//! the browser.
//!
//! Everything here runs on the main thread, which owns the message loop
//! (see `tray`). Closing the window destroys it, freeing WebView2's memory;
//! it's made again the next time it's opened.

use std::cell::RefCell;
use std::num::NonZeroIsize;
use std::path::PathBuf;
use std::sync::OnceLock;

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows_sys::Win32::UI::HiDpi::{GetDpiForSystem, GetDpiForWindow};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CW_USEDEFAULT, CreateWindowExW, DefWindowProcW, DestroyWindow, GetSystemMetrics, IDC_ARROW,
    IMAGE_ICON, IsIconic, LR_DEFAULTSIZE, LoadCursorW, LoadImageW, MINMAXINFO, PostMessageW,
    RegisterClassExW, SM_CXSCREEN, SM_CYSCREEN, SW_RESTORE, SW_SHOW, SetForegroundWindow,
    ShowWindow, WM_APP, WM_CLOSE, WM_GETMINMAXINFO, WNDCLASSEXW, WS_OVERLAPPEDWINDOW,
};
use wry::raw_window_handle::{
    HandleError, HasWindowHandle, RawWindowHandle, Win32WindowHandle, WindowHandle,
};
use wry::{WebContext, WebView, WebViewBuilder};

/// Posted to the window by its close button: destroyed outside of
/// whatever WebView2 is doing at that moment.
const WM_DESTROY_LATER: u32 = WM_APP + 10;

struct AppWindow {
    hwnd: HWND,
    // Dropped before the window is destroyed.
    webview: Option<WebView>,
    // WebView2's data folder; must outlive the web view.
    _context: WebContext,
}

thread_local! {
    static WINDOW: RefCell<Option<AppWindow>> = const { RefCell::new(None) };
    /// While WebView2 starts (it runs the message loop meanwhile).
    static CREATING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Where WebView2 keeps its data (cache, local storage). Set at start-up;
/// the program folder may not be writable.
pub fn set_data_dir(dir: PathBuf) {
    let _ = DATA_DIR.set(dir.join("window"));
}

/// Whether this computer has WebView2.
pub fn available() -> bool {
    static AVAILABLE: OnceLock<bool> = OnceLock::new();
    *AVAILABLE.get_or_init(|| match wry::webview_version() {
        Ok(v) => {
            log::info!("WebView2 {v}");
            true
        }
        Err(e) => {
            log::info!("no WebView2 ({e}): the settings page opens in the browser");
            false
        }
    })
}

/// Shows the window with `url` (making it if needed). `home` is the
/// settings page's address: links elsewhere open in the browser. False if
/// the window can't be shown; the caller then uses the browser.
pub fn show(url: &str, home: &str) -> bool {
    if !available() {
        return false;
    }
    if CREATING.get() {
        return true;
    }
    // Already open: bring it to the front, on the requested page.
    let shown = WINDOW.with(|w| {
        let Ok(w) = w.try_borrow() else {
            return Some(true);
        };
        let w = w.as_ref()?;
        if let Some(webview) = &w.webview {
            let current = webview.url().unwrap_or_default();
            if current != url {
                let _ = webview.load_url(url);
            }
        }
        unsafe {
            ShowWindow(
                w.hwnd,
                if IsIconic(w.hwnd) != 0 {
                    SW_RESTORE
                } else {
                    SW_SHOW
                },
            );
            SetForegroundWindow(w.hwnd);
        }
        if let Some(webview) = &w.webview {
            let _ = webview.focus();
        }
        Some(true)
    });
    if let Some(shown) = shown {
        return shown;
    }
    CREATING.set(true);
    let created = create(url, home);
    CREATING.set(false);
    match created {
        Ok(w) => {
            WINDOW.with(|cell| *cell.borrow_mut() = Some(w));
            true
        }
        Err(e) => {
            log::warn!("can't open the PairDesk window: {e}");
            false
        }
    }
}

/// Closes the window (when PairDesk stops).
pub fn close() {
    let Some(mut w) = WINDOW.with(|cell| cell.try_borrow_mut().ok().and_then(|mut c| c.take()))
    else {
        return;
    };
    w.webview = None;
    unsafe { DestroyWindow(w.hwnd) };
}

fn create(url: &str, home: &str) -> Result<AppWindow, String> {
    let hwnd = make_window()?;
    let mut context = WebContext::new(DATA_DIR.get().cloned());
    let home = home.to_string();
    let home_for_popups = home.clone();
    let dark = system_uses_dark_mode();
    let built = WebViewBuilder::new_with_web_context(&mut context)
        .with_url(url)
        .with_focused(true)
        .with_on_page_load_handler(|event, _| {
            if matches!(event, wry::PageLoadEvent::Finished) {
                log::info!("window: page loaded");
            }
        })
        // The page's own background, so opening doesn't flash white.
        .with_background_color(if dark {
            (0x12, 0x14, 0x18, 255)
        } else {
            (0xf5, 0xf6, 0xf8, 255)
        })
        .with_navigation_handler(move |to| {
            if to.starts_with(&home) || to == "about:blank" {
                return true;
            }
            open_in_browser(&to);
            false
        })
        .with_new_window_req_handler(move |to, _| {
            if !to.starts_with(&home_for_popups) {
                open_in_browser(&to);
            }
            wry::NewWindowResponse::Deny
        })
        .build(&Parent(hwnd));
    match built {
        Ok(webview) => {
            unsafe {
                ShowWindow(hwnd, SW_SHOW);
                SetForegroundWindow(hwnd);
            }
            let _ = webview.focus();
            log::info!("window: opened");
            Ok(AppWindow {
                hwnd,
                webview: Some(webview),
                _context: context,
            })
        }
        Err(e) => {
            unsafe { DestroyWindow(hwnd) };
            Err(e.to_string())
        }
    }
}

fn open_in_browser(url: &str) {
    let web = ["https://", "http://", "mailto:"]
        .iter()
        .any(|p| url.starts_with(p));
    if web && let Err(e) = webbrowser::open(url) {
        log::warn!("cannot open the browser: {e}");
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn make_window() -> Result<HWND, String> {
    static CLASS: OnceLock<Vec<u16>> = OnceLock::new();
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        let class = CLASS.get_or_init(|| {
            let name = wide("PairDeskWindow");
            // Icon 1 in the .exe's resources (pairdesk.rc.in).
            let icon = LoadImageW(instance, 1 as _, IMAGE_ICON, 0, 0, LR_DEFAULTSIZE);
            let small = LoadImageW(instance, 1 as _, IMAGE_ICON, 16, 16, 0);
            let wc = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(window_proc),
                hInstance: instance,
                hIcon: icon as _,
                hIconSm: small as _,
                hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
                lpszClassName: name.as_ptr(),
                ..std::mem::zeroed()
            };
            RegisterClassExW(&wc);
            name
        });
        // About 1040×740 at 100 % scaling, never bigger than the screen.
        let dpi = GetDpiForSystem().max(96) as i32;
        let width = (1040 * dpi / 96).min(GetSystemMetrics(SM_CXSCREEN) * 9 / 10);
        let height = (740 * dpi / 96).min(GetSystemMetrics(SM_CYSCREEN) * 9 / 10);
        let title = wide("PairDesk");
        let hwnd = CreateWindowExW(
            0,
            class.as_ptr(),
            title.as_ptr(),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            width,
            height,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            instance,
            std::ptr::null(),
        );
        if hwnd.is_null() {
            return Err(format!(
                "CreateWindowEx failed ({})",
                std::io::Error::last_os_error()
            ));
        }
        if system_uses_dark_mode() {
            // DWMWA_USE_IMMERSIVE_DARK_MODE: a dark title bar.
            let on: i32 = 1;
            DwmSetWindowAttribute(hwnd, 20, (&on as *const i32).cast(), 4);
        }
        Ok(hwnd)
    }
}

unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_CLOSE => {
                ShowWindow(hwnd, 0); // SW_HIDE: gone at once for the user
                PostMessageW(hwnd, WM_DESTROY_LATER, 0, 0);
                0
            }
            WM_GETMINMAXINFO => {
                // Room for the sidebar and a screen beside it.
                let dpi = GetDpiForWindow(hwnd).max(96) as i32;
                let info = &mut *(lp as *mut MINMAXINFO);
                info.ptMinTrackSize.x = 760 * dpi / 96;
                info.ptMinTrackSize.y = 520 * dpi / 96;
                0
            }
            WM_DESTROY_LATER => {
                let ours = WINDOW.with(|cell| {
                    cell.try_borrow()
                        .map(|w| w.as_ref().is_some_and(|w| w.hwnd == hwnd))
                        .unwrap_or(false)
                });
                if ours {
                    close();
                } else {
                    DestroyWindow(hwnd);
                }
                0
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Windows' "Choose your app mode: Dark".
fn system_uses_dark_mode() -> bool {
    let key = wide(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
    let value = wide("AppsUseLightTheme");
    let mut data: u32 = 1;
    let mut size = 4u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            (&mut data as *mut u32).cast(),
            &mut size,
        )
    };
    r == 0 && data == 0
}

/// Our window, as wry wants it.
struct Parent(HWND);

impl HasWindowHandle for Parent {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let hwnd = NonZeroIsize::new(self.0 as isize).ok_or(HandleError::Unavailable)?;
        let mut handle = Win32WindowHandle::new(hwnd);
        handle.hinstance =
            NonZeroIsize::new(unsafe { GetModuleHandleW(std::ptr::null()) } as isize);
        // Safety: the window lives as long as the web view (see `close`).
        Ok(unsafe { WindowHandle::borrow_raw(RawWindowHandle::Win32(handle)) })
    }
}
