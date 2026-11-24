# PairDesk

Control your laptop from your phone. Pair once, then just open the app and go —
no codes or "accept" prompts every time.

**Website:** <https://pairdesk.madhushan.me> · **Licence:** GPL-3.0-or-later

> **Status: 0.16.** Now in the
> [Microsoft Store](https://pairdesk.madhushan.me/store/) for Windows.
> Pair once with a QR code or a link; after that the phone
> connects whenever the computer is on, with no prompts. Connections are encrypted
> and only paired phones get in. Touchpad, keyboard, shortcut buttons, an app
> launcher, power controls, a live view of the screen, clipboard and files, on your
> Wi-Fi or from anywhere (directly when the networks allow it, otherwise through the
> PairDesk relay), two-way sound, and
> "Get help" links to help someone else for a while. A new look on the phone and on
> the computer, with a dark mode. Installers for Windows and
> Linux, automatic updates, smooth H.264 screen view, and on Windows the lock
> screen, sign-in screen and admin prompts.

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
| Clipboard | Copy the computer's clipboard to the phone, send the phone's clipboard to the computer, or paste it straight into the computer's active window |
| Files | Phone → computer: pick files, or **Share → PairDesk** from any app; saved in `Downloads/PairDesk`. Computer → phone: drop files on PairDesk's page, or right-click → **Send to → PairDesk phone** (Windows), "Send to phone (PairDesk)" (GNOME Files, Dolphin); saved in `Download/PairDesk` |
| Sound | Hear what the computer plays (videos, music, calls) on the phone; talk through the computer's speakers (hold to talk or hands-free); hear the computer's microphone (off unless allowed on the computer; red tray dot while used) |
| Anywhere | Away from home, the PairDesk relay introduces the phone to the computer and they open a direct path through their routers when the networks allow it; otherwise the relay carries the connection (TLS to the relay, and still encrypted end to end; up to 4 relays, with a relay check in the app). Also IPv6, and a port the computer asks the router to open (UPnP / NAT-PMP). Picks the best route by itself |
| Links | Pair by sending a link from the computer to the phone (chat, email) instead of scanning the QR code |
| Get help | Someone presses **Get help** on their computer and sends you the link: you see and control their screen for up to 2 hours, without power, files or sound, and they can end it any time |

## Quick start

Get the downloads from [pairdesk.madhushan.me](https://pairdesk.madhushan.me/#download)
or the [latest release](https://github.com/sandunMadhushan/pairdesk/releases/latest).

1. **Computer:** install PairDesk.
   - Windows: get PairDesk from the
     [Microsoft Store](https://pairdesk.madhushan.me/store/); the Store keeps
     it up to date. Or run `PairDesk-Setup-…-x64.exe` from GitHub (no administrator
     rights needed). If SmartScreen warns about an unknown publisher, choose **More
     info → Run anyway**. When Windows Firewall asks, allow **Private networks**.
   - Linux: install the `.deb` (Ubuntu, Debian, Mint) or `.rpm` (Fedora,
     openSUSE), or make the AppImage executable and run it. Then open PairDesk
     from the app menu. In a Wayland session (the default on Ubuntu and Fedora),
     your desktop asks once whether PairDesk may control it: tick **Allow Remote
     Interaction** (keep **Allow Clipboard Access** on), pick your screen, keep
     **Remember This Selection** on and press **Share**.
2. PairDesk opens with a QR code: in its own window on Windows, as a page in
   your browser on Linux.
3. **Phone:** install the APK, open PairDesk, tap **Scan pairing code** and scan it.

That's it. From now on, open PairDesk on the phone and it connects by itself. The
agent starts when you sign in to the computer and lives in the tray; click the tray
icon to open it, pair another phone or remove one.

**Updating:** PairDesk checks for new releases once a day and offers **Install
update** on its page (the Windows setup, the program files and the AppImage
update themselves; with the `.deb`/`.rpm`, install the new package). Each update
is signed; PairDesk checks the signature and checksum first. The phone app (from
GitHub) does the same: it offers **Update**, downloads the APK, checks it against
the signed manifest and lets Android install it over the old copy — Android asks
once for permission to let PairDesk install apps, and always asks you to confirm
each install. **Settings → About → Check for updates** asks straight away. The
F-Droid build leaves updating to F-Droid.

Upgrading the phone app from 0.7 or earlier: uninstall the old app first (it was
signed with a test key), install 0.8 and pair again.

Phone and computer must be on the same Wi-Fi. Some guest or campus networks block
devices from talking to each other; a phone hotspot or home Wi-Fi works.

### Pair with a link instead of the QR code

On the computer, under the QR code, press **Copy** next to the link and send it to
your phone (a chat with yourself, an email). Tap it on the phone: PairDesk opens
and pairs. The link works once, for 10 minutes. In the app, **Paste a link** works
too.

Links go from the computer to the phone, not the other way: the phone connects to
the computer, so the computer has to hand out its address and a one-time code.

### Help someone else

1. They install PairDesk on their computer, open it and press **Get help** (Home).
2. They send you the link it shows (chat, email).
3. You tap it on your phone and confirm. You can see and control their screen;
   power, session, files and sound stay off for you.
4. Access ends after 2 hours, 5 minutes after you disconnect, or when they press
   **End help**. Your phone then forgets that computer.

Across the internet this goes through the PairDesk relay, so no setup is needed on
either side. The relay only passes encrypted data along; see
[docs/RELAY.md](docs/RELAY.md) to run your own.

### Use it away from home

Usually nothing to do. When the phone can't reach the computer directly, the
PairDesk relay introduces them, and they try to open a **direct path** through both
routers, so the screen goes straight to your phone. Where the networks don't allow
that (many mobile carriers and offices), the relay carries the connection. The title
bar on the phone says **Direct** or **Relay**. **Remote access** on the computer shows
whether the relay is connected, how the last phone connected, and **Check now** tests
each relay. The relay is reached over TLS, with a plain fallback, and the phone still
checks the computer's own certificate inside it. If a relay is down the phone tries
the next one, and **Check the relay** on the phone shows what failed.

PairDesk also asks your router to forward a port to the computer (UPnP or NAT-PMP,
**Open a port on the router automatically** on the computer), and offers the
computer's IPv6 addresses; when either works, the phone connects with no relay at
all.

The computer must be awake: turn on **Keep this computer awake** on its PairDesk page
if it tends to sleep.

**Don't want to use the relay?** Your phone and your computer are on two
different private networks, so something has to join them. If your router doesn't
open a port by itself, set one up by hand: give the computer a fixed address on your home network, forward TCP
port 47800 to it, point a free dynamic DNS name (DuckDNS, No-IP, or your router's
own) at your home connection, then on the phone use **⋮ → Add an address** and
type that name — `home.example.org`, or `home.example.org:8443` if the router
forwards a different outside port. Nothing is in the middle, and the phone still
checks the computer's certificate exactly as on Wi-Fi. This needs a public
address from your internet provider: if your router's address differs from what a
"what is my IP" page shows, you are behind the provider's NAT and a port forward
can't reach you. **Remote access** on the computer walks through the steps.

### Known limits

- Windows: the lock screen, the sign-in screen and administrator (UAC) prompts need
  **Sign-in screen and admin prompts** turned on in PairDesk's settings (Windows asks
  for administrator permission once). Windows that run as administrator can't be
  controlled without it either. In the Microsoft Store version the helper comes with
  the app (turn the same switch on; Windows 10 version 2004 or newer).
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
- The Microsoft Store and Flatpak copies can't add **Send to → PairDesk phone** to
  the file manager; drop files on PairDesk's page instead.
- Windows reserves a few shortcuts that no app can send, such as Ctrl+Alt+Delete and
  Win+L. Use the Power tab to lock.
- With the helper on, the lock screen and UAC prompts are shown at a lower frame
  rate (they're read through the helper).
- Linux power actions use `loginctl`/`systemctl`, which most desktops allow for the
  signed-in user; screen off uses GNOME's display settings, `kscreen-doctor` (KDE)
  or `xset` (X11).

## Build from source

Requirements: [Rust](https://rustup.rs) (stable) and [Flutter](https://flutter.dev) (stable).

```bash
# Everything GitHub Actions checks, before you push
tools/check.sh                 # or: tools/check.sh phone | agent | relay

# Desktop agent
cd agent
cargo test
cargo run --release            # see --help for options

# End-to-end test of phone code against the real agent (Linux, needs Xvfb)
tools/e2e.sh
# The same on a headless GNOME Wayland session (mutter, portals, PipeWire)
tools/e2e-wayland.sh
# The updater: signed manifest, download, swap, takeover
tools/e2e-update.sh
# The Windows setup under Wine: install, self-update, uninstall
SETUP=PairDesk-Setup-x.y.z-x64.exe tools/e2e-windows-setup.sh
# Sound both ways, with echo cancelling (PipeWire)
tools/e2e-audio.sh
# "Get help" through the relay (build relay/ first: cd relay && cargo build)
tools/e2e-relay.sh
# Direct paths: the relay introduces, then UDP carries the session
tools/e2e-direct.sh

# Relay
cd relay && cargo test && cargo run -- --listen 127.0.0.1:47900

# Phone app
cd mobile
flutter test
flutter run                     # with a phone connected over USB
flutter build apk --release
```

## Project layout

```text
agent/      Rust desktop agent: TLS server, pairing, settings page, tray, input, updater
relay/      PairDesk relay: joins phones and computers that can't reach each other
mobile/     Flutter phone app (Android now, iPhone later)
packaging/  Icons, Windows setup and Store package, Linux packages, F-Droid and Flatpak
fastlane/   F-Droid listing: text, icon, screenshots, changelogs
site/       pairdesk.madhushan.me (Next.js, Tailwind, GSAP, Three.js, Lenis; static export)
docs/       Protocol, relay hosting, releasing, stores
tools/      End-to-end tests
```

The protocol and security design are described in [docs/PROTOCOL.md](docs/PROTOCOL.md);
releases in [docs/RELEASING.md](docs/RELEASING.md); store submissions in
[docs/STORES.md](docs/STORES.md).

## Roadmap

| Phase | Goal |
| --- | --- |
| 0 | Touchpad over home Wi-Fi |
| 1 | One-time QR pairing, encryption, tray app, auto-start, auto-discovery |
| 2 | Power actions, app launcher, custom buttons, phone app lock |
| 3 | Connect from anywhere (Tailscale at first, now the relay and your own router) |
| 4 | Live screen view on Windows and Linux X11 |
| 5 | Linux agent on Wayland |
| 6 | Clipboard sync and file transfer |
| 7 | Installers, automatic updates, website; Microsoft Store and F-Droid packages |
| 8 | Smoother screen (H.264); Windows sign-in screen and admin prompts; PairDesk window on Windows |
| 9 | Two-way sound, with echo cancelling |
| 10 | Pairing links, "Get help", PairDesk relay |
| **11** | **Direct paths through the relay's introduction, IPv6, automatic router port (this release)** |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Support PairDesk

PairDesk is free, has no ads and no account. If it is useful to you, you can
sponsor it on [GitHub Sponsors](https://github.com/sponsors/sandunMadhushan),
[Patreon](https://www.patreon.com/sandunMadhushan) or
[Buy Me a Coffee](https://buymeacoffee.com/sandunhmadhushan). The same links
are in the apps' Settings (GitHub downloads only, see docs/STORES.md).

## Licence

PairDesk is free software under the [GNU General Public License v3.0 or later](LICENSE).
