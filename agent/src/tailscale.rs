// SPDX-License-Identifier: GPL-3.0-or-later
//! What PairDesk knows about Tailscale on this computer.
//!
//! PairDesk doesn't change Tailscale; it only reads `tailscale status
//! --json` (when the command exists) to show the status on the settings
//! page and to tell phones the computer's Tailscale name.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// The `tailscale` command wasn't found.
    NotInstalled,
    /// Installed but not connected (stopped, or waiting for sign-in).
    NotConnected { reason: String },
    Running {
        ips: Vec<String>,
        /// MagicDNS name, e.g. `laptop.tail1234.ts.net`, when MagicDNS is on.
        dns_name: Option<String>,
        /// The account or tailnet name.
        tailnet: Option<String>,
    },
    /// The command exists but its answer couldn't be read.
    Unknown { reason: String },
}

fn cli_path() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        for var in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"] {
            if let Some(dir) = std::env::var_os(var) {
                let p = PathBuf::from(dir).join(r"Tailscale\tailscale.exe");
                if p.is_file() {
                    return Some(p);
                }
            }
        }
        None
    }
    #[cfg(not(windows))]
    {
        let path = std::env::var_os("PATH")?;
        std::env::split_paths(&path)
            .map(|d| d.join("tailscale"))
            .chain([
                PathBuf::from("/usr/bin/tailscale"),
                PathBuf::from("/usr/local/bin/tailscale"),
                PathBuf::from("/snap/bin/tailscale"),
            ])
            .find(|p| p.is_file())
    }
}

/// Runs a command, giving up after `limit`.
fn output_with_timeout(mut cmd: Command, limit: Duration) -> Result<Vec<u8>, String> {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    let mut stdout = child.stdout.take().ok_or("no output")?;
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = std::io::Read::read_to_end(&mut stdout, &mut buf);
        buf
    });
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() > limit => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("tailscale didn't answer in time".into());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(25)),
            Err(e) => return Err(e.to_string()),
        }
    }
    reader.join().map_err(|_| "reader failed".to_string())
}

pub fn query() -> Status {
    let Some(cli) = cli_path() else {
        return Status::NotInstalled;
    };
    let mut cmd = Command::new(cli);
    cmd.args(["status", "--json"]);
    match output_with_timeout(cmd, Duration::from_secs(4)) {
        // `tailscale status` exits non-zero when stopped but still prints JSON.
        Ok(out) => parse_status(&String::from_utf8_lossy(&out)),
        Err(e) => Status::Unknown { reason: e },
    }
}

pub fn parse_status(json: &str) -> Status {
    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Raw {
        backend_state: Option<String>,
        #[serde(rename = "Self")]
        me: Option<Me>,
        current_tailnet: Option<Tailnet>,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Me {
        #[serde(rename = "DNSName")]
        dns_name: Option<String>,
        #[serde(rename = "TailscaleIPs")]
        tailscale_ips: Option<Vec<String>>,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Tailnet {
        name: Option<String>,
        #[serde(rename = "MagicDNSEnabled")]
        magic_dns_enabled: Option<bool>,
    }

    let raw: Raw = match serde_json::from_str(json.trim()) {
        Ok(r) => r,
        Err(e) => {
            return Status::Unknown {
                reason: format!("unexpected tailscale output ({e})"),
            };
        }
    };
    match raw.backend_state.as_deref() {
        Some("Running") => {
            let me = raw.me;
            let ips = me
                .as_ref()
                .and_then(|m| m.tailscale_ips.clone())
                .unwrap_or_default()
                .into_iter()
                .filter(|ip| ip.parse::<std::net::Ipv4Addr>().is_ok())
                .collect();
            let magic = raw
                .current_tailnet
                .as_ref()
                .and_then(|t| t.magic_dns_enabled)
                .unwrap_or(false);
            let dns_name = me
                .and_then(|m| m.dns_name)
                .map(|n| n.trim_end_matches('.').to_string())
                .filter(|n| magic && !n.is_empty());
            Status::Running {
                ips,
                dns_name,
                tailnet: raw.current_tailnet.and_then(|t| t.name),
            }
        }
        Some("NeedsLogin") | Some("NeedsMachineAuth") => Status::NotConnected {
            reason: "Tailscale needs you to sign in.".into(),
        },
        Some("Stopped") => Status::NotConnected {
            reason: "Tailscale is turned off.".into(),
        },
        Some(other) => Status::NotConnected {
            reason: format!("Tailscale is {other}."),
        },
        None => Status::Unknown {
            reason: "unexpected tailscale output".into(),
        },
    }
}

/// Remembers the last answer so pages and phones never wait for the command.
#[derive(Default)]
pub struct Cache {
    last: Mutex<Option<(Instant, Status)>>,
}

impl Cache {
    /// The last known status, without running anything.
    pub fn peek(&self) -> Option<Status> {
        self.last
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .as_ref()
            .map(|(_, s)| s.clone())
    }

    /// Runs `tailscale status` if the last answer is older than `max_age`.
    pub fn refresh(&self, max_age: Duration) -> Status {
        if let Some((at, s)) = self.last.lock().unwrap_or_else(|p| p.into_inner()).as_ref()
            && at.elapsed() < max_age
        {
            return s.clone();
        }
        let status = query();
        *self.last.lock().unwrap_or_else(|p| p.into_inner()) =
            Some((Instant::now(), status.clone()));
        status
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_running_tailnet() {
        let json = r#"{
            "Version": "1.80.0",
            "BackendState": "Running",
            "Self": {
                "HostName": "sandun-pc",
                "DNSName": "sandun-pc.tail1234.ts.net.",
                "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"],
                "Online": true
            },
            "CurrentTailnet": {"Name": "sandun@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
            "Peer": {}
        }"#;
        assert_eq!(
            parse_status(json),
            Status::Running {
                ips: vec!["100.101.102.103".into()],
                dns_name: Some("sandun-pc.tail1234.ts.net".into()),
                tailnet: Some("sandun@example.com".into()),
            }
        );
    }

    #[test]
    fn ignores_the_name_when_magic_dns_is_off() {
        let json = r#"{"BackendState":"Running","Self":{"DNSName":"pc.tail1.ts.net.","TailscaleIPs":["100.64.0.9"]},
                       "CurrentTailnet":{"Name":"x","MagicDNSEnabled":false}}"#;
        match parse_status(json) {
            Status::Running { dns_name, ips, .. } => {
                assert_eq!(dns_name, None);
                assert_eq!(ips, vec!["100.64.0.9"]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn reports_stopped_and_signed_out() {
        assert!(matches!(
            parse_status(r#"{"BackendState":"Stopped"}"#),
            Status::NotConnected { .. }
        ));
        assert!(matches!(
            parse_status(r#"{"BackendState":"NeedsLogin","Self":null}"#),
            Status::NotConnected { reason } if reason.contains("sign in")
        ));
        assert!(matches!(parse_status("not json"), Status::Unknown { .. }));
    }
}
