// SPDX-License-Identifier: GPL-3.0-or-later
//! The list of paired phones, saved as JSON in the data folder.

use std::io;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

const FILE: &str = "paired-phones.json";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Phone {
    /// The phone's Ed25519 public key, base64url without padding.
    pub id: String,
    pub name: String,
    /// Unix seconds.
    pub paired_at: u64,
    /// Unix seconds of the last successful connection.
    #[serde(default)]
    pub last_seen: Option<u64>,
    /// Paired to help ("Get help"): removed at this time (Unix seconds),
    /// or earlier when the helper leaves. None for the owner's phones.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub help_until: Option<u64>,
}

#[derive(Serialize, Deserialize, Default)]
struct FileFormat {
    version: u32,
    phones: Vec<Phone>,
}

pub struct PhoneStore {
    path: PathBuf,
    phones: Vec<Phone>,
}

impl PhoneStore {
    pub fn load(dir: &std::path::Path) -> io::Result<Self> {
        let path = dir.join(FILE);
        let phones = match std::fs::read(&path) {
            Ok(bytes) => {
                let parsed: FileFormat = serde_json::from_slice(&bytes)
                    .map_err(|e| io::Error::other(format!("{} is damaged: {e}", path.display())))?;
                parsed.phones
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e),
        };
        Ok(Self { path, phones })
    }

    fn save(&self) -> io::Result<()> {
        let json = serde_json::to_vec_pretty(&FileFormat {
            version: 1,
            phones: self.phones.clone(),
        })
        .map_err(io::Error::other)?;
        crate::config::write_private(&self.path, &json)
    }

    pub fn list(&self) -> &[Phone] {
        &self.phones
    }

    pub fn get(&self, id: &str) -> Option<&Phone> {
        self.phones.iter().find(|p| p.id == id)
    }

    pub fn is_paired(&self, id: &str) -> bool {
        self.get(id).is_some()
    }

    /// Adds a phone, or renames it if it pairs again. `help_until`: a
    /// helper's temporary access (see `help_until` on [`Phone`]).
    pub fn add(&mut self, id: &str, name: &str, help_until: Option<u64>) -> io::Result<()> {
        let now = crate::config::unix_now();
        match self.phones.iter_mut().find(|p| p.id == id) {
            Some(p) => {
                p.name = name.to_string();
                p.last_seen = Some(now);
                // An owner's phone stays one, even if it also helps.
                if p.help_until.is_some() || help_until.is_none() {
                    p.help_until = help_until;
                }
            }
            None => self.phones.push(Phone {
                id: id.to_string(),
                name: name.to_string(),
                paired_at: now,
                last_seen: Some(now),
                help_until,
            }),
        }
        self.save()
    }

    /// Removes a phone. Returns false if it wasn't paired.
    pub fn remove(&mut self, id: &str) -> io::Result<bool> {
        let before = self.phones.len();
        self.phones.retain(|p| p.id != id);
        if self.phones.len() == before {
            return Ok(false);
        }
        self.save()?;
        Ok(true)
    }

    pub fn touch(&mut self, id: &str) {
        if let Some(p) = self.phones.iter_mut().find(|p| p.id == id) {
            p.last_seen = Some(crate::config::unix_now());
            if let Err(e) = self.save() {
                log::warn!("could not save paired phones: {e}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_rename_remove_and_reload() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = PhoneStore::load(dir.path()).unwrap();
        assert!(s.list().is_empty());
        s.add("k1", "Pixel", None).unwrap();
        s.add("k2", "Galaxy", None).unwrap();
        s.add("k1", "Pixel 7", None).unwrap();
        s.add("k3", "Helper", Some(123)).unwrap();
        // A paired phone that later helps keeps its full access.
        s.add("k2", "Galaxy", Some(456)).unwrap();

        let mut s = PhoneStore::load(dir.path()).unwrap();
        assert_eq!(s.list().len(), 3);
        assert_eq!(s.get("k1").unwrap().name, "Pixel 7");
        assert!(s.remove("k1").unwrap());
        assert!(!s.remove("k1").unwrap());

        let s = PhoneStore::load(dir.path()).unwrap();
        assert!(!s.is_paired("k1"));
        assert!(s.is_paired("k2"));
        assert_eq!(s.get("k2").unwrap().help_until, None);
        assert_eq!(s.get("k3").unwrap().help_until, Some(123));
    }
}
