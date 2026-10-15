// SPDX-License-Identifier: GPL-3.0-or-later
//! X keysyms for the portal's `NotifyKeyboardKeysym` (values from
//! xkbcommon-keysyms.h).

use crate::protocol::{Modifier, NamedKey};

/// The keysym that types `c`.
pub fn char_keysym(c: char) -> i32 {
    match c {
        '\n' | '\r' => 0xff0d, // Return
        '\t' => 0xff09,        // Tab
        '\u{8}' => 0xff08,     // BackSpace
        // Latin-1 keysyms equal the code point.
        ' '..='~' | '\u{a0}'..='\u{ff}' => c as i32,
        // Everything else: the Unicode keysym range.
        _ => 0x0100_0000 | c as i32,
    }
}

pub fn named_keysym(k: NamedKey) -> i32 {
    match k {
        NamedKey::Enter => 0xff0d,
        NamedKey::Backspace => 0xff08,
        NamedKey::Escape => 0xff1b,
        NamedKey::Tab => 0xff09,
        NamedKey::Space => 0x20,
        NamedKey::Delete => 0xffff,
        NamedKey::Up => 0xff52,
        NamedKey::Down => 0xff54,
        NamedKey::Left => 0xff51,
        NamedKey::Right => 0xff53,
        NamedKey::Home => 0xff50,
        NamedKey::End => 0xff57,
        NamedKey::PageUp => 0xff55,
        NamedKey::PageDown => 0xff56,
        NamedKey::VolumeUp => 0x1008_ff13,
        NamedKey::VolumeDown => 0x1008_ff11,
        NamedKey::Mute => 0x1008_ff12,
        NamedKey::PlayPause => 0x1008_ff14,
        NamedKey::Next => 0x1008_ff17,
        NamedKey::Prev => 0x1008_ff16,
        NamedKey::Insert => 0xff63,
        NamedKey::PrintScreen => 0xff61,
        NamedKey::F1 => 0xffbe,
        NamedKey::F2 => 0xffbf,
        NamedKey::F3 => 0xffc0,
        NamedKey::F4 => 0xffc1,
        NamedKey::F5 => 0xffc2,
        NamedKey::F6 => 0xffc3,
        NamedKey::F7 => 0xffc4,
        NamedKey::F8 => 0xffc5,
        NamedKey::F9 => 0xffc6,
        NamedKey::F10 => 0xffc7,
        NamedKey::F11 => 0xffc8,
        NamedKey::F12 => 0xffc9,
    }
}

pub fn modifier_keysym(m: Modifier) -> i32 {
    match m {
        Modifier::Ctrl => 0xffe3,  // Control_L
        Modifier::Alt => 0xffe9,   // Alt_L
        Modifier::Shift => 0xffe1, // Shift_L
        Modifier::Meta => 0xffeb,  // Super_L
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_characters() {
        assert_eq!(char_keysym('a'), 0x61);
        assert_eq!(char_keysym('A'), 0x41);
        assert_eq!(char_keysym(' '), 0x20);
        assert_eq!(char_keysym('é'), 0xe9);
        assert_eq!(char_keysym('\n'), 0xff0d);
        assert_eq!(char_keysym('€'), 0x0100_20ac);
        assert_eq!(char_keysym('අ'), 0x0100_0d85, "Sinhala");
    }

    #[test]
    fn function_keys_are_consecutive() {
        assert_eq!(named_keysym(NamedKey::F12) - named_keysym(NamedKey::F1), 11);
    }
}
