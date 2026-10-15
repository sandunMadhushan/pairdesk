// SPDX-License-Identifier: GPL-3.0-or-later
//! Wire protocol between the PairDesk phone app and the desktop agent.
//!
//! Every message is a JSON object with a `t` (type) field. See
//! `docs/PROTOCOL.md` for the full description.

use serde::{Deserialize, Serialize};

/// Protocol version spoken by this agent. Version 2 added pairing,
/// TLS and signed authentication; version 1 phones are refused.
pub const PROTOCOL_VERSION: u32 = 2;
/// Longest phone name kept, in characters.
pub const MAX_NAME_CHARS: usize = 64;

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
    /// First message from an already paired phone. `id` is the phone's
    /// Ed25519 public key (base64url, no padding).
    Hello {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        v: Option<u32>,
        #[serde(default)]
        id: Option<String>,
    },
    /// First message from a phone that scanned the pairing QR code.
    Pair {
        #[serde(default)]
        v: Option<u32>,
        token: String,
        id: String,
        #[serde(default)]
        name: Option<String>,
    },
    /// Answer to `challenge`: Ed25519 signature (base64url) over the
    /// bytes described in docs/PROTOCOL.md.
    Auth { sig: String },
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
    /// Random nonce the phone must sign (base64url, 32 bytes).
    Challenge {
        nonce: String,
        v: u32,
    },
    /// Authentication succeeded; input commands are accepted from now on.
    Welcome {
        name: String,
        os: String,
        v: u32,
        /// True when this connection just completed pairing.
        paired: bool,
    },
    Pong,
    Error {
        code: ErrorCode,
        msg: String,
    },
}

/// Machine-readable error codes. Every code except `bad_message` is
/// followed by the agent closing the connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The phone speaks a protocol version this agent doesn't support.
    Version,
    /// The phone isn't (or is no longer) paired with this computer.
    NotPaired,
    /// The pairing code is wrong, used or expired.
    BadToken,
    /// The signature didn't verify.
    BadSignature,
    /// A message arrived in the wrong order, e.g. input before `auth`.
    Unexpected,
    /// The message couldn't be parsed. Not fatal.
    BadMessage,
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
            ClientMsg::Hello { name, v, id } => ClientMsg::Hello {
                name: name.map(clean_name),
                v,
                id,
            },
            ClientMsg::Pair { v, token, id, name } => ClientMsg::Pair {
                v,
                token,
                id,
                name: name.map(clean_name),
            },
            other => other,
        }
    }
}

/// Drops control characters and limits length, so a phone name is safe
/// to show in logs and on the settings page.
pub fn clean_name(name: String) -> String {
    name.chars()
        .filter(|c| !c.is_control())
        .take(MAX_NAME_CHARS)
        .collect::<String>()
        .trim()
        .to_string()
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
    fn serializes_server_messages() {
        let json = serde_json::to_string(&ServerMsg::Welcome {
            name: "laptop".into(),
            os: "windows".into(),
            v: 2,
            paired: false,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"t":"welcome","name":"laptop","os":"windows","v":2,"paired":false}"#
        );
        let json = serde_json::to_string(&ServerMsg::Error {
            code: ErrorCode::NotPaired,
            msg: "x".into(),
        })
        .unwrap();
        assert_eq!(json, r#"{"t":"error","code":"not_paired","msg":"x"}"#);
    }

    #[test]
    fn parses_pair_and_cleans_name() {
        let msg = ClientMsg::parse(
            r#"{"t":"pair","v":2,"token":"tk","id":"pk","name":" Pixel\u0007 7 "}"#,
        )
        .unwrap();
        assert_eq!(
            msg,
            ClientMsg::Pair {
                v: Some(2),
                token: "tk".into(),
                id: "pk".into(),
                name: Some("Pixel 7".into()),
            }
        );
    }
}
