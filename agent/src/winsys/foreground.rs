// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows blocks input from a normal program to a window of a program with
//! more rights (User Interface Privilege Isolation): an app run as
//! administrator, Task Manager, or the "Windows Security" box that asks for
//! the PIN before Edge shows passwords. While such a window is in front,
//! every pointer move and key from PairDesk is dropped without an error, so
//! the pointer seems stuck. PairDesk then sends input through the SYSTEM
//! helper instead, which those windows accept.

use std::cell::Cell;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::Security::{
    GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TOKEN_MANDATORY_LABEL,
    TOKEN_QUERY, TokenIntegrityLevel, TokenUIAccess,
};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

/// What we know about a process's rights.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Rights {
    integrity: u32,
    ui_access: bool,
}

fn token_rights(token: HANDLE) -> Option<Rights> {
    let mut buf = [0u8; 128];
    let mut len = 0u32;
    // SAFETY: the buffer is large enough for a TOKEN_MANDATORY_LABEL and its SID.
    let ok = unsafe {
        GetTokenInformation(
            token,
            TokenIntegrityLevel,
            buf.as_mut_ptr().cast(),
            buf.len() as u32,
            &mut len,
        )
    };
    if ok == 0 {
        return None;
    }
    // SAFETY: filled in by GetTokenInformation above.
    let integrity = unsafe {
        let label = &*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
        let sid = label.Label.Sid;
        let count = *GetSidSubAuthorityCount(sid);
        if count == 0 {
            return None;
        }
        *GetSidSubAuthority(sid, u32::from(count) - 1)
    };
    let mut ui: u32 = 0;
    // SAFETY: TokenUIAccess is a DWORD.
    let ok = unsafe {
        GetTokenInformation(
            token,
            TokenUIAccess,
            (&mut ui as *mut u32).cast(),
            4,
            &mut len,
        )
    };
    Some(Rights {
        integrity,
        ui_access: ok != 0 && ui != 0,
    })
}

fn process_rights(pid: u32) -> Option<Rights> {
    // SAFETY: plain Win32 calls; handles closed below.
    unsafe {
        let process = if pid == 0 {
            GetCurrentProcess()
        } else {
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        };
        if process.is_null() {
            return None;
        }
        let mut token: HANDLE = std::ptr::null_mut();
        let opened = OpenProcessToken(process, TOKEN_QUERY, &mut token) != 0;
        if pid != 0 {
            CloseHandle(process);
        }
        if !opened {
            return None;
        }
        let r = token_rights(token);
        CloseHandle(token);
        r
    }
}

/// Programs that show Windows' own credential prompts (the PIN or password
/// box of "Windows Security", the sign-in UI). The helper may type into
/// these even on the normal desktop; see `helper.rs`.
const CREDENTIAL_UI: &[&str] = &["credentialuibroker.exe", "logonui.exe", "consent.exe"];

/// File name (lower case) of the program that owns the window in front.
pub fn foreground_exe() -> Option<String> {
    // SAFETY: plain Win32 calls; the handle is closed below.
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_null() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        if pid == 0 {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buf = [0u16; 520];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, buf.as_mut_ptr(), &mut len);
        CloseHandle(process);
        if ok == 0 {
            return None;
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        path.rsplit(['\\', '/']).next().map(str::to_ascii_lowercase)
    }
}

/// True when the window in front is a Windows credential prompt.
pub fn credential_prompt_in_front() -> bool {
    foreground_exe().is_some_and(|n| CREDENTIAL_UI.contains(&n.as_str()))
}

/// True when the window in front belongs to a program Windows won't let us
/// send input to.
fn check() -> bool {
    if credential_prompt_in_front() {
        return true;
    }
    // SAFETY: plain Win32 calls.
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.is_null() {
        return false;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    if pid == 0 || pid == std::process::id() {
        return false;
    }
    let Some(me) = process_rights(0) else {
        return false;
    };
    match process_rights(pid) {
        Some(them) => blocked(me, them),
        // A program we may not even look at (SYSTEM, protected): it runs with
        // more rights than us.
        None => true,
    }
}

fn blocked(me: Rights, them: Rights) -> bool {
    them.integrity > me.integrity || (them.ui_access && !me.ui_access)
}

thread_local! {
    static LAST: Cell<Option<(Instant, bool)>> = const { Cell::new(None) };
}

/// Like [`check`], remembered for a moment: pointer moves arrive many times
/// a second.
pub fn needs_helper() -> bool {
    if std::env::var_os("PAIRDESK_TEST_ELEVATED_WINDOW").is_some() {
        return true;
    }
    LAST.with(|last| {
        if let Some((at, v)) = last.get()
            && at.elapsed() < Duration::from_millis(250)
        {
            return v;
        }
        let v = check();
        if last.get().map(|(_, before)| before) != Some(v) {
            log::info!(
                "input {} the helper (window in front: {})",
                if v { "goes through" } else { "no longer needs" },
                foreground_exe().unwrap_or_else(|| "unknown".into())
            );
        }
        last.set(Some((Instant::now(), v)));
        v
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const MEDIUM: u32 = 0x2000;
    const HIGH: u32 = 0x3000;

    #[test]
    fn credential_prompt_programs_are_listed_in_lower_case() {
        assert!(CREDENTIAL_UI.contains(&"credentialuibroker.exe"));
        assert!(CREDENTIAL_UI.iter().all(|n| *n == n.to_ascii_lowercase()));
    }

    #[test]
    fn higher_rights_or_ui_access_block_input() {
        let me = Rights {
            integrity: MEDIUM,
            ui_access: false,
        };
        assert!(!blocked(
            me,
            Rights {
                integrity: MEDIUM,
                ui_access: false
            }
        ));
        assert!(blocked(
            me,
            Rights {
                integrity: HIGH,
                ui_access: false
            }
        ));
        assert!(blocked(
            me,
            Rights {
                integrity: MEDIUM,
                ui_access: true
            }
        ));
        let admin = Rights {
            integrity: HIGH,
            ui_access: false,
        };
        assert!(!blocked(
            admin,
            Rights {
                integrity: MEDIUM,
                ui_access: false
            }
        ));
    }
}
