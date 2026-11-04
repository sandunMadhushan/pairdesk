// SPDX-License-Identifier: GPL-3.0-or-later
//! State shared by the phone server, the settings page and the tray.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use tokio::sync::watch;

use crate::apps::Catalogue;
use crate::identity::Identity;
use crate::pairing::{PairingCode, PairingLink};
use crate::prefs::PrefsStore;
use crate::store::PhoneStore;

/// A phone that is connected right now.
#[derive(Clone, Debug)]
pub struct Session {
    pub phone_id: String,
    pub address: String,
    /// Reaches the connection (to send it a file).
    pub cmd: tokio::sync::mpsc::UnboundedSender<SessionCmd>,
}

/// Work for one phone connection, from the settings page or `--send`.
#[derive(Debug)]
pub enum SessionCmd {
    SendFile(std::sync::Arc<crate::files::Outbound>),
    /// Tell the phone the computer's addresses changed.
    Addrs(Vec<String>),
}

impl std::fmt::Debug for crate::files::Outbound {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Outbound({})", self.path.display())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferState {
    Waiting,
    Active,
    Done,
    Failed,
}

/// A file going to or coming from a phone, for the settings page.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Transfer {
    pub id: u64,
    /// The phone's name.
    pub phone: String,
    /// From the phone to this computer.
    pub incoming: bool,
    pub name: String,
    pub size: u64,
    pub done: u64,
    pub state: TransferState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub msg: Option<String>,
    /// Where a received file was saved.
    #[serde(skip)]
    pub path: Option<std::path::PathBuf>,
}

/// Transfers kept in the list.
const MAX_TRANSFERS: usize = 30;

pub struct PairingLinks {
    /// `pairdesk://pair?…`, shown as the QR code.
    pub qr: String,
    /// `https://…/p#…`, to send in a message.
    pub share: String,
    pub remaining: Duration,
    pub help: bool,
    /// The link includes a relay, so it works from anywhere.
    pub relay: bool,
}

/// A phone watching the screen.
pub struct ScreenViewer {
    pub phone_id: String,
    pub stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    pub notify: tokio::sync::mpsc::UnboundedSender<crate::protocol::ServerMsg>,
}

/// A phone listening to the computer's sound or microphone.
pub struct AudioListener {
    pub phone_id: String,
    pub sound: bool,
    pub mic: bool,
    pub stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    pub notify: tokio::sync::mpsc::UnboundedSender<crate::protocol::ServerMsg>,
}

pub struct AppState {
    pub identity: Identity,
    pub name: String,
    pub port: u16,
    phones: Mutex<PhoneStore>,
    pairing: Mutex<Option<PairingCode>>,
    sessions: Mutex<HashMap<u64, Session>>,
    next_session: AtomicU64,
    /// Bumped whenever a phone is removed, so its open connection closes.
    revocations: watch::Sender<u64>,
    prefs: Mutex<PrefsStore>,
    pub apps: Catalogue,
    pub tailscale: crate::tailscale::Cache,
    /// Reaching this computer through a relay.
    pub relay: crate::relay::Shared,
    /// Phones watching the screen, by session.
    viewers: Mutex<HashMap<u64, ScreenViewer>>,
    viewers_changed: watch::Sender<usize>,
    /// Phones listening, by session (also signalled on `viewers_changed`).
    listeners: Mutex<HashMap<u64, AudioListener>>,
    pub awake: crate::awake::KeepAwake,
    /// Messages for every connected phone (e.g. "approve on the computer").
    pub notices: tokio::sync::broadcast::Sender<String>,
    transfers: Mutex<Vec<Transfer>>,
    next_transfer: AtomicU64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panic while holding a lock must not take the whole agent down.
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl AppState {
    pub fn new(
        identity: Identity,
        phones: PhoneStore,
        prefs: PrefsStore,
        name: String,
        port: u16,
    ) -> Self {
        Self {
            identity,
            name,
            port,
            phones: Mutex::new(phones),
            pairing: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            next_session: AtomicU64::new(1),
            revocations: watch::channel(0).0,
            prefs: Mutex::new(prefs),
            apps: Catalogue::default(),
            tailscale: Default::default(),
            relay: Default::default(),
            viewers: Mutex::new(HashMap::new()),
            viewers_changed: watch::channel(0).0,
            listeners: Mutex::new(HashMap::new()),
            awake: Default::default(),
            notices: tokio::sync::broadcast::channel(8).0,
            transfers: Mutex::new(Vec::new()),
            next_transfer: AtomicU64::new(1),
        }
    }

    /// The owner's permissions and shortcuts.
    pub fn prefs(&self) -> MutexGuard<'_, PrefsStore> {
        lock(&self.prefs)
    }

    // ---- paired phones ----

    pub fn phones(&self) -> MutexGuard<'_, PhoneStore> {
        lock(&self.phones)
    }

    pub fn is_paired(&self, id: &str) -> bool {
        self.phones().is_paired(id)
    }

    /// Saves a newly paired phone; `help`: paired with a "Get help" code
    /// (temporary, limited access).
    pub fn add_phone(&self, id: &str, name: &str, help: bool) -> io::Result<()> {
        let until =
            help.then(|| crate::config::unix_now() + crate::pairing::HELP_LIFETIME.as_secs());
        self.phones().add(id, name, until)?;
        Ok(())
    }

    /// True for a phone that is only helping (temporary access).
    pub fn is_helper(&self, id: &str) -> bool {
        self.phones()
            .get(id)
            .is_some_and(|p| p.help_until.is_some())
    }

    /// What this phone may do: the owner's switches, and for a helper,
    /// only seeing and using the screen (pointer, keyboard, clipboard and
    /// apps): no power actions, files or sound.
    pub fn allow_for(&self, phone_id: &str) -> crate::protocol::Allow {
        let mut allow = self.prefs().get().allow();
        if self.is_helper(phone_id) {
            allow.power = false;
            allow.session = false;
            allow.files = false;
            allow.audio = false;
            allow.mic = false;
        }
        allow
    }

    /// Ends helpers' access when its time is up, or 5 minutes after they
    /// left. Returns the names removed.
    pub fn sweep_helpers(&self) -> Vec<String> {
        let now = crate::config::unix_now();
        let connected: Vec<String> = self.sessions().iter().map(|s| s.phone_id.clone()).collect();
        let expired: Vec<(String, String)> = self
            .phones()
            .list()
            .iter()
            .filter(|p| {
                p.help_until.is_some_and(|until| {
                    now >= until
                        || (!connected.contains(&p.id)
                            && p.last_seen.is_some_and(|seen| now > seen + 5 * 60))
                })
            })
            .map(|p| (p.id.clone(), p.name.clone()))
            .collect();
        let mut removed = Vec::new();
        for (id, name) in expired {
            if self.remove_phone(&id).unwrap_or(false) {
                removed.push(name);
            }
        }
        removed
    }

    /// Unpairs a phone and disconnects it if it's connected.
    pub fn remove_phone(&self, id: &str) -> io::Result<bool> {
        let removed = self.phones().remove(id)?;
        if removed {
            self.revocations.send_modify(|g| *g += 1);
        }
        Ok(removed)
    }

    pub fn subscribe_revocations(&self) -> watch::Receiver<u64> {
        self.revocations.subscribe()
    }

    // ---- pairing codes ----

    /// Starts a new pairing window, replacing any earlier code.
    pub fn start_pairing(&self) {
        *lock(&self.pairing) = Some(PairingCode::new());
    }

    /// "Get help": a code for someone to help, with temporary access.
    pub fn start_help(&self) {
        *lock(&self.pairing) = Some(PairingCode::for_help());
    }

    /// True if `token` is the current code and it's a "Get help" code.
    pub fn pairing_is_help(&self, token: &str) -> bool {
        lock(&self.pairing)
            .as_ref()
            .is_some_and(|c| c.matches(token) && c.is_help())
    }

    pub fn cancel_pairing(&self) {
        *lock(&self.pairing) = None;
    }

    /// The current pairing link (for the QR code) and how long it stays
    /// valid, if any.
    pub fn pairing_link(&self) -> Option<(String, Duration)> {
        self.pairing_links().map(|l| (l.qr, l.remaining))
    }

    /// The current code as a QR link and a link to send, if any.
    pub fn pairing_links(&self) -> Option<PairingLinks> {
        let guard = lock(&self.pairing);
        let code = guard.as_ref().filter(|c| !c.is_expired())?;
        // Every route the phone could use, so a link scanned away from home
        // (or before Tailscale was running) still carries the Tailscale
        // address and name. The relay goes in its own field.
        let addresses: Vec<String> = self
            .phone_addresses()
            .into_iter()
            .filter(|a| !a.starts_with("relay:"))
            .collect();
        let route = self.relay.route();
        let link = PairingLink {
            name: &self.name,
            fingerprint: self.identity.fingerprint(),
            token: code.token(),
            port: self.port,
            addresses: &addresses,
            relay: route.as_deref(),
            help: code.is_help(),
        };
        Some(PairingLinks {
            qr: link.to_uri(),
            share: link.to_share(),
            remaining: code.remaining(),
            help: code.is_help(),
            relay: route.is_some(),
        })
    }

    /// Every address a phone may use, best first: home network, then
    /// Tailscale addresses, then the Tailscale (MagicDNS) name.
    pub fn phone_addresses(&self) -> Vec<String> {
        let mut out: Vec<String> = crate::net::addresses()
            .into_iter()
            .map(|a| a.ip.to_string())
            .collect();
        if let Some(crate::tailscale::Status::Running { ips, dns_name, .. }) = self.tailscale.peek()
        {
            for ip in ips {
                if !out.contains(&ip) {
                    out.push(ip);
                }
            }
            if let Some(name) = dns_name {
                out.push(name);
            }
        }
        if let Some(route) = self.relay.route() {
            out.push(format!("relay:{route}"));
        }
        out
    }

    /// Tells every connected phone the computer's addresses, so a phone
    /// that connected over Wi-Fi learns the Tailscale address (or relay
    /// route) the moment it appears, without pairing again.
    /// Returns how many phones were told.
    pub fn broadcast_addresses(&self) -> usize {
        let addrs = self.phone_addresses();
        lock(&self.sessions)
            .values()
            .filter(|s| s.cmd.send(SessionCmd::Addrs(addrs.clone())).is_ok())
            .count()
    }

    pub fn pairing_token_valid(&self, token: &str) -> bool {
        lock(&self.pairing)
            .as_ref()
            .is_some_and(|c| c.matches(token))
    }

    /// Uses up the pairing code. Returns false if it was already used,
    /// replaced or expired in the meantime.
    pub fn consume_pairing_token(&self, token: &str) -> bool {
        let mut guard = lock(&self.pairing);
        if guard.as_ref().is_some_and(|c| c.matches(token)) {
            *guard = None;
            true
        } else {
            false
        }
    }

    // ---- connected phones ----

    pub fn open_session(&self, session: Session) -> u64 {
        let id = self.next_session.fetch_add(1, Ordering::Relaxed);
        lock(&self.sessions).insert(id, session);
        id
    }

    pub fn close_session(&self, id: u64) {
        if let Some(s) = lock(&self.sessions).remove(&id) {
            self.phones().touch(&s.phone_id);
        }
    }

    // ---- screen viewers ----

    pub fn add_viewer(&self, session: u64, viewer: ScreenViewer) {
        let mut v = lock(&self.viewers);
        v.insert(session, viewer);
        let n = v.len();
        drop(v);
        self.viewers_changed.send_replace(n);
    }

    pub fn remove_viewer(&self, session: u64) {
        let mut v = lock(&self.viewers);
        if v.remove(&session).is_some() {
            let n = v.len();
            drop(v);
            self.viewers_changed.send_replace(n);
        }
    }

    /// Phone IDs currently watching the screen.
    pub fn viewing_phones(&self) -> Vec<String> {
        lock(&self.viewers)
            .values()
            .map(|v| v.phone_id.clone())
            .collect()
    }

    pub fn subscribe_viewers(&self) -> watch::Receiver<usize> {
        self.viewers_changed.subscribe()
    }

    /// Ends screen view for one phone (or all with `None`), telling it why.
    pub fn stop_viewing(&self, phone_id: Option<&str>) {
        let mut v = lock(&self.viewers);
        v.retain(|_, viewer| {
            if phone_id.is_some_and(|id| id != viewer.phone_id) {
                return true;
            }
            viewer
                .stop
                .store(true, std::sync::atomic::Ordering::Relaxed);
            let _ = viewer
                .notify
                .send(crate::protocol::ServerMsg::ScreenStopped {
                    msg: "Screen view was stopped on the computer.".into(),
                });
            false
        });
        let n = v.len();
        drop(v);
        self.viewers_changed.send_replace(n);
    }

    // ---- audio ----

    pub fn add_listener(&self, session: u64, listener: AudioListener) {
        lock(&self.listeners).insert(session, listener);
        // The count is of viewers; sending marks a change either way.
        self.viewers_changed.send_replace(lock(&self.viewers).len());
    }

    pub fn remove_listener(&self, session: u64) {
        if lock(&self.listeners).remove(&session).is_some() {
            self.viewers_changed.send_replace(lock(&self.viewers).len());
        }
    }

    /// (phone id, hears the sound, hears the microphone) for each listener.
    pub fn listening_phones(&self) -> Vec<(String, bool, bool)> {
        lock(&self.listeners)
            .values()
            .map(|l| (l.phone_id.clone(), l.sound, l.mic))
            .collect()
    }

    /// True while a phone sees the screen or hears the microphone: the
    /// tray shows a red dot.
    pub fn watched(&self) -> bool {
        !lock(&self.viewers).is_empty() || lock(&self.listeners).values().any(|l| l.mic)
    }

    /// Stops listening for one phone (or all), telling it why. With
    /// `mic_only`, only listeners that hear the microphone.
    pub fn stop_listening(&self, phone_id: Option<&str>, mic_only: bool, why: &str) {
        lock(&self.listeners).retain(|_, l| {
            if phone_id.is_some_and(|id| id != l.phone_id) || (mic_only && !l.mic) {
                return true;
            }
            l.stop.store(true, std::sync::atomic::Ordering::Relaxed);
            let _ = l
                .notify
                .send(crate::protocol::ServerMsg::AudioStopped { msg: why.into() });
            false
        });
        self.viewers_changed.send_replace(lock(&self.viewers).len());
    }

    // ---- files ----

    /// Queues `file` for every connected phone, or the one with id `phone`.
    /// Returns how many phones will get it.
    pub fn send_file(
        &self,
        phone: Option<&str>,
        file: std::sync::Arc<crate::files::Outbound>,
    ) -> usize {
        lock(&self.sessions)
            .values()
            .filter(|s| phone.is_none_or(|p| p == s.phone_id))
            .filter(|s| s.cmd.send(SessionCmd::SendFile(file.clone())).is_ok())
            .count()
    }

    pub fn transfer_start(&self, phone: &str, incoming: bool, name: &str, size: u64) -> u64 {
        let id = self.next_transfer.fetch_add(1, Ordering::Relaxed);
        let mut list = lock(&self.transfers);
        list.push(Transfer {
            id,
            phone: phone.to_string(),
            incoming,
            name: name.to_string(),
            size,
            done: 0,
            state: TransferState::Waiting,
            msg: None,
            path: None,
        });
        // Forget the oldest finished ones.
        while list.len() > MAX_TRANSFERS {
            match list
                .iter()
                .position(|t| matches!(t.state, TransferState::Done | TransferState::Failed))
            {
                Some(i) => {
                    list.remove(i);
                }
                None => break,
            }
        }
        id
    }

    pub fn transfer_progress(&self, id: u64, done: u64) {
        if let Some(t) = lock(&self.transfers).iter_mut().find(|t| t.id == id) {
            t.done = done.min(t.size);
            t.state = TransferState::Active;
        }
    }

    /// `Ok(path)`: done (received files have a path); `Err`: why it failed.
    pub fn transfer_end(&self, id: u64, result: Result<Option<std::path::PathBuf>, String>) {
        if let Some(t) = lock(&self.transfers).iter_mut().find(|t| t.id == id) {
            match result {
                Ok(path) => {
                    t.state = TransferState::Done;
                    t.done = t.size;
                    if let Some(p) = &path
                        && let Some(n) = p.file_name()
                    {
                        t.name = n.to_string_lossy().into_owned();
                    }
                    t.path = path;
                }
                Err(msg) => {
                    t.state = TransferState::Failed;
                    t.msg = Some(msg);
                }
            }
        }
    }

    /// Newest first.
    pub fn transfers(&self) -> Vec<Transfer> {
        let mut list = lock(&self.transfers).clone();
        list.reverse();
        list
    }

    pub fn transfer_path(&self, id: u64) -> Option<std::path::PathBuf> {
        lock(&self.transfers)
            .iter()
            .find(|t| t.id == id)?
            .path
            .clone()
    }

    pub fn sessions(&self) -> Vec<Session> {
        lock(&self.sessions).values().cloned().collect()
    }
}
