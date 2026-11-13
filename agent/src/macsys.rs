// SPDX-License-Identifier: GPL-3.0-or-later
//! Mac: the permissions PairDesk needs from macOS, which only the owner can
//! give in System Settings → Privacy & Security.
//!
//! - Accessibility: move the pointer and type (input.rs asks the first time).
//! - Screen Recording: the screen view, and the computer's sound.
//! - Microphone: asked by macOS itself when a phone first listens to it.

use std::process::Command;

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

/// May PairDesk move the pointer and type?
pub fn accessibility() -> bool {
    // SAFETY: no arguments; reads the process's trust state.
    unsafe { AXIsProcessTrusted() }
}

/// May PairDesk record the screen? (macOS may only notice a new "yes"
/// after PairDesk restarts.)
pub fn screen_recording() -> bool {
    // SAFETY: no arguments.
    unsafe { CGPreflightScreenCaptureAccess() }
}

/// Shows macOS's own Screen Recording prompt (once; afterwards macOS
/// sends the owner to System Settings).
pub fn request_screen_recording() {
    // SAFETY: no arguments.
    unsafe {
        CGRequestScreenCaptureAccess();
    }
}

/// Opens System Settings at a Privacy & Security page:
/// "accessibility", "screen" or "microphone".
pub fn open_settings(which: &str) -> Result<(), String> {
    let anchor = match which {
        "accessibility" => "Privacy_Accessibility",
        "screen" => "Privacy_ScreenCapture",
        "microphone" => "Privacy_Microphone",
        _ => return Err("unknown permission".into()),
    };
    Command::new("/usr/bin/open")
        .arg(format!(
            "x-apple.systempreferences:com.apple.preference.security?{anchor}"
        ))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// For the settings page.
pub fn status() -> serde_json::Value {
    serde_json::json!({
        "accessibility": accessibility(),
        "screen": screen_recording(),
    })
}
