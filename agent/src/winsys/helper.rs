// SPDX-License-Identifier: GPL-3.0-or-later
//! `--session-helper`: runs as SYSTEM in the session at the screen
//! (started by the service). Serves the bridge for the user's PairDesk and,
//! while nobody is signed in, runs the phone server for the sign-in screen.

use std::cell::RefCell;
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use enigo::{Enigo, Settings};

use super::{acl, desktop, session};
use crate::bridge::{self, Backend, Endpoint};
use crate::input::InputCmd;
use crate::screen::capture::Frame;

/// Input and capture on the secure desktop (lock screen, sign-in, UAC).
///
/// Only there: on the normal desktop PairDesk works by itself, and helping
/// there would let any program running as the user send SYSTEM input to
/// administrator windows. (`allow-normal-desktop` in the admin-only
/// ProgramData folder lifts this, for tests under Wine, which has no secure
/// desktop.)
struct SecureDesktop {
    allow_normal: bool,
}

impl SecureDesktop {
    fn check(&self) -> Result<(), String> {
        desktop::follow_input_desktop()?;
        let name = desktop::input_desktop_name().unwrap_or_default();
        if name.eq_ignore_ascii_case("Default") && !self.allow_normal {
            return Err("the normal desktop is handled by PairDesk itself".into());
        }
        Ok(())
    }
}

thread_local! {
    static ENIGO: RefCell<Option<Enigo>> = const { RefCell::new(None) };
}

impl Backend for SecureDesktop {
    fn input(&self, cmd: &InputCmd) -> Result<(), String> {
        self.check()?;
        ENIGO.with(|e| {
            let mut e = e.borrow_mut();
            if e.is_none() {
                *e = Some(Enigo::new(&Settings::default()).map_err(|e| e.to_string())?);
            }
            crate::input::apply(e.as_mut().expect("just made"), cmd).map_err(|e| e.to_string())
        })
    }

    fn capture(&self, x: i32, y: i32, width: u32, height: u32) -> Result<Frame, String> {
        self.check()?;
        crate::screen::capture::grab(x, y, width, height)
    }

    fn desktop(&self) -> (String, Option<(i32, i32)>) {
        let _ = desktop::follow_input_desktop();
        (
            desktop::input_desktop_name().unwrap_or_default(),
            crate::screen::capture::cursor_position(),
        )
    }
}

pub fn run(base: PathBuf) -> ! {
    super::set_system_mode();
    let Some(session) = session::current_session() else {
        log::error!("helper: unknown session");
        std::process::exit(1);
    };
    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(l) => l,
        Err(e) => {
            log::error!("helper: can't listen: {e}");
            std::process::exit(1);
        }
    };
    let endpoint = Endpoint {
        port: listener.local_addr().map(|a| a.port()).unwrap_or(0),
        token: bridge::new_token(),
    };
    {
        let token = endpoint.token.clone();
        let backend = SecureDesktop {
            allow_normal: base.join("allow-normal-desktop").exists(),
        };
        std::thread::spawn(move || bridge::serve(listener, token, Arc::new(backend)));
    }
    log::info!("helper for session {session} on port {}", endpoint.port);
    let file = super::endpoint_file(&base, session);
    let exe = std::env::current_exe().unwrap_or_default();
    let mut reader: Option<Option<String>> = None;
    let mut sign_in_server: Option<std::process::Child> = None;

    loop {
        let user = session::user_token(session);
        let sid = user.as_ref().and_then(session::user_sid);
        // Who may read the endpoint: the signed-in user (their PairDesk).
        if reader.as_ref() != Some(&sid) {
            let sddl = match &sid {
                Some(s) => acl::admin_and_reader(s),
                None => acl::ADMIN_ONLY.replace("OICI", ""),
            };
            let json = serde_json::to_vec(&endpoint).unwrap_or_default();
            match std::fs::create_dir_all(file.parent().expect("has a folder"))
                .map_err(|e| e.to_string())
                .and_then(|()| acl::write(&file, &json, &sddl))
            {
                Ok(()) => reader = Some(sid.clone()),
                Err(e) => log::warn!("helper: can't write {}: {e}", file.display()),
            }
        }
        // Nobody signed in: serve phones at the sign-in screen. Someone
        // signed in: their own PairDesk takes over.
        if user.is_none() {
            let running = sign_in_server
                .as_mut()
                .is_some_and(|c| c.try_wait().ok().flatten().is_none());
            if !running {
                match session::spawn_here(&exe, &["--system-mode"]) {
                    Ok(c) => {
                        log::info!("sign-in screen: phone server started");
                        sign_in_server = Some(c);
                    }
                    Err(e) => log::warn!("can't start the sign-in screen server: {e}"),
                }
            }
        } else if let Some(mut c) = sign_in_server.take() {
            log::info!("someone signed in: stopping the sign-in screen server");
            let _ = c.kill();
            let _ = c.wait();
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}
