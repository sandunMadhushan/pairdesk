# PairDesk

Control your laptop from your phone. Pair once, then just open the app and go —
no codes or "accept" prompts every time.

**Website:** <https://pairdesk.madhushan.me> · **Licence:** GPL-3.0-or-later

> **Status: Phase 0 (preview).** Touchpad, mouse buttons, typing and media keys work
> over your home Wi-Fi. There is **no pairing or encryption yet**: anyone on the same
> network can connect while the agent is running. Use it only on a network you trust.
> Pairing arrives in Phase 1.

## What works now

| | |
| --- | --- |
| Laptop | Windows 10/11, Linux (X11 session; Wayland comes in Phase 5) |
| Phone | Android |
| Touchpad | Move, tap to click, two-finger scroll, two-finger tap for right-click, three-finger tap for middle-click |
| Buttons | Hold **Left** or **Right** and move with another finger to drag |
| Keyboard | Type text, plus Enter, Backspace, Esc, Tab, arrows, Delete, Home/End, Page Up/Down |
| Media | Volume, mute, play/pause, next, previous |

## Quick start

Download the agent and the app from the
[latest release](https://github.com/sandunMadhushan/pairdesk/releases/latest).

1. **Laptop:** run the agent.
   - Windows: double-click `pairdesk-agent.exe`. If SmartScreen warns about an unknown
     publisher, choose **More info → Run anyway** (signed builds come with the first release).
     When Windows Firewall asks, allow it on **Private networks**.
   - Linux: `chmod +x pairdesk-agent && ./pairdesk-agent`
2. The agent window shows an address such as `192.168.1.5:47800`.
3. **Phone:** install `pairdesk.apk`, open PairDesk, enter that address and tap **Connect**.

Phone and laptop must be on the same Wi-Fi. Some guest or campus networks block
devices from talking to each other; a phone hotspot or home Wi-Fi works.

### Known limits in Phase 0

- Windows does not let a normal app control windows running as administrator, or the
  lock/login screen.
- The agent runs only while its window is open; auto-start comes in Phase 1.
- Linux Wayland sessions are not supported yet.

## Build from source

Requirements: [Rust](https://rustup.rs) (stable) and [Flutter](https://flutter.dev) (stable).

```bash
# Desktop agent
cd agent
cargo test
cargo run --release            # options: --port 47800 --bind 0.0.0.0

# Phone app
cd mobile
flutter test
flutter run                     # with a phone connected over USB
flutter build apk --release
```

## Project layout

```text
agent/     Rust desktop agent (WebSocket server + input injection)
mobile/    Flutter phone app (Android now, iPhone later)
docs/      Protocol and design notes
```

The wire protocol is described in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Roadmap

| Phase | Goal |
| --- | --- |
| **0** | **Touchpad over home Wi-Fi (this release)** |
| 1 | One-time QR pairing, encryption, tray app, auto-start, auto-discovery |
| 2 | Power actions, app launcher, custom buttons, phone app lock |
| 3 | Connect from anywhere with Tailscale |
| 4 | Live screen view on Windows |
| 5 | Linux agent on Wayland |
| 6 | Clipboard sync and file transfer |
| 7 | Signed installers, Microsoft Store, F-Droid, Flathub |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

PairDesk is free software under the [GNU General Public License v3.0 or later](LICENSE).
