// SPDX-License-Identifier: GPL-3.0-or-later
//! "Send to phone" in the file manager's right-click menu.
//!
//! - Windows: a "PairDesk phone" shortcut in the Send To folder.
//! - Linux: a GNOME Files (Nautilus) script and a Dolphin service menu,
//!   for whichever is installed.
//!
//! Each runs `pairdesk-agent --send <files>`, which hands the files to the
//! running PairDesk. Refreshed on every start, so they follow the program
//! file when a new version is downloaded elsewhere.

use std::path::Path;

pub fn install(data_dir: &Path) {
    let Ok(exe) = crate::install::program_path() else {
        return;
    };
    let marker = data_dir.join("send-to-menu");
    let current = exe.display().to_string();
    let data_dir = data_dir.to_path_buf();
    std::thread::spawn(move || {
        let fresh =
            std::fs::read_to_string(&marker).is_ok_and(|m| m == current) && platform::present();
        if fresh {
            return;
        }
        match platform::install(&exe) {
            Ok(()) => {
                log::info!("added \"Send to phone\" to the file manager");
                let _ = std::fs::write(data_dir.join("send-to-menu"), current);
            }
            Err(e) => log::warn!("couldn't add \"Send to phone\" to the file manager: {e}"),
        }
    });
}

#[cfg(windows)]
mod platform {
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    fn link() -> Option<PathBuf> {
        let appdata = std::env::var_os("APPDATA")?;
        Some(Path::new(&appdata).join(r"Microsoft\Windows\SendTo\PairDesk phone.lnk"))
    }

    pub fn present() -> bool {
        link().is_some_and(|l| l.exists())
    }

    pub fn install(exe: &Path) -> Result<(), String> {
        let link = link().ok_or("no APPDATA folder")?;
        // Paths go in through the environment: no quoting to get wrong.
        let script = "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:PD_LINK); \
                      $s.TargetPath = $env:PD_EXE; $s.Arguments = '--send'; \
                      $s.IconLocation = $env:PD_EXE + ',0'; \
                      $s.Description = 'Send to your phone with PairDesk'; $s.Save()";
        let status = std::process::Command::new("powershell.exe")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                script,
            ])
            .env("PD_LINK", &link)
            .env("PD_EXE", exe)
            .creation_flags(CREATE_NO_WINDOW)
            .status()
            .map_err(|e| e.to_string())?;
        if status.success() && link.exists() {
            Ok(())
        } else {
            Err(format!("PowerShell failed ({status})"))
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use std::path::{Path, PathBuf};

    const NAME: &str = "Send to phone (PairDesk)";

    fn data_home() -> Option<PathBuf> {
        directories::BaseDirs::new().map(|b| b.data_dir().to_path_buf())
    }

    fn installed(program: &str) -> bool {
        std::env::var_os("PATH")
            .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(program).is_file()))
    }

    fn nautilus_script() -> Option<PathBuf> {
        Some(data_home()?.join("nautilus/scripts").join(NAME))
    }

    fn dolphin_menu() -> Option<PathBuf> {
        Some(data_home()?.join("kio/servicemenus/pairdesk-send.desktop"))
    }

    pub fn present() -> bool {
        let n = !installed("nautilus") || nautilus_script().is_some_and(|p| p.exists());
        let d = !installed("dolphin") || dolphin_menu().is_some_and(|p| p.exists());
        n && d
    }

    /// `'…'` for sh, with `'` written as `'\''`.
    pub fn sh_quote(s: &str) -> String {
        format!("'{}'", s.replace('\'', r"'\''"))
    }

    /// A Desktop Entry `Exec=` argument: quoted, `"` `` ` `` `$` `\` escaped,
    /// then backslashes doubled for the string level.
    pub fn exec_quote(s: &str) -> String {
        let mut q = String::from("\"");
        for c in s.chars() {
            if "\"`$\\".contains(c) {
                q.push('\\');
            }
            q.push(c);
        }
        q.push('"');
        q.replace('\\', "\\\\")
    }

    fn write_exec(path: &Path, content: &str) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(path, content).map_err(|e| e.to_string())?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| e.to_string())
    }

    pub fn install(exe: &Path) -> Result<(), String> {
        let exe = exe.display().to_string();
        let mut done = false;
        if installed("nautilus")
            && let Some(p) = nautilus_script()
        {
            write_exec(
                &p,
                &format!("#!/bin/sh\nexec {} --send \"$@\"\n", sh_quote(&exe)),
            )?;
            done = true;
        }
        if installed("dolphin")
            && let Some(p) = dolphin_menu()
        {
            write_exec(
                &p,
                &format!(
                    "[Desktop Entry]\nType=Service\nMimeType=all/allfiles;\n\
                     X-KDE-ServiceTypes=KonqPopupMenu/Plugin\nActions=send\n\n\
                     [Desktop Action send]\nName={NAME}\nIcon=smartphone\nExec={} --send %F\n",
                    exec_quote(&exe)
                ),
            )?;
            done = true;
        }
        if done {
            Ok(())
        } else {
            Err("no supported file manager found".into())
        }
    }
}

#[cfg(all(test, not(windows)))]
mod tests {
    use super::platform::*;

    #[test]
    fn quotes_paths() {
        assert_eq!(sh_quote("/opt/My Apps/it's"), r"'/opt/My Apps/it'\''s'");
        assert_eq!(exec_quote("/opt/My Apps/a$b"), "\"/opt/My Apps/a\\\\$b\"");
    }
}
