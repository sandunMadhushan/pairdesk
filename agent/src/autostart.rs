// SPDX-License-Identifier: GPL-3.0-or-later
//! Starting PairDesk when the user signs in.
//!
//! Windows: a value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
//! Linux: `~/.config/autostart/PairDesk.desktop`.
//! Neither needs administrator rights.
//!
//! Microsoft Store copy: a startup task in the package manifest, which the
//! owner turns on and off in Windows (Settings → Apps → Startup).
//! Flatpak: the Background portal, which writes the autostart entry for us.

use std::path::Path;

use auto_launch::{AutoLaunch, AutoLaunchBuilder};

/// Marker file: auto-start has been switched on once, so a user who later
/// turns it off isn't overridden.
const INITIALIZED: &str = "autostart-initialized";

fn launcher() -> Result<AutoLaunch, String> {
    let exe = crate::install::program_path().map_err(|e| e.to_string())?;
    let exe = exe.to_str().ok_or("the program path isn't valid text")?;
    AutoLaunchBuilder::new()
        .set_app_name("PairDesk")
        .set_app_path(&quoted(exe))
        .set_args(&["--background"])
        .build()
        .map_err(|e| e.to_string())
}

/// The entry is a command line (Windows `Run` value, Linux `Exec=`), so a
/// path with spaces ("C:\\Users\\Jane Doe\\…") must be quoted.
fn quoted(exe: &str) -> String {
    if cfg!(windows) {
        format!("\"{exe}\"")
    } else if exe.contains(|c: char| c.is_whitespace() || "\"'\\`$".contains(c)) {
        // Desktop Entry quoting: inside quotes, escape " ` $ and \.
        let mut s = String::from("\"");
        for c in exe.chars() {
            if "\"`$\\".contains(c) {
                s.push('\\');
            }
            s.push(c);
        }
        s.push('"');
        // A literal backslash in a .desktop value is itself written as \\.
        s.replace('\\', "\\\\")
    } else {
        exe.to_string()
    }
}

/// Who manages start at sign-in when it isn't PairDesk: "windows" for the
/// Microsoft Store copy.
pub fn managed_by() -> Option<&'static str> {
    (crate::install::current() == crate::install::Kind::Store).then_some("windows")
}

pub fn is_enabled() -> bool {
    if managed_by().is_some() {
        return true;
    }
    #[cfg(target_os = "linux")]
    if crate::install::current() == crate::install::Kind::Flatpak {
        return flatpak::is_enabled();
    }
    launcher()
        .and_then(|l| l.is_enabled().map_err(|e| e.to_string()))
        .unwrap_or(false)
}

pub fn set_enabled(enabled: bool) -> Result<(), String> {
    if managed_by().is_some() {
        return Err("Windows manages this: Settings → Apps → Startup → PairDesk.".into());
    }
    #[cfg(target_os = "linux")]
    if crate::install::current() == crate::install::Kind::Flatpak {
        return flatpak::set_enabled(enabled);
    }
    let l = launcher()?;
    // The library creates only the last folder of ~/.config/autostart.
    #[cfg(target_os = "linux")]
    if enabled && let Some(home) = std::env::var_os("HOME") {
        let _ = std::fs::create_dir_all(Path::new(&home).join(".config").join("autostart"));
    }
    if enabled {
        l.enable().map_err(|e| e.to_string())
    } else {
        l.disable().map_err(|e| e.to_string())
    }
}

/// If start-at-sign-in is on, makes it start this program file. After a
/// download of a new release it would otherwise keep starting the old one.
pub fn refresh() {
    if managed_by().is_some() {
        return;
    }
    if is_enabled()
        && let Err(e) = set_enabled(true)
    {
        log::warn!("could not update start at sign-in: {e}");
    }
}

/// Turns auto-start on the first time PairDesk runs, so the computer is
/// reachable after every restart without the user doing anything.
pub fn enable_on_first_run(data_dir: &Path) {
    let marker = data_dir.join(INITIALIZED);
    if marker.exists() || managed_by().is_some() {
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

/// Flatpak: the sandbox can't write ~/.config/autostart; the Background
/// portal does it (and may ask the owner). The portal can't be asked what
/// it did, so the last choice is remembered in the data folder.
#[cfg(target_os = "linux")]
mod flatpak {
    use std::collections::HashMap;

    use zbus::zvariant::Value;

    const MARKER: &str = "autostart-flatpak";

    pub fn is_enabled() -> bool {
        crate::config::data_dir()
            .ok()
            .and_then(|d| std::fs::read_to_string(d.join(MARKER)).ok())
            .is_some_and(|v| v.trim() == "1")
    }

    pub fn set_enabled(enabled: bool) -> Result<(), String> {
        let conn = zbus::blocking::Connection::session().map_err(|e| e.to_string())?;
        let mut options: HashMap<&str, Value> = HashMap::new();
        options.insert(
            "reason",
            Value::from("Start PairDesk when you sign in, so your phone can reach this computer"),
        );
        options.insert("autostart", Value::from(enabled));
        options.insert(
            "commandline",
            Value::from(vec![
                "pairdesk-agent".to_string(),
                "--background".to_string(),
            ]),
        );
        conn.call_method(
            Some("org.freedesktop.portal.Desktop"),
            "/org/freedesktop/portal/desktop",
            Some("org.freedesktop.portal.Background"),
            "RequestBackground",
            &("", options),
        )
        .map_err(|e| format!("the Background portal refused: {e}"))?;
        let dir = crate::config::data_dir().map_err(|e| e.to_string())?;
        std::fs::write(dir.join(MARKER), if enabled { "1" } else { "0" }).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::quoted;

    #[test]
    #[cfg(windows)]
    fn quotes_the_windows_path() {
        assert_eq!(
            quoted(r"C:\Users\Jane Doe\pairdesk-agent.exe"),
            r#""C:\Users\Jane Doe\pairdesk-agent.exe""#
        );
    }

    #[test]
    #[cfg(not(windows))]
    fn quotes_desktop_entry_paths_only_when_needed() {
        assert_eq!(quoted("/opt/pairdesk/agent"), "/opt/pairdesk/agent");
        assert_eq!(
            quoted("/home/jane/My Apps/agent"),
            "\"/home/jane/My Apps/agent\""
        );
        assert_eq!(quoted("/tmp/a$b"), "\"/tmp/a\\\\$b\"");
    }
}
