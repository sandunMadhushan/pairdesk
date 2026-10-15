// SPDX-License-Identifier: GPL-3.0-or-later
//! Where PairDesk keeps its files, and small helpers for writing them safely.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// Directory holding the identity, paired phones and settings.
///
/// - Windows: `%APPDATA%\PairDesk`
/// - Linux: `$XDG_CONFIG_HOME/pairdesk` (usually `~/.config/pairdesk`)
///
/// `PAIRDESK_HOME` overrides it (used by tests and portable setups).
pub fn data_dir() -> io::Result<PathBuf> {
    let dir = if let Some(custom) = std::env::var_os("PAIRDESK_HOME") {
        PathBuf::from(custom)
    } else if cfg!(windows) {
        let base = directories::BaseDirs::new()
            .ok_or_else(|| io::Error::other("cannot find the user's AppData folder"))?;
        base.config_dir().join("PairDesk")
    } else {
        let base = directories::BaseDirs::new()
            .ok_or_else(|| io::Error::other("cannot find the user's config folder"))?;
        base.config_dir().join("pairdesk")
    };
    fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
    }
    Ok(dir)
}

/// Writes a file by writing a temporary file next to it and renaming it,
/// so a crash never leaves a half-written file behind.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// Like [`write_atomic`] but readable only by the current user on Linux.
/// On Windows the per-user AppData folder already restricts access.
pub fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let tmp = path.with_extension("tmp");
        {
            let mut f = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
        }
        fs::rename(&tmp, path)
    }
    #[cfg(not(unix))]
    {
        write_atomic(path, bytes)
    }
}

/// Current time as seconds since 1970.
pub fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// This computer's name as shown on the phone.
pub fn device_name() -> String {
    let name = gethostname::gethostname().to_string_lossy().into_owned();
    if name.is_empty() {
        "My computer".into()
    } else {
        name
    }
}

/// Random bytes from the operating system.
pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut buf = [0u8; N];
    getrandom::getrandom(&mut buf).expect("the operating system's random generator failed");
    buf
}

pub fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn unb64(text: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(text.trim_end_matches('='))
        .ok()
}
