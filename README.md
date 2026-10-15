# PairDesk

Control your laptop from your phone. Pair once, then just open the app and go —
no codes or "accept" prompts every time.

**Website:** <https://pairdesk.madhushan.me> · **Licence:** GPL-3.0-or-later

> **Status: 0.3 preview (Phase 2).** Pair once with a QR code; after that the phone
> connects whenever the computer is on, with no prompts. Connections are encrypted
> and only paired phones get in. Touchpad, keyboard, shortcut buttons, an app
> launcher and power controls. Works over your local Wi-Fi; connecting from
> anywhere (Tailscale) comes in Phase 3.

## What works now

| | |
| --- | --- |
| Computer | Windows 10/11, Linux (X11 session; Wayland comes in Phase 5) |
| Phone | Android 6.0 or newer |
| Pairing | Scan a QR code once. The phone is remembered; remove it any time on the computer |
| Security | TLS with a pinned certificate, Ed25519 sign-in, one-time pairing codes |
| Background | Tray icon, starts when you sign in, finds the computer again if its address changes |
| Touchpad | Move, tap to click, two-finger scroll, two-finger tap for right-click, three-finger tap for middle-click |
| Buttons | Hold **Left** or **Right** and move with another finger to drag |
| Keyboard | Type text, plus Enter, Backspace, Esc, Tab, arrows, Delete, Home/End, Page Up/Down |
| Media | Volume, mute, play/pause, next, previous |
| Shortcut buttons | One-tap shortcuts (Copy, Paste, Alt+Tab, Task Manager…), and your own: key combos, text, apps or power actions |
| Apps | Open any installed app, plus websites, folders and programs you add on the computer's settings page |
| Power | Lock, sleep, screen off, sign out, restart, shut down (each can be switched off on the computer) |
| App lock | Optional fingerprint, face or screen-lock check to open PairDesk |

## Quick start

Download the agent and the app from the
[latest release](https://github.com/sandunMadhushan/pairdesk/releases/latest).

1. **Computer:** run the agent.
   - Windows: put `pairdesk-agent-…-windows-x64.exe` in a folder you'll keep (for
     example `Documents\PairDesk`) and double-click it. If SmartScreen warns about
     an unknown publisher, choose **More info → Run anyway**. When Windows Firewall
     asks, allow **Private networks**.
   - Linux: `chmod +x pairdesk-agent-…-linux-x64 && ./pairdesk-agent-…-linux-x64`
2. A PairDesk page opens in your browser with a QR code.
3. **Phone:** install the APK, open PairDesk, tap **Scan pairing code** and scan it.

That's it. From now on, open PairDesk on the phone and it connects by itself. The
agent starts when you sign in to the computer and lives in the tray; click the tray
icon to open its page, pair another phone or remove one.

Phone and computer must be on the same Wi-Fi. Some guest or campus networks block
devices from talking to each other; a phone hotspot or home Wi-Fi works.

### Known limits

- Windows doesn't let a normal app control windows running as administrator, or the
  lock/login screen.
- Linux Wayland sessions aren't supported yet. On GNOME, the tray icon needs the
  AppIndicator extension; without it, run the agent again to open its page.
- If you move the agent program to another folder, turn **Start PairDesk when I
  sign in** off and on again on its page.
- On Linux without a desktop, `pairdesk-agent --pair` prints the QR code in the terminal.
- Windows reserves a few shortcuts that no app can send, such as Ctrl+Alt+Delete and
  Win+L. Use the Power tab to lock.
- Linux power actions use `loginctl`/`systemctl`, which most desktops allow for the
  signed-in user; screen off uses `xset` (X11).

## Build from source

Requirements: [Rust](https://rustup.rs) (stable) and [Flutter](https://flutter.dev) (stable).

```bash
# Desktop agent
cd agent
cargo test
cargo run --release            # see --help for options

# End-to-end test of phone code against the real agent (Linux, needs Xvfb)
tools/e2e.sh

# Phone app
cd mobile
flutter test
flutter run                     # with a phone connected over USB
flutter build apk --release
```

## Project layout

```text
agent/     Rust desktop agent: TLS server, pairing, settings page, tray, input
mobile/    Flutter phone app (Android now, iPhone later)
docs/      Protocol and security design
tools/     End-to-end test script
```

The protocol and security design are described in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Roadmap

| Phase | Goal |
| --- | --- |
| 0 | Touchpad over home Wi-Fi |
| 1 | One-time QR pairing, encryption, tray app, auto-start, auto-discovery |
| **2** | **Power actions, app launcher, custom buttons, phone app lock (this release)** |
| 3 | Connect from anywhere with Tailscale |
| 4 | Live screen view on Windows |
| 5 | Linux agent on Wayland |
| 6 | Clipboard sync and file transfer |
| 7 | Signed installers, Microsoft Store, F-Droid, Flathub |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

PairDesk is free software under the [GNU General Public License v3.0 or later](LICENSE).
