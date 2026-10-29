// SPDX-License-Identifier: GPL-3.0-or-later
//! Files between the phone and the computer, over the phone's connection.
//!
//! Both directions work the same way (see docs/PROTOCOL.md):
//! `file_offer` → `file_accept` → binary chunks → `file_end` (SHA-256) →
//! `file_done`. The receiver reports `file_progress` every MiB and when it
//! has everything; the sender keeps at most [`WINDOW`] bytes unacknowledged
//! (so a slow link doesn't pile up memory or starve the touchpad) and sends
//! `file_end` only once all bytes are acknowledged.
//!
//! Received files go to `Downloads/PairDesk`, written to a hidden part file
//! first and renamed once the checksum matches; names are cleaned and never
//! overwrite an existing file.

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;
use tokio::sync::mpsc;

use crate::protocol::ServerMsg;

pub const MAGIC: &[u8; 4] = b"PDF1";
/// File bytes per binary message.
pub const CHUNK: usize = 128 * 1024;
/// Bytes the sender may have on the way before hearing `file_progress`.
pub const WINDOW: u64 = 4 * 1024 * 1024;
/// The receiver reports progress this often.
pub const PROGRESS_EVERY: u64 = 1024 * 1024;
/// Largest file accepted from a phone.
pub const MAX_SIZE: u64 = 64 * 1024 * 1024 * 1024;
/// Files a phone may be sending at the same time.
pub const MAX_INCOMING: usize = 8;
/// File ids the agent picks start here; phones use lower ones.
pub const AGENT_FIDS: u32 = 1 << 31;
/// Longest file name kept (characters).
const MAX_NAME: usize = 150;

/// `MAGIC | fid u32 | offset u64`, little-endian, then the bytes.
pub fn chunk_message(fid: u32, offset: u64, data: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(16 + data.len());
    m.extend_from_slice(MAGIC);
    m.extend_from_slice(&fid.to_le_bytes());
    m.extend_from_slice(&offset.to_le_bytes());
    m.extend_from_slice(data);
    m
}

pub fn parse_chunk(m: &[u8]) -> Option<(u32, u64, &[u8])> {
    if m.len() < 16 || &m[..4] != MAGIC {
        return None;
    }
    let fid = u32::from_le_bytes(m[4..8].try_into().ok()?);
    let offset = u64::from_le_bytes(m[8..16].try_into().ok()?);
    Some((fid, offset, &m[16..]))
}

/// A file name that is safe on Windows and Linux: no folders, no control
/// or reserved characters, not a reserved device name, not hidden.
pub fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let mut out: String = base
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '|' | '?' | '*' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    out = out.trim().trim_matches('.').trim().to_string();
    if out.chars().count() > MAX_NAME {
        // Keep the extension.
        let (stem, ext) = split_ext(&out);
        let keep = MAX_NAME.saturating_sub(ext.chars().count());
        out = stem.chars().take(keep).collect::<String>() + ext;
    }
    let (stem, _) = split_ext(&out);
    const RESERVED: [&str; 22] = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    if RESERVED.iter().any(|r| r.eq_ignore_ascii_case(stem.trim())) {
        out = format!("_{out}");
    }
    if out.is_empty() {
        out = "file".into();
    }
    out
}

/// `("photo", ".jpg")`; names without a dot (or starting with one) have no
/// extension.
fn split_ext(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 && name.len() - i <= 12 => (&name[..i], &name[i..]),
        _ => (name, ""),
    }
}

/// `dir/name`, or `dir/name (2).ext` … if taken.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = split_ext(name);
    (2..)
        .map(|n| dir.join(format!("{stem} ({n}){ext}")))
        .find(|p| !p.exists())
        .expect("some name is free")
}

/// Where files from phones are saved.
pub fn downloads_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("PAIRDESK_DOWNLOADS") {
        return PathBuf::from(d);
    }
    let base = directories::UserDirs::new()
        .and_then(|u| u.download_dir().map(Path::to_path_buf))
        .or_else(|| directories::BaseDirs::new().map(|b| b.home_dir().join("Downloads")))
        .unwrap_or_else(std::env::temp_dir);
    base.join("PairDesk")
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ------------------------------------------------------------- receiving

/// A file a phone is sending.
pub struct Incoming {
    pub name: String,
    pub size: u64,
    pub received: u64,
    dir: PathBuf,
    part: PathBuf,
    file: Option<File>,
    hasher: Sha256,
    reported: u64,
    /// Entry in the settings page's list.
    pub transfer: u64,
}

impl Incoming {
    pub fn begin(dir: &Path, name: &str, size: u64, transfer: u64) -> Result<Incoming, String> {
        if size > MAX_SIZE {
            return Err("That file is too big.".into());
        }
        std::fs::create_dir_all(dir).map_err(|e| format!("Can't create {}: {e}", dir.display()))?;
        let part = dir.join(format!(
            ".pairdesk-{}.part",
            crate::config::b64(&crate::config::random_bytes::<6>())
        ));
        let file = File::create(&part).map_err(|e| format!("Can't save the file: {e}"))?;
        Ok(Incoming {
            name: safe_name(name),
            size,
            received: 0,
            dir: dir.to_path_buf(),
            part,
            file: Some(file),
            hasher: Sha256::new(),
            reported: 0,
            transfer,
        })
    }

    /// Appends a chunk; returns the byte count to report, when it's time.
    pub fn write(&mut self, offset: u64, data: &[u8]) -> Result<Option<u64>, String> {
        if offset != self.received {
            return Err("Parts of the file arrived out of order.".into());
        }
        if self.received + data.len() as u64 > self.size {
            return Err("The file is bigger than announced.".into());
        }
        let file = self.file.as_mut().ok_or("already finished")?;
        file.write_all(data)
            .map_err(|e| format!("Can't save the file: {e}"))?;
        self.hasher.update(data);
        self.received += data.len() as u64;
        if self.received - self.reported >= PROGRESS_EVERY || self.received == self.size {
            self.reported = self.received;
            return Ok(Some(self.received));
        }
        Ok(None)
    }

    /// Checks size and checksum, then gives the file its real name.
    pub fn finish(mut self, sha256: &str) -> Result<PathBuf, String> {
        let file = self.file.take().ok_or("already finished")?;
        if self.received != self.size {
            return Err("The file arrived incomplete.".into());
        }
        file.sync_all()
            .map_err(|e| format!("Can't save the file: {e}"))?;
        drop(file);
        let digest = hex(&std::mem::take(&mut self.hasher).finalize());
        if !digest.eq_ignore_ascii_case(sha256.trim()) {
            return Err("The file was damaged on the way (checksum mismatch).".into());
        }
        let path = unique_path(&self.dir, &self.name);
        std::fs::rename(&self.part, &path).map_err(|e| format!("Can't save the file: {e}"))?;
        Ok(path)
    }
}

impl Drop for Incoming {
    /// Not finished (cancelled, failed, connection lost): no half file left.
    fn drop(&mut self) {
        self.file.take();
        let _ = std::fs::remove_file(&self.part);
    }
}

// --------------------------------------------------------------- sending

/// A file on this computer to send to phones.
pub struct Outbound {
    pub path: PathBuf,
    pub name: String,
    pub size: u64,
    /// Delete `path` once every phone is done with it (a browser upload).
    pub temporary: bool,
}

impl Drop for Outbound {
    fn drop(&mut self) {
        if self.temporary {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

impl Outbound {
    pub fn from_path(path: &Path) -> Result<Outbound, String> {
        let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if !meta.is_file() {
            return Err(format!("{} isn't a file", path.display()));
        }
        Ok(Outbound {
            path: path.to_path_buf(),
            name: safe_name(&path.file_name().unwrap_or_default().to_string_lossy()),
            size: meta.len(),
            temporary: false,
        })
    }
}

/// What the phone says about a file the agent is sending.
#[derive(Debug)]
pub enum Reply {
    Accepted,
    Progress(u64),
    Done { ok: bool, msg: Option<String> },
    Cancelled(Option<String>),
}

/// Sends one file over a connection. `frames` carries binary messages,
/// `replies` JSON ones, `answers` what the phone says; `progress` is told
/// how far along it is.
pub async fn send(
    fid: u32,
    file: &Outbound,
    frames: mpsc::UnboundedSender<Vec<u8>>,
    replies: mpsc::UnboundedSender<ServerMsg>,
    mut answers: mpsc::UnboundedReceiver<Reply>,
    progress: impl Fn(u64),
) -> Result<(), String> {
    let gone = || "The phone disconnected.".to_string();
    replies
        .send(ServerMsg::FileOffer {
            fid,
            name: file.name.clone(),
            size: file.size,
        })
        .map_err(|_| gone())?;
    match tokio::time::timeout(Duration::from_secs(120), answers.recv()).await {
        Ok(Some(Reply::Accepted)) => {}
        Ok(Some(Reply::Cancelled(msg))) => {
            return Err(msg.unwrap_or_else(|| "Declined on the phone.".into()));
        }
        Ok(Some(other)) => return Err(format!("unexpected answer: {other:?}")),
        Ok(None) => return Err(gone()),
        Err(_) => return Err("The phone didn't answer.".into()),
    }

    let mut f = tokio::fs::File::open(&file.path)
        .await
        .map_err(|e| format!("Can't read {}: {e}", file.path.display()))?;
    let mut hasher = Sha256::new();
    let mut sent = 0u64;
    let mut acked = 0u64;
    let mut buf = vec![0u8; CHUNK];
    while sent < file.size {
        while sent - acked >= WINDOW {
            match tokio::time::timeout(Duration::from_secs(60), answers.recv()).await {
                Ok(Some(Reply::Progress(n))) => {
                    acked = acked.max(n.min(sent));
                    progress(acked);
                }
                Ok(Some(Reply::Cancelled(msg))) => {
                    return Err(msg.unwrap_or_else(|| "Cancelled on the phone.".into()));
                }
                Ok(Some(_)) => {}
                Ok(None) => return Err(gone()),
                Err(_) => return Err("The phone stopped receiving.".into()),
            }
        }
        let want = CHUNK.min((file.size - sent) as usize);
        let n = f
            .read(&mut buf[..want])
            .await
            .map_err(|e| format!("Can't read {}: {e}", file.path.display()))?;
        if n == 0 {
            return Err("The file got shorter while sending.".into());
        }
        hasher.update(&buf[..n]);
        frames
            .send(chunk_message(fid, sent, &buf[..n]))
            .map_err(|_| gone())?;
        sent += n as u64;
        // Take any progress that's already here, without waiting.
        while let Ok(r) = answers.try_recv() {
            match r {
                Reply::Progress(n) => {
                    acked = acked.max(n.min(sent));
                    progress(acked);
                }
                Reply::Cancelled(msg) => {
                    return Err(msg.unwrap_or_else(|| "Cancelled on the phone.".into()));
                }
                _ => {}
            }
        }
    }
    // Chunks and messages travel on different queues: wait until the phone
    // has every byte, so `file_end` can't overtake the last chunk.
    while acked < file.size {
        match tokio::time::timeout(Duration::from_secs(60), answers.recv()).await {
            Ok(Some(Reply::Progress(n))) => {
                acked = acked.max(n.min(sent));
                progress(acked);
            }
            Ok(Some(Reply::Cancelled(msg))) => {
                return Err(msg.unwrap_or_else(|| "Cancelled on the phone.".into()));
            }
            Ok(Some(_)) => {}
            Ok(None) => return Err(gone()),
            Err(_) => return Err("The phone stopped receiving.".into()),
        }
    }
    replies
        .send(ServerMsg::FileEnd {
            fid,
            sha256: hex(&hasher.finalize()),
        })
        .map_err(|_| gone())?;
    loop {
        match tokio::time::timeout(Duration::from_secs(120), answers.recv()).await {
            Ok(Some(Reply::Progress(n))) => progress(n.min(file.size)),
            Ok(Some(Reply::Done { ok: true, .. })) => {
                progress(file.size);
                return Ok(());
            }
            Ok(Some(Reply::Done { ok: false, msg })) | Ok(Some(Reply::Cancelled(msg))) => {
                return Err(msg.unwrap_or_else(|| "The phone couldn't save it.".into()));
            }
            Ok(Some(Reply::Accepted)) => {}
            Ok(None) => return Err(gone()),
            Err(_) => return Err("The phone didn't confirm the file.".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_round_trip() {
        let m = chunk_message(7, 1 << 33, b"hello");
        assert_eq!(&m[..4], b"PDF1");
        assert_eq!(parse_chunk(&m), Some((7, 1 << 33, &b"hello"[..])));
        assert_eq!(parse_chunk(b"PDS1............"), None, "screen frame");
        assert_eq!(parse_chunk(b"PDF1"), None, "too short");
    }

    #[test]
    fn cleans_names() {
        assert_eq!(safe_name("photo.jpg"), "photo.jpg");
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name(r"C:\Windows\system32\evil.dll"), "evil.dll");
        assert_eq!(safe_name("a<b>c:d\"e|f?g*h.txt"), "a_b_c_d_e_f_g_h.txt");
        assert_eq!(safe_name("CON"), "_CON");
        assert_eq!(safe_name("nul.txt"), "_nul.txt");
        assert_eq!(safe_name("..."), "file");
        assert_eq!(safe_name(".hidden"), "hidden");
        assert_eq!(safe_name("trailing. "), "trailing");
        assert_eq!(safe_name("line\nbreak.txt"), "line_break.txt");
        let long = format!("{}.pdf", "x".repeat(400));
        let cut = safe_name(&long);
        assert_eq!(cut.chars().count(), 150);
        assert!(cut.ends_with(".pdf"));
        assert_eq!(safe_name("ශ්‍රී ලංකාව.png"), "ශ්‍රී ලංකාව.png");
    }

    #[test]
    fn never_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "1").unwrap();
        std::fs::write(dir.path().join("a (2).txt"), "2").unwrap();
        assert_eq!(
            unique_path(dir.path(), "a.txt"),
            dir.path().join("a (3).txt")
        );
        assert_eq!(unique_path(dir.path(), "b"), dir.path().join("b"));
    }

    #[test]
    fn receives_checks_and_names_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let data: Vec<u8> = (0..3 * PROGRESS_EVERY as usize / 2)
            .map(|i| i as u8)
            .collect();
        let mut inc = Incoming::begin(dir.path(), "../report.pdf", data.len() as u64, 1).unwrap();
        let mut reports = Vec::new();
        for (i, c) in data.chunks(CHUNK).enumerate() {
            if let Some(n) = inc.write((i * CHUNK) as u64, c).unwrap() {
                reports.push(n);
            }
        }
        assert_eq!(reports.len(), 2, "every MiB and at the end: {reports:?}");
        assert_eq!(*reports.last().unwrap(), data.len() as u64);
        let sha = hex(&Sha256::digest(&data));
        let path = inc.finish(&sha).unwrap();
        assert_eq!(path, dir.path().join("report.pdf"));
        assert_eq!(std::fs::read(&path).unwrap(), data);
        assert_eq!(
            std::fs::read_dir(dir.path()).unwrap().count(),
            1,
            "no part file left"
        );
    }

    #[test]
    fn refuses_bad_files_and_leaves_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let mut inc = Incoming::begin(dir.path(), "x.bin", 4, 1).unwrap();
        assert!(inc.write(1, b"a").is_err(), "out of order");
        inc.write(0, b"abcd").unwrap();
        assert!(inc.write(4, b"e").is_err(), "too long");
        assert!(inc.finish("00").unwrap_err().contains("checksum"));
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);

        let inc = Incoming::begin(dir.path(), "y.bin", 10, 2).unwrap();
        drop(inc); // connection lost
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
        assert!(Incoming::begin(dir.path(), "z", MAX_SIZE + 1, 3).is_err());
    }

    #[tokio::test]
    async fn sends_with_flow_control_and_checksum() {
        let dir = tempfile::tempdir().unwrap();
        let data: Vec<u8> = (0..(WINDOW as usize + 3 * CHUNK + 5))
            .map(|i| (i * 7) as u8)
            .collect();
        let path = dir.path().join("big.bin");
        std::fs::write(&path, &data).unwrap();
        let out = Outbound::from_path(&path).unwrap();
        let (ftx, mut frx) = mpsc::unbounded_channel();
        let (rtx, mut rrx) = mpsc::unbounded_channel();
        let (atx, arx) = mpsc::unbounded_channel();
        let task = tokio::spawn(async move { send(5, &out, ftx, rtx, arx, |_| {}).await });

        assert!(
            matches!(rrx.recv().await, Some(ServerMsg::FileOffer { fid: 5, size, .. }) if size == data.len() as u64)
        );
        atx.send(Reply::Accepted).unwrap();
        // Without progress reports, only a window's worth is sent.
        let mut got = Vec::new();
        while got.len() < WINDOW as usize {
            let m = frx.recv().await.unwrap();
            let (fid, off, bytes) = parse_chunk(&m).unwrap();
            assert_eq!((fid, off as usize), (5, got.len()));
            got.extend_from_slice(bytes);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(frx.try_recv().is_err(), "waits for the phone");
        atx.send(Reply::Progress(got.len() as u64)).unwrap();
        while got.len() < data.len() {
            let m = frx.recv().await.unwrap();
            got.extend_from_slice(parse_chunk(&m).unwrap().2);
        }
        assert_eq!(got, data);
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            rrx.try_recv().is_err(),
            "file_end waits for the last progress"
        );
        atx.send(Reply::Progress(data.len() as u64)).unwrap();
        let Some(ServerMsg::FileEnd { sha256, .. }) = rrx.recv().await else {
            panic!()
        };
        assert_eq!(sha256, hex(&Sha256::digest(&data)));
        atx.send(Reply::Done {
            ok: true,
            msg: None,
        })
        .unwrap();
        task.await.unwrap().unwrap();
    }
}
