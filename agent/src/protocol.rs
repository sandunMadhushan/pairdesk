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
    Insert,
    PrintScreen,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
}

/// Modifier keys held during a `combo`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Modifier {
    Ctrl,
    Alt,
    Shift,
    /// The Windows key, or Super on Linux.
    Meta,
}

/// Power and session actions. Which ones are allowed is set on the
/// computer's settings page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PowerAction {
    Lock,
    Sleep,
    ScreenOff,
    SignOut,
    Restart,
    ShutDown,
}

impl PowerAction {
    /// Actions that end the session and can lose unsaved work.
    pub fn ends_session(self) -> bool {
        matches!(
            self,
            PowerAction::SignOut | PowerAction::Restart | PowerAction::ShutDown
        )
    }
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
    Auth {
        sig: String,
    },
    /// Keep-alive; the agent answers with `pong`.
    Ping,
    /// Relative mouse move in pixels.
    Move {
        dx: i32,
        dy: i32,
    },
    /// Press and release a mouse button.
    Click {
        b: MouseButton,
    },
    /// Press a mouse button and keep it held (for dragging).
    Down {
        b: MouseButton,
    },
    /// Release a held mouse button.
    Up {
        b: MouseButton,
    },
    /// Scroll in lines. Positive `dy` scrolls down, positive `dx` scrolls right.
    Scroll {
        #[serde(default)]
        dx: i32,
        #[serde(default)]
        dy: i32,
    },
    /// Type a string of text.
    Text {
        s: String,
    },
    /// Press and release a named key.
    Key {
        k: NamedKey,
    },
    /// Keyboard shortcut: hold `mods`, press `k` (named key) or `c` (one
    /// character), release. With neither, the modifiers alone are tapped
    /// (e.g. the Windows key).
    Combo {
        #[serde(default)]
        mods: Vec<Modifier>,
        #[serde(default)]
        k: Option<NamedKey>,
        #[serde(default)]
        c: Option<char>,
    },
    /// Lock, sleep, sign out, restart, shut down…
    Power {
        #[serde(default)]
        id: Option<u64>,
        a: PowerAction,
    },
    /// Asks for the apps and shortcuts that can be launched.
    Apps {
        #[serde(default)]
        id: Option<u64>,
    },
    /// Opens an app or shortcut by the ID from `apps`.
    Launch {
        #[serde(default)]
        id: Option<u64>,
        app: String,
    },
    /// Starts (or restarts) screen view.
    ScreenStart {
        #[serde(default)]
        id: Option<u64>,
        /// Monitor index from `screen.monitors`; default the main one.
        #[serde(default)]
        monitor: Option<u32>,
        /// `low`, `medium` (default) or `high`.
        #[serde(default)]
        quality: Option<String>,
        /// Video formats the phone can decode, e.g. `["h264"]` (since 0.9).
        /// Without it, JPEG rectangles.
        #[serde(default)]
        codecs: Vec<String>,
    },
    /// The phone has shown frame `seq`; the agent may send more.
    ScreenAck {
        seq: u32,
    },
    /// Send the whole screen again on the next frame.
    ScreenRefresh,
    ScreenStop,
    /// Starts (or changes) listening: the computer's sound and/or its
    /// microphone, sent as "PDA1" binary messages (since 0.10). Answered
    /// with `audio`. Both false stops it.
    AudioStart {
        #[serde(default)]
        id: Option<u64>,
        #[serde(default)]
        sound: bool,
        #[serde(default)]
        mic: bool,
        /// What the phone can decode, best first: `opus`, `pcm`.
        #[serde(default)]
        codecs: Vec<String>,
    },
    AudioStop,
    /// Moves the pointer to a point on the shown screen, 0..1 from the
    /// top-left corner.
    MoveTo {
        x: f64,
        y: f64,
    },
    /// Asks for the computer's clipboard text; answered with `clip`.
    ClipGet {
        #[serde(default)]
        id: Option<u64>,
    },
    /// Puts text on the computer's clipboard and, with `paste`, pastes it
    /// into the active window (Ctrl+V). Answered with `ack`.
    ClipSet {
        #[serde(default)]
        id: Option<u64>,
        text: String,
        #[serde(default)]
        paste: bool,
    },
    /// The phone wants to send a file (see `files.rs`).
    FileOffer {
        fid: u32,
        name: String,
        size: u64,
    },
    /// The phone takes a file the computer offered.
    FileAccept {
        fid: u32,
    },
    /// Bytes of a file received so far (flow control).
    FileProgress {
        fid: u32,
        received: u64,
    },
    /// All bytes are sent; the checksum to verify.
    FileEnd {
        fid: u32,
        sha256: String,
    },
    /// The phone saved (or couldn't save) a file from the computer.
    FileDone {
        fid: u32,
        ok: bool,
        #[serde(default)]
        msg: Option<String>,
    },
    /// Stops a transfer in either direction.
    FileCancel {
        fid: u32,
        #[serde(default)]
        msg: Option<String>,
    },
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
        /// The agent's release, e.g. "0.5.1" (added in 0.5.1).
        version: &'static str,
        /// True when this connection just completed pairing.
        paired: bool,
        /// Optional features this agent supports.
        features: Vec<&'static str>,
        /// What the computer's owner allows phones to do.
        allow: Allow,
        /// Addresses the phone can use to reach this computer: home
        /// network first, then Tailscale addresses and name.
        addrs: Vec<String>,
    },
    /// Answer to a request that carried an `id`.
    Ack {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<u64>,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<AckCode>,
        #[serde(skip_serializing_if = "Option::is_none")]
        msg: Option<String>,
    },
    /// Answer to `screen_start`; binary frames follow.
    Screen {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<u64>,
        monitors: Vec<MonitorInfo>,
        monitor: u32,
        /// Size of the frames that will arrive.
        width: u32,
        height: u32,
        /// `jpeg` ("PDS1" frames) or `h264` ("PDV1" frames).
        codec: &'static str,
    },
    /// Screen view ended on the computer's side.
    ScreenStopped {
        msg: String,
    },
    /// Answer to `audio_start`; "PDA1" messages follow.
    Audio {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<u64>,
        /// `opus` or `pcm` (16-bit little-endian).
        codec: &'static str,
        rate: u32,
        channels: u32,
        frame_ms: u32,
        /// Opus samples to drop at the start (for the decoder's header).
        pre_skip: u16,
        sound: bool,
        mic: bool,
    },
    /// Listening ended on the computer's side.
    AudioStopped {
        msg: String,
    },
    /// Something the person should know (e.g. "approve on the computer").
    /// Phones before 0.6 ignore it.
    Notice {
        msg: String,
    },
    /// The computer's addresses changed (e.g. Tailscale came up after the
    /// phone connected). Same list as `Welcome.addrs`: home network first,
    /// then Tailscale addresses and name, then the relay route.
    /// Added in 0.11.1; older phones ignore it.
    Addrs {
        addrs: Vec<String>,
    },
    /// Answer to `clip_get`.
    Clip {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<u64>,
        text: String,
    },
    /// The computer wants to send a file.
    FileOffer {
        fid: u32,
        name: String,
        size: u64,
    },
    FileAccept {
        fid: u32,
    },
    FileProgress {
        fid: u32,
        received: u64,
    },
    FileEnd {
        fid: u32,
        sha256: String,
    },
    /// A file from the phone was saved (`name`: under which name), or not.
    FileDone {
        fid: u32,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        msg: Option<String>,
    },
    FileCancel {
        fid: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        msg: Option<String>,
    },
    /// Answer to `apps`.
    Apps {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<u64>,
        /// Shortcuts set up on the settings page.
        shortcuts: Vec<AppEntry>,
        /// Apps installed on the computer.
        apps: Vec<AppEntry>,
    },
    Pong,
    Error {
        code: ErrorCode,
        msg: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Allow {
    /// Lock, sleep, screen off.
    pub power: bool,
    /// Sign out, restart, shut down.
    pub session: bool,
    /// Launch apps and shortcuts.
    pub apps: bool,
    /// See the screen.
    pub screen: bool,
    /// Read and set the clipboard.
    pub clipboard: bool,
    /// Send files to this computer.
    pub files: bool,
    /// Hear the computer's sound and talk through its speakers (0.10).
    #[serde(default)]
    pub audio: bool,
    /// Hear the computer's microphone (0.10).
    #[serde(default)]
    pub mic: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MonitorInfo {
    pub index: u32,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub primary: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AckCode {
    /// Turned off on the computer's settings page.
    NotAllowed,
    /// No app or shortcut with that ID.
    NotFound,
    /// The computer tried and failed.
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AppEntry {
    pub id: String,
    pub name: String,
    /// `app`, `url`, `folder`, `file` or `program`.
    pub kind: &'static str,
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
        if let ClientMsg::Combo { mods, k, c } = &msg {
            if k.is_some() && c.is_some() {
                return Err("combo takes `k` or `c`, not both".into());
            }
            if c.is_some_and(|c| c.is_control() || c.is_whitespace()) {
                return Err("combo `c` must be a visible character".into());
            }
            if k.is_none() && c.is_none() && mods.is_empty() {
                return Err("empty combo".into());
            }
            if mods.len() > 4 {
                return Err("too many modifiers".into());
            }
        }
        if let ClientMsg::Launch { app, .. } = &msg
            && app.len() > 256
        {
            return Err("app ID too long".into());
        }
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
            ClientMsg::MoveTo { x, y } => ClientMsg::MoveTo {
                x: if x.is_finite() {
                    x.clamp(0.0, 1.0)
                } else {
                    0.5
                },
                y: if y.is_finite() {
                    y.clamp(0.0, 1.0)
                } else {
                    0.5
                },
            },
            ClientMsg::Text { s } => ClientMsg::Text {
                s: s.chars().take(MAX_TEXT_CHARS).collect(),
            },
            ClientMsg::ClipSet { id, text, paste } => ClientMsg::ClipSet {
                id,
                text: crate::clipboard::clamp(text),
                paste,
            },
            ClientMsg::FileOffer { fid, name, size } => ClientMsg::FileOffer {
                fid,
                name: name.chars().take(512).collect(),
                size,
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
            version: "9.9.9",
            paired: false,
            features: vec!["power"],
            allow: Allow {
                power: true,
                session: false,
                apps: true,
                screen: true,
                clipboard: true,
                files: false,
                audio: true,
                mic: false,
            },
            addrs: vec!["192.168.1.5".into(), "100.101.102.103".into()],
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"t":"welcome","name":"laptop","os":"windows","v":2,"version":"9.9.9","paired":false,"features":["power"],"allow":{"power":true,"session":false,"apps":true,"screen":true,"clipboard":true,"files":false,"audio":true,"mic":false},"addrs":["192.168.1.5","100.101.102.103"]}"#
        );
        let json = serde_json::to_string(&ServerMsg::Ack {
            id: Some(4),
            ok: false,
            code: Some(AckCode::NotAllowed),
            msg: None,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"t":"ack","id":4,"ok":false,"code":"not_allowed"}"#
        );
        let json = serde_json::to_string(&ServerMsg::Error {
            code: ErrorCode::NotPaired,
            msg: "x".into(),
        })
        .unwrap();
        assert_eq!(json, r#"{"t":"error","code":"not_paired","msg":"x"}"#);
    }

    #[test]
    fn parses_and_checks_combos() {
        assert_eq!(
            ClientMsg::parse(r#"{"t":"combo","mods":["ctrl","shift"],"k":"escape"}"#).unwrap(),
            ClientMsg::Combo {
                mods: vec![Modifier::Ctrl, Modifier::Shift],
                k: Some(NamedKey::Escape),
                c: None
            }
        );
        assert_eq!(
            ClientMsg::parse(r#"{"t":"combo","mods":["ctrl"],"c":"c"}"#).unwrap(),
            ClientMsg::Combo {
                mods: vec![Modifier::Ctrl],
                k: None,
                c: Some('c')
            }
        );
        assert!(ClientMsg::parse(r#"{"t":"combo","mods":["meta"]}"#).is_ok());
        assert!(ClientMsg::parse(r#"{"t":"combo","k":"f4","mods":["alt"]}"#).is_ok());
        assert!(ClientMsg::parse(r#"{"t":"combo"}"#).is_err(), "empty");
        assert!(
            ClientMsg::parse(r#"{"t":"combo","c":"ab"}"#).is_err(),
            "two chars"
        );
        assert!(
            ClientMsg::parse(r#"{"t":"combo","c":"\n"}"#).is_err(),
            "control"
        );
        assert!(
            ClientMsg::parse(r#"{"t":"combo","k":"enter","c":"x"}"#).is_err(),
            "both"
        );
        assert!(ClientMsg::parse(r#"{"t":"combo","mods":["hyper"],"c":"x"}"#).is_err());
    }

    #[test]
    fn parses_power_apps_and_launch() {
        assert_eq!(
            ClientMsg::parse(r#"{"t":"power","id":3,"a":"shut_down"}"#).unwrap(),
            ClientMsg::Power {
                id: Some(3),
                a: PowerAction::ShutDown
            }
        );
        assert!(ClientMsg::parse(r#"{"t":"power","a":"format_disk"}"#).is_err());
        assert_eq!(
            ClientMsg::parse(r#"{"t":"apps","id":1}"#).unwrap(),
            ClientMsg::Apps { id: Some(1) }
        );
        assert_eq!(
            ClientMsg::parse(r#"{"t":"launch","app":"a1"}"#).unwrap(),
            ClientMsg::Launch {
                id: None,
                app: "a1".into()
            }
        );
        let long = "x".repeat(300);
        assert!(ClientMsg::parse(&format!(r#"{{"t":"launch","app":"{long}"}}"#)).is_err());
        // A command line is not an app ID: launch only accepts IDs from `apps`.
        assert!(ClientMsg::parse(r#"{"t":"launch","cmd":"calc.exe"}"#).is_err());
    }

    #[test]
    fn parses_screen_messages_and_clamps_points() {
        assert_eq!(
            ClientMsg::parse(r#"{"t":"screen_start","id":1,"monitor":1,"quality":"low"}"#).unwrap(),
            ClientMsg::ScreenStart {
                id: Some(1),
                monitor: Some(1),
                quality: Some("low".into()),
                codecs: vec![],
            }
        );
        assert_eq!(
            ClientMsg::parse(r#"{"t":"screen_ack","seq":9}"#).unwrap(),
            ClientMsg::ScreenAck { seq: 9 }
        );
        assert_eq!(
            ClientMsg::parse(r#"{"t":"move_to","x":1.7,"y":-3}"#).unwrap(),
            ClientMsg::MoveTo { x: 1.0, y: 0.0 }
        );
        assert!(ClientMsg::parse(r#"{"t":"move_to","x":"a","y":0}"#).is_err());
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
