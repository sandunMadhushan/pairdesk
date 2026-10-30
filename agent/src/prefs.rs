// SPDX-License-Identifier: GPL-3.0-or-later
//! The owner's choices: what paired phones may do, and the shortcuts they
//! can open. Saved as JSON in the data folder and changed only on the
//! settings page, never by a phone.

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::protocol::{Allow, PowerAction};

const FILE: &str = "settings.json";
const MAX_SHORTCUTS: usize = 50;

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Prefs {
    /// Lock, sleep, screen off.
    #[serde(default = "yes")]
    pub allow_power: bool,
    /// Sign out, restart, shut down.
    #[serde(default = "yes")]
    pub allow_session: bool,
    /// Launch installed apps and shortcuts.
    #[serde(default = "yes")]
    pub allow_apps: bool,
    /// See the screen.
    #[serde(default = "yes")]
    pub allow_screen: bool,
    /// Read and set the clipboard.
    #[serde(default = "yes")]
    pub allow_clipboard: bool,
    /// Receive files from phones.
    #[serde(default = "yes")]
    pub allow_files: bool,
    /// Hear the computer's sound; talk through its speakers.
    #[serde(default = "yes")]
    pub allow_audio: bool,
    /// Hear the computer's microphone. Off until the owner turns it on.
    #[serde(default)]
    pub allow_mic: bool,
    #[serde(default)]
    pub shortcuts: Vec<Shortcut>,
    /// Keep the computer from sleeping so phones can always reach it.
    #[serde(default)]
    pub keep_awake: bool,
    /// Look for new releases once a day.
    #[serde(default = "yes")]
    pub check_updates: bool,
    /// Be reachable through a relay when phones can't reach this computer
    /// directly.
    #[serde(default = "yes")]
    pub relay_on: bool,
    /// The relay, `host:port`.
    #[serde(default = "default_relay")]
    pub relay: String,
}

fn default_relay() -> String {
    crate::relay::DEFAULT_RELAY.to_string()
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            allow_power: true,
            allow_session: true,
            allow_apps: true,
            allow_screen: true,
            allow_clipboard: true,
            allow_files: true,
            allow_audio: true,
            allow_mic: false,
            shortcuts: Vec::new(),
            keep_awake: false,
            check_updates: true,
            relay_on: true,
            relay: default_relay(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShortcutKind {
    /// A web address (http or https).
    Url,
    /// A file or folder, opened with its default app.
    Path,
    /// A program, with optional arguments.
    Program,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Shortcut {
    pub id: String,
    pub name: String,
    pub kind: ShortcutKind,
    pub target: String,
    /// Program arguments, split like a command line ("quoted parts" stay together).
    #[serde(default)]
    pub args: String,
}

impl Shortcut {
    /// Kind label sent to phones.
    pub fn kind_label(&self) -> &'static str {
        match self.kind {
            ShortcutKind::Url => "url",
            ShortcutKind::Program => "program",
            ShortcutKind::Path if Path::new(&self.target).is_dir() => "folder",
            ShortcutKind::Path => "file",
        }
    }
}

impl Prefs {
    pub fn allow(&self) -> Allow {
        Allow {
            power: self.allow_power,
            session: self.allow_session,
            apps: self.allow_apps,
            screen: self.allow_screen,
            clipboard: self.allow_clipboard,
            files: self.allow_files,
            audio: self.allow_audio,
            mic: self.allow_mic,
        }
    }

    pub fn allows(&self, action: PowerAction) -> bool {
        if action.ends_session() {
            self.allow_session
        } else {
            self.allow_power
        }
    }
}

pub struct PrefsStore {
    path: PathBuf,
    prefs: Prefs,
}

impl PrefsStore {
    pub fn load(dir: &Path) -> io::Result<Self> {
        let path = dir.join(FILE);
        let prefs = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                log::warn!("{} is damaged ({e}); using defaults", path.display());
                Prefs::default()
            }),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Prefs::default(),
            Err(e) => return Err(e),
        };
        Ok(Self { path, prefs })
    }

    pub fn get(&self) -> &Prefs {
        &self.prefs
    }

    fn save(&self) -> io::Result<()> {
        let json = serde_json::to_vec_pretty(&self.prefs).map_err(io::Error::other)?;
        crate::config::write_private(&self.path, &json)
    }

    pub fn set_permissions(&mut self, power: bool, session: bool, apps: bool) -> io::Result<()> {
        self.prefs.allow_power = power;
        self.prefs.allow_session = session;
        self.prefs.allow_apps = apps;
        self.save()
    }

    pub fn set_allow_screen(&mut self, on: bool) -> io::Result<()> {
        self.prefs.allow_screen = on;
        self.save()
    }

    pub fn set_allow_clipboard(&mut self, on: bool) -> io::Result<()> {
        self.prefs.allow_clipboard = on;
        self.save()
    }

    pub fn set_relay(&mut self, on: bool, address: &str) -> io::Result<()> {
        self.prefs.relay_on = on;
        self.prefs.relay = address.trim().to_string();
        self.save()
    }

    pub fn set_allow_audio(&mut self, on: bool) -> io::Result<()> {
        self.prefs.allow_audio = on;
        self.save()
    }

    pub fn set_allow_mic(&mut self, on: bool) -> io::Result<()> {
        self.prefs.allow_mic = on;
        self.save()
    }

    pub fn set_allow_files(&mut self, on: bool) -> io::Result<()> {
        self.prefs.allow_files = on;
        self.save()
    }

    pub fn set_keep_awake(&mut self, on: bool) -> io::Result<()> {
        self.prefs.keep_awake = on;
        self.save()
    }

    pub fn set_check_updates(&mut self, on: bool) -> io::Result<()> {
        self.prefs.check_updates = on;
        self.save()
    }

    /// Checks and adds a shortcut. Returns a message for people on failure.
    pub fn add_shortcut(
        &mut self,
        name: &str,
        kind: ShortcutKind,
        target: &str,
        args: &str,
    ) -> Result<(), String> {
        let name = crate::protocol::clean_name(name.to_string());
        let target = target.trim().trim_matches('"').trim().to_string();
        let args = args.trim().to_string();
        if name.is_empty() {
            return Err("Give the shortcut a name.".into());
        }
        if target.is_empty() || target.len() > 2048 || args.len() > 2048 {
            return Err("The target is empty or too long.".into());
        }
        if self.prefs.shortcuts.len() >= MAX_SHORTCUTS {
            return Err(format!("You can have up to {MAX_SHORTCUTS} shortcuts."));
        }
        match kind {
            ShortcutKind::Url => {
                let lower = target.to_ascii_lowercase();
                if !(lower.starts_with("https://") || lower.starts_with("http://")) {
                    return Err("Web addresses must start with https:// or http://".into());
                }
                if !args.is_empty() {
                    return Err("Web addresses don't take arguments.".into());
                }
            }
            ShortcutKind::Path => {
                if !Path::new(&target).exists() {
                    return Err(format!("Nothing found at {target}"));
                }
                if !args.is_empty() {
                    return Err("Files and folders don't take arguments.".into());
                }
            }
            ShortcutKind::Program => {
                if !Path::new(&target).is_file() {
                    return Err(format!("No program found at {target}"));
                }
                split_args(&args)?;
            }
        }
        self.prefs.shortcuts.push(Shortcut {
            id: format!(
                "s{}",
                crate::config::b64(&crate::config::random_bytes::<6>())
            ),
            name,
            kind,
            target,
            args,
        });
        self.save().map_err(|e| format!("Couldn't save: {e}"))
    }

    pub fn remove_shortcut(&mut self, id: &str) -> io::Result<bool> {
        let before = self.prefs.shortcuts.len();
        self.prefs.shortcuts.retain(|s| s.id != id);
        if before == self.prefs.shortcuts.len() {
            return Ok(false);
        }
        self.save()?;
        Ok(true)
    }
}

/// Splits program arguments: spaces separate, double quotes group, and
/// `\"` is a literal quote. No shell is involved, so `&`, `|`, `>` etc.
/// are passed through as ordinary characters.
pub fn split_args(s: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut has_token = false;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'"') => {
                cur.push('"');
                chars.next();
                has_token = true;
            }
            '"' => {
                in_quotes = !in_quotes;
                has_token = true;
            }
            c if c.is_whitespace() && !in_quotes => {
                if has_token {
                    out.push(std::mem::take(&mut cur));
                    has_token = false;
                }
            }
            c => {
                cur.push(c);
                has_token = true;
            }
        }
    }
    if in_quotes {
        return Err("A quote in the arguments isn't closed.".into());
    }
    if has_token {
        out.push(cur);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_arguments_without_a_shell() {
        assert_eq!(
            split_args(r#"--new-window "C:\My Files" a\"b x&y"#).unwrap(),
            vec!["--new-window", r"C:\My Files", r#"a"b"#, "x&y"]
        );
        assert_eq!(split_args("  ").unwrap(), Vec::<String>::new());
        assert_eq!(split_args(r#""""#).unwrap(), vec![""]);
        assert!(split_args(r#""open"#).is_err());
    }

    #[test]
    fn defaults_allow_everything_and_survive_reload() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = PrefsStore::load(dir.path()).unwrap();
        assert_eq!(s.get(), &Prefs::default());
        assert!(s.get().allows(PowerAction::ShutDown));

        s.set_permissions(true, false, true).unwrap();
        s.add_shortcut("Docs", ShortcutKind::Url, "https://example.com", "")
            .unwrap();
        let folder = dir.path().to_str().unwrap();
        s.add_shortcut("Data", ShortcutKind::Path, &format!("\"{folder}\""), "")
            .unwrap();

        let s = PrefsStore::load(dir.path()).unwrap();
        assert!(s.get().allows(PowerAction::Lock));
        assert!(!s.get().allows(PowerAction::Restart));
        assert_eq!(s.get().shortcuts.len(), 2);
        assert_eq!(s.get().shortcuts[1].target, folder, "quotes trimmed");
        assert_eq!(s.get().shortcuts[1].kind_label(), "folder");
    }

    #[test]
    fn rejects_bad_shortcuts() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = PrefsStore::load(dir.path()).unwrap();
        let bad = [
            ("", ShortcutKind::Url, "https://x.org", ""),
            ("x", ShortcutKind::Url, "javascript:alert(1)", ""),
            ("x", ShortcutKind::Url, "file:///etc/passwd", ""),
            ("x", ShortcutKind::Path, "/no/such/place", ""),
            ("x", ShortcutKind::Program, "/no/such/program", ""),
            ("x", ShortcutKind::Program, "/bin/sh", "\"unclosed"),
        ];
        for (name, kind, target, args) in bad {
            assert!(
                s.add_shortcut(name, kind, target, args).is_err(),
                "{target}"
            );
        }
        assert!(s.get().shortcuts.is_empty());
    }
}
