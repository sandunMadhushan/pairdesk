// SPDX-License-Identifier: GPL-3.0-or-later
//! Wire protocol between the PairDesk phone app and the desktop agent.
//!
//! Every message is a JSON object with a `t` (type) field. See
//! `docs/PROTOCOL.md` for the full description.

use serde::{Deserialize, Serialize};

/// Protocol version spoken by this agent.
pub const PROTOCOL_VERSION: u32 = 1;

/// Upper bound for a single relative mouse move, in pixels.
pub const MAX_MOVE: i32 = 4000;
/// Upper bound for a single scroll step, in lines.
pub const MAX_SCROLL: i32 = 50;
/// Upper bound for a single text message, in characters.
pub const MAX_TEXT_CHARS: usize = 2000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

/// Named keys the phone may press. Only these are accepted, so a phone can
/// never send arbitrary key codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NamedKey {
    Enter,
    Backspace,
    Escape,
    Tab,
    Space,
    Delete,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    VolumeUp,
    VolumeDown,
    Mute,
    PlayPause,
    Next,
    Prev,
}

/// Messages sent by the phone.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ClientMsg {
    /// First message after connecting.
    Hello {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        v: Option<u32>,
    },
    /// Keep-alive; the agent answers with `pong`.
    Ping,
    /// Relative mouse move in pixels.
    Move { dx: i32, dy: i32 },
    /// Press and release a mouse button.
    Click { b: MouseButton },
    /// Press a mouse button and keep it held (for dragging).
    Down { b: MouseButton },
    /// Release a held mouse button.
    Up { b: MouseButton },
    /// Scroll in lines. Positive `dy` scrolls down, positive `dx` scrolls right.
    Scroll {
        #[serde(default)]
        dx: i32,
        #[serde(default)]
        dy: i32,
    },
    /// Type a string of text.
    Text { s: String },
    /// Press and release a named key.
    Key { k: NamedKey },
}

/// Messages sent by the agent.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ServerMsg {
    Hello { name: String, os: String, v: u32 },
    Pong,
    Error { msg: String },
}

impl ClientMsg {
    /// Parses one JSON text frame and clamps values to safe ranges.
    pub fn parse(text: &str) -> Result<Self, String> {
        let msg: ClientMsg = serde_json::from_str(text).map_err(|e| e.to_string())?;
        Ok(msg.clamped())
    }

    fn clamped(self) -> Self {
        match self {
            ClientMsg::Move { dx, dy } => ClientMsg::Move {
                dx: dx.clamp(-MAX_MOVE, MAX_MOVE),
                dy: dy.clamp(-MAX_MOVE, MAX_MOVE),
            },
            ClientMsg::Scroll { dx, dy } => ClientMsg::Scroll {
                dx: dx.clamp(-MAX_SCROLL, MAX_SCROLL),
                dy: dy.clamp(-MAX_SCROLL, MAX_SCROLL),
            },
            ClientMsg::Text { s } => ClientMsg::Text {
                s: s.chars().take(MAX_TEXT_CHARS).collect(),
            },
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_move() {
        assert_eq!(
            ClientMsg::parse(r#"{"v":1,"t":"move","dx":4,"dy":-2}"#).unwrap(),
            ClientMsg::Move { dx: 4, dy: -2 }
        );
    }

    #[test]
    fn clamps_huge_move() {
        assert_eq!(
            ClientMsg::parse(r#"{"t":"move","dx":999999,"dy":-999999}"#).unwrap(),
            ClientMsg::Move {
                dx: MAX_MOVE,
                dy: -MAX_MOVE
            }
        );
    }

    #[test]
    fn parses_click_and_key() {
        assert_eq!(
            ClientMsg::parse(r#"{"t":"click","b":"right"}"#).unwrap(),
            ClientMsg::Click {
                b: MouseButton::Right
            }
        );
        assert_eq!(
            ClientMsg::parse(r#"{"t":"key","k":"page_down"}"#).unwrap(),
            ClientMsg::Key {
                k: NamedKey::PageDown
            }
        );
    }

    #[test]
    fn scroll_defaults_missing_axis() {
        assert_eq!(
            ClientMsg::parse(r#"{"t":"scroll","dy":3}"#).unwrap(),
            ClientMsg::Scroll { dx: 0, dy: 3 }
        );
    }

    #[test]
    fn truncates_long_text() {
        let long = "a".repeat(MAX_TEXT_CHARS + 10);
        let json = format!(r#"{{"t":"text","s":"{long}"}}"#);
        match ClientMsg::parse(&json).unwrap() {
            ClientMsg::Text { s } => assert_eq!(s.chars().count(), MAX_TEXT_CHARS),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn rejects_unknown_type_and_key() {
        assert!(ClientMsg::parse(r#"{"t":"shell","cmd":"rm -rf /"}"#).is_err());
        assert!(ClientMsg::parse(r#"{"t":"key","k":"f13"}"#).is_err());
    }

    #[test]
    fn serializes_server_hello() {
        let json = serde_json::to_string(&ServerMsg::Hello {
            name: "laptop".into(),
            os: "windows".into(),
            v: 1,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"t":"hello","name":"laptop","os":"windows","v":1}"#
        );
    }
}
