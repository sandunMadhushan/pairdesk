# PairDesk

Control your laptop from your phone. Pair once, then just open the app and go —
no codes or "accept" prompts every time.

**Website:** <https://pairdesk.madhushan.me> · **Licence:** GPL-3.0-or-later

> **Status: 0.6 preview (Phase 5).** Pair once with a QR code; after that the phone
> connects whenever the computer is on, with no prompts. Connections are encrypted
> and only paired phones get in. Touchpad, keyboard, shortcut buttons, an app
> launcher, power controls and a live view of the screen, on your Wi-Fi or from
> anywhere with Tailscale.

## What works now

| | |
| --- | --- |
| Computer | Windows 10/11, Linux: X11, and Wayland on GNOME and KDE Plasma (Ubuntu 20.04 / Debian 11 or newer) |
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
| Screen | Live view of the computer's screen. Move the pointer like on the touchpad (tap to click, tap-and-drag to drag, two fingers to scroll or right-click, pinch to zoom; the zoomed view follows the pointer), or switch to tap-to-point. Full screen; red tray dot while watched |
| Anywhere | Away from home, connects through [Tailscale](https://tailscale.com) (free for personal use); picks Wi-Fi or Tailscale by itself |

## Quick start

Download the agent and the app from the
[latest release](https://github.com/sandunMadhushan/pairdesk/releases/latest).

1. **Computer:** run the agent.
   - Windows: put `pairdesk-agent-…-windows-x64.exe` in a folder you'll keep (for
     example `Documents\PairDesk`) and double-click it. If SmartScreen warns about
     an unknown publisher, choose **More info → Run anyway**. When Windows Firewall
     asks, allow **Private networks**.
   - Linux: `chmod +x pairdesk-agent-…-linux-x64 && ./pairdesk-agent-…-linux-x64`.
     In a Wayland session (the default on Ubuntu and Fedora), your desktop asks
     once whether PairDesk may control it: tick **Allow Remote Interaction**, pick
     your screen, keep **Remember This Selection** on and press **Share**.
2. A PairDesk page opens in your browser with a QR code.
3. **Phone:** install the APK, open PairDesk, tap **Scan pairing code** and scan it.

That's it. From now on, open PairDesk on the phone and it connects by itself. The
agent starts when you sign in to the computer and lives in the tray; click the tray
icon to open its page, pair another phone or remove one.

**Updating:** download the new agent and open it. From 0.5.1 on, it replaces the
running older one by itself and the start-at-sign-in entry follows it to its new
file. (Updating from 0.5.0 or earlier: right-click the PairDesk tray icon →
**Stop PairDesk** first, then open the new one.)

Phone and computer must be on the same Wi-Fi. Some guest or campus networks block
devices from talking to each other; a phone hotspot or home Wi-Fi works.

### Use it away from home

1. Install [Tailscale](https://tailscale.com/download) on the computer and on the
   phone, and sign in to both with the same account (free for personal use).
2. Open PairDesk on the phone once at home, so it learns the computer's Tailscale address.
3. Away from home, turn Tailscale on, on the phone, and open PairDesk. The title bar
   shows whether you're connected via Wi-Fi or Tailscale.

The computer must be awake: turn on **Keep this computer awake** on its PairDesk page
if it tends to sleep.

### Known limits

- Windows doesn't let a normal app control windows running as administrator, or the
  lock/login screen.
- Linux Wayland works through the desktop's remote desktop permission (tested on
  GNOME; KDE Plasma offers the same permission). While a phone is connected the desktop shows that it's being
  shared. Desktops without that permission (Sway, Hyprland and other wlroots
  desktops) need an X11 session. Characters that aren't on your keyboard layout
  can't be typed on GNOME Wayland.
- On GNOME, the tray icon needs the AppIndicator extension (Ubuntu has it); without
  it, run the agent again to open its page.
- If you move the agent program to another folder, turn **Start PairDesk when I
  sign in** off and on again on its page.
- On Linux without a desktop, `pairdesk-agent --pair` prints the QR code in the terminal.
- Windows reserves a few shortcuts that no app can send, such as Ctrl+Alt+Delete and
  Win+L. Use the Power tab to lock.
- Screen view can't show the Windows lock screen or UAC prompts.
- Linux power actions use `loginctl`/`systemctl`, which most desktops allow for the
  signed-in user; screen off uses GNOME's display settings, `kscreen-doctor` (KDE)
  or `xset` (X11).

## Build from source

Requirements: [Rust](https://rustup.rs) (stable) and [Flutter](https://flutter.dev) (stable).

```bash
# Desktop agent
cd agent
cargo test
cargo run --release            # see --help for options

# End-to-end test of phone code against the real agent (Linux, needs Xvfb)
tools/e2e.sh
# The same on a headless GNOME Wayland session (mutter, portals, PipeWire)
tools/e2e-wayland.sh

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
| 2 | Power actions, app launcher, custom buttons, phone app lock |
| 3 | Connect from anywhere with Tailscale |
| 4 | Live screen view on Windows and Linux X11 |
| **5** | **Linux agent on Wayland (this release)** |
| 6 | Clipboard sync and file transfer |
| 7 | Signed installers, Microsoft Store, F-Droid, Flathub |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

PairDesk is free software under the [GNU General Public License v3.0 or later](LICENSE).
