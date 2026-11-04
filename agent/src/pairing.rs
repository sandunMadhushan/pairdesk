// SPDX-License-Identifier: GPL-3.0-or-later
//! One-time pairing codes and the link the phone scans.
//!
//! A code is 16 random bytes, valid for a few minutes and usable once.
//! It reaches the phone only through the QR code on this screen, which is
//! what proves the phone's owner is sitting at this computer.

use std::time::{Duration, Instant};

use subtle::ConstantTimeEq;

/// How long a pairing code stays valid.
pub const CODE_LIFETIME: Duration = Duration::from_secs(10 * 60);

/// How long a helper keeps access after pairing ("Get help").
pub const HELP_LIFETIME: Duration = Duration::from_secs(2 * 60 * 60);

pub struct PairingCode {
    token: String,
    expires: Instant,
    /// A "Get help" code: the phone gets temporary, limited access.
    help: bool,
}

impl PairingCode {
    pub fn new() -> Self {
        Self::with_lifetime(CODE_LIFETIME)
    }

    pub fn with_lifetime(lifetime: Duration) -> Self {
        Self {
            token: crate::config::b64(&crate::config::random_bytes::<16>()),
            expires: Instant::now() + lifetime,
            help: false,
        }
    }

    /// A code that lets someone help: temporary, limited access.
    pub fn for_help() -> Self {
        Self {
            help: true,
            ..Self::new()
        }
    }

    pub fn is_help(&self) -> bool {
        self.help
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn is_expired(&self) -> bool {
        Instant::now() >= self.expires
    }

    pub fn remaining(&self) -> Duration {
        self.expires.saturating_duration_since(Instant::now())
    }

    /// True if `candidate` is this code and it hasn't expired.
    pub fn matches(&self, candidate: &str) -> bool {
        !self.is_expired() && bool::from(self.token.as_bytes().ct_eq(candidate.as_bytes()))
    }
}

/// Where the shareable link points; the part after `#` never leaves the
/// phone (browsers don't send it), and the app reads it.
pub const SHARE_BASE: &str = "https://pairdesk.madhushan.me/p#";

/// Everything the phone needs, as a `pairdesk://pair?...` link (the QR
/// code) or a shareable `https://` link (sent by message).
pub struct PairingLink<'a> {
    pub name: &'a str,
    pub fingerprint: &'a [u8; 32],
    pub token: &'a str,
    pub port: u16,
    /// IPv4 addresses and, when Tailscale has MagicDNS on, its name.
    pub addresses: &'a [String],
    /// `host:port/id` of the relay this computer is reachable through.
    pub relay: Option<&'a str>,
    pub help: bool,
}

impl PairingLink<'_> {
    fn query(&self) -> String {
        let addrs = self.addresses.join(",");
        let mut q = format!(
            "v={}&n={}&fp={}&t={}&p={}&a={}",
            crate::protocol::PROTOCOL_VERSION,
            percent_encode(self.name),
            crate::config::b64(self.fingerprint),
            self.token,
            self.port,
            addrs
        );
        if let Some(r) = self.relay {
            q.push_str(&format!("&r={}", percent_encode(r)));
        }
        if self.help {
            q.push_str("&h=1");
        }
        q
    }

    pub fn to_uri(&self) -> String {
        format!("pairdesk://pair?{}", self.query())
    }

    pub fn to_share(&self) -> String {
        format!("{SHARE_BASE}{}", self.query())
    }
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_matches_only_itself_and_expires() {
        let code = PairingCode::new();
        assert_eq!(code.token().len(), 22);
        assert!(code.matches(code.token()));
        assert!(!code.matches("wrong"));
        assert!(!code.matches(""));

        let expired = PairingCode::with_lifetime(Duration::ZERO);
        assert!(!expired.matches(expired.token()));
    }

    #[test]
    fn link_encodes_name_and_addresses() {
        let fp = [0xABu8; 32];
        let link = PairingLink {
            name: "Sandun's laptop",
            fingerprint: &fp,
            token: "TOKEN",
            port: 47800,
            addresses: &[
                "192.168.1.5".into(),
                "10.0.0.2".into(),
                "pc.tail1.ts.net".into(),
            ],
            relay: None,
            help: false,
        }
        .to_uri();
        assert!(link.starts_with("pairdesk://pair?v=2&n=Sandun%27s%20laptop&fp="));
        assert!(link.ends_with("&t=TOKEN&p=47800&a=192.168.1.5,10.0.0.2,pc.tail1.ts.net"));
    }

    #[test]
    fn share_link_carries_the_relay_and_help() {
        let fp = [1u8; 32];
        let link = PairingLink {
            name: "PC",
            fingerprint: &fp,
            token: "TOKEN",
            port: 47800,
            addresses: &[],
            relay: Some("relay.example.org:443/0123abcd"),
            help: true,
        };
        let share = link.to_share();
        assert!(share.starts_with("https://pairdesk.madhushan.me/p#v=2&n=PC&fp="));
        assert!(share.ends_with("&a=&r=relay.example.org%3A443%2F0123abcd&h=1"));
        assert_eq!(
            &share[SHARE_BASE.len()..],
            &link.to_uri()["pairdesk://pair?".len()..]
        );
    }
}
