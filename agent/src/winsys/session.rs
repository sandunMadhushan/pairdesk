// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows sessions: which one is at the screen, who is signed in to it,
//! and starting SYSTEM processes in it (the service runs in session 0,
//! away from any screen).

use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, LocalFree, WAIT_TIMEOUT};
use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows_sys::Win32::Security::{
    DuplicateTokenEx, GetTokenInformation, SecurityImpersonation, SetTokenInformation,
    TOKEN_ALL_ACCESS, TOKEN_USER, TokenPrimary, TokenSessionId, TokenUser,
};
use windows_sys::Win32::System::RemoteDesktop::{WTSGetActiveConsoleSessionId, WTSQueryUserToken};
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW, GetCurrentProcess,
    GetCurrentProcessId, OpenProcessToken, PROCESS_INFORMATION, STARTUPINFOW, TerminateProcess,
    WaitForSingleObject,
};
use windows_sys::Win32::UI::Shell::{FOLDERID_RoamingAppData, SHGetKnownFolderPath};

fn wide(s: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

/// A Win32 handle closed on drop.
pub struct Handle(pub HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseHandle(self.0) };
        }
    }
}

unsafe impl Send for Handle {}

/// The session at the physical screen, if any.
pub fn active_console_session() -> Option<u32> {
    let id = unsafe { WTSGetActiveConsoleSessionId() };
    (id != u32::MAX).then_some(id)
}

/// This process's session.
pub fn current_session() -> Option<u32> {
    let mut id = 0u32;
    let ok = unsafe {
        windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId(
            GetCurrentProcessId(),
            &mut id,
        )
    };
    (ok != 0).then_some(id)
}

/// The signed-in user's token for `session` (SYSTEM only). `None` when
/// nobody is signed in (the sign-in screen).
pub fn user_token(session: u32) -> Option<Handle> {
    let mut token: HANDLE = std::ptr::null_mut();
    let ok = unsafe { WTSQueryUserToken(session, &mut token) };
    (ok != 0 && !token.is_null()).then(|| Handle(token))
}

/// The token's user as an SID string ("S-1-5-21-…").
pub fn user_sid(token: &Handle) -> Option<String> {
    let mut needed = 0u32;
    unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
    if needed == 0 {
        return None;
    }
    let mut buf = vec![0u8; needed as usize];
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buf.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return None;
    }
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let mut text: windows_sys::core::PWSTR = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut text) } == 0 {
        return None;
    }
    let s = unsafe { wide_ptr_to_string(text) };
    unsafe { LocalFree(text.cast()) };
    Some(s)
}

unsafe fn wide_ptr_to_string(p: *const u16) -> String {
    let mut len = 0;
    while unsafe { *p.add(len) } != 0 {
        len += 1;
    }
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(p, len) })
}

/// The user's roaming AppData folder (where their PairDesk keeps its data).
pub fn roaming_appdata(token: &Handle) -> Option<PathBuf> {
    let mut path: windows_sys::core::PWSTR = std::ptr::null_mut();
    let hr = unsafe { SHGetKnownFolderPath(&FOLDERID_RoamingAppData, 0, token.0, &mut path) };
    if hr < 0 || path.is_null() {
        return None;
    }
    let s = unsafe { wide_ptr_to_string(path) };
    unsafe { windows_sys::Win32::System::Com::CoTaskMemFree(path.cast()) };
    Some(PathBuf::from(s))
}

/// A process started by [`spawn_system_in_session`].
pub struct Child {
    process: Handle,
    pub pid: u32,
}

impl Child {
    pub fn alive(&self) -> bool {
        unsafe { WaitForSingleObject(self.process.0, 0) == WAIT_TIMEOUT }
    }

    pub fn kill(&self) {
        unsafe { TerminateProcess(self.process.0, 1) };
    }

    pub fn handle(&self) -> HANDLE {
        self.process.0
    }
}

/// Starts `exe args` as SYSTEM in `session`, on its normal desktop (the
/// process moves to the secure desktop by itself when needed).
pub fn spawn_system_in_session(session: u32, exe: &Path, args: &str) -> Result<Child, String> {
    let mut own: HANDLE = std::ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &mut own) } == 0 {
        return Err(format!(
            "OpenProcessToken: {}",
            std::io::Error::last_os_error()
        ));
    }
    let own = Handle(own);
    let mut token: HANDLE = std::ptr::null_mut();
    if unsafe {
        DuplicateTokenEx(
            own.0,
            TOKEN_ALL_ACCESS,
            std::ptr::null(),
            SecurityImpersonation,
            TokenPrimary,
            &mut token,
        )
    } == 0
    {
        return Err(format!(
            "DuplicateTokenEx: {}",
            std::io::Error::last_os_error()
        ));
    }
    let token = Handle(token);
    let mut sid = session;
    if unsafe {
        SetTokenInformation(
            token.0,
            TokenSessionId,
            (&mut sid as *mut u32).cast(),
            std::mem::size_of::<u32>() as u32,
        )
    } == 0
    {
        return Err(format!(
            "SetTokenInformation: {}",
            std::io::Error::last_os_error()
        ));
    }
    let app = wide(exe);
    let mut cmdline = wide(format!("\"{}\" {args}", exe.display()));
    let mut desktop = wide("winsta0\\default");
    let mut si: STARTUPINFOW = unsafe { std::mem::zeroed() };
    si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    si.lpDesktop = desktop.as_mut_ptr();
    let mut pi: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    let ok = unsafe {
        CreateProcessAsUserW(
            token.0,
            app.as_ptr(),
            cmdline.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
            std::ptr::null(),
            std::ptr::null(),
            &si,
            &mut pi,
        )
    };
    if ok == 0 {
        return Err(format!(
            "CreateProcessAsUserW: {}",
            std::io::Error::last_os_error()
        ));
    }
    unsafe { CloseHandle(pi.hThread) };
    Ok(Child {
        process: Handle(pi.hProcess),
        pid: pi.dwProcessId,
    })
}

/// Starts `exe args` as a child of this process (same user and session).
pub fn spawn_here(exe: &Path, args: &[&str]) -> Result<std::process::Child, String> {
    use std::os::windows::process::CommandExt;
    std::process::Command::new(exe)
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())
}
