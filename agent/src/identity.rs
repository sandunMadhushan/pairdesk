// SPDX-License-Identifier: GPL-3.0-or-later
//! This computer's long-term identity: a self-signed TLS certificate.
//!
//! Phones never trust it through a certificate authority. Instead, the
//! SHA-256 fingerprint of the certificate travels in the pairing QR code
//! and the phone pins it, so a look-alike server on the network can't
//! impersonate this computer.

use std::fs;
use std::io;
use std::path::Path;
use std::sync::Arc;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};

const CERT_FILE: &str = "identity-cert.der";
const KEY_FILE: &str = "identity-key.der";

pub struct Identity {
    cert_der: Vec<u8>,
    key_der: Vec<u8>,
    fingerprint: [u8; 32],
}

impl Identity {
    /// Loads the identity from `dir`, creating it on first run.
    pub fn load_or_create(dir: &Path) -> io::Result<Self> {
        let cert_path = dir.join(CERT_FILE);
        let key_path = dir.join(KEY_FILE);
        if cert_path.exists() && key_path.exists() {
            let cert_der = fs::read(&cert_path)?;
            let key_der = fs::read(&key_path)?;
            return Ok(Self::from_der(cert_der, key_der));
        }

        let generated = rcgen::generate_simple_self_signed(vec!["pairdesk.local".to_string()])
            .map_err(io::Error::other)?;
        let cert_der = generated.cert.der().to_vec();
        let key_der = generated.key_pair.serialize_der();
        crate::config::write_private(&key_path, &key_der)?;
        crate::config::write_atomic(&cert_path, &cert_der)?;
        log::info!("created a new identity for this computer");
        Ok(Self::from_der(cert_der, key_der))
    }

    fn from_der(cert_der: Vec<u8>, key_der: Vec<u8>) -> Self {
        let fingerprint: [u8; 32] = Sha256::digest(&cert_der).into();
        Self {
            cert_der,
            key_der,
            fingerprint,
        }
    }

    /// SHA-256 of the DER certificate. Phones pin this value.
    pub fn fingerprint(&self) -> &[u8; 32] {
        &self.fingerprint
    }

    /// Short stable ID used in network discovery (first 8 bytes of the
    /// fingerprint as hex). Not a secret and not used for trust.
    pub fn short_id(&self) -> String {
        self.fingerprint[..8]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    /// Fingerprint as colon-separated groups, for showing to people.
    pub fn fingerprint_display(&self) -> String {
        self.fingerprint
            .chunks(2)
            .map(|c| format!("{:02X}{:02X}", c[0], c[1]))
            .collect::<Vec<_>>()
            .join(":")
    }

    pub fn tls_config(&self) -> Result<Arc<rustls::ServerConfig>, rustls::Error> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let cert = CertificateDer::from(self.cert_der.clone());
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.key_der.clone()));
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)?;
        Ok(Arc::new(config))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_created_once_and_reloaded() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::load_or_create(dir.path()).unwrap();
        let b = Identity::load_or_create(dir.path()).unwrap();
        assert_eq!(a.fingerprint(), b.fingerprint());
        assert_eq!(a.short_id().len(), 16);
        assert!(a.tls_config().is_ok());
    }
}
