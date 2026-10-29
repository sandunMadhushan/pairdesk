// SPDX-License-Identifier: GPL-3.0-or-later
//! The bridge between PairDesk (running as the signed-in user) and the
//! PairDesk helper (running as SYSTEM in the same Windows session).
//!
//! Windows shows the lock screen and administrator (UAC) prompts on a
//! separate "secure desktop" that only SYSTEM can see or control. While it
//! is up, PairDesk hands pointer and keyboard input and screen capture to the
//! helper through this bridge.
//!
//! Transport: TCP on 127.0.0.1, port and a random token in a file that only
//! SYSTEM and the session's user can read (see `winsys`). Every connection
//! starts with `hello {token}`; anything else closes it.
//!
//! Messages (both ways): `u32 json length | JSON | u32 data length | data`,
//! little-endian. Only `frame` answers carry data (BGRA pixels).
//!
//! The protocol is cross-platform so it can be tested anywhere; only the
//! helper's backend (secure desktop input and capture) is Windows-specific.

// Used by the Windows helper; elsewhere only by tests.
#![cfg_attr(not(windows), allow(dead_code))]

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::input::InputCmd;
use crate::screen::capture::Frame;

/// Bumped only for incompatible changes; both sides send theirs in `hello`.
pub const VERSION: u32 = 1;
const MAX_JSON: u32 = 64 * 1024;
const MAX_DATA: u32 = 128 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Request {
    Hello {
        token: String,
        version: u32,
    },
    /// Pointer and keyboard on the input desktop.
    Input {
        cmd: InputCmd,
    },
    /// A screen area in virtual-desktop pixels, from the input desktop.
    Capture {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    },
    /// The input desktop's name (`Default`, `Winlogon`, …) and the pointer.
    Desktop,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Response {
    Hello {
        version: u32,
    },
    Ok,
    /// Followed by `width * height * 4` bytes of BGRA.
    Frame {
        width: u32,
        height: u32,
    },
    Desktop {
        name: String,
        cursor: Option<(i32, i32)>,
    },
    Error {
        msg: String,
    },
}

/// What the helper does for PairDesk (Windows: on the secure desktop).
pub trait Backend: Send + Sync {
    fn input(&self, cmd: &InputCmd) -> Result<(), String>;
    fn capture(&self, x: i32, y: i32, width: u32, height: u32) -> Result<Frame, String>;
    fn desktop(&self) -> (String, Option<(i32, i32)>);
}

fn write_msg(w: &mut impl Write, json: &impl Serialize, data: &[u8]) -> io::Result<()> {
    let json = serde_json::to_vec(json).map_err(io::Error::other)?;
    let mut buf = Vec::with_capacity(8 + json.len());
    buf.extend_from_slice(&(json.len() as u32).to_le_bytes());
    buf.extend_from_slice(&json);
    buf.extend_from_slice(&(data.len() as u32).to_le_bytes());
    w.write_all(&buf)?;
    w.write_all(data)?;
    w.flush()
}

fn read_msg<T: for<'de> Deserialize<'de>>(r: &mut impl Read) -> io::Result<(T, Vec<u8>)> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let n = u32::from_le_bytes(len);
    if n > MAX_JSON {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "message too large",
        ));
    }
    let mut json = vec![0u8; n as usize];
    r.read_exact(&mut json)?;
    r.read_exact(&mut len)?;
    let d = u32::from_le_bytes(len);
    if d > MAX_DATA {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "data too large"));
    }
    let mut data = vec![0u8; d as usize];
    r.read_exact(&mut data)?;
    let msg =
        serde_json::from_slice(&json).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok((msg, data))
}

/// Compares tokens in constant time.
fn same(a: &str, b: &str) -> bool {
    use subtle::ConstantTimeEq;
    a.len() == b.len() && bool::from(a.as_bytes().ct_eq(b.as_bytes()))
}

/// Serves the bridge on `listener` until the process ends. Each connection
/// gets its own thread; requests are answered in order.
pub fn serve(listener: TcpListener, token: String, backend: Arc<dyn Backend>) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        // Only this computer (the listener is on 127.0.0.1 anyway).
        if !stream.peer_addr().is_ok_and(|a| a.ip().is_loopback()) {
            continue;
        }
        let (token, backend) = (token.clone(), backend.clone());
        let _ = std::thread::Builder::new()
            .name("bridge-conn".into())
            .spawn(move || {
                if let Err(e) = handle(stream, &token, &*backend) {
                    log::debug!("bridge connection ended: {e}");
                }
            });
    }
}

fn handle(mut stream: TcpStream, token: &str, backend: &dyn Backend) -> io::Result<()> {
    stream.set_nodelay(true)?;
    // The hello must come quickly; after that the agent may be idle.
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    match read_msg::<Request>(&mut stream)? {
        (Request::Hello { token: t, .. }, _) if same(&t, token) => {
            write_msg(&mut stream, &Response::Hello { version: VERSION }, &[])?;
        }
        _ => {
            log::warn!("bridge: refused a connection without the right token");
            return Ok(());
        }
    }
    stream.set_read_timeout(None)?;
    loop {
        let (req, _) = read_msg::<Request>(&mut stream)?;
        match req {
            Request::Hello { .. } => write_msg(&mut stream, &Response::Ok, &[])?,
            Request::Input { cmd } => match backend.input(&cmd) {
                Ok(()) => write_msg(&mut stream, &Response::Ok, &[])?,
                Err(msg) => write_msg(&mut stream, &Response::Error { msg }, &[])?,
            },
            Request::Capture {
                x,
                y,
                width,
                height,
            } => match backend.capture(x, y, width, height) {
                Ok(f) => write_msg(
                    &mut stream,
                    &Response::Frame {
                        width: f.width,
                        height: f.height,
                    },
                    &f.data,
                )?,
                Err(msg) => write_msg(&mut stream, &Response::Error { msg }, &[])?,
            },
            Request::Desktop => {
                let (name, cursor) = backend.desktop();
                write_msg(&mut stream, &Response::Desktop { name, cursor }, &[])?
            }
        }
    }
}

/// Where a helper listens: written by the helper, read by PairDesk.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Endpoint {
    pub port: u16,
    pub token: String,
}

/// PairDesk's side: one connection, reopened when it breaks.
pub struct Client {
    endpoint: Box<dyn Fn() -> Option<Endpoint> + Send + Sync>,
    conn: Mutex<Option<TcpStream>>,
}

impl Client {
    /// `endpoint` finds the helper (re-read on every reconnect, since the
    /// helper restarts with a new port and token).
    pub fn new(endpoint: impl Fn() -> Option<Endpoint> + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            endpoint: Box::new(endpoint),
            conn: Mutex::new(None),
        })
    }

    fn connect(&self) -> io::Result<TcpStream> {
        let ep = (self.endpoint)().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "the PairDesk helper isn't running (turn on Sign-in screen and admin prompts in PairDesk's settings)")
        })?;
        let addr = SocketAddr::from(([127, 0, 0, 1], ep.port));
        let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(2))?;
        s.set_nodelay(true)?;
        s.set_read_timeout(Some(Duration::from_secs(10)))?;
        write_msg(
            &mut s,
            &Request::Hello {
                token: ep.token,
                version: VERSION,
            },
            &[],
        )?;
        match read_msg::<Response>(&mut s)? {
            (Response::Hello { .. }, _) => Ok(s),
            _ => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "the helper refused",
            )),
        }
    }

    /// Sends a request; one retry on a fresh connection if the old one broke.
    fn call(&self, req: &Request) -> io::Result<(Response, Vec<u8>)> {
        let mut conn = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        for attempt in 0..2 {
            if conn.is_none() {
                *conn = Some(self.connect()?);
            }
            let s = conn.as_mut().expect("just connected");
            match write_msg(s, req, &[]).and_then(|_| read_msg::<Response>(s)) {
                Ok(r) => return Ok(r),
                Err(e) if attempt == 0 => {
                    log::debug!("bridge: reconnecting ({e})");
                    *conn = None;
                }
                Err(e) => {
                    *conn = None;
                    return Err(e);
                }
            }
        }
        unreachable!()
    }

    pub fn input(&self, cmd: &InputCmd) -> Result<(), String> {
        match self.call(&Request::Input { cmd: cmd.clone() }) {
            Ok((Response::Ok, _)) => Ok(()),
            Ok((Response::Error { msg }, _)) => Err(msg),
            Ok(_) => Err("unexpected answer from the helper".into()),
            Err(e) => Err(e.to_string()),
        }
    }

    pub fn capture(&self, x: i32, y: i32, width: u32, height: u32) -> Result<Frame, String> {
        match self.call(&Request::Capture {
            x,
            y,
            width,
            height,
        }) {
            Ok((Response::Frame { width, height }, data))
                if data.len() == (width * height * 4) as usize =>
            {
                Ok(Frame {
                    width,
                    height,
                    data,
                })
            }
            Ok((Response::Error { msg }, _)) => Err(msg),
            Ok(_) => Err("unexpected answer from the helper".into()),
            Err(e) => Err(e.to_string()),
        }
    }

    pub fn desktop(&self) -> Result<(String, Option<(i32, i32)>), String> {
        match self.call(&Request::Desktop) {
            Ok((Response::Desktop { name, cursor }, _)) => Ok((name, cursor)),
            Ok(_) => Err("unexpected answer from the helper".into()),
            Err(e) => Err(e.to_string()),
        }
    }
}

/// A random token for a new helper.
pub fn new_token() -> String {
    crate::config::b64(&crate::config::random_bytes::<24>())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::MouseButton;

    #[derive(Default)]
    struct Fake {
        seen: Mutex<Vec<InputCmd>>,
    }

    impl Backend for Fake {
        fn input(&self, cmd: &InputCmd) -> Result<(), String> {
            if *cmd == InputCmd::Text("fail".into()) {
                return Err("can't type that".into());
            }
            self.seen.lock().unwrap().push(cmd.clone());
            Ok(())
        }
        fn capture(&self, _x: i32, _y: i32, width: u32, height: u32) -> Result<Frame, String> {
            Ok(Frame {
                width,
                height,
                data: vec![7; (width * height * 4) as usize],
            })
        }
        fn desktop(&self) -> (String, Option<(i32, i32)>) {
            ("Winlogon".into(), Some((5, 6)))
        }
    }

    fn start(token: &str) -> (Endpoint, Arc<Fake>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let fake = Arc::new(Fake::default());
        let (t, b) = (token.to_string(), fake.clone() as Arc<dyn Backend>);
        std::thread::spawn(move || serve(l, t, b));
        (
            Endpoint {
                port,
                token: token.into(),
            },
            fake,
        )
    }

    #[test]
    fn input_capture_and_desktop_go_through() {
        let (ep, fake) = start("s3cret");
        let client = Client::new(move || Some(ep.clone()));
        client.input(&InputCmd::Click(MouseButton::Left)).unwrap();
        client.input(&InputCmd::Text("1234".into())).unwrap();
        assert_eq!(
            client.input(&InputCmd::Text("fail".into())),
            Err("can't type that".into())
        );
        assert_eq!(
            *fake.seen.lock().unwrap(),
            vec![
                InputCmd::Click(MouseButton::Left),
                InputCmd::Text("1234".into())
            ]
        );
        let f = client.capture(0, 0, 32, 16).unwrap();
        assert_eq!((f.width, f.height, f.data.len()), (32, 16, 32 * 16 * 4));
        assert_eq!(client.desktop().unwrap(), ("Winlogon".into(), Some((5, 6))));
    }

    #[test]
    fn a_wrong_token_is_refused() {
        let (mut ep, fake) = start("right");
        ep.token = "wrong".into();
        let client = Client::new(move || Some(ep.clone()));
        assert!(client.input(&InputCmd::Click(MouseButton::Left)).is_err());
        assert!(fake.seen.lock().unwrap().is_empty());
    }

    #[test]
    fn reconnects_to_a_restarted_helper() {
        let (first, _) = start("one");
        let current = Arc::new(Mutex::new(Some(first)));
        let c2 = current.clone();
        let client = Client::new(move || c2.lock().unwrap().clone());
        client.desktop().unwrap();
        // The helper restarts elsewhere with a new token.
        let (second, fake2) = start("two");
        *current.lock().unwrap() = Some(second);
        // The old connection still works (the old helper is alive in this
        // test), so make it break: point at nothing, then at the new one.
        *client.conn.lock().unwrap() = None;
        client.input(&InputCmd::Move { dx: 1, dy: 1 }).unwrap();
        assert_eq!(fake2.seen.lock().unwrap().len(), 1);
        *current.lock().unwrap() = None;
        *client.conn.lock().unwrap() = None;
        assert!(client.desktop().unwrap_err().contains("isn't running"));
    }

    #[test]
    fn oversized_messages_are_refused() {
        let mut bad = Vec::new();
        bad.extend_from_slice(&(MAX_JSON + 1).to_le_bytes());
        assert!(read_msg::<Request>(&mut &bad[..]).is_err());
    }
}
