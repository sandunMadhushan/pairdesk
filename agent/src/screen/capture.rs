// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading pixels from the screen.
//!
//! - Windows: GDI `BitBlt` from the desktop. The agent is per-monitor DPI
//!   aware, so all coordinates are real pixels across every monitor.
//! - Linux: X11 `GetImage` on the root window, monitors from RandR. In a
//!   Wayland session: the desktop's screen-cast portal and PipeWire.
//!
//! Frames are BGRA (blue, green, red, unused), top row first.

/// One monitor, in virtual-desktop pixels.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Monitor {
    pub index: u32,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub primary: bool,
}

pub struct Frame {
    pub width: u32,
    pub height: u32,
    /// BGRA, `width * 4` bytes per row.
    pub data: Vec<u8>,
}

/// Why screen view can't run here, if it can't.
pub fn unsupported_reason() -> Option<String> {
    #[cfg(not(windows))]
    {
        #[cfg(target_os = "linux")]
        if crate::wayland::global().is_some() {
            return None;
        }
        if std::env::var_os("DISPLAY").is_none() {
            return Some("No display found on this computer.".into());
        }
    }
    None
}

pub use platform::{Capturer, monitors};
#[cfg(windows)]
pub use platform::{cursor_position, grab};

// ---------------------------------------------------------------- Windows

#[cfg(windows)]
mod platform {
    use super::*;
    use windows_sys::Win32::Foundation::{BOOL, LPARAM, POINT, RECT, TRUE};
    use windows_sys::Win32::Graphics::Gdi::{
        BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC,
        DIB_RGB_COLORS, DeleteDC, DeleteObject, EnumDisplayMonitors, GetDC, GetDIBits,
        GetMonitorInfoW, HBITMAP, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW, ReleaseDC, SRCCOPY,
        SelectObject,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetCursorPos, MONITORINFOF_PRIMARY};

    pub fn monitors() -> Result<Vec<Monitor>, String> {
        unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
            let list = unsafe { &mut *(data as *mut Vec<Monitor>) };
            let mut info: MONITORINFOEXW = unsafe { std::mem::zeroed() };
            info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
            if unsafe { GetMonitorInfoW(m, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) }
                != 0
            {
                let r = info.monitorInfo.rcMonitor;
                let primary = info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0;
                let index = list.len() as u32;
                list.push(Monitor {
                    index,
                    name: format!(
                        "Display {}{}",
                        index + 1,
                        if primary { " (main)" } else { "" }
                    ),
                    x: r.left,
                    y: r.top,
                    width: (r.right - r.left).max(0) as u32,
                    height: (r.bottom - r.top).max(0) as u32,
                    primary,
                });
            }
            TRUE
        }
        let mut list: Vec<Monitor> = Vec::new();
        unsafe {
            EnumDisplayMonitors(
                std::ptr::null_mut(),
                std::ptr::null(),
                Some(each),
                &mut list as *mut Vec<Monitor> as LPARAM,
            );
        }
        if list.is_empty() {
            return Err("no monitors found".into());
        }
        Ok(list)
    }

    pub fn cursor_position() -> Option<(i32, i32)> {
        let mut p = POINT { x: 0, y: 0 };
        (unsafe { GetCursorPos(&mut p) } != 0).then_some((p.x, p.y))
    }

    /// One capture of a screen area, on this thread's desktop (the helper
    /// moves its threads to the secure desktop first).
    pub fn grab(x: i32, y: i32, width: u32, height: u32) -> Result<Frame, String> {
        let monitor = Monitor {
            index: 0,
            name: String::new(),
            x,
            y,
            width,
            height,
            primary: true,
        };
        Capturer::new_local(monitor)?.capture_local()
    }

    pub struct Capturer {
        monitor: Monitor,
        screen: HDC,
        mem: HDC,
        bitmap: HBITMAP,
        /// The last picture came from the SYSTEM helper (secure desktop).
        via_helper: bool,
    }

    // The handles are only used from the capture thread that owns this.
    unsafe impl Send for Capturer {}

    impl Capturer {
        pub fn new(monitor: Monitor) -> Result<Self, String> {
            if crate::winsys::is_system_mode() {
                let _ = crate::winsys::desktop::follow_input_desktop();
            }
            Self::new_local(monitor)
        }

        fn new_local(monitor: Monitor) -> Result<Self, String> {
            unsafe {
                let screen = GetDC(std::ptr::null_mut());
                if screen.is_null() {
                    return Err("can't open the screen".into());
                }
                let mem = CreateCompatibleDC(screen);
                let bitmap =
                    CreateCompatibleBitmap(screen, monitor.width as i32, monitor.height as i32);
                if mem.is_null() || bitmap.is_null() {
                    ReleaseDC(std::ptr::null_mut(), screen);
                    return Err("can't create a capture buffer".into());
                }
                SelectObject(mem, bitmap);
                Ok(Self {
                    monitor,
                    screen,
                    mem,
                    bitmap,
                    via_helper: false,
                })
            }
        }

        pub fn monitor(&self) -> &Monitor {
            &self.monitor
        }

        /// The picture of the monitor. In the helper's processes this
        /// follows the input desktop; for the signed-in user, the secure
        /// desktop is read through the helper when it's turned on.
        pub fn capture(&mut self) -> Result<Frame, String> {
            if crate::winsys::is_system_mode()
                && crate::winsys::desktop::follow_input_desktop() == Ok(true)
            {
                // A new desktop: the screen handles must be made again.
                *self = Self::new_local(self.monitor.clone())?;
            }
            // The secure desktop can't be read from here (at best it reads
            // as black): ask the helper while it's up.
            if !crate::winsys::is_system_mode()
                && let Some(helper) = crate::winsys::bridge()
                && !crate::winsys::desktop::user_can_reach_input_desktop()
            {
                let m = &self.monitor;
                let f = helper.capture(m.x, m.y, m.width, m.height)?;
                self.via_helper = true;
                return Ok(f);
            }
            self.via_helper = false;
            self.capture_local()
        }

        pub fn via_helper(&self) -> bool {
            self.via_helper
        }

        fn capture_local(&mut self) -> Result<Frame, String> {
            let (w, h) = (self.monitor.width as i32, self.monitor.height as i32);
            unsafe {
                if BitBlt(
                    self.mem,
                    0,
                    0,
                    w,
                    h,
                    self.screen,
                    self.monitor.x,
                    self.monitor.y,
                    SRCCOPY,
                ) == 0
                {
                    // Happens on the lock screen and UAC prompts (secure desktop).
                    return Err("the screen can't be read right now".into());
                }
                let mut info: BITMAPINFO = std::mem::zeroed();
                info.bmiHeader = BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // negative: top row first
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB,
                    ..std::mem::zeroed()
                };
                let mut data = vec![0u8; (w * h * 4) as usize];
                let lines = GetDIBits(
                    self.mem,
                    self.bitmap,
                    0,
                    h as u32,
                    data.as_mut_ptr().cast(),
                    &mut info,
                    DIB_RGB_COLORS,
                );
                if lines == 0 {
                    return Err("can't read the captured image".into());
                }
                Ok(Frame {
                    width: w as u32,
                    height: h as u32,
                    data,
                })
            }
        }
    }

    impl Drop for Capturer {
        fn drop(&mut self) {
            unsafe {
                DeleteObject(self.bitmap);
                DeleteDC(self.mem);
                ReleaseDC(std::ptr::null_mut(), self.screen);
            }
        }
    }
}

// ------------------------------------------------------------------ Linux

#[cfg(not(windows))]
mod platform {
    use super::*;
    use x11rb::connection::Connection;
    use x11rb::protocol::randr::ConnectionExt as _;
    use x11rb::protocol::xproto::{ConnectionExt as _, ImageFormat, Window};
    use x11rb::rust_connection::RustConnection;

    fn connect() -> Result<(RustConnection, Window), String> {
        let (conn, screen) =
            x11rb::connect(None).map_err(|e| format!("can't open the X display: {e}"))?;
        let root = conn.setup().roots[screen].root;
        Ok((conn, root))
    }

    fn monitors_on(conn: &RustConnection, root: Window) -> Result<Vec<Monitor>, String> {
        let from_randr = conn
            .randr_get_monitors(root, true)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| r.monitors)
            .unwrap_or_default();
        let mut list = Vec::new();
        for (i, m) in from_randr.iter().enumerate() {
            let name = conn
                .get_atom_name(m.name)
                .ok()
                .and_then(|c| c.reply().ok())
                .map(|r| String::from_utf8_lossy(&r.name).into_owned())
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| format!("Display {}", i + 1));
            list.push(Monitor {
                index: i as u32,
                name: if m.primary {
                    format!("{name} (main)")
                } else {
                    name
                },
                x: m.x as i32,
                y: m.y as i32,
                width: m.width as u32,
                height: m.height as u32,
                primary: m.primary,
            });
        }
        if list.is_empty() {
            // No RandR: the whole screen is one monitor.
            let geo = conn
                .get_geometry(root)
                .map_err(|e| e.to_string())?
                .reply()
                .map_err(|e| e.to_string())?;
            list.push(Monitor {
                index: 0,
                name: "Display 1".into(),
                x: 0,
                y: 0,
                width: geo.width as u32,
                height: geo.height as u32,
                primary: true,
            });
        }
        if !list.iter().any(|m| m.primary) {
            list[0].primary = true;
        }
        Ok(list)
    }

    pub fn monitors() -> Result<Vec<Monitor>, String> {
        #[cfg(target_os = "linux")]
        if let Some(remote) = crate::wayland::global() {
            return remote.monitors();
        }
        let (conn, root) = connect()?;
        monitors_on(&conn, root)
    }

    /// X11, or (Linux) a Wayland screen from the portal.
    pub enum Capturer {
        X11(Box<X11Capturer>),
        #[cfg(target_os = "linux")]
        Wayland(WaylandCapturer),
    }

    impl Capturer {
        pub fn new(monitor: Monitor) -> Result<Self, String> {
            #[cfg(target_os = "linux")]
            if let Some(remote) = crate::wayland::global() {
                let (stream, _) = remote.open_screen(monitor.index)?;
                return Ok(Capturer::Wayland(WaylandCapturer {
                    monitor,
                    stream,
                    size: (0, 0),
                }));
            }
            X11Capturer::new(monitor).map(|c| Capturer::X11(Box::new(c)))
        }

        pub fn monitor(&self) -> &Monitor {
            match self {
                Capturer::X11(c) => &c.monitor,
                #[cfg(target_os = "linux")]
                Capturer::Wayland(c) => &c.monitor,
            }
        }

        /// Pointer position in desktop coordinates.
        pub fn cursor(&self) -> Option<(i32, i32)> {
            match self {
                Capturer::X11(c) => c.cursor(),
                #[cfg(target_os = "linux")]
                Capturer::Wayland(c) => c.cursor(),
            }
        }

        pub fn capture(&mut self) -> Result<Frame, String> {
            match self {
                Capturer::X11(c) => c.capture(),
                #[cfg(target_os = "linux")]
                Capturer::Wayland(c) => c.capture(),
            }
        }
    }

    #[cfg(target_os = "linux")]
    pub struct WaylandCapturer {
        monitor: Monitor,
        stream: crate::wayland::pipewire::Stream,
        /// Size of the last picture, in pixels (can differ from the
        /// monitor's desktop size with display scaling).
        size: (u32, u32),
    }

    #[cfg(target_os = "linux")]
    impl WaylandCapturer {
        fn cursor(&self) -> Option<(i32, i32)> {
            let (cx, cy) = self.stream.cursor()?;
            let m = &self.monitor;
            let (pw, ph) = if self.size.0 > 0 {
                self.size
            } else {
                (m.width, m.height)
            };
            Some((
                m.x + (cx as i64 * m.width as i64 / pw.max(1) as i64) as i32,
                m.y + (cy as i64 * m.height as i64 / ph.max(1) as i64) as i32,
            ))
        }

        fn capture(&mut self) -> Result<Frame, String> {
            let (width, height, data) = self.stream.frame(std::time::Duration::from_secs(5))?;
            self.size = (width, height);
            Ok(Frame {
                width,
                height,
                data,
            })
        }
    }

    pub struct X11Capturer {
        monitor: Monitor,
        conn: RustConnection,
        root: Window,
    }

    impl X11Capturer {
        pub fn new(monitor: Monitor) -> Result<Self, String> {
            let (conn, root) = connect()?;
            let bpp = conn
                .setup()
                .pixmap_formats
                .iter()
                .find(|f| f.depth == 24)
                .map(|f| f.bits_per_pixel);
            if bpp != Some(32) {
                return Err("this display's colour format isn't supported".into());
            }
            Ok(Self {
                monitor,
                conn,
                root,
            })
        }

        pub fn cursor(&self) -> Option<(i32, i32)> {
            let p = self.conn.query_pointer(self.root).ok()?.reply().ok()?;
            Some((p.root_x as i32, p.root_y as i32))
        }

        pub fn capture(&mut self) -> Result<Frame, String> {
            let m = &self.monitor;
            let reply = self
                .conn
                .get_image(
                    ImageFormat::Z_PIXMAP,
                    self.root,
                    m.x as i16,
                    m.y as i16,
                    m.width as u16,
                    m.height as u16,
                    !0,
                )
                .map_err(|e| e.to_string())?
                .reply()
                .map_err(|e| format!("can't read the screen: {e}"))?;
            let expected = (m.width * m.height * 4) as usize;
            if reply.data.len() < expected {
                return Err("the screen image was cut short".into());
            }
            let mut data = reply.data;
            data.truncate(expected);
            Ok(Frame {
                width: m.width,
                height: m.height,
                data,
            })
        }
    }
}

#[cfg(windows)]
impl Capturer {
    pub fn cursor(&self) -> Option<(i32, i32)> {
        if self.via_helper()
            && let Some(helper) = crate::winsys::bridge()
        {
            return helper.desktop().ok().and_then(|(_, c)| c);
        }
        platform::cursor_position()
    }
}

/// Makes Windows report real pixels everywhere (screen capture, cursor
/// position, monitor sizes) instead of scaled ones. Call once at start-up.
pub fn set_dpi_aware() {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::UI::HiDpi::{
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
        };
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}

#[cfg(all(test, not(windows)))]
mod tests {
    use super::*;

    /// Runs only when an X display is available (e.g. under Xvfb).
    #[test]
    fn captures_the_x11_screen() {
        if std::env::var_os("DISPLAY").is_none() {
            eprintln!("no DISPLAY; skipped");
            return;
        }
        let monitors = monitors().expect("monitors");
        assert!(!monitors.is_empty());
        let main = monitors.iter().find(|m| m.primary).unwrap().clone();
        let mut cap = Capturer::new(main.clone()).expect("capturer");
        let frame = cap.capture().expect("frame");
        assert_eq!((frame.width, frame.height), (main.width, main.height));
        assert_eq!(frame.data.len(), (main.width * main.height * 4) as usize);
        assert!(cap.cursor().is_some());
    }
}
