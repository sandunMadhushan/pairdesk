// SPDX-License-Identifier: GPL-3.0-or-later
//! Windows: puts the PairDesk icon and version details into the .exe
//! (shown by Explorer, the taskbar, the firewall prompt and SmartScreen).

fn main() {
    println!("cargo:rerun-if-changed=pairdesk.rc");
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
    embed_resource::compile(
        "pairdesk.rc",
        [
            format!("PD_VERSION_NUM={numeric}"),
            format!("PD_VERSION_STR=\\\"{version}\\\""),
        ],
    )
    .manifest_optional()
    .unwrap();
}
