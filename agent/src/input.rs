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
                enigo.text(s)?;
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
