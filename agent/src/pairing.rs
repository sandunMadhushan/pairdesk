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

pub struct PairingCode {
    token: String,
    expires: Instant,
}

impl PairingCode {
    pub fn new() -> Self {
        Self::with_lifetime(CODE_LIFETIME)
    }

    pub fn with_lifetime(lifetime: Duration) -> Self {
        Self {
            token: crate::config::b64(&crate::config::random_bytes::<16>()),
            expires: Instant::now() + lifetime,
        }
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

/// Everything the phone needs, as a `pairdesk://pair?...` link.
pub struct PairingLink<'a> {
    pub name: &'a str,
    pub fingerprint: &'a [u8; 32],
    pub token: &'a str,
    pub port: u16,
    pub addresses: &'a [std::net::Ipv4Addr],
}

impl PairingLink<'_> {
    pub fn to_uri(&self) -> String {
        let addrs = self
            .addresses
            .iter()
            .map(|a| a.to_string())
            .collect::<Vec<_>>()
            .join(",");
        format!(
            "pairdesk://pair?v={}&n={}&fp={}&t={}&p={}&a={}",
            crate::protocol::PROTOCOL_VERSION,
            percent_encode(self.name),
            crate::config::b64(self.fingerprint),
            self.token,
            self.port,
            addrs
        )
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
            addresses: &["192.168.1.5".parse().unwrap(), "10.0.0.2".parse().unwrap()],
        }
        .to_uri();
        assert!(link.starts_with("pairdesk://pair?v=2&n=Sandun%27s%20laptop&fp="));
        assert!(link.ends_with("&t=TOKEN&p=47800&a=192.168.1.5,10.0.0.2"));
    }
}
