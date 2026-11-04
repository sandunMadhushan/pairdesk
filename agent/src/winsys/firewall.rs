// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows Firewall rules for PairDesk.
//!
//! Windows asks "allow PairDesk on which networks?" the first time the
//! agent listens, and its answer is remembered per network profile. The
//! box for Public networks is normally left unticked, and Windows often
//! files the Tailscale adapter under Public (it is an unidentified
//! network), so phones reach the computer over Wi-Fi but never over
//! Tailscale. This writes rules that apply to every profile instead.
//!
//! Adding a rule needs administrator rights, so the settings page asks
//! for them and re-runs the agent with `--allow-firewall`.

#![cfg(windows)]

use std::process::Command;
use std::sync::Mutex;

use crate::winsys::service;

/// Our rules' names. Distinct from anything Windows writes by itself, so
/// finding one means we put it there with the right profiles.
const TCP_RULE: &str = "PairDesk (phones)";
const MDNS_RULE: &str = "PairDesk (finding this computer)";

static WORKING: Mutex<bool> = Mutex::new(false);
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
/// The last answer from `netsh`, so polling the settings page doesn't
/// start a process every second.
static CACHE: Mutex<Option<(std::time::Instant, bool)>> = Mutex::new(None);

fn netsh(args: &[&str]) -> Result<bool, String> {
    let mut cmd = Command::new("netsh");
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    // netsh exits non-zero when nothing matched, which is an answer, not a
    // failure; only a missing or unusable netsh is an error.
    cmd.status()
        .map(|s| s.success())
        .map_err(|e| format!("can't run netsh: {e}"))
}

/// True when our own rules are in place. Their presence is enough: we
/// only ever write them with `profile=any`. Cached for 20 seconds.
pub fn allowed() -> bool {
    {
        let cache = CACHE.lock().unwrap();
        if let Some((at, ok)) = *cache
            && at.elapsed() < std::time::Duration::from_secs(20)
        {
            return ok;
        }
    }
    let ok = query_allowed();
    *CACHE.lock().unwrap() = Some((std::time::Instant::now(), ok));
    ok
}

fn query_allowed() -> bool {
    netsh(&[
        "advfirewall",
        "firewall",
        "show",
        "rule",
        &format!("name={TCP_RULE}"),
    ])
    .unwrap_or(false)
}

/// Replaces every firewall rule for this program with ones that apply to
/// all profiles. Needs administrator rights.
pub fn allow(port: u16) -> Result<(), String> {
    let exe = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .to_string_lossy()
        .into_owned();
    // Anything Windows wrote from its first-run prompt (or an older
    // install at this path) would keep Public blocked, so clear it first.
    for name in [TCP_RULE, MDNS_RULE] {
        let _ = netsh(&[
            "advfirewall",
            "firewall",
            "delete",
            "rule",
            &format!("name={name}"),
        ]);
    }
    let _ = netsh(&[
        "advfirewall",
        "firewall",
        "delete",
        "rule",
        "name=all",
        &format!("program={exe}"),
    ]);
    let rules: [Vec<String>; 2] = [
        vec![
            format!("name={TCP_RULE}"),
            "dir=in".into(),
            "action=allow".into(),
            format!("program={exe}"),
            "protocol=TCP".into(),
            format!("localport={port}"),
            "profile=any".into(),
            "enable=yes".into(),
            "description=Lets your paired phones reach PairDesk on this computer, including over Tailscale.".into(),
        ],
        vec![
            format!("name={MDNS_RULE}"),
            "dir=in".into(),
            "action=allow".into(),
            format!("program={exe}"),
            "protocol=UDP".into(),
            "localport=5353".into(),
            "profile=any".into(),
            "enable=yes".into(),
            "description=Lets phones find this computer on the local network.".into(),
        ],
    ];
    for rule in rules {
        let mut args: Vec<&str> = vec!["advfirewall", "firewall", "add", "rule"];
        args.extend(rule.iter().map(|s| s.as_str()));
        if !netsh(&args)? {
            return Err(
                "Windows refused the firewall rule (administrator rights are needed).".into(),
            );
        }
    }
    *CACHE.lock().unwrap() = None;
    Ok(())
}

/// What the settings page shows.
pub fn status() -> serde_json::Value {
    serde_json::json!({
        "allowed": allowed(),
        "working": *WORKING.lock().unwrap(),
        "error": LAST_ERROR.lock().unwrap().clone(),
    })
}

/// Asks Windows for administrator rights and re-runs the agent with
/// `--allow-firewall`. Returns at once; the page follows the state.
pub fn request() {
    let mut working = WORKING.lock().unwrap();
    if *working {
        return;
    }
    *working = true;
    *LAST_ERROR.lock().unwrap() = None;
    drop(working);
    std::thread::spawn(move || {
        if let Err(e) = service::run_elevated("--allow-firewall") {
            log::warn!("firewall: {e}");
            *LAST_ERROR.lock().unwrap() = Some(e);
        }
        *CACHE.lock().unwrap() = None;
        *WORKING.lock().unwrap() = false;
    });
}
