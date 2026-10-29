// SPDX-License-Identifier: GPL-3.0-or-later
//! Microsoft Store build only: Windows starts this at sign-in (a package
//! startup task can't pass arguments), and it starts PairDesk quietly.

#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() {
    let Ok(me) = std::env::current_exe() else {
        return;
    };
    let agent = me.with_file_name(if cfg!(windows) {
        "pairdesk-agent.exe"
    } else {
        "pairdesk-agent"
    });
    let _ = std::process::Command::new(agent)
        .arg("--background")
        .spawn();
}
