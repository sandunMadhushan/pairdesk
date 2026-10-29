// SPDX-License-Identifier: GPL-3.0-or-later
//! The desktop's "remote desktop" permission (XDG desktop portal), the
//! standard way for an app to move the pointer, type and see the screen in
//! a Wayland session (GNOME, KDE Plasma).
//!
//! One portal session gives both: pointer and keyboard (RemoteDesktop) and
//! the screen of each chosen monitor (ScreenCast). The first time, the
//! desktop asks the owner in a dialog; with "remember" the portal returns a
//! restore token, and later sessions start without asking.

use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use zbus::Connection;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

const DEST: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const REMOTE: &str = "org.freedesktop.portal.RemoteDesktop";
const SCREEN: &str = "org.freedesktop.portal.ScreenCast";
const CLIPBOARD: &str = "org.freedesktop.portal.Clipboard";
/// Text types offered when PairDesk owns the clipboard.
const TEXT_TYPES: [&str; 5] = [
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
];

pub const DEVICE_KEYBOARD: u32 = 1;
pub const DEVICE_POINTER: u32 = 2;

/// One shared monitor.
#[derive(Debug, Clone, PartialEq)]
pub struct StreamInfo {
    pub node: u32,
    /// Position and size in the desktop's (logical) coordinates.
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// Why a session couldn't start.
#[derive(Debug, Clone, PartialEq)]
pub enum StartError {
    /// The owner pressed Cancel (or closed the dialog).
    Cancelled,
    /// No RemoteDesktop portal (e.g. wlroots desktops).
    NoPortal(String),
    Failed(String),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartError::Cancelled => write!(f, "not allowed on the computer"),
            StartError::NoPortal(e) => write!(f, "no remote desktop portal: {e}"),
            StartError::Failed(e) => write!(f, "{e}"),
        }
    }
}

fn failed(e: impl std::fmt::Display) -> StartError {
    StartError::Failed(e.to_string())
}

pub struct Session {
    conn: Connection,
    pub handle: OwnedObjectPath,
    pub devices: u32,
    pub streams: Vec<StreamInfo>,
    /// For the next start without a dialog; `None` if the desktop doesn't
    /// remember permissions.
    pub restore_token: Option<String>,
    /// The desktop shares its clipboard with this session.
    pub clipboard: bool,
    /// Text PairDesk put on the clipboard, handed out on request.
    offered: Arc<Mutex<Option<String>>>,
    /// Answers the desktop's requests for that text.
    serving: Option<tokio::task::JoinHandle<()>>,
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Some(t) = self.serving.take() {
            t.abort();
        }
    }
}

type Options<'a> = HashMap<&'a str, Value<'a>>;

/// Calls a portal method that answers through a `Request` object. `body`
/// gets the handle token to put in the method's options.
async fn request<B>(
    conn: &Connection,
    iface: &str,
    method: &str,
    body: impl FnOnce(String) -> B,
) -> Result<HashMap<String, OwnedValue>, StartError>
where
    B: serde::Serialize + zbus::zvariant::DynamicType,
{
    let sender = conn
        .unique_name()
        .ok_or_else(|| failed("no D-Bus name"))?
        .trim_start_matches(':')
        .replace('.', "_");
    let handle_token = token(method);
    let path = format!("{PATH}/request/{sender}/{handle_token}");
    // Listen before asking, so the answer can't be missed.
    let req = zbus::Proxy::new(conn, DEST, path, "org.freedesktop.portal.Request")
        .await
        .map_err(failed)?;
    let mut answers = req.receive_signal("Response").await.map_err(failed)?;
    let proxy = zbus::Proxy::new(conn, DEST, PATH, iface)
        .await
        .map_err(failed)?;
    proxy
        .call_method(method, &body(handle_token))
        .await
        .map_err(no_portal)?;
    let msg = answers
        .next()
        .await
        .ok_or_else(|| failed("the portal went away"))?;
    let (code, results): (u32, HashMap<String, OwnedValue>) =
        msg.body().deserialize().map_err(failed)?;
    match code {
        0 => Ok(results),
        1 => Err(StartError::Cancelled),
        _ => Err(failed(format!("{method} was refused"))),
    }
}

fn no_portal(e: zbus::Error) -> StartError {
    match e {
        zbus::Error::MethodError(name, msg, _)
            if name
                .as_str()
                .starts_with("org.freedesktop.DBus.Error.Unknown")
                || name.as_str() == "org.freedesktop.DBus.Error.ServiceUnknown" =>
        {
            StartError::NoPortal(msg.unwrap_or_default())
        }
        zbus::Error::FDO(e) => match *e {
            zbus::fdo::Error::UnknownMethod(m)
            | zbus::fdo::Error::UnknownInterface(m)
            | zbus::fdo::Error::UnknownObject(m)
            | zbus::fdo::Error::ServiceUnknown(m) => StartError::NoPortal(m),
            other => failed(other),
        },
        other => failed(other),
    }
}

fn token(what: &str) -> String {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(1);
    format!(
        "pairdesk_{}_{}_{}",
        what.to_ascii_lowercase(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

/// The best pointer mode the desktop offers: position as metadata (so the
/// phone draws it), else drawn into the picture.
async fn cursor_mode(conn: &Connection) -> u32 {
    let modes: u32 = async {
        let p = zbus::Proxy::new(conn, DEST, PATH, SCREEN).await.ok()?;
        p.get_property::<u32>("AvailableCursorModes").await.ok()
    }
    .await
    .unwrap_or(0);
    if modes & 4 != 0 {
        4
    } else if modes & 2 != 0 {
        2
    } else {
        1
    }
}

/// Starts a session: pointer, keyboard and the screen. Shows the desktop's
/// dialog unless `restore_token` is still valid.
pub async fn start(restore_token: Option<&str>) -> Result<Session, StartError> {
    let conn = Connection::session()
        .await
        .map_err(|e| StartError::NoPortal(e.to_string()))?;

    let created = request(&conn, REMOTE, "CreateSession", |t| {
        let opts: Options = HashMap::from([
            ("handle_token", Value::from(t)),
            ("session_handle_token", Value::from(token("session"))),
        ]);
        (opts,)
    })
    .await?;
    let handle: String = created
        .get("session_handle")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| String::try_from(v).ok())
        .ok_or_else(|| failed("no session handle"))?;
    let handle = OwnedObjectPath::try_from(handle).map_err(failed)?;

    // The clipboard has to be asked for before Start; older portals don't
    // have it, and PairDesk works without it.
    let clip_proxy = zbus::Proxy::new(&conn, DEST, PATH, CLIPBOARD).await;
    let asked_clipboard = match &clip_proxy {
        Ok(p) => p
            .call_method("RequestClipboard", &(handle.as_ref(), Options::new()))
            .await
            .map_err(|e| log::info!("no clipboard through the portal: {e}"))
            .is_ok(),
        Err(_) => false,
    };

    let result = select_and_start(&conn, &handle, restore_token).await;
    match result {
        Ok((devices, streams, restore_token, clipboard)) => {
            let clipboard = asked_clipboard && clipboard;
            let offered = Arc::new(Mutex::new(None));
            let serving = if clipboard {
                Some(tokio::spawn(serve_clipboard(
                    conn.clone(),
                    handle.clone(),
                    offered.clone(),
                )))
            } else {
                None
            };
            Ok(Session {
                conn,
                handle,
                devices,
                streams,
                restore_token,
                clipboard,
                offered,
                serving,
            })
        }
        Err(e) => {
            close_path(&conn, &handle).await;
            Err(e)
        }
    }
}

async fn select_and_start(
    conn: &Connection,
    handle: &OwnedObjectPath,
    restore_token: Option<&str>,
) -> Result<(u32, Vec<StreamInfo>, Option<String>, bool), StartError> {
    let s = handle.as_ref();
    request(conn, REMOTE, "SelectDevices", |t| {
        let mut opts: Options = HashMap::from([
            ("handle_token", Value::from(t)),
            ("types", Value::from(DEVICE_KEYBOARD | DEVICE_POINTER)),
            // Remember until the owner revokes it.
            ("persist_mode", Value::from(2u32)),
        ]);
        if let Some(r) = restore_token {
            opts.insert("restore_token", Value::from(r.to_string()));
        }
        (s.clone(), opts)
    })
    .await?;

    let mode = cursor_mode(conn).await;
    request(conn, SCREEN, "SelectSources", |t| {
        let opts: Options = HashMap::from([
            ("handle_token", Value::from(t)),
            ("types", Value::from(1u32)), // monitors
            ("multiple", Value::from(true)),
            ("cursor_mode", Value::from(mode)),
        ]);
        (s.clone(), opts)
    })
    .await?;

    let started = request(conn, REMOTE, "Start", |t| {
        let opts: Options = HashMap::from([("handle_token", Value::from(t))]);
        (s.clone(), "", opts)
    })
    .await?;

    let devices = started
        .get("devices")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| u32::try_from(v).ok())
        .unwrap_or(0);
    let restore = started
        .get("restore_token")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| String::try_from(v).ok());
    let streams = started
        .get("streams")
        .and_then(|v| v.try_clone().ok())
        .map(parse_streams)
        .unwrap_or_default();
    let clipboard = started
        .get("clipboard_enabled")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| bool::try_from(v).ok())
        .unwrap_or(false);
    Ok((devices, streams, restore, clipboard))
}

/// While PairDesk owns the clipboard, the desktop asks for the text with
/// `SelectionTransfer`; it's written to a pipe the portal gives out. When
/// another app copies something, PairDesk's text is forgotten.
async fn serve_clipboard(
    conn: Connection,
    handle: OwnedObjectPath,
    offered: Arc<Mutex<Option<String>>>,
) {
    let Ok(proxy) = zbus::Proxy::new(&conn, DEST, PATH, CLIPBOARD).await else {
        return;
    };
    let (Ok(mut transfers), Ok(mut owners)) = (
        proxy.receive_signal("SelectionTransfer").await,
        proxy.receive_signal("SelectionOwnerChanged").await,
    ) else {
        return;
    };
    loop {
        tokio::select! {
            Some(msg) = transfers.next() => {
                let Ok((session, _mime, serial)) =
                    msg.body().deserialize::<(OwnedObjectPath, String, u32)>()
                else {
                    continue;
                };
                if session != handle {
                    continue;
                }
                let text = offered.lock().unwrap_or_else(|p| p.into_inner()).clone();
                let ok = match text {
                    Some(text) => write_selection(&proxy, &handle, serial, text).await.is_ok(),
                    None => false,
                };
                let _ = proxy
                    .call_method("SelectionWriteDone", &(handle.as_ref(), serial, ok))
                    .await;
            }
            Some(msg) = owners.next() => {
                let Ok((session, opts)) =
                    msg.body().deserialize::<(OwnedObjectPath, HashMap<String, OwnedValue>)>()
                else {
                    continue;
                };
                let ours = opts
                    .get("session_is_owner")
                    .and_then(|v| v.try_clone().ok())
                    .and_then(|v| bool::try_from(v).ok())
                    .unwrap_or(false);
                if session == handle && !ours {
                    *offered.lock().unwrap_or_else(|p| p.into_inner()) = None;
                }
            }
            else => return,
        }
    }
}

async fn write_selection(
    proxy: &zbus::Proxy<'_>,
    handle: &OwnedObjectPath,
    serial: u32,
    text: String,
) -> Result<(), String> {
    let fd: zbus::zvariant::OwnedFd = proxy
        .call("SelectionWrite", &(handle.as_ref(), serial))
        .await
        .map_err(|e| e.to_string())?;
    let fd: OwnedFd = fd.into();
    tokio::task::spawn_blocking(move || {
        use std::io::Write;
        std::fs::File::from(fd).write_all(text.as_bytes())
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| e.to_string())
}

/// `a(ua{sv})`: node id, then `position (ii)` and `size (ii)`.
fn parse_streams(v: OwnedValue) -> Vec<StreamInfo> {
    let Ok(list) = Vec::<(u32, HashMap<String, OwnedValue>)>::try_from(v) else {
        return Vec::new();
    };
    list.into_iter()
        .map(|(node, props)| {
            let pair = |k: &str| -> (i32, i32) {
                props
                    .get(k)
                    .and_then(|v| v.try_clone().ok())
                    .and_then(|v| <(i32, i32)>::try_from(v).ok())
                    .unwrap_or((0, 0))
            };
            let (x, y) = pair("position");
            let (width, height) = pair("size");
            StreamInfo {
                node,
                x,
                y,
                width,
                height,
            }
        })
        .collect()
}

async fn close_path(conn: &Connection, handle: &OwnedObjectPath) {
    if let Ok(proxy) = zbus::Proxy::new(
        conn,
        DEST,
        handle.as_str(),
        "org.freedesktop.portal.Session",
    )
    .await
    {
        let _ = tokio::time::timeout(Duration::from_secs(2), proxy.call_method("Close", &())).await;
    }
}

impl Session {
    async fn notify(
        &self,
        method: &str,
        body: impl serde::Serialize + zbus::zvariant::DynamicType,
    ) -> zbus::Result<()> {
        let proxy = zbus::Proxy::new(&self.conn, DEST, PATH, REMOTE).await?;
        proxy.call_method(method, &body).await?;
        Ok(())
    }

    fn path(&self) -> ObjectPath<'_> {
        self.handle.as_ref()
    }

    pub async fn pointer_motion(&self, dx: f64, dy: f64) -> zbus::Result<()> {
        self.notify("NotifyPointerMotion", (self.path(), Options::new(), dx, dy))
            .await
    }

    pub async fn pointer_motion_absolute(&self, node: u32, x: f64, y: f64) -> zbus::Result<()> {
        self.notify(
            "NotifyPointerMotionAbsolute",
            (self.path(), Options::new(), node, x, y),
        )
        .await
    }

    /// `button`: Linux evdev code (BTN_LEFT = 0x110 …).
    pub async fn pointer_button(&self, button: i32, pressed: bool) -> zbus::Result<()> {
        self.notify(
            "NotifyPointerButton",
            (self.path(), Options::new(), button, pressed as u32),
        )
        .await
    }

    /// `vertical`: positive scrolls down; otherwise positive scrolls right.
    pub async fn scroll(&self, vertical: bool, steps: i32) -> zbus::Result<()> {
        self.notify(
            "NotifyPointerAxisDiscrete",
            (
                self.path(),
                Options::new(),
                if vertical { 0u32 } else { 1u32 },
                steps,
            ),
        )
        .await
    }

    pub async fn keysym(&self, keysym: i32, pressed: bool) -> zbus::Result<()> {
        self.notify(
            "NotifyKeyboardKeysym",
            (self.path(), Options::new(), keysym, pressed as u32),
        )
        .await
    }

    /// A connection to PipeWire that can see this session's screens.
    pub async fn open_pipewire(&self) -> zbus::Result<OwnedFd> {
        let proxy = zbus::Proxy::new(&self.conn, DEST, PATH, SCREEN).await?;
        let fd: zbus::zvariant::OwnedFd = proxy
            .call("OpenPipeWireRemote", &(self.path(), Options::new()))
            .await?;
        Ok(fd.into())
    }

    /// Resolves when the desktop ends the session (the owner stopped it).
    pub async fn closed(&self) {
        let Ok(proxy) = zbus::Proxy::new(
            &self.conn,
            DEST,
            self.handle.as_str(),
            "org.freedesktop.portal.Session",
        )
        .await
        else {
            return std::future::pending().await;
        };
        match proxy.receive_signal("Closed").await {
            Ok(mut s) => {
                s.next().await;
            }
            Err(_) => std::future::pending().await,
        }
    }

    pub async fn close(&self) {
        close_path(&self.conn, &self.handle).await;
    }

    /// Puts `text` on the desktop's clipboard.
    pub async fn set_clipboard(&self, text: String) -> Result<(), String> {
        if !self.clipboard {
            return Err("this desktop doesn't share its clipboard".into());
        }
        *self.offered.lock().unwrap_or_else(|p| p.into_inner()) = Some(text);
        let proxy = zbus::Proxy::new(&self.conn, DEST, PATH, CLIPBOARD)
            .await
            .map_err(|e| e.to_string())?;
        let opts: Options = HashMap::from([("mime_types", Value::from(TEXT_TYPES.to_vec()))]);
        proxy
            .call_method("SetSelection", &(self.path(), opts))
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// The text on the desktop's clipboard ("" when it holds no text).
    pub async fn clipboard(&self) -> Result<String, String> {
        if !self.clipboard {
            return Err("this desktop doesn't share its clipboard".into());
        }
        if let Some(t) = self
            .offered
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
        {
            return Ok(t);
        }
        let proxy = zbus::Proxy::new(&self.conn, DEST, PATH, CLIPBOARD)
            .await
            .map_err(|e| e.to_string())?;
        for mime in ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"] {
            let Ok(fd) = proxy
                .call::<_, _, zbus::zvariant::OwnedFd>("SelectionRead", &(self.path(), mime))
                .await
            else {
                continue;
            };
            let fd: OwnedFd = fd.into();
            let read = tokio::task::spawn_blocking(move || {
                use std::io::Read;
                let mut bytes = Vec::new();
                std::fs::File::from(fd)
                    .take(crate::clipboard::MAX_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)
                    .map(|_| bytes)
            });
            match tokio::time::timeout(Duration::from_secs(3), read).await {
                Ok(Ok(Ok(bytes))) => return Ok(String::from_utf8_lossy(&bytes).into_owned()),
                _ => continue,
            }
        }
        Ok(String::new())
    }
}
