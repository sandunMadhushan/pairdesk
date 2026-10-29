// SPDX-License-Identifier: GPL-3.0-or-later
//! Apps a phone can open: the computer's installed apps plus the
//! shortcuts set up on the settings page.
//!
//! A phone only ever sends an ID from the list it was given. It can't
//! send a command line, a path or a URL of its own.
//!
//! - Windows: the Start menu's app list (`Get-StartApps`, which includes
//!   Store apps such as Calculator), falling back to Start menu shortcuts.
//! - Linux: `.desktop` files in the usual XDG folders, including Flatpak
//!   and Snap.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use crate::prefs::{Prefs, ShortcutKind};
use crate::protocol::AppEntry;

/// How long the installed-app list is reused before scanning again.
const CACHE_FOR: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq)]
pub enum Target {
    /// Windows Start menu app, by AppUserModelID or path.
    #[allow(dead_code)]
    StartApp(String),
    /// A file, folder or `.lnk`, opened with its default handler.
    OpenPath(PathBuf),
    /// A web address.
    Url(String),
    /// A program and its arguments, started directly (no shell).
    Program(Vec<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct App {
    pub id: String,
    pub name: String,
    pub kind: &'static str,
    pub target: Target,
}

impl App {
    pub fn entry(&self) -> AppEntry {
        AppEntry {
            id: self.id.clone(),
            name: self.name.clone(),
            kind: self.kind,
        }
    }
}

/// Stable ID from a stable key, so phones can keep favourites.
fn app_id(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    format!("a{}", crate::config::b64(&digest[..9]))
}

#[derive(Default)]
pub struct Catalogue {
    cache: Mutex<Option<(Instant, Arc<Vec<App>>)>>,
}

impl Catalogue {
    /// Installed apps, scanning again if the list is older than a minute.
    pub fn installed(&self) -> Arc<Vec<App>> {
        self.installed_max_age(CACHE_FOR)
    }

    fn installed_max_age(&self, max_age: Duration) -> Arc<Vec<App>> {
        if let Some((at, apps)) = self
            .cache
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .as_ref()
            && at.elapsed() < max_age
        {
            return apps.clone();
        }
        let started = Instant::now();
        let apps = Arc::new(scan_installed());
        log::info!(
            "found {} installed apps in {} ms",
            apps.len(),
            started.elapsed().as_millis()
        );
        *self.cache.lock().unwrap_or_else(|p| p.into_inner()) =
            Some((Instant::now(), apps.clone()));
        apps
    }

    /// Finds an app or shortcut by ID.
    pub fn find(&self, id: &str, prefs: &Prefs) -> Option<App> {
        if let Some(s) = shortcuts(prefs).into_iter().find(|a| a.id == id) {
            return Some(s);
        }
        if let Some(a) = self.installed().iter().find(|a| a.id == id) {
            return Some(a.clone());
        }
        // Maybe it was installed a moment ago.
        self.installed_max_age(Duration::from_secs(5))
            .iter()
            .find(|a| a.id == id)
            .cloned()
    }
}

/// The settings page's shortcuts, as launchable apps.
pub fn shortcuts(prefs: &Prefs) -> Vec<App> {
    prefs
        .shortcuts
        .iter()
        .filter_map(|s| {
            let target = match s.kind {
                ShortcutKind::Url => Target::Url(s.target.clone()),
                ShortcutKind::Path => Target::OpenPath(PathBuf::from(&s.target)),
                ShortcutKind::Program => {
                    let mut argv = vec![s.target.clone()];
                    argv.extend(crate::prefs::split_args(&s.args).ok()?);
                    Target::Program(argv)
                }
            };
            Some(App {
                id: s.id.clone(),
                name: s.name.clone(),
                kind: s.kind_label(),
                target,
            })
        })
        .collect()
}

pub fn launch(app: &App) -> Result<(), String> {
    log::info!("opening \"{}\"", app.name);
    match &app.target {
        Target::Url(url) => open::that_detached(url).map_err(|e| e.to_string()),
        Target::OpenPath(path) => {
            if !path.exists() {
                return Err(format!("{} no longer exists", path.display()));
            }
            open::that_detached(path).map_err(|e| e.to_string())
        }
        Target::Program(argv) => spawn_detached(argv),
        Target::StartApp(app_id) => start_app(app_id),
    }
}

/// Starts a program without a shell and without tying it to the agent.
fn spawn_detached(argv: &[String]) -> Result<(), String> {
    let (program, args) = argv.split_first().ok_or("nothing to run")?;
    let mut cmd = crate::install::host_command(program);
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NEW_CONSOLE | CREATE_NEW_PROCESS_GROUP: console programs get
        // their own window; nothing is shared with the agent.
        cmd.creation_flags(0x0000_0010 | 0x0000_0200);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
        if let Some(home) = std::env::var_os("HOME") {
            cmd.current_dir(home);
        }
    }
    let mut child = cmd.spawn().map_err(|e| format!("{program}: {e}"))?;
    // Reap it when it exits so it doesn't linger as a zombie.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(windows)]
fn start_app(app_id: &str) -> Result<(), String> {
    // explorer.exe resolves both packaged (Store) and classic apps.
    spawn_detached(&[
        "explorer.exe".to_string(),
        format!(r"shell:AppsFolder\{app_id}"),
    ])
}

#[cfg(not(windows))]
fn start_app(_app_id: &str) -> Result<(), String> {
    Err("Start menu apps exist only on Windows".into())
}

// ------------------------------------------------------------- Windows scan

#[cfg(windows)]
fn scan_installed() -> Vec<App> {
    match scan_start_apps() {
        Ok(apps) if !apps.is_empty() => apps,
        Ok(_) => scan_start_menu_links(),
        Err(e) => {
            log::warn!("Get-StartApps failed ({e}); reading Start menu shortcuts instead");
            scan_start_menu_links()
        }
    }
}

#[cfg(windows)]
fn scan_start_apps() -> Result<Vec<App>, String> {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \
             Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress",
        ])
        .stdin(std::process::Stdio::null())
        .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    parse_start_apps(&String::from_utf8_lossy(&out.stdout))
}

/// Parses `Get-StartApps | ConvertTo-Json` (an array, or one object).
#[allow(dead_code)]
fn parse_start_apps(json: &str) -> Result<Vec<App>, String> {
    #[derive(serde::Deserialize)]
    struct Row {
        #[serde(rename = "Name")]
        name: Option<String>,
        #[serde(rename = "AppID")]
        app_id: Option<String>,
    }
    let json = json.trim().trim_start_matches('\u{feff}');
    if json.is_empty() {
        return Ok(Vec::new());
    }
    let rows: Vec<Row> = if json.starts_with('[') {
        serde_json::from_str(json).map_err(|e| e.to_string())?
    } else {
        vec![serde_json::from_str(json).map_err(|e| e.to_string())?]
    };
    let mut apps: Vec<App> = rows
        .into_iter()
        .filter_map(|r| {
            let name = crate::protocol::clean_name(r.name?);
            let aumid = r.app_id?;
            if name.is_empty() || aumid.is_empty() || is_noise(&name) {
                return None;
            }
            Some(App {
                id: app_id(&format!("start:{aumid}")),
                name,
                kind: "app",
                target: Target::StartApp(aumid),
            })
        })
        .collect();
    sort_and_dedupe(&mut apps);
    Ok(apps)
}

#[cfg(windows)]
fn scan_start_menu_links() -> Vec<App> {
    let mut roots = Vec::new();
    if let Some(p) = std::env::var_os("ProgramData") {
        roots.push(PathBuf::from(p).join(r"Microsoft\Windows\Start Menu\Programs"));
    }
    if let Some(p) = std::env::var_os("APPDATA") {
        roots.push(PathBuf::from(p).join(r"Microsoft\Windows\Start Menu\Programs"));
    }
    let mut apps = Vec::new();
    for root in roots {
        walk(&root, 0, &mut |path| {
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if !ext.eq_ignore_ascii_case("lnk") && !ext.eq_ignore_ascii_case("url") {
                return;
            }
            let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
                return;
            };
            if is_noise(name) {
                return;
            }
            apps.push(App {
                id: app_id(&format!("lnk:{}", path.display())),
                name: name.to_string(),
                kind: "app",
                target: Target::OpenPath(path.to_path_buf()),
            });
        });
    }
    sort_and_dedupe(&mut apps);
    apps
}

#[allow(dead_code)]
fn walk(dir: &Path, depth: usize, f: &mut dyn FnMut(&Path)) {
    if depth > 4 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        match entry.file_type() {
            Ok(t) if t.is_dir() => walk(&path, depth + 1, f),
            Ok(t) if t.is_file() => f(&path),
            _ => {}
        }
    }
}

/// Uninstallers, readmes and help files clutter the list.
fn is_noise(name: &str) -> bool {
    let lower = name.to_lowercase();
    [
        "uninstall",
        "readme",
        "read me",
        "release notes",
        "license",
        "documentation",
    ]
    .iter()
    .any(|w| lower.contains(w))
}

fn sort_and_dedupe(apps: &mut Vec<App>) {
    apps.sort_by_key(|a| a.name.to_lowercase());
    apps.dedup_by(|a, b| a.name.eq_ignore_ascii_case(&b.name));
}

// --------------------------------------------------------------- Linux scan

#[cfg(not(windows))]
fn scan_installed() -> Vec<App> {
    scan_desktop_dirs(&desktop_dirs())
}

/// XDG application folders, most specific first.
#[cfg(not(windows))]
fn desktop_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut dirs = Vec::new();
    match std::env::var_os("XDG_DATA_HOME") {
        Some(d) if !d.is_empty() => dirs.push(PathBuf::from(d).join("applications")),
        _ => {
            if let Some(h) = &home {
                dirs.push(h.join(".local/share/applications"));
            }
        }
    }
    if let Some(h) = &home {
        dirs.push(h.join(".local/share/flatpak/exports/share/applications"));
    }
    let data_dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    for d in data_dirs.split(':').filter(|d| !d.is_empty()) {
        dirs.push(PathBuf::from(d).join("applications"));
    }
    dirs.push(PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    // Inside the Flatpak sandbox the computer's own apps are under /run/host.
    if std::env::var_os("FLATPAK_ID").is_some() {
        dirs.push(PathBuf::from("/run/host/usr/share/applications"));
        dirs.push(PathBuf::from("/run/host/usr/local/share/applications"));
    }
    dirs.push(PathBuf::from("/var/lib/snapd/desktop/applications"));
    dirs.dedup();
    dirs
}

/// Reads `.desktop` files. An entry in an earlier folder hides one with
/// the same ID in a later folder, as the XDG spec says.
#[cfg_attr(windows, allow(dead_code))]
pub fn scan_desktop_dirs(dirs: &[PathBuf]) -> Vec<App> {
    let mut seen = std::collections::HashSet::new();
    let mut apps = Vec::new();
    for dir in dirs {
        let mut files = Vec::new();
        collect_desktop_files(dir, dir, 0, &mut files);
        for (desktop_id, path) in files {
            if !seen.insert(desktop_id.clone()) {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let Some(entry) = parse_desktop_entry(&text) else {
                continue;
            };
            apps.push(App {
                id: app_id(&format!("desktop:{desktop_id}")),
                name: entry.name,
                kind: "app",
                target: Target::Program(entry.argv),
            });
        }
    }
    sort_and_dedupe(&mut apps);
    apps
}

#[cfg_attr(windows, allow(dead_code))]
fn collect_desktop_files(root: &Path, dir: &Path, depth: usize, out: &mut Vec<(String, PathBuf)>) {
    if depth > 3 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_desktop_files(root, &path, depth + 1, out);
        } else if path.extension().is_some_and(|e| e == "desktop") {
            let id = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace(['/', '\\'], "-");
            out.push((id, path));
        }
    }
}

#[cfg_attr(windows, allow(dead_code))]
struct DesktopEntry {
    name: String,
    argv: Vec<String>,
}

#[cfg_attr(windows, allow(dead_code))]
fn parse_desktop_entry(text: &str) -> Option<DesktopEntry> {
    let mut in_main = false;
    let (mut name, mut exec, mut kind) = (None, None, None);
    let (mut hidden, mut terminal) = (false, false);
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_main = line == "[Desktop Entry]";
            continue;
        }
        if !in_main || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        match key {
            "Name" => name = Some(value.to_string()),
            "Exec" => exec = Some(value.to_string()),
            "Type" => kind = Some(value.to_string()),
            "NoDisplay" | "Hidden" => hidden |= value.eq_ignore_ascii_case("true"),
            "Terminal" => terminal = value.eq_ignore_ascii_case("true"),
            _ => {}
        }
    }
    if kind.as_deref() != Some("Application") || hidden || terminal {
        return None;
    }
    let name = crate::protocol::clean_name(name?);
    if name.is_empty() || is_noise(&name) {
        return None;
    }
    let argv = parse_exec(&exec?, &name)?;
    Some(DesktopEntry { name, argv })
}

/// Turns a `.desktop` `Exec=` value into argv: handles quoting and drops
/// the `%f`/`%u`… placeholders (PairDesk opens apps without files).
#[cfg_attr(windows, allow(dead_code))]
pub fn parse_exec(exec: &str, name: &str) -> Option<Vec<String>> {
    // String-level escapes first (\\ → \, \s → space).
    let mut unescaped = String::new();
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('s') => unescaped.push(' '),
                Some('\\') => unescaped.push('\\'),
                Some(other) => {
                    unescaped.push('\\');
                    unescaped.push(other);
                }
                None => unescaped.push('\\'),
            }
        } else {
            unescaped.push(c);
        }
    }

    // Then quoting: inside "…", backslash escapes " ` $ and \.
    let mut tokens: Vec<(String, bool)> = Vec::new();
    let mut cur = String::new();
    let (mut in_quotes, mut has_token, mut quoted) = (false, false, false);
    let mut chars = unescaped.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                has_token = true;
                quoted = true;
            }
            '\\' if in_quotes => {
                if let Some(next) = chars.next() {
                    cur.push(next);
                }
            }
            c if c.is_whitespace() && !in_quotes => {
                if has_token {
                    tokens.push((std::mem::take(&mut cur), quoted));
                    has_token = false;
                    quoted = false;
                }
            }
            c => {
                cur.push(c);
                has_token = true;
            }
        }
    }
    if in_quotes {
        return None;
    }
    if has_token {
        tokens.push((cur, quoted));
    }

    let mut argv = Vec::new();
    for (token, quoted) in tokens {
        if !quoted
            && matches!(
                token.as_str(),
                "%f" | "%F" | "%u" | "%U" | "%d" | "%D" | "%n" | "%N" | "%v" | "%m" | "%i"
            )
        {
            continue;
        }
        let mut out = String::new();
        let mut it = token.chars().peekable();
        while let Some(c) = it.next() {
            if c != '%' {
                out.push(c);
                continue;
            }
            match it.next() {
                Some('%') => out.push('%'),
                Some('c') => out.push_str(name),
                Some(_) | None => {} // other field codes expand to nothing
            }
        }
        if !out.is_empty() || quoted {
            argv.push(out);
        }
    }
    if argv.is_empty() { None } else { Some(argv) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_exec_lines() {
        assert_eq!(
            parse_exec("firefox %u", "Firefox").unwrap(),
            vec!["firefox"]
        );
        assert_eq!(
            parse_exec(
                r#"/usr/bin/flatpak run --branch=stable org.gimp.GIMP @@ %F @@"#,
                "GIMP"
            )
            .unwrap(),
            vec![
                "/usr/bin/flatpak",
                "run",
                "--branch=stable",
                "org.gimp.GIMP",
                "@@",
                "@@"
            ]
        );
        assert_eq!(
            parse_exec(r#""/opt/My App/app" --title "%c" 100%%"#, "My App").unwrap(),
            vec!["/opt/My App/app", "--title", "My App", "100%"]
        );
        assert_eq!(
            parse_exec(r#"sh -c "echo \"hi\" \\$HOME""#, "x").unwrap(),
            vec!["sh", "-c", r#"echo "hi" $HOME"#]
        );
        assert!(parse_exec("%U", "x").is_none());
        assert!(parse_exec(r#""unclosed"#, "x").is_none());
    }

    #[test]
    fn scans_desktop_files_with_xdg_precedence() {
        let user = tempfile::tempdir().unwrap();
        let system = tempfile::tempdir().unwrap();
        let write = |dir: &Path, file: &str, body: &str| {
            std::fs::create_dir_all(dir.join(file).parent().unwrap()).unwrap();
            std::fs::write(dir.join(file), body).unwrap();
        };
        let app = |name: &str, exec: &str| {
            format!("[Desktop Entry]\nType=Application\nName={name}\nExec={exec}\n")
        };
        write(
            system.path(),
            "editor.desktop",
            &app("Text Editor", "gedit %U"),
        );
        write(system.path(), "term.desktop", &app("Terminal", "xterm"));
        // The user's copy overrides the system one.
        write(user.path(), "term.desktop", &app("My Terminal", "kitty"));
        // Hidden by the user.
        write(system.path(), "hidden.desktop", &app("Hidden", "x"));
        write(
            user.path(),
            "hidden.desktop",
            "[Desktop Entry]\nType=Application\nName=Hidden\nExec=x\nNoDisplay=true\n",
        );
        // Not apps, or not wanted.
        write(
            system.path(),
            "link.desktop",
            "[Desktop Entry]\nType=Link\nName=Site\nURL=https://x\n",
        );
        write(
            system.path(),
            "cli.desktop",
            &format!("{}Terminal=true\n", app("Top", "top")),
        );
        write(
            system.path(),
            "un.desktop",
            &app("Uninstall Foo", "foo-uninstall"),
        );
        write(
            system.path(),
            "kde/okular.desktop",
            &app("Okular", "okular %U"),
        );
        write(
            system.path(),
            "action.desktop",
            "[Desktop Entry]\nType=Application\nName=Viewer\nExec=viewer\n[Desktop Action New]\nName=Evil\nExec=rm -rf ~\n",
        );

        let apps = scan_desktop_dirs(&[user.path().into(), system.path().into()]);
        let names: Vec<_> = apps.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["My Terminal", "Okular", "Text Editor", "Viewer"]
        );
        let viewer = apps.iter().find(|a| a.name == "Viewer").unwrap();
        assert_eq!(viewer.target, Target::Program(vec!["viewer".into()]));
        // IDs are stable across scans.
        let again = scan_desktop_dirs(&[user.path().into(), system.path().into()]);
        assert_eq!(apps, again);
    }

    #[test]
    fn parses_get_start_apps_output() {
        let json = "\u{feff}[{\"Name\":\"Calculator\",\"AppID\":\"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App\"},\
                    {\"Name\":\"Uninstall Foo\",\"AppID\":\"x\"},{\"Name\":\"Notepad\",\"AppID\":\"{1AC}\\\\notepad.exe\"}]";
        let apps = parse_start_apps(json).unwrap();
        assert_eq!(apps.len(), 2);
        assert_eq!(apps[0].name, "Calculator");
        assert_eq!(
            apps[1].target,
            Target::StartApp(r"{1AC}\notepad.exe".into())
        );
        let one = parse_start_apps(r#"{"Name":"Only","AppID":"o"}"#).unwrap();
        assert_eq!(one.len(), 1);
        assert!(parse_start_apps("").unwrap().is_empty());
    }

    /// A program that exists on the test machine.
    #[cfg(windows)]
    const SHELL: &str = r"C:\Windows\System32\cmd.exe";
    #[cfg(not(windows))]
    const SHELL: &str = "/bin/sh";

    #[test]
    fn shortcuts_become_apps() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = crate::prefs::PrefsStore::load(dir.path()).unwrap();
        store
            .add_shortcut("Mail", ShortcutKind::Url, "https://mail.example.com", "")
            .unwrap();
        store
            .add_shortcut("Shell", ShortcutKind::Program, SHELL, r#"-c "echo hi""#)
            .unwrap();
        let list = shortcuts(store.get());
        assert_eq!(
            list[0].target,
            Target::Url("https://mail.example.com".into())
        );
        assert_eq!(list[0].kind, "url");
        assert_eq!(
            list[1].target,
            Target::Program(vec![SHELL.into(), "-c".into(), "echo hi".into()])
        );
        let cat = Catalogue::default();
        assert_eq!(cat.find(&list[1].id, store.get()).unwrap().name, "Shell");
        assert!(cat.find("nope", store.get()).is_none());
    }
}
