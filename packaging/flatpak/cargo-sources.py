#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Writes cargo-sources.json for the Flatpak build from agent/Cargo.lock.

Flathub builds without network access, so every crate is listed as a
download with its checksum (from Cargo.lock) and Cargo is pointed at the
unpacked copies. Rerun after changing dependencies:

    packaging/flatpak/cargo-sources.py agent/Cargo.lock > packaging/flatpak/cargo-sources.json
"""
import json
import sys
import tomllib

lock = tomllib.load(open(sys.argv[1], "rb"))
sources = []
for p in lock["package"]:
    src = p.get("source", "")
    if not src:
        continue  # the agent itself
    if not src.startswith("registry+https://github.com/rust-lang/crates.io-index"):
        sys.exit(f"unsupported source for {p['name']}: {src}")
    name, ver, sha = p["name"], p["version"], p["checksum"]
    dest = f"cargo/vendor/{name}-{ver}"
    sources.append({
        "type": "archive",
        "archive-type": "tar-gzip",
        "url": f"https://static.crates.io/crates/{name}/{name}-{ver}.crate",
        "sha256": sha,
        "dest": dest,
    })
    sources.append({
        "type": "inline",
        "contents": json.dumps({"package": sha, "files": {}}),
        "dest": dest,
        "dest-filename": ".cargo-checksum.json",
    })
sources.append({
    "type": "inline",
    "contents": '[source.vendored-sources]\ndirectory = "cargo/vendor"\n\n'
                '[source.crates-io]\nreplace-with = "vendored-sources"\n',
    "dest": "cargo",
    "dest-filename": "config.toml",
})
json.dump(sources, sys.stdout, indent=2)
print()
