// SPDX-License-Identifier: GPL-3.0-or-later
//! How this copy of PairDesk was installed. That decides how it updates
//! itself and a few other things (start at sign-in, the Send To menu).

use std::path::{Path, PathBuf};

/// Name of the uninstaller the Windows setup puts next to the program.
pub const WINDOWS_UNINSTALLER: &str = "Uninstall PairDesk.exe";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    /// Windows setup (per-user, in %LOCALAPPDATA%\Programs\PairDesk).
    /// Updates by running the new setup.
    WindowsSetup,
    /// Microsoft Store (MSIX). The Store updates it.
    Store,
    /// A program file the user downloaded and runs from anywhere they can
    /// write to. Updates by swapping the file.
    Portable,
    /// Linux AppImage. Updates by swapping the AppImage file.
    AppImage(PathBuf),
    /// Installed by the system package manager (.deb, .rpm) in a folder the
    /// user can't write to. Only tells the user about new releases.
    SystemPackage,
    /// Flatpak (Flathub). Flathub updates it.
    Flatpak,
    /// The Windows helper service's own copy in Program Files. Updates by
    /// swapping the file and letting the service manager restart it.
    #[cfg_attr(not(windows), allow(dead_code))]
    Service,
}

impl Kind {
    /// Short name for the settings page and logs.
    pub fn label(&self) -> &'static str {
        match self {
            Kind::WindowsSetup => "windows-setup",
            Kind::Store => "store",
            Kind::Portable => "portable",
            Kind::AppImage(_) => "appimage",
            Kind::SystemPackage => "package",
            Kind::Flatpak => "flatpak",
            Kind::Service => "service",
        }
    }

    /// Updates come from a store; PairDesk doesn't look for them itself.
    pub fn store_updates(&self) -> bool {
        matches!(self, Kind::Store | Kind::Flatpak)
    }

    /// Where the update manifest lists the file for this kind of install.
    pub fn asset_key(&self) -> Option<&'static str> {
        match self {
            Kind::WindowsSetup => Some("windows-x64-setup"),
            Kind::Portable | Kind::Service if cfg!(windows) => Some("windows-x64"),
            Kind::Portable => Some("linux-x64"),
            Kind::AppImage(_) => Some("linux-x64-appimage"),
            Kind::SystemPackage | Kind::Store | Kind::Flatpak | Kind::Service => None,
        }
    }
}

/// This copy's install kind (worked out once).
pub fn current() -> Kind {
    static KIND: std::sync::OnceLock<Kind> = std::sync::OnceLock::new();
    KIND.get_or_init(|| {
        let exe = std::env::current_exe().unwrap_or_default();
        detect(
            &exe,
            |k| std::env::var_os(k).map(PathBuf::from),
            is_store_package(),
        )
    })
    .clone()
}

/// The decision, separated from the environment for tests.
fn detect(exe: &Path, env: impl Fn(&str) -> Option<PathBuf>, packaged: bool) -> Kind {
    if packaged {
        return Kind::Store;
    }
    if env("FLATPAK_ID").is_some() {
        return Kind::Flatpak;
    }
    if let Some(image) = env("APPIMAGE") {
        return Kind::AppImage(image);
    }
    let dir = exe.parent().unwrap_or(Path::new("."));
    if cfg!(windows) {
        if dir.join(WINDOWS_UNINSTALLER).is_file() {
            return Kind::WindowsSetup;
        }
        return Kind::Portable;
    }
    if (dir.starts_with("/usr") || dir.starts_with("/opt")) && !writable(dir) {
        return Kind::SystemPackage;
    }
    Kind::Portable
}

fn writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".pairdesk-probe-{}", std::process::id()));
    match std::fs::File::create(&probe) {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// The file to start PairDesk from (sign-in, the file manager's menu): the
/// AppImage itself when running from one, not its temporary mount.
pub fn program_path() -> std::io::Result<PathBuf> {
    match current() {
        Kind::AppImage(image) => Ok(image),
        _ => std::env::current_exe(),
    }
}

/// A command that runs `program` on this computer. Inside the Flatpak
/// sandbox that means asking the host through `flatpak-spawn --host`
/// (apps, power actions, keeping awake).
pub fn host_command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    if cfg!(target_os = "linux") && current() == Kind::Flatpak {
        let mut cmd = std::process::Command::new("flatpak-spawn");
        cmd.arg("--host").arg(program);
        cmd
    } else {
        std::process::Command::new(program)
    }
}

/// Running from an MSIX package (the Microsoft Store build)?
#[cfg(windows)]
fn is_store_package() -> bool {
    use windows_sys::Win32::Storage::Packaging::Appx::GetCurrentPackageFullName;
    const APPMODEL_ERROR_NO_PACKAGE: i32 = 15700;
    let mut len = 0u32;
    // SAFETY: asking for the length only (null buffer, zero length).
    let rc = unsafe { GetCurrentPackageFullName(&mut len, std::ptr::null_mut()) };
    rc as i32 != APPMODEL_ERROR_NO_PACKAGE
}

#[cfg(not(windows))]
fn is_store_package() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &str) -> Option<PathBuf> {
        None
    }

    #[test]
    fn stores_and_bundles_come_first() {
        let exe = Path::new("/home/jane/pairdesk-agent");
        assert_eq!(detect(exe, none, true), Kind::Store);
        assert_eq!(
            detect(exe, |k| (k == "FLATPAK_ID").then(|| "x".into()), false),
            Kind::Flatpak
        );
        assert_eq!(
            detect(
                exe,
                |k| (k == "APPIMAGE").then(|| "/home/j/P.AppImage".into()),
                false
            ),
            Kind::AppImage("/home/j/P.AppImage".into())
        );
        assert!(Kind::Flatpak.store_updates() && Kind::Store.store_updates());
        assert_eq!(Kind::Flatpak.asset_key(), None);
    }

    #[test]
    fn setup_is_recognised_by_its_uninstaller() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("pairdesk-agent.exe");
        if cfg!(windows) {
            assert_eq!(detect(&exe, none, false), Kind::Portable);
            std::fs::write(dir.path().join(WINDOWS_UNINSTALLER), b"").unwrap();
            assert_eq!(detect(&exe, none, false), Kind::WindowsSetup);
            assert_eq!(Kind::WindowsSetup.asset_key(), Some("windows-x64-setup"));
        } else {
            assert_eq!(detect(&exe, none, false), Kind::Portable);
            assert_eq!(Kind::Portable.asset_key(), Some("linux-x64"));
        }
    }

    #[test]
    #[cfg(unix)]
    fn system_folders_the_user_cannot_write_are_packages() {
        // Root can write anywhere; the rule only matters for normal users.
        if writable(Path::new("/usr/bin")) {
            return;
        }
        assert_eq!(
            detect(Path::new("/usr/bin/pairdesk-agent"), none, false),
            Kind::SystemPackage
        );
    }
}
