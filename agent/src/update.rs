// SPDX-License-Identifier: GPL-3.0-or-later
//! Updates from GitHub Releases.
//!
//! Every release carries `latest.json` (the version and, for each kind of
//! install, the file to download with its SHA-256) and `latest.json.sig`, an
//! Ed25519 signature made by the release workflow with a key only the
//! project holds. PairDesk checks the signature against the public key built
//! into it, then the file's size and SHA-256, before it touches anything.
//!
//! Installing depends on how PairDesk was installed ([`install::Kind`]):
//! - Windows setup: run the new setup silently; it stops this copy, replaces
//!   the files and starts the new version.
//! - Program file (Windows .exe, Linux binary, AppImage): rename the running
//!   file aside, put the new one in its place and start it; it takes over
//!   from this copy like any newer release does (see `instance`).
//! - .deb/.rpm: the settings page links to the download; the package
//!   manager installs it.
//! - Microsoft Store, Flathub: the store updates PairDesk; no checks here.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::install::Kind;

pub const MANIFEST_URL: &str =
    "https://github.com/sandunMadhushan/pairdesk/releases/latest/download/latest.json";
/// The release workflow's public key (raw Ed25519, base64).
pub const PUBLIC_KEY: &str = "mPqsTySowXha+X+KMh49/y3HgcepbYP8QvYdpIGnwaU=";
const RELEASES_PAGE: &str = "https://github.com/sandunMadhushan/pairdesk/releases/latest";

const MAX_MANIFEST: u64 = 64 * 1024;
const MAX_DOWNLOAD: u64 = 300 * 1024 * 1024;
/// First check a little after start, then once a day.
const FIRST_CHECK: Duration = Duration::from_secs(60);
const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

static GLOBAL: std::sync::OnceLock<Arc<Updater>> = std::sync::OnceLock::new();

/// The running agent's updater (the settings page uses it).
pub fn global() -> Option<&'static Arc<Updater>> {
    GLOBAL.get()
}

pub fn set_global(u: Arc<Updater>) {
    let _ = GLOBAL.set(u);
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub version: String,
    #[serde(default)]
    pub date: String,
    /// The release page (what's new).
    #[serde(default)]
    pub notes_url: String,
    /// "windows-x64-setup", "windows-x64", "linux-x64", "linux-x64-appimage",
    /// "linux-x64-deb", "android-arm64", …
    pub assets: BTreeMap<String, Asset>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Asset {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

/// Where updates come from; tests point it at a local server and key.
#[derive(Clone)]
pub struct Source {
    pub manifest_url: String,
    pub key: VerifyingKey,
}

impl Source {
    /// GitHub Releases and the project's key. `PAIRDESK_UPDATE_MANIFEST` and
    /// `PAIRDESK_UPDATE_KEY` replace them for tests (whoever can set this
    /// program's environment can already replace the program itself).
    pub fn github() -> Self {
        let key = std::env::var("PAIRDESK_UPDATE_KEY")
            .ok()
            .and_then(|k| parse_key(&k))
            .unwrap_or_else(|| parse_key(PUBLIC_KEY).expect("PUBLIC_KEY is a base64 Ed25519 key"));
        Self {
            manifest_url: std::env::var("PAIRDESK_UPDATE_MANIFEST")
                .unwrap_or_else(|_| MANIFEST_URL.into()),
            key,
        }
    }

    /// Only HTTPS, except to this computer (tests).
    fn allowed(url: &str) -> bool {
        url.starts_with("https://") || url.starts_with("http://127.0.0.1:")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Status {
    /// Not checked yet (or checks are off).
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading {
        done: u64,
        total: u64,
    },
    /// Downloaded and handed over; this copy is about to be replaced.
    Installing,
    Failed {
        message: String,
    },
}

pub struct Updater {
    pub kind: Kind,
    source: Source,
    data_dir: PathBuf,
    inner: Mutex<Inner>,
}

struct Inner {
    status: Status,
    latest: Option<Manifest>,
    checked_at: Option<u64>,
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(60 * 10)))
        .timeout_connect(Some(Duration::from_secs(15)))
        .user_agent(concat!("PairDesk/", env!("CARGO_PKG_VERSION")))
        .build()
        .into()
}

/// GETs a small resource (the manifest or its signature).
fn get_small(url: &str) -> Result<Vec<u8>, String> {
    if !Source::allowed(url) {
        return Err(format!("not an https address: {url}"));
    }
    let resp = agent()
        .get(url)
        .call()
        .map_err(|e| format!("couldn't reach GitHub: {e}"))?;
    let mut body = Vec::new();
    resp.into_body()
        .into_reader()
        .take(MAX_MANIFEST + 1)
        .read_to_end(&mut body)
        .map_err(|e| e.to_string())?;
    if body.len() as u64 > MAX_MANIFEST {
        return Err("the update information is too large".into());
    }
    Ok(body)
}

/// Fetches and checks the signed manifest.
pub fn fetch(source: &Source) -> Result<Manifest, String> {
    let manifest = get_small(&source.manifest_url)?;
    let sig = get_small(&format!("{}.sig", source.manifest_url))?;
    verify(&source.key, &manifest, &sig)?;
    let m: Manifest =
        serde_json::from_slice(&manifest).map_err(|e| format!("bad update information: {e}"))?;
    if m.assets.values().any(|a| !Source::allowed(&a.url)) {
        return Err("the update information lists a download that isn't https".into());
    }
    Ok(m)
}

fn parse_key(b64: &str) -> Option<VerifyingKey> {
    use base64::Engine;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .ok()?;
    VerifyingKey::from_bytes(&raw.try_into().ok()?).ok()
}

/// `sig` is the base64 signature file (raw 64 bytes are accepted too).
pub fn verify(key: &VerifyingKey, data: &[u8], sig: &[u8]) -> Result<(), String> {
    use base64::Engine;
    let raw = if sig.len() == 64 {
        sig.to_vec()
    } else {
        base64::engine::general_purpose::STANDARD
            .decode(String::from_utf8_lossy(sig).trim())
            .map_err(|_| "the update signature is damaged")?
    };
    let sig = Signature::from_slice(&raw).map_err(|_| "the update signature is damaged")?;
    key.verify(data, &sig)
        .map_err(|_| "the update information isn't signed by PairDesk; ignoring it".to_string())
}

impl Updater {
    pub fn new(kind: Kind, source: Source, data_dir: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            kind,
            source,
            data_dir,
            inner: Mutex::new(Inner {
                status: Status::Idle,
                latest: None,
                checked_at: None,
            }),
        })
    }

    fn set(&self, status: Status) {
        self.inner.lock().unwrap().status = status;
    }

    pub fn status(&self) -> Status {
        self.inner.lock().unwrap().status.clone()
    }

    /// The newer release, if one was found.
    pub fn available(&self) -> Option<Manifest> {
        self.inner.lock().unwrap().latest.clone()
    }

    /// For the settings page.
    pub fn snapshot(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        let latest = inner.latest.as_ref();
        let asset = latest.and_then(|m| self.kind.asset_key().and_then(|k| m.assets.get(k)));
        json!({
            "kind": self.kind.label(),
            // The store updates it; nothing to show but that.
            "store": self.kind.store_updates(),
            "current": env!("CARGO_PKG_VERSION"),
            "latest": latest.map(|m| m.version.clone()),
            "notes_url": latest.map(|m| m.notes_url.clone()).filter(|u| !u.is_empty())
                .unwrap_or_else(|| RELEASES_PAGE.into()),
            // Can this copy install it by itself?
            "can_install": asset.is_some(),
            "checked_at": inner.checked_at,
            "state": inner.status,
        })
    }

    /// Asks GitHub for the latest release. Returns true if it's newer.
    pub fn check(&self) -> Result<bool, String> {
        if self.kind.store_updates() {
            return Ok(false);
        }
        if matches!(
            self.status(),
            Status::Downloading { .. } | Status::Installing | Status::Checking
        ) {
            return Ok(self.available().is_some());
        }
        self.set(Status::Checking);
        let result = fetch(&self.source);
        let mut inner = self.inner.lock().unwrap();
        inner.checked_at = Some(crate::config::unix_now());
        match result {
            Ok(m) if crate::instance::is_older(env!("CARGO_PKG_VERSION"), &m.version) => {
                log::info!("PairDesk {} is available", m.version);
                inner.latest = Some(m);
                inner.status = Status::Available;
                Ok(true)
            }
            Ok(_) => {
                inner.latest = None;
                inner.status = Status::UpToDate;
                Ok(false)
            }
            Err(e) => {
                log::info!("update check failed: {e}");
                inner.status = Status::Failed { message: e.clone() };
                Err(e)
            }
        }
    }

    /// Checks now and then while `enabled()` says so.
    pub fn run_checks(self: &Arc<Self>, enabled: impl Fn() -> bool + Send + 'static) {
        if self.kind.store_updates() {
            return;
        }
        let me = self.clone();
        let _ = std::thread::Builder::new()
            .name("update-check".into())
            .spawn(move || {
                std::thread::sleep(FIRST_CHECK);
                loop {
                    if enabled() {
                        let _ = me.check();
                    }
                    std::thread::sleep(CHECK_EVERY);
                }
            });
    }

    /// Downloads, checks and installs the available update on its own
    /// thread. `quit` stops this copy when that is what installing needs.
    pub fn install(self: &Arc<Self>, quit: Arc<dyn Fn() + Send + Sync>) -> Result<(), String> {
        let manifest = self.available().ok_or("No update is available.")?;
        let key = self
            .kind
            .asset_key()
            .ok_or("This copy of PairDesk is updated by your package manager.")?;
        let asset = manifest
            .assets
            .get(key)
            .cloned()
            .ok_or("This release has no download for this kind of install.")?;
        if matches!(
            self.status(),
            Status::Downloading { .. } | Status::Installing
        ) {
            return Ok(());
        }
        self.set(Status::Downloading {
            done: 0,
            total: asset.size,
        });
        let me = self.clone();
        let _ = std::thread::Builder::new()
            .name("update-install".into())
            .spawn(
                move || match me.download_and_apply(&manifest, &asset, quit) {
                    Ok(()) => me.set(Status::Installing),
                    Err(e) => {
                        log::warn!("update failed: {e}");
                        me.set(Status::Failed { message: e });
                    }
                },
            );
        Ok(())
    }

    fn download_and_apply(
        &self,
        manifest: &Manifest,
        asset: &Asset,
        quit: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<(), String> {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        // Program files are swapped in place, so they're downloaded next to
        // the program (a rename can't cross drives). A setup goes to the
        // data folder.
        let target = match &self.kind {
            Kind::AppImage(image) => image.clone(),
            _ => exe.clone(),
        };
        let dest = match self.kind {
            Kind::WindowsSetup => {
                let dir = self.data_dir.join("updates");
                std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                dir.join(format!("PairDesk-Setup-{}.exe", manifest.version))
            }
            _ => sibling(&target, ".download"),
        };
        self.download(asset, &dest).inspect_err(|_| {
            let _ = std::fs::remove_file(&dest);
        })?;
        log::info!("downloaded PairDesk {}; installing", manifest.version);
        match self.kind {
            Kind::WindowsSetup => run_setup(&dest),
            Kind::Service => {
                // The service manager starts the new file after `quit`.
                swap(&target, &dest)?;
                quit();
                return Ok(());
            }
            _ => {
                swap(&target, &dest)?;
                start_new(&target, &self.data_dir.join("update.log"))
            }
        }
        .inspect_err(|_| {
            let _ = std::fs::remove_file(&dest);
        })?;
        // The setup stops this copy itself (and a new program file takes
        // over); if neither happens within a minute, stop anyway so the
        // new version can start at the next sign-in.
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(60));
            quit();
        });
        Ok(())
    }

    fn download(&self, asset: &Asset, dest: &Path) -> Result<(), String> {
        if !Source::allowed(&asset.url) {
            return Err("the download isn't https".into());
        }
        if asset.size > MAX_DOWNLOAD {
            return Err("the download is unexpectedly large".into());
        }
        let resp = agent()
            .get(&asset.url)
            .call()
            .map_err(|e| format!("download failed: {e}"))?;
        let mut reader = resp.into_body().into_reader().take(asset.size + 1);
        let mut file = std::fs::File::create(dest).map_err(|e| {
            format!(
                "can't write next to PairDesk ({e}). Download the new version from {RELEASES_PAGE}"
            )
        })?;
        let mut hash = Sha256::new();
        let mut done = 0u64;
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            done += n as u64;
            if done > asset.size {
                return Err("the download is larger than announced".into());
            }
            hash.update(&buf[..n]);
            file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            self.set(Status::Downloading {
                done,
                total: asset.size,
            });
        }
        file.sync_all().map_err(|e| e.to_string())?;
        if done != asset.size {
            return Err("the download was cut short".into());
        }
        let got = hex(&hash.finalize());
        if !got.eq_ignore_ascii_case(asset.sha256.trim()) {
            return Err("the download is damaged (checksum mismatch)".into());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dest, std::fs::Permissions::from_mode(0o755))
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `dir/.name<suffix>`, hidden next to `path`.
fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!(".{name}{suffix}"))
}

/// Puts `new` where `target` is. The running file is renamed aside first
/// (Windows allows renaming, not overwriting, a running program); it is
/// deleted on the next start ([`cleanup`]).
pub fn swap(target: &Path, new: &Path) -> Result<(), String> {
    let old = sibling(target, ".old");
    let _ = std::fs::remove_file(&old);
    let old = if old.exists() {
        // Still running from a previous update on Windows: pick a new name.
        sibling(target, &format!(".old-{}", std::process::id()))
    } else {
        old
    };
    std::fs::rename(target, &old).map_err(|e| format!("can't replace PairDesk: {e}"))?;
    if let Err(e) = std::fs::rename(new, target) {
        let _ = std::fs::rename(&old, target);
        return Err(format!("can't replace PairDesk: {e}"));
    }
    Ok(())
}

/// Removes what a previous update left behind.
pub fn cleanup(data_dir: &Path) {
    let targets = [
        std::env::current_exe().ok(),
        std::env::var_os("APPIMAGE").map(PathBuf::from),
    ];
    for target in targets.into_iter().flatten() {
        let (Some(dir), Some(name)) = (target.parent(), target.file_name()) else {
            continue;
        };
        let prefix = format!(".{}.old", name.to_string_lossy());
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.flatten() {
                if e.file_name().to_string_lossy().starts_with(&prefix) {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
    }
    let _ = std::fs::remove_dir_all(data_dir.join("updates"));
}

/// Starts the new program file. It takes over from this copy. Its first
/// words go to `log` (there's no terminal to show them).
fn start_new(program: &Path, log: &Path) -> Result<(), String> {
    let mut cmd = std::process::Command::new(program);
    cmd.args(relaunch_args(std::env::args().skip(1)));
    detach(&mut cmd);
    if let Ok(f) = std::fs::File::create(log) {
        if let Ok(f2) = f.try_clone() {
            cmd.stdout(f2);
        }
        cmd.stderr(f);
    }
    cmd.spawn()
        .map(|_| ())
        .map_err(|e| format!("can't start the new version: {e}"))
}

/// The new copy keeps this copy's port, address and tray choice.
fn relaunch_args(current: impl Iterator<Item = String>) -> Vec<String> {
    let mut out = vec!["--background".to_string(), "--updated".to_string()];
    let mut it = current;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--port" | "-p" | "--bind" => {
                if let Some(v) = it.next() {
                    out.extend([a, v]);
                }
            }
            "--no-tray" => out.push(a),
            _ => {}
        }
    }
    out
}

/// Runs the Windows setup silently in update mode.
fn run_setup(setup: &Path) -> Result<(), String> {
    let mut cmd = std::process::Command::new(setup);
    cmd.args(["/S", "/UPDATE"]);
    detach(&mut cmd);
    cmd.spawn()
        .map(|_| ())
        .map_err(|e| format!("can't start the setup: {e}"))
}

fn detach(cmd: &mut std::process::Command) {
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    /// Serves files on 127.0.0.1; `files` gets the base address and
    /// returns (path, bytes) pairs. Returns the base address.
    fn serve(files: impl FnOnce(&str) -> Vec<(String, Vec<u8>)>) -> String {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://{}", server.server_addr().to_ip().unwrap());
        let files = files(&base);
        std::thread::spawn(move || {
            for req in server.incoming_requests() {
                let body = files
                    .iter()
                    .find(|(p, _)| *p == req.url())
                    .map(|(_, b)| b.clone());
                let _ = match body {
                    Some(b) => req.respond(tiny_http::Response::from_data(b)),
                    None => req.respond(tiny_http::Response::empty(404)),
                };
            }
        });
        base
    }

    fn key() -> SigningKey {
        SigningKey::from_bytes(&[7u8; 32])
    }

    fn manifest_for(base: &str, version: &str, file: &[u8]) -> Vec<u8> {
        let asset = |name: &str| json!({"url": format!("{base}/{name}"), "sha256": hex(&Sha256::digest(file)), "size": file.len()});
        serde_json::to_vec(&json!({
            "version": version,
            "date": "2026-10-29",
            "notes_url": "https://github.com/sandunMadhushan/pairdesk/releases/tag/v9.0.0",
            "assets": {"linux-x64": asset("agent"), "windows-x64": asset("agent")},
        }))
        .unwrap()
    }

    fn signed(manifest: &[u8]) -> Vec<u8> {
        use base64::Engine;
        let sig = key().sign(manifest).to_bytes();
        base64::engine::general_purpose::STANDARD
            .encode(sig)
            .into_bytes()
    }

    fn source(base: &str) -> Source {
        Source {
            manifest_url: format!("{base}/latest.json"),
            key: key().verifying_key(),
        }
    }

    #[test]
    fn the_built_in_key_is_valid() {
        let _ = Source::github();
    }

    #[test]
    fn accepts_what_the_release_workflow_signs() {
        // `openssl pkeyutl -sign -rawin -inkey <key [7; 32]> -in <"release"> | base64`,
        // exactly as .github/workflows/release.yml signs latest.json.
        let sig = "8LdA3PEtQ7ECUHn4blJ5spQzf4BcFaokESZOPU4KAFnAlZzoEPF/T/kMQKVIn0sUJFoP/irgcRA8MNeZ0MpYDw==\n";
        verify(&key().verifying_key(), b"release", sig.as_bytes()).unwrap();
    }

    #[test]
    fn signature_files_are_base64_or_raw() {
        use base64::Engine;
        let k = key();
        let sig = k.sign(b"release");
        let b64 = base64::engine::general_purpose::STANDARD.encode(sig.to_bytes());
        verify(&k.verifying_key(), b"release", b64.as_bytes()).unwrap();
        verify(&k.verifying_key(), b"release", &sig.to_bytes()).unwrap();
        assert!(verify(&k.verifying_key(), b"other", b64.as_bytes()).is_err());
    }

    #[test]
    fn finds_a_signed_newer_release() {
        let file = b"new agent".to_vec();
        let dir = tempfile::tempdir().unwrap();
        let f = file.clone();
        let base = serve(move |base| {
            let manifest = manifest_for(base, "9.0.0", &f);
            vec![
                ("/latest.json.sig".into(), signed(&manifest)),
                ("/latest.json".into(), manifest),
                ("/agent".into(), f),
            ]
        });
        let u = Updater::new(Kind::Portable, source(&base), dir.path().into());
        assert!(u.check().unwrap());
        assert_eq!(u.status(), Status::Available);
        let snap = u.snapshot();
        assert_eq!(snap["latest"], "9.0.0");
        assert_eq!(snap["can_install"], true);

        // The download is checked, then swapped in for the program file.
        let target = dir.path().join("pairdesk-agent");
        std::fs::write(&target, b"old agent").unwrap();
        let m = u.available().unwrap();
        let asset = &m.assets["linux-x64"];
        let dl = sibling(&target, ".download");
        u.download(asset, &dl).unwrap();
        swap(&target, &dl).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), file);
        assert_eq!(
            std::fs::read(sibling(&target, ".old")).unwrap(),
            b"old agent"
        );

        // A damaged download is refused.
        let bad = Asset {
            sha256: "00".repeat(32),
            ..asset.clone()
        };
        assert!(u.download(&bad, &dl).unwrap_err().contains("damaged"));
    }

    #[test]
    fn ignores_unsigned_or_older_releases() {
        let dir = tempfile::tempdir().unwrap();
        let base = serve(|base| {
            let newer = manifest_for(base, "9.0.0", b"x");
            let older = manifest_for(base, "0.0.1", b"x");
            vec![
                ("/forged/latest.json".into(), newer),
                ("/forged/latest.json.sig".into(), signed(b"something else")),
                ("/old/latest.json.sig".into(), signed(&older)),
                ("/old/latest.json".into(), older),
            ]
        });
        let forged = Updater::new(
            Kind::Portable,
            source(&format!("{base}/forged")),
            dir.path().into(),
        );
        assert!(forged.check().unwrap_err().contains("isn't signed"));
        assert!(forged.available().is_none());

        let old = Updater::new(
            Kind::Portable,
            source(&format!("{base}/old")),
            dir.path().into(),
        );
        assert!(!old.check().unwrap());
        assert_eq!(old.status(), Status::UpToDate);

        // Stores update PairDesk themselves: no checks at all.
        let store = Updater::new(Kind::Flatpak, source(&base), dir.path().into());
        assert!(!store.check().unwrap());
        assert_eq!(store.status(), Status::Idle);
        let package = Updater::new(Kind::SystemPackage, source(&base), dir.path().into());
        assert_eq!(package.snapshot()["can_install"], false);
    }

    #[test]
    fn the_new_copy_keeps_port_and_tray_choice() {
        let args = [
            "--port",
            "47831",
            "--pair",
            "--no-tray",
            "--bind",
            "0.0.0.0",
            "--background",
        ]
        .map(String::from);
        assert_eq!(
            relaunch_args(args.into_iter()),
            [
                "--background",
                "--updated",
                "--port",
                "47831",
                "--no-tray",
                "--bind",
                "0.0.0.0"
            ]
        );
    }

    #[test]
    fn cleanup_removes_leftovers() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("updates")).unwrap();
        std::fs::write(dir.path().join("updates/PairDesk-Setup-9.exe"), b"x").unwrap();
        cleanup(dir.path());
        assert!(!dir.path().join("updates").exists());
    }

    #[test]
    fn only_https_downloads() {
        assert!(Source::allowed("https://github.com/x"));
        assert!(Source::allowed("http://127.0.0.1:8000/x"));
        assert!(!Source::allowed("http://github.com/x"));
        assert!(!Source::allowed("file:///etc/passwd"));
    }
}
