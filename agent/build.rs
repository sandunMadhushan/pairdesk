// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows: puts the PairDesk icon and version details into the .exe
//! (shown by Explorer, the taskbar, the firewall prompt and SmartScreen).
//!
//! The resource script is generated with the version written in, since the
//! MSVC and MinGW resource compilers quote macro strings differently.

fn main() {
    println!("cargo:rerun-if-changed=pairdesk.rc.in");
    println!("cargo:rerun-if-changed=pairdesk.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let version = env!("CARGO_PKG_VERSION");
    let mut parts: Vec<u32> = version
        .split(['.', '-', '+'])
        .take(3)
        .map(|p| p.parse().unwrap_or(0))
        .collect();
    parts.resize(3, 0);
    let numeric = format!("{},{},{},0", parts[0], parts[1], parts[2]);
    let dir = std::env::var("CARGO_MANIFEST_DIR")
        .unwrap()
        .replace('\\', "/");
    let rc = std::fs::read_to_string("pairdesk.rc.in")
        .unwrap()
        .replace("@ICON@", &format!("{dir}/pairdesk.ico"))
        .replace("@VERSION_NUM@", &numeric)
        .replace("@VERSION@", version);
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("pairdesk.rc");
    std::fs::write(&out, rc).unwrap();
    embed_resource::compile(&out, embed_resource::NONE)
        .manifest_optional()
        .unwrap();
}
