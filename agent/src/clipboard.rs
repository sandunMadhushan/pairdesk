// SPDX-License-Identifier: GPL-3.0-or-later
//! The computer's clipboard (text).
//!
//! Windows and X11: arboard. A Linux Wayland session: the remote desktop
//! portal's clipboard, shared by the session phones already use; if the
//! desktop doesn't offer it, the X11 clipboard of Xwayland (which GNOME and
//! KDE keep in step with the Wayland one) is tried instead.
//!
//! All calls block; run them off the async runtime.

use std::sync::Mutex;

/// Largest clipboard text exchanged with a phone (bytes of UTF-8).
pub const MAX_BYTES: usize = 200_000;

/// Kept alive for the agent's lifetime: on X11 the text PairDesk copied is
/// only available while a clipboard object exists.
static NATIVE: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);

fn with_native<T>(
    f: impl FnOnce(&mut arboard::Clipboard) -> Result<T, arboard::Error>,
) -> Result<T, String> {
    let mut guard = NATIVE.lock().unwrap_or_else(|p| p.into_inner());
    if guard.is_none() {
        *guard =
            Some(arboard::Clipboard::new().map_err(|e| format!("can't open the clipboard: {e}"))?);
    }
    f(guard.as_mut().expect("just set")).map_err(|e| e.to_string())
}

/// Cuts `text` to at most [`MAX_BYTES`] at a character boundary.
pub fn clamp(mut text: String) -> String {
    if text.len() > MAX_BYTES {
        let mut end = MAX_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

/// Tests use a clipboard in memory, not the real one.
#[cfg(test)]
pub static TEST_CLIPBOARD: Mutex<String> = Mutex::new(String::new());

/// The clipboard's text; empty when it holds something else (an image…).
// Under test the in-memory clipboard returns first.
#[cfg_attr(test, allow(unreachable_code))]
pub fn get() -> Result<String, String> {
    #[cfg(test)]
    return Ok(TEST_CLIPBOARD.lock().unwrap().clone());
    #[cfg(target_os = "linux")]
    if let Some(r) = crate::wayland::global().and_then(|r| r.clipboard_get()) {
        return r.map(clamp);
    }
    match with_native(|c| c.get_text()) {
        Ok(t) => Ok(clamp(t)),
        // Empty, or not text: nothing to hand over.
        Err(e) if e.contains("empty") || e.contains("not available") => Ok(String::new()),
        Err(e) => Err(e),
    }
}

#[cfg_attr(test, allow(unreachable_code))]
pub fn set(text: &str) -> Result<(), String> {
    #[cfg(test)]
    {
        *TEST_CLIPBOARD.lock().unwrap() = text.to_string();
        return Ok(());
    }
    #[cfg(target_os = "linux")]
    if let Some(r) = crate::wayland::global().and_then(|r| r.clipboard_set(text)) {
        return r;
    }
    with_native(|c| c.set_text(text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_at_a_character_boundary() {
        let long = "අ".repeat(MAX_BYTES); // 3 bytes each
        let cut = clamp(long);
        assert!(cut.len() <= MAX_BYTES);
        assert!(cut.len() > MAX_BYTES - 3);
        assert!(cut.chars().all(|c| c == 'අ'));
        assert_eq!(clamp("short".into()), "short");
    }
}
