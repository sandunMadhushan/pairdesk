// SPDX-License-Identifier: GPL-3.0-or-later
//! The input desktop: `Default` normally, `Winlogon` for the lock screen,
//! the sign-in screen and UAC prompts.

use std::cell::RefCell;

use windows_sys::Win32::Foundation::GENERIC_ALL;
use windows_sys::Win32::System::StationsAndDesktops::{
    CloseDesktop, DESKTOP_READOBJECTS, GetUserObjectInformationW, HDESK, OpenInputDesktop,
    SetThreadDesktop, UOI_NAME,
};

fn name_of(desk: HDESK) -> Option<String> {
    let mut buf = [0u16; 128];
    let mut needed = 0u32;
    // SAFETY: `buf` is large enough for desktop names; the length is in bytes.
    let ok = unsafe {
        GetUserObjectInformationW(
            desk,
            UOI_NAME,
            buf.as_mut_ptr().cast(),
            std::mem::size_of_val(&buf) as u32,
            &mut needed,
        )
    };
    if ok == 0 {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]))
}

/// The input desktop's name, if this process may look at it. A normal user
/// process gets `None` while the secure desktop is up.
pub fn input_desktop_name() -> Option<String> {
    // SAFETY: plain Win32 calls; the handle is closed below.
    let desk = unsafe { OpenInputDesktop(0, 0, DESKTOP_READOBJECTS) };
    if desk.is_null() {
        return None;
    }
    let name = name_of(desk);
    unsafe { CloseDesktop(desk) };
    name
}

/// True when this (user) process can reach the input desktop, i.e. the
/// secure desktop isn't showing.
pub fn user_can_reach_input_desktop() -> bool {
    // Tests (Wine has no secure desktop): act as if the lock screen were up.
    if std::env::var_os("PAIRDESK_TEST_SECURE_DESKTOP").is_some() {
        return false;
    }
    input_desktop_name().is_some_and(|n| !n.eq_ignore_ascii_case("Winlogon"))
}

thread_local! {
    /// The desktop this thread was last moved to, and its name.
    static CURRENT: RefCell<Option<(usize, String)>> = const { RefCell::new(None) };
}

/// SYSTEM processes: moves the calling thread to the input desktop when it
/// changed. Returns `Ok(true)` if the thread moved (capture handles must be
/// made again), `Ok(false)` if it was already there.
pub fn follow_input_desktop() -> Result<bool, String> {
    // SAFETY: the new handle is kept while the thread uses it; the previous
    // one is closed after switching.
    let desk = unsafe { OpenInputDesktop(0, 0, GENERIC_ALL) };
    if desk.is_null() {
        return Err("can't open the input desktop".into());
    }
    let name = name_of(desk).unwrap_or_default();
    CURRENT.with(|cur| {
        let mut cur = cur.borrow_mut();
        if cur.as_ref().is_some_and(|(_, n)| *n == name) {
            unsafe { CloseDesktop(desk) };
            return Ok(false);
        }
        if unsafe { SetThreadDesktop(desk) } == 0 {
            unsafe { CloseDesktop(desk) };
            return Err(format!("can't switch to the {name} desktop"));
        }
        if let Some((old, _)) = cur.take() {
            unsafe { CloseDesktop(old as HDESK) };
        }
        log::info!("now on the {name} desktop");
        *cur = Some((desk as usize, name));
        Ok(true)
    })
}
