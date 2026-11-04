// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows: control at the sign-in screen and on administrator (UAC) prompts.
//!
//! Windows shows the lock screen, the sign-in screen and UAC prompts on the
//! "secure desktop", which only SYSTEM can see or control. PairDesk runs as
//! the signed-in user, so on its own it can't. The optional *PairDesk helper*
//! service fixes that (turned on from the settings page, with one
//! administrator prompt):
//!
//! - `--install-service` (elevated) copies PairDesk to Program Files, where
//!   only administrators can change it, and registers the service.
//! - `--service` (the service, SYSTEM) keeps one `--session-helper` running
//!   as SYSTEM in the session at the screen, mirrors the signed-in user's
//!   pairing (identity, paired phones, settings) into a protected folder,
//!   and keeps itself up to date (signed updates, like the agent).
//! - `--session-helper` (SYSTEM, in the user's session) serves the bridge
//!   (`bridge.rs`): while the secure desktop is up, PairDesk sends input and
//!   reads the screen through it. When nobody is signed in it runs
//!   `--system-mode`: PairDesk's phone server with the mirrored pairing, so
//!   the phone works at the sign-in screen after a restart. It stops that as
//!   soon as someone signs in and their own PairDesk starts.
//!
//! The folder `%ProgramData%\PairDesk` is readable by SYSTEM and
//! administrators only; each bridge endpoint file there is also readable by
//! the user of its session.

// Used by the Windows helper; elsewhere only by tests.
#![cfg_attr(not(windows), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

#[cfg(windows)]
pub mod acl;
#[cfg(windows)]
pub mod desktop;
#[cfg(windows)]
pub mod firewall;
#[cfg(windows)]
pub mod helper;
#[cfg(windows)]
pub mod service;
#[cfg(windows)]
pub mod session;

/// Service name in the Windows service manager.
pub const SERVICE_NAME: &str = "PairDesk";

/// The pairing files the sign-in screen needs, copied from the user's
/// PairDesk folder.
pub const MIRRORED: [&str; 4] = [
    "identity-cert.der",
    "identity-key.der",
    "paired-phones.json",
    "settings.json",
];

static SYSTEM_MODE: AtomicBool = AtomicBool::new(false);
static BRIDGE: OnceLock<Arc<crate::bridge::Client>> = OnceLock::new();

/// This process runs as SYSTEM (helper or sign-in-screen server): input and
/// capture follow the input desktop themselves.
pub fn set_system_mode() {
    SYSTEM_MODE.store(true, Ordering::Relaxed);
}

pub fn is_system_mode() -> bool {
    SYSTEM_MODE.load(Ordering::Relaxed)
}

/// The helper of this session, when the service is installed.
pub fn bridge() -> Option<&'static Arc<crate::bridge::Client>> {
    BRIDGE.get()
}

pub fn set_bridge(c: Arc<crate::bridge::Client>) {
    let _ = BRIDGE.set(c);
}

/// The helper of this session is running and lets us in (its endpoint
/// file is readable).
#[cfg(windows)]
pub fn helper_available() -> bool {
    session::current_session()
        .and_then(|s| read_endpoint(&endpoint_file(&service::program_data(), s)))
        .is_some()
}

/// What the settings page shows, and the last on/off attempt's error.
static WORKING: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
static LAST_ERROR: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// For the settings page: `null` off Windows.
pub fn settings_state() -> serde_json::Value {
    #[cfg(windows)]
    {
        // Store apps may not install services.
        if crate::install::current() == crate::install::Kind::Store {
            return serde_json::Value::Null;
        }
        serde_json::json!({
            "state": service::state().label(),
            "helper": helper_available(),
            "working": WORKING.lock().unwrap().clone(),
            "error": LAST_ERROR.lock().unwrap().clone(),
        })
    }
    #[cfg(not(windows))]
    {
        serde_json::Value::Null
    }
}

/// Turns the helper on or off: asks Windows for administrator rights (the
/// owner sees a prompt) and runs `--install-service` / `--uninstall-service`.
/// Returns at once; the settings page follows the state.
pub fn set_enabled(on: bool) {
    let mut working = WORKING.lock().unwrap();
    if working.is_some() {
        return;
    }
    *working = Some(if on { "on" } else { "off" }.into());
    *LAST_ERROR.lock().unwrap() = None;
    std::thread::spawn(move || {
        #[cfg(windows)]
        let result = service::run_elevated(if on {
            "--install-service"
        } else {
            "--uninstall-service"
        });
        #[cfg(not(windows))]
        let result: Result<(), String> = Err("only on Windows".into());
        if let Err(e) = result {
            log::warn!("helper service: {e}");
            *LAST_ERROR.lock().unwrap() = Some(e);
        }
        *WORKING.lock().unwrap() = None;
    });
}

/// `%ProgramData%\PairDesk` (`base`) layout.
pub fn system_data_dir(base: &Path) -> PathBuf {
    base.join("system")
}

pub fn endpoint_file(base: &Path, session: u32) -> PathBuf {
    base.join("bridge").join(format!("session-{session}.json"))
}

/// Copies the pairing files that changed from `from` to `to`. Returns
/// whether anything was copied. Files missing in `from` are left alone in
/// `to` (a half-written state is never mirrored: each copy is atomic).
pub fn mirror(from: &Path, to: &Path) -> std::io::Result<bool> {
    std::fs::create_dir_all(to)?;
    let mut changed = false;
    for name in MIRRORED {
        let Ok(bytes) = std::fs::read(from.join(name)) else {
            continue;
        };
        let dest = to.join(name);
        if std::fs::read(&dest).is_ok_and(|old| old == bytes) {
            continue;
        }
        crate::config::write_atomic(&dest, &bytes)?;
        changed = true;
    }
    Ok(changed)
}

/// Reads a helper's endpoint file.
pub fn read_endpoint(path: &Path) -> Option<crate::bridge::Endpoint> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mirrors_only_pairing_files_and_only_changes() {
        let user = tempfile::tempdir().unwrap();
        let sys = tempfile::tempdir().unwrap();
        let to = system_data_dir(sys.path());
        std::fs::write(user.path().join("identity-key.der"), b"key").unwrap();
        std::fs::write(user.path().join("paired-phones.json"), b"[1]").unwrap();
        std::fs::write(user.path().join("agent.log"), b"not this").unwrap();
        assert!(mirror(user.path(), &to).unwrap());
        assert_eq!(std::fs::read(to.join("identity-key.der")).unwrap(), b"key");
        assert!(!to.join("agent.log").exists());
        assert!(!mirror(user.path(), &to).unwrap(), "nothing changed");
        std::fs::write(user.path().join("paired-phones.json"), b"[1,2]").unwrap();
        assert!(mirror(user.path(), &to).unwrap());
        assert_eq!(
            std::fs::read(to.join("paired-phones.json")).unwrap(),
            b"[1,2]"
        );
        // A phone removed by the user stays removed; a file deleted in the
        // user folder is kept (the agent rewrites files, never deletes them).
        std::fs::remove_file(user.path().join("identity-key.der")).unwrap();
        assert!(!mirror(user.path(), &to).unwrap());
        assert!(to.join("identity-key.der").exists());
    }

    #[test]
    fn endpoint_files_round_trip() {
        let d = tempfile::tempdir().unwrap();
        let path = endpoint_file(d.path(), 3);
        assert!(
            path.ends_with("bridge/session-3.json") || path.ends_with("bridge\\session-3.json")
        );
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let ep = crate::bridge::Endpoint {
            port: 5000,
            token: "t".into(),
        };
        std::fs::write(&path, serde_json::to_vec(&ep).unwrap()).unwrap();
        assert_eq!(read_endpoint(&path), Some(ep));
        assert_eq!(read_endpoint(&d.path().join("nope")), None);
    }
}
