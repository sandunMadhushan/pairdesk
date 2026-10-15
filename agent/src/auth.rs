// SPDX-License-Identifier: GPL-3.0-or-later
//! Checking that a phone holds the private key it claims.
//!
//! The phone signs:
//!
//! ```text
//! "pairdesk-auth-v2" || 0x00 || cert_fingerprint (32) || nonce (32) || phone_public_key (32)
//! ```
//!
//! Including the certificate fingerprint ties the signature to this
//! computer's TLS identity, so a signature captured by a man in the middle
//! can't be replayed to the real computer. The nonce is fresh per
//! connection, so old signatures can't be replayed either.

use ed25519_dalek::{Signature, VerifyingKey};

const CONTEXT: &[u8] = b"pairdesk-auth-v2\0";

/// Parses a phone ID (base64url Ed25519 public key).
pub fn parse_phone_id(id: &str) -> Option<VerifyingKey> {
    let bytes: [u8; 32] = crate::config::unb64(id)?.try_into().ok()?;
    VerifyingKey::from_bytes(&bytes).ok()
}

pub fn signed_message(fingerprint: &[u8; 32], nonce: &[u8; 32], phone: &VerifyingKey) -> Vec<u8> {
    let mut msg = Vec::with_capacity(CONTEXT.len() + 96);
    msg.extend_from_slice(CONTEXT);
    msg.extend_from_slice(fingerprint);
    msg.extend_from_slice(nonce);
    msg.extend_from_slice(phone.as_bytes());
    msg
}

/// True if `sig_b64` is the phone's valid signature for this connection.
pub fn verify(
    phone: &VerifyingKey,
    fingerprint: &[u8; 32],
    nonce: &[u8; 32],
    sig_b64: &str,
) -> bool {
    let Some(bytes) = crate::config::unb64(sig_b64) else {
        return false;
    };
    let Ok(sig_bytes) = <[u8; 64]>::try_from(bytes.as_slice()) else {
        return false;
    };
    let sig = Signature::from_bytes(&sig_bytes);
    phone
        .verify_strict(&signed_message(fingerprint, nonce, phone), &sig)
        .is_ok()
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    pub fn phone_key(seed: u8) -> SigningKey {
        SigningKey::from_bytes(&[seed; 32])
    }

    pub fn sign(key: &SigningKey, fp: &[u8; 32], nonce: &[u8; 32]) -> String {
        let msg = signed_message(fp, nonce, &key.verifying_key());
        crate::config::b64(&key.sign(&msg).to_bytes())
    }

    #[test]
    fn accepts_valid_and_rejects_tampered_signatures() {
        let key = phone_key(7);
        let id = crate::config::b64(key.verifying_key().as_bytes());
        let pk = parse_phone_id(&id).unwrap();
        let fp = [1u8; 32];
        let nonce = [2u8; 32];
        let sig = sign(&key, &fp, &nonce);

        assert!(verify(&pk, &fp, &nonce, &sig));
        assert!(!verify(&pk, &[9u8; 32], &nonce, &sig), "other computer");
        assert!(!verify(&pk, &fp, &[9u8; 32], &sig), "replayed nonce");
        let other = phone_key(8).verifying_key();
        assert!(!verify(&other, &fp, &nonce, &sig), "other phone");
        assert!(!verify(&pk, &fp, &nonce, "not-base64!"));
        assert!(!verify(&pk, &fp, &nonce, ""));
    }

    #[test]
    fn rejects_bad_phone_ids() {
        assert!(parse_phone_id("").is_none());
        assert!(parse_phone_id("abc").is_none());
        assert!(parse_phone_id(&crate::config::b64(&[0u8; 31])).is_none());
    }
}
