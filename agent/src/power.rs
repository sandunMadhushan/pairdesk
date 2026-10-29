// SPDX-License-Identifier: GPL-3.0-or-later
//! Lock, sleep, screen off, sign out, restart and shut down.
//!
//! None of these need administrator rights: they act on the signed-in
//! user's own session, the way the Start menu does.
//!
//! Set `PAIRDESK_POWER_DRY_RUN=1` to log actions instead of doing them
//! (used by the end-to-end tests).

use crate::protocol::PowerAction;

pub fn run(action: PowerAction) -> Result<(), String> {
    if std::env::var_os("PAIRDESK_POWER_DRY_RUN").is_some() {
        log::info!("power action {action:?} (dry run, not performed)");
        return Ok(());
    }
    log::info!("power action {action:?}");
    platform::run(action)
}

/// Runs a program and waits for it; Ok if it exits successfully.
#[allow(dead_code)]
fn command(program: &str, args: &[&str]) -> Result<(), String> {
    let mut cmd = crate::install::host_command(program);
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    match cmd.status() {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("{program} failed ({s})")),
        Err(e) => Err(format!("{program}: {e}")),
    }
}

/// Tries each command in turn until one works.
#[allow(dead_code)]
fn first_working(options: &[(&str, &[&str])]) -> Result<(), String> {
    let mut errors = Vec::new();
    for (program, args) in options {
        match command(program, args) {
            Ok(()) => return Ok(()),
            Err(e) => errors.push(e),
        }
    }
    Err(errors.join("; "))
}

#[cfg(windows)]
mod platform {
    use super::*;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, LUID};
    use windows_sys::Win32::Security::{
        AdjustTokenPrivileges, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW, SE_PRIVILEGE_ENABLED,
        TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES, TOKEN_QUERY,
    };
    use windows_sys::Win32::System::Power::SetSuspendState;
    use windows_sys::Win32::System::Shutdown::LockWorkStation;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        HWND_BROADCAST, PostMessageW, SC_MONITORPOWER, WM_SYSCOMMAND,
    };

    pub fn run(action: PowerAction) -> Result<(), String> {
        match action {
            PowerAction::Lock => {
                if unsafe { LockWorkStation() } == 0 {
                    return Err("Windows refused to lock".into());
                }
                Ok(())
            }
            PowerAction::ScreenOff => {
                // 2 = power off. Posted, so a hung window can't block us.
                unsafe { PostMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER as usize, 2) };
                Ok(())
            }
            PowerAction::Sleep => {
                enable_shutdown_privilege();
                // (hibernate = false, force = false, disable wake events = false)
                if unsafe { SetSuspendState(0, 0, 0) } == 0 {
                    return Err("Windows refused to sleep".into());
                }
                Ok(())
            }
            PowerAction::SignOut => command("shutdown.exe", &["/l"]),
            PowerAction::Restart => command("shutdown.exe", &["/r", "/t", "0"]),
            PowerAction::ShutDown => command("shutdown.exe", &["/s", "/t", "0"]),
        }
    }

    /// Sleep needs SeShutdownPrivilege switched on in our own token. Normal
    /// users have it; it's just off by default.
    fn enable_shutdown_privilege() {
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                &mut token,
            ) == 0
            {
                return;
            }
            let name: Vec<u16> = "SeShutdownPrivilege\0".encode_utf16().collect();
            let mut luid = LUID {
                LowPart: 0,
                HighPart: 0,
            };
            if LookupPrivilegeValueW(std::ptr::null(), name.as_ptr(), &mut luid) != 0 {
                let privileges = TOKEN_PRIVILEGES {
                    PrivilegeCount: 1,
                    Privileges: [LUID_AND_ATTRIBUTES {
                        Luid: luid,
                        Attributes: SE_PRIVILEGE_ENABLED,
                    }],
                };
                AdjustTokenPrivileges(
                    token,
                    0,
                    &privileges,
                    0,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                );
            }
            CloseHandle(token);
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use super::*;

    pub fn run(action: PowerAction) -> Result<(), String> {
        let session = std::env::var("XDG_SESSION_ID").unwrap_or_default();
        match action {
            PowerAction::Lock => first_working(&[
                ("loginctl", &["lock-session"]),
                ("xdg-screensaver", &["lock"]),
                ("dm-tool", &["lock"]),
                ("gnome-screensaver-command", &["--lock"]),
            ]),
            // GNOME (X11 or Wayland), KDE Plasma (Wayland), then any X11.
            PowerAction::ScreenOff => first_working(&[
                (
                    "busctl",
                    &[
                        "--user",
                        "set-property",
                        "org.gnome.Mutter.DisplayConfig",
                        "/org/gnome/Mutter/DisplayConfig",
                        "org.gnome.Mutter.DisplayConfig",
                        "PowerSaveMode",
                        "i",
                        "1",
                    ],
                ),
                ("kscreen-doctor", &["--dpms", "off"]),
                ("xset", &["dpms", "force", "off"]),
            ]),
            PowerAction::Sleep => command("systemctl", &["suspend"]),
            PowerAction::SignOut => {
                let mut options: Vec<(&str, &[&str])> = Vec::new();
                let terminate = ["terminate-session", session.as_str()];
                if !session.is_empty() {
                    options.push(("loginctl", &terminate));
                }
                options.extend_from_slice(&[
                    ("gnome-session-quit", &["--logout", "--no-prompt"][..]),
                    ("xfce4-session-logout", &["--logout"][..]),
                    (
                        "qdbus",
                        &["org.kde.ksmserver", "/KSMServer", "logout", "0", "0", "0"][..],
                    ),
                ]);
                first_working(&options)
            }
            PowerAction::Restart => command("systemctl", &["reboot"]),
            PowerAction::ShutDown => command("systemctl", &["poweroff"]),
        }
    }
}
