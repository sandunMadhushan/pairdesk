// SPDX-License-Identifier: GPL-3.0-or-later
//! Wayland sessions (GNOME, KDE Plasma): pointer, keyboard and screen go
//! through the desktop's remote desktop portal instead of X11.
//!
//! One portal session is open while a phone is connected (and a little
//! longer, so a quick reconnect doesn't restart it). The first time, the
//! desktop asks the owner; "Remember" makes later sessions start silently.
//! Desktops that can't remember keep the session open for as long as
//! PairDesk runs, so they ask only once per sign-in.

pub mod keys;
pub mod pipewire;
pub mod pod;
pub mod portal;

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use log::{info, warn};
use serde::Serialize;
use tokio::sync::{broadcast, watch};

use crate::input::InputCmd;
use crate::protocol::MouseButton;
use portal::{Session, StartError};

const TOKEN_FILE: &str = "wayland-restore-token";
/// Keep the session this long after the last phone leaves.
const LINGER: Duration = Duration::from_secs(15);

/// True in a Wayland desktop session.
pub fn is_wayland_session() -> bool {
    if let Ok(t) = std::env::var("XDG_SESSION_TYPE") {
        return t.eq_ignore_ascii_case("wayland");
    }
    std::env::var_os("WAYLAND_DISPLAY").is_some()
}

static GLOBAL: OnceLock<Arc<Remote>> = OnceLock::new();

/// The remote desktop session manager, in a Wayland session.
pub fn global() -> Option<&'static Arc<Remote>> {
    GLOBAL.get()
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", tag = "status")]
pub enum Status {
    /// Nothing running (no phone connected).
    Idle,
    /// The desktop is showing its dialog (or restoring).
    Asking,
    Ready {
        /// Pointer and keyboard allowed (not only the screen).
        control: bool,
        /// The desktop will start future sessions without asking.
        remembered: bool,
    },
    /// The owner pressed Cancel.
    Denied,
    /// The owner ended it from the desktop (e.g. GNOME's top bar).
    Stopped,
    NoPortal,
    Failed {
        msg: String,
    },
}

pub struct Remote {
    data_dir: PathBuf,
    rt: tokio::runtime::Handle,
    /// Held while starting, so concurrent callers share one dialog.
    start_lock: tokio::sync::Mutex<()>,
    session: Mutex<Option<Arc<Session>>>,
    status: watch::Sender<Status>,
    notices: broadcast::Sender<String>,
    phones: AtomicUsize,
}

impl Remote {
    /// Sets up the manager (once). `notices` reach connected phones.
    pub fn init(
        data_dir: PathBuf,
        rt: tokio::runtime::Handle,
        notices: broadcast::Sender<String>,
    ) -> &'static Arc<Remote> {
        GLOBAL.get_or_init(|| {
            Arc::new(Remote {
                data_dir,
                rt,
                start_lock: tokio::sync::Mutex::new(()),
                session: Mutex::new(None),
                status: watch::Sender::new(Status::Idle),
                notices,
                phones: AtomicUsize::new(0),
            })
        })
    }

    pub fn status(&self) -> Status {
        self.status.borrow().clone()
    }

    fn set_status(&self, s: Status) {
        self.status.send_replace(s);
    }

    fn notify_phones(&self, msg: &str) {
        let _ = self.notices.send(msg.to_string());
    }

    /// A saved permission exists (the next session starts without asking).
    pub fn is_remembered(&self) -> bool {
        self.token().is_some()
    }

    fn token(&self) -> Option<String> {
        std::fs::read_to_string(self.data_dir.join(TOKEN_FILE))
            .ok()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
    }

    fn save_token(&self, token: Option<&str>) {
        let path = self.data_dir.join(TOKEN_FILE);
        let r = match token {
            Some(t) => crate::config::write_private(&path, t.as_bytes()),
            None => std::fs::remove_file(&path).or(Ok(())),
        };
        if let Err(e) = r {
            warn!("cannot save the remote desktop permission: {e}");
        }
    }

    /// The running session, if any (never waits).
    pub fn current(&self) -> Option<Arc<Session>> {
        self.session
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    /// Returns the session, starting it if needed (the desktop may ask
    /// the owner first).
    pub async fn ensure(self: &Arc<Self>) -> Result<Arc<Session>, String> {
        if let Some(s) = self.current() {
            return Ok(s);
        }
        let _starting = self.start_lock.lock().await;
        if let Some(s) = self.current() {
            return Ok(s);
        }
        let token = self.token();
        self.set_status(Status::Asking);
        if token.is_none() {
            self.notify_phones(
                "Approve PairDesk on the computer: tick \u{201c}Allow Remote Interaction\u{201d}, then press Share.",
            );
        }
        info!(
            "starting the remote desktop session ({})",
            if token.is_some() {
                "remembered"
            } else {
                "asking the owner"
            }
        );
        match portal::start(token.as_deref()).await {
            Ok(session) => {
                let control =
                    session.devices & (portal::DEVICE_POINTER | portal::DEVICE_KEYBOARD) != 0;
                let remembered = session.restore_token.is_some();
                // Tokens work once; keep the new one for next time.
                self.save_token(session.restore_token.as_deref());
                info!(
                    "remote desktop session ready: {} screen(s), control {}, remembered {}",
                    session.streams.len(),
                    control,
                    remembered
                );
                let session = Arc::new(session);
                *self.session.lock().unwrap_or_else(|p| p.into_inner()) = Some(session.clone());
                self.set_status(Status::Ready {
                    control,
                    remembered,
                });
                if !control {
                    self.notify_phones(
                        "The computer shares its screen but doesn't allow control. On the computer, open PairDesk and choose Allow control, then tick \u{201c}Allow Remote Interaction\u{201d}.",
                    );
                }
                self.watch_closed(session.clone());
                Ok(session)
            }
            Err(e) => {
                let (status, msg) = match &e {
                    StartError::Cancelled => (
                        Status::Denied,
                        "Control wasn't allowed on the computer. On the computer, open PairDesk and choose Allow control.".to_string(),
                    ),
                    StartError::NoPortal(_) => (
                        Status::NoPortal,
                        "This desktop doesn't let apps control it (no remote desktop portal). Sign in with an X11 session on the computer.".to_string(),
                    ),
                    StartError::Failed(m) => (
                        Status::Failed { msg: m.clone() },
                        format!("The computer couldn't start remote control: {m}"),
                    ),
                };
                warn!("remote desktop session didn't start: {e}");
                // A refused or stale token mustn't be retried silently.
                if token.is_some() && !matches!(e, StartError::NoPortal(_)) {
                    self.save_token(None);
                }
                self.set_status(status);
                self.notify_phones(&msg);
                Err(msg)
            }
        }
    }

    fn watch_closed(self: &Arc<Self>, session: Arc<Session>) {
        let me = self.clone();
        self.rt.spawn(async move {
            session.closed().await;
            let mut cur = me.session.lock().unwrap_or_else(|p| p.into_inner());
            if cur.as_ref().is_some_and(|s| Arc::ptr_eq(s, &session)) {
                *cur = None;
                drop(cur);
                info!("the remote desktop session was ended on the computer");
                me.set_status(Status::Stopped);
                me.notify_phones("Remote control was stopped on the computer.");
            }
        });
    }

    /// Starts the session in the background (e.g. the owner pressed
    /// Allow control on the settings page).
    pub fn start_in_background(self: &Arc<Self>) {
        let me = self.clone();
        self.rt.spawn(async move {
            let _ = me.ensure().await;
        });
    }

    /// The owner pressed "Allow control" on the settings page: ask again
    /// (forgetting a permission that didn't include control).
    pub fn allow_now(self: &Arc<Self>) {
        let me = self.clone();
        self.rt.spawn(async move {
            let old = me.session.lock().unwrap_or_else(|p| p.into_inner()).take();
            if let Some(old) = old {
                old.close().await;
            }
            me.save_token(None);
            let _ = me.ensure().await;
        });
    }

    /// Whether a phone action may start a session by itself: not after the
    /// owner refused or stopped it (that waits for a new connection or the
    /// settings page).
    fn may_start(&self) -> bool {
        matches!(self.status(), Status::Idle)
    }

    pub fn phone_connected(self: &Arc<Self>) {
        self.phones.fetch_add(1, Ordering::SeqCst);
        if self.current().is_none() && self.status() != Status::Asking {
            self.start_in_background();
        }
    }

    pub fn phone_disconnected(self: &Arc<Self>) {
        if self.phones.fetch_sub(1, Ordering::SeqCst) != 1 {
            return;
        }
        let me = self.clone();
        self.rt.spawn(async move {
            tokio::time::sleep(LINGER).await;
            if me.phones.load(Ordering::SeqCst) != 0 {
                return;
            }
            let Some(session) = me.current() else { return };
            // Without "remember", closing would mean asking again next time.
            if session.restore_token.is_none() {
                return;
            }
            *me.session.lock().unwrap_or_else(|p| p.into_inner()) = None;
            session.close().await;
            me.set_status(Status::Idle);
            info!("remote desktop session closed (no phone connected)");
        });
    }

    /// Shared monitors, in the desktop's coordinates.
    pub fn monitors(self: &Arc<Self>) -> Result<Vec<crate::screen::Monitor>, String> {
        let session = self.blocking_ensure(Duration::from_secs(60))?;
        if session.streams.is_empty() {
            return Err("No screen was shared on the computer. On the computer, open PairDesk, choose Allow control and pick a screen.".into());
        }
        Ok(session
            .streams
            .iter()
            .enumerate()
            .map(|(i, s)| crate::screen::Monitor {
                index: i as u32,
                name: format!("Display {}", i + 1),
                x: s.x,
                y: s.y,
                width: s.width.max(1) as u32,
                height: s.height.max(1) as u32,
                primary: i == 0,
            })
            .collect())
    }

    /// For blocking threads (screen capture): waits for the session.
    fn blocking_ensure(self: &Arc<Self>, wait: Duration) -> Result<Arc<Session>, String> {
        if let Some(s) = self.current() {
            return Ok(s);
        }
        match self.status() {
            Status::Idle | Status::Asking => {}
            Status::Denied => {
                return Err("Screen view wasn't allowed on the computer. On the computer, open PairDesk and choose Allow control.".into());
            }
            Status::Stopped => {
                return Err("Remote control was stopped on the computer. Reconnect, or choose Allow control in PairDesk on the computer.".into());
            }
            Status::NoPortal => {
                return Err("This desktop doesn't let apps see the screen (no remote desktop portal). Sign in with an X11 session on the computer.".into());
            }
            Status::Failed { msg } => {
                return Err(format!("The computer couldn't start screen sharing: {msg}"));
            }
            Status::Ready { .. } => {}
        }
        self.rt.block_on(async {
            tokio::time::timeout(wait, self.ensure())
                .await
                .map_err(|_| "Waiting for approval on the computer.".to_string())?
        })
    }

    /// The clipboard through the portal session, if the session shares it.
    /// `None`: use another way (no session, or no clipboard in it).
    pub fn clipboard_get(self: &Arc<Self>) -> Option<Result<String, String>> {
        let s = self.current().filter(|s| s.clipboard)?;
        Some(self.rt.block_on(s.clipboard()))
    }

    pub fn clipboard_set(self: &Arc<Self>, text: &str) -> Option<Result<(), String>> {
        let s = self.current().filter(|s| s.clipboard)?;
        Some(self.rt.block_on(s.set_clipboard(text.to_string())))
    }

    /// Opens the picture of monitor `index`.
    pub fn open_screen(
        self: &Arc<Self>,
        index: u32,
    ) -> Result<(pipewire::Stream, portal::StreamInfo), String> {
        let session = self.blocking_ensure(Duration::from_secs(60))?;
        let info = session
            .streams
            .get(index as usize)
            .cloned()
            .ok_or("That screen isn't shared any more.")?;
        let fd = self
            .rt
            .block_on(session.open_pipewire())
            .map_err(|e| format!("Can't open the screen: {e}"))?;
        let stream = pipewire::Stream::connect(fd, info.node)?;
        Ok((stream, info))
    }

    /// Applies one input command (on the input thread). Dropped while the
    /// session isn't ready; the phone has been told why.
    pub fn apply(self: &Arc<Self>, cmd: &InputCmd) -> Result<(), String> {
        let Some(s) = self.current() else {
            if self.may_start() {
                self.start_in_background();
            }
            return Ok(());
        };
        self.rt.block_on(apply(&s, cmd)).map_err(|e| e.to_string())
    }
}

/// Linux evdev button codes.
fn evdev(b: MouseButton) -> i32 {
    match b {
        MouseButton::Left => 0x110,
        MouseButton::Right => 0x111,
        MouseButton::Middle => 0x112,
    }
}

async fn apply(s: &Session, cmd: &InputCmd) -> zbus::Result<()> {
    match cmd {
        InputCmd::Move { dx, dy } => {
            if *dx != 0 || *dy != 0 {
                s.pointer_motion(*dx as f64, *dy as f64).await?;
            }
        }
        InputCmd::MoveTo { x, y } => {
            // Desktop coordinates → the monitor's stream.
            let hit = s
                .streams
                .iter()
                .find(|m| *x >= m.x && *x < m.x + m.width && *y >= m.y && *y < m.y + m.height);
            if let Some(m) = hit {
                s.pointer_motion_absolute(m.node, (*x - m.x) as f64, (*y - m.y) as f64)
                    .await?;
            }
        }
        InputCmd::Click(b) => {
            s.pointer_button(evdev(*b), true).await?;
            s.pointer_button(evdev(*b), false).await?;
        }
        InputCmd::Down(b) => s.pointer_button(evdev(*b), true).await?,
        InputCmd::Up(b) => s.pointer_button(evdev(*b), false).await?,
        InputCmd::Scroll { dx, dy } => {
            if *dy != 0 {
                s.scroll(true, *dy).await?;
            }
            if *dx != 0 {
                s.scroll(false, *dx).await?;
            }
        }
        InputCmd::Text(text) => {
            for c in text.chars() {
                let k = keys::char_keysym(c);
                s.keysym(k, true).await?;
                s.keysym(k, false).await?;
            }
        }
        InputCmd::Key(k) => {
            let k = keys::named_keysym(*k);
            s.keysym(k, true).await?;
            s.keysym(k, false).await?;
        }
        InputCmd::Combo { mods, key, ch } => {
            let mut held = Vec::new();
            for m in mods {
                let k = keys::modifier_keysym(*m);
                if !held.contains(&k) {
                    s.keysym(k, true).await?;
                    held.push(k);
                }
            }
            let main = match (key, ch) {
                (Some(k), _) => Some(keys::named_keysym(*k)),
                (None, Some(c)) => Some(keys::char_keysym(c.to_lowercase().next().unwrap_or(*c))),
                (None, None) => None,
            };
            let mut result = Ok(());
            if let Some(k) = main {
                result = async {
                    s.keysym(k, true).await?;
                    s.keysym(k, false).await
                }
                .await;
            }
            for k in held.into_iter().rev() {
                let _ = s.keysym(k, false).await;
            }
            result?;
        }
    }
    Ok(())
}
