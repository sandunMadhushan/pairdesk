// SPDX-License-Identifier: GPL-3.0-or-later
//! Injects mouse and keyboard input into the desktop.
//!
//! The OS input handle (`Enigo`) lives on one dedicated thread. Network tasks
//! send it commands over a channel, so input is applied in order and the async
//! runtime never blocks on the OS. In a Linux Wayland session the same thread
//! sends the commands to the desktop's remote desktop portal instead.

use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use log::{info, warn};

use crate::protocol::{Modifier, MouseButton, NamedKey};

/// Serializable for the bridge to the Windows helper (`bridge.rs`).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputCmd {
    Move {
        dx: i32,
        dy: i32,
    },
    Click(MouseButton),
    Down(MouseButton),
    Up(MouseButton),
    Scroll {
        dx: i32,
        dy: i32,
    },
    Text(String),
    Key(NamedKey),
    /// Absolute pointer position in virtual-desktop pixels.
    MoveTo {
        x: i32,
        y: i32,
    },
    Combo {
        mods: Vec<Modifier>,
        key: Option<NamedKey>,
        ch: Option<char>,
    },
}

/// Cheap, cloneable handle to the input thread.
#[derive(Clone)]
pub struct InputHandle {
    tx: Sender<InputCmd>,
}

impl InputHandle {
    /// Starts the input thread. Fails if the OS refuses an input connection
    /// (for example no display on Linux).
    pub fn spawn() -> Result<Self, String> {
        let (tx, rx) = mpsc::channel::<InputCmd>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

        #[cfg(target_os = "linux")]
        if let Some(remote) = crate::wayland::global() {
            let remote = remote.clone();
            thread::Builder::new()
                .name("pairdesk-input".into())
                .spawn(move || {
                    info!("input goes through the remote desktop portal (Wayland)");
                    run(rx, |cmd| remote.apply(cmd));
                })
                .map_err(|e| e.to_string())?;
            return Ok(Self { tx });
        }

        thread::Builder::new()
            .name("pairdesk-input".into())
            .spawn(move || match Enigo::new(&Settings::default()) {
                Ok(mut enigo) => {
                    let _ = ready_tx.send(Ok(()));
                    run(rx, |cmd| apply_routed(&mut enigo, cmd));
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("cannot open input device: {e}")));
                }
            })
            .map_err(|e| e.to_string())?;

        ready_rx
            .recv()
            .map_err(|_| "input thread exited during start-up".to_string())??;
        Ok(Self { tx })
    }

    /// A handle whose commands go to a channel instead of the desktop.
    #[cfg(test)]
    pub fn recording() -> (Self, Receiver<InputCmd>) {
        let (tx, rx) = mpsc::channel();
        (Self { tx }, rx)
    }

    pub fn send(&self, cmd: InputCmd) {
        if self.tx.send(cmd).is_err() {
            warn!("input thread has stopped; command dropped");
        }
    }
}

fn run(rx: Receiver<InputCmd>, mut apply: impl FnMut(&InputCmd) -> Result<(), String>) {
    info!("input thread ready");
    while let Ok(first) = rx.recv() {
        // Merge queued moves so a burst of small deltas becomes one OS call.
        let mut pending = Some(first);
        while let Some(cmd) = pending.take() {
            let cmd = match cmd {
                InputCmd::Move { mut dx, mut dy } => {
                    loop {
                        match rx.try_recv() {
                            Ok(InputCmd::Move { dx: x, dy: y }) => {
                                dx = dx.saturating_add(x);
                                dy = dy.saturating_add(y);
                            }
                            Ok(other) => {
                                pending = Some(other);
                                break;
                            }
                            Err(_) => break,
                        }
                    }
                    InputCmd::Move { dx, dy }
                }
                other => other,
            };
            if let Err(e) = apply(&cmd) {
                // Not the command itself: it may be a typed password.
                warn!("input failed: {e}");
            }
        }
    }
    info!("input thread stopped");
}

/// Windows: while the lock screen, sign-in screen or a UAC prompt is up
/// (the secure desktop), input goes through the SYSTEM helper, if the owner
/// turned it on. In the helper's own processes, the input thread follows
/// the input desktop itself.
#[cfg(windows)]
fn apply_routed(enigo: &mut Enigo, cmd: &InputCmd) -> Result<(), String> {
    use crate::winsys;
    if winsys::is_system_mode() {
        winsys::desktop::follow_input_desktop()?;
        return apply(enigo, cmd).map_err(|e| e.to_string());
    }
    if winsys::desktop::user_can_reach_input_desktop() {
        return apply(enigo, cmd).map_err(|e| e.to_string());
    }
    match winsys::bridge() {
        Some(helper) => helper.input(cmd),
        None => Err(
            "the lock screen or an administrator prompt is showing; turn on \
                     \"Sign-in screen and admin prompts\" in PairDesk's settings to use it"
                .into(),
        ),
    }
}

#[cfg(not(windows))]
fn apply_routed(enigo: &mut Enigo, cmd: &InputCmd) -> Result<(), String> {
    apply(enigo, cmd).map_err(|e| e.to_string())
}

pub(crate) fn apply(enigo: &mut Enigo, cmd: &InputCmd) -> enigo::InputResult<()> {
    match cmd {
        InputCmd::Move { dx, dy } => {
            if *dx != 0 || *dy != 0 {
                enigo.move_mouse(*dx, *dy, Coordinate::Rel)?;
            }
        }
        InputCmd::MoveTo { x, y } => move_to(enigo, *x, *y)?,
        InputCmd::Click(b) => enigo.button(button(*b), Direction::Click)?,
        InputCmd::Down(b) => enigo.button(button(*b), Direction::Press)?,
        InputCmd::Up(b) => enigo.button(button(*b), Direction::Release)?,
        InputCmd::Scroll { dx, dy } => {
            if *dy != 0 {
                enigo.scroll(*dy, Axis::Vertical)?;
            }
            if *dx != 0 {
                enigo.scroll(*dx, Axis::Horizontal)?;
            }
        }
        InputCmd::Text(s) => {
            if !s.is_empty() {
                if real_keys_for_text() {
                    type_with_real_keys(enigo, s)?;
                } else {
                    enigo.text(s)?;
                }
            }
        }
        InputCmd::Key(k) => enigo.key(key(*k), Direction::Click)?,
        InputCmd::Combo { mods, key: k, ch } => {
            let mut pressed = Vec::new();
            let mut result = Ok(());
            for m in mods {
                let mk = modifier(*m);
                if pressed.contains(&mk) {
                    continue;
                }
                if let Err(e) = enigo.key(mk, Direction::Press) {
                    result = Err(e);
                    break;
                }
                pressed.push(mk);
            }
            if result.is_ok() {
                let main = match (k, ch) {
                    (Some(k), _) => Some(key(*k)),
                    // Lower-case so Shift stays an explicit modifier.
                    (None, Some(c)) => Some(Key::Unicode(c.to_lowercase().next().unwrap_or(*c))),
                    (None, None) => None,
                };
                if let Some(main) = main {
                    result = enigo.key(main, Direction::Click);
                }
            }
            // Always release what was pressed, newest first.
            for mk in pressed.into_iter().rev() {
                let _ = enigo.key(mk, Direction::Release);
            }
            result?;
        }
    }
    Ok(())
}

/// Windows: `SetCursorPos` covers every monitor (enigo's absolute move
/// only maps the main one). Linux: XTest absolute motion on the root window.
#[cfg(windows)]
fn move_to(_enigo: &mut Enigo, x: i32, y: i32) -> enigo::InputResult<()> {
    if unsafe { windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos(x, y) } == 0 {
        return Err(enigo::InputError::Simulate("SetCursorPos failed"));
    }
    Ok(())
}

#[cfg(not(windows))]
fn move_to(enigo: &mut Enigo, x: i32, y: i32) -> enigo::InputResult<()> {
    enigo.move_mouse(x, y, Coordinate::Abs)
}

fn modifier(m: Modifier) -> Key {
    match m {
        Modifier::Ctrl => Key::Control,
        Modifier::Alt => Key::Alt,
        Modifier::Shift => Key::Shift,
        Modifier::Meta => Key::Meta,
    }
}

fn button(b: MouseButton) -> Button {
    match b {
        MouseButton::Left => Button::Left,
        MouseButton::Right => Button::Right,
        MouseButton::Middle => Button::Middle,
    }
}

fn key(k: NamedKey) -> Key {
    match k {
        NamedKey::Enter => Key::Return,
        NamedKey::Backspace => Key::Backspace,
        NamedKey::Escape => Key::Escape,
        NamedKey::Tab => Key::Tab,
        NamedKey::Space => Key::Space,
        NamedKey::Delete => Key::Delete,
        NamedKey::Up => Key::UpArrow,
        NamedKey::Down => Key::DownArrow,
        NamedKey::Left => Key::LeftArrow,
        NamedKey::Right => Key::RightArrow,
        NamedKey::Home => Key::Home,
        NamedKey::End => Key::End,
        NamedKey::PageUp => Key::PageUp,
        NamedKey::PageDown => Key::PageDown,
        NamedKey::VolumeUp => Key::VolumeUp,
        NamedKey::VolumeDown => Key::VolumeDown,
        NamedKey::Mute => Key::VolumeMute,
        NamedKey::PlayPause => Key::MediaPlayPause,
        NamedKey::Next => Key::MediaNextTrack,
        NamedKey::Prev => Key::MediaPrevTrack,
        NamedKey::Insert => Key::Insert,
        NamedKey::PrintScreen => Key::PrintScr,
        NamedKey::F1 => Key::F1,
        NamedKey::F2 => Key::F2,
        NamedKey::F3 => Key::F3,
        NamedKey::F4 => Key::F4,
        NamedKey::F5 => Key::F5,
        NamedKey::F6 => Key::F6,
        NamedKey::F7 => Key::F7,
        NamedKey::F8 => Key::F8,
        NamedKey::F9 => Key::F9,
        NamedKey::F10 => Key::F10,
        NamedKey::F11 => Key::F11,
        NamedKey::F12 => Key::F12,
    }
}

/// One step of typing text with real key presses.
#[cfg(any(windows, test))]
#[derive(Debug, Clone, Copy, PartialEq)]
enum TypeStep {
    /// A key with its virtual-key code, pressed with Shift when asked.
    Key { vk: u32, shift: bool },
    /// Anything the keyboard layout can't produce: sent as a Unicode character.
    Char(char),
}

#[cfg(any(windows, test))]
/// Plans how to type `text` with real key presses. `lookup` says which
/// virtual key (and whether Shift) produces a character on the current
/// layout; `None` or a result that needs Ctrl or Alt (AltGr) falls back to
/// a Unicode character.
fn plan_real_keys(text: &str, lookup: impl Fn(char) -> Option<(u32, bool, bool)>) -> Vec<TypeStep> {
    text.chars()
        .filter(|&c| c != '\r' && c != '\0')
        .map(|c| match c {
            '\n' => TypeStep::Key {
                vk: 0x0D,
                shift: false,
            },
            '\t' => TypeStep::Key {
                vk: 0x09,
                shift: false,
            },
            _ => match lookup(c) {
                Some((vk, shift, false)) => TypeStep::Key { vk, shift },
                _ => TypeStep::Char(c),
            },
        })
        .collect()
}

/// The Windows PIN and password boxes on the sign-in screen read real key
/// presses and ignore the Unicode packets `Enigo::text` sends. So in the
/// SYSTEM helper (the sign-in screen, lock screen and UAC), text is typed as
/// key presses with scan codes.
#[cfg(windows)]
fn real_keys_for_text() -> bool {
    crate::winsys::is_system_mode() || std::env::var_os("PAIRDESK_TEST_REAL_KEYS").is_some()
}

#[cfg(not(windows))]
fn real_keys_for_text() -> bool {
    false
}

#[cfg(windows)]
fn type_with_real_keys(enigo: &mut Enigo, text: &str) -> enigo::InputResult<()> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::VkKeyScanW;
    let lookup = |c: char| {
        let mut buf = [0u16; 2];
        if c.encode_utf16(&mut buf).len() != 1 {
            return None;
        }
        // SAFETY: plain Win32 call with a UTF-16 unit.
        let r = unsafe { VkKeyScanW(buf[0]) };
        if r == -1 {
            return None;
        }
        let vk = (r & 0xFF) as u32;
        let state = (r >> 8) & 0xFF;
        // Bit 0 Shift, 1 Ctrl, 2 Alt.
        Some((vk, state & 1 != 0, state & 6 != 0))
    };
    for step in plan_real_keys(text, lookup) {
        match step {
            TypeStep::Key { vk, shift } => {
                if shift {
                    enigo.key(Key::Shift, Direction::Press)?;
                }
                let r = enigo.key(Key::Other(vk), Direction::Click);
                if shift {
                    let _ = enigo.key(Key::Shift, Direction::Release);
                }
                r?;
            }
            TypeStep::Char(c) => enigo.text(&c.to_string())?,
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn type_with_real_keys(enigo: &mut Enigo, text: &str) -> enigo::InputResult<()> {
    enigo.text(text)
}

#[cfg(test)]
mod real_key_tests {
    use super::*;

    // A US layout in miniature.
    fn us(c: char) -> Option<(u32, bool, bool)> {
        match c {
            '0'..='9' => Some((c as u32, false, false)),
            'a'..='z' => Some((c.to_ascii_uppercase() as u32, false, false)),
            'A'..='Z' => Some((c as u32, true, false)),
            '@' => Some((0x32, true, false)),
            '€' => Some((0x45, false, true)), // AltGr on some layouts
            _ => None,
        }
    }

    #[test]
    fn a_pin_is_typed_as_digit_keys() {
        let steps = plan_real_keys("0415", us);
        assert_eq!(
            steps,
            vec![
                TypeStep::Key {
                    vk: 0x30,
                    shift: false
                },
                TypeStep::Key {
                    vk: 0x34,
                    shift: false
                },
                TypeStep::Key {
                    vk: 0x31,
                    shift: false
                },
                TypeStep::Key {
                    vk: 0x35,
                    shift: false
                },
            ]
        );
    }

    #[test]
    fn capitals_use_shift_and_enter_is_a_key() {
        let steps = plan_real_keys("Ab\n", us);
        assert_eq!(
            steps,
            vec![
                TypeStep::Key {
                    vk: 0x41,
                    shift: true
                },
                TypeStep::Key {
                    vk: 0x42,
                    shift: false
                },
                TypeStep::Key {
                    vk: 0x0D,
                    shift: false
                },
            ]
        );
    }

    #[test]
    fn what_the_layout_can_not_type_falls_back_to_unicode() {
        let steps = plan_real_keys("€é", us);
        assert_eq!(steps, vec![TypeStep::Char('€'), TypeStep::Char('é')]);
    }
}
