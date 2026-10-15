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
}

/// A phone watching the screen.
pub struct ScreenViewer {
    pub phone_id: String,
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
    /// Phones watching the screen, by session.
    viewers: Mutex<HashMap<u64, ScreenViewer>>,
    viewers_changed: watch::Sender<usize>,
    pub awake: crate::awake::KeepAwake,
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
            viewers: Mutex::new(HashMap::new()),
            viewers_changed: watch::channel(0).0,
            awake: Default::default(),
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

    pub fn add_phone(&self, id: &str, name: &str) -> io::Result<()> {
        self.phones().add(id, name)?;
        Ok(())
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

    pub fn cancel_pairing(&self) {
        *lock(&self.pairing) = None;
    }

    /// The current pairing link and how long it stays valid, if any.
    pub fn pairing_link(&self) -> Option<(String, Duration)> {
        let guard = lock(&self.pairing);
        let code = guard.as_ref().filter(|c| !c.is_expired())?;
        let addresses: Vec<_> = crate::net::addresses().into_iter().map(|a| a.ip).collect();
        let uri = PairingLink {
            name: &self.name,
            fingerprint: self.identity.fingerprint(),
            token: code.token(),
            port: self.port,
            addresses: &addresses,
        }
        .to_uri();
        Some((uri, code.remaining()))
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
        out
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

    pub fn sessions(&self) -> Vec<Session> {
        lock(&self.sessions).values().cloned().collect()
    }
}
