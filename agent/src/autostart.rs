// SPDX-License-Identifier: GPL-3.0-or-later
//! Starting PairDesk when the user signs in.
//!
//! Windows: a value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
//! Linux: `~/.config/autostart/PairDesk.desktop`.
//! Neither needs administrator rights.

use std::path::Path;

use auto_launch::{AutoLaunch, AutoLaunchBuilder};

/// Marker file: auto-start has been switched on once, so a user who later
/// turns it off isn't overridden.
const INITIALIZED: &str = "autostart-initialized";

fn launcher() -> Result<AutoLaunch, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let exe = exe.to_str().ok_or("the program path isn't valid text")?;
    AutoLaunchBuilder::new()
        .set_app_name("PairDesk")
        .set_app_path(exe)
        .set_args(&["--background"])
        .build()
        .map_err(|e| e.to_string())
}

pub fn is_enabled() -> bool {
    launcher()
        .and_then(|l| l.is_enabled().map_err(|e| e.to_string()))
        .unwrap_or(false)
}

pub fn set_enabled(enabled: bool) -> Result<(), String> {
    let l = launcher()?;
    if enabled {
        l.enable().map_err(|e| e.to_string())
    } else {
        l.disable().map_err(|e| e.to_string())
    }
}

/// Turns auto-start on the first time PairDesk runs, so the computer is
/// reachable after every restart without the user doing anything.
pub fn enable_on_first_run(data_dir: &Path) {
    let marker = data_dir.join(INITIALIZED);
    if marker.exists() {
        return;
    }
    match set_enabled(true) {
        Ok(()) => {
            log::info!("PairDesk will start when you sign in (change this in settings)");
            let _ = std::fs::write(&marker, b"1");
        }
        Err(e) => log::warn!("could not turn on start at sign-in: {e}"),
    }
}
