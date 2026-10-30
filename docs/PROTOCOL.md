# PairDesk protocol (v2)

The phone talks to the desktop agent over a **WebSocket inside TLS** (`wss://`),
port **47800** by default. Every message is one JSON text frame with a `t` (type)
field. Unknown types and unknown key names are rejected, so a phone can only do
what is listed here.

Version 2 added pairing, TLS and signed sign-in. Version 1 (plain `ws://`, no
pairing) is no longer accepted.

## Identities

| Who | Identity | Where it's kept |
| --- | --- | --- |
| Computer | Self-signed TLS certificate (ECDSA P-256), created on first run. Identified by the **SHA-256 fingerprint** of the certificate (DER). | `%APPDATA%\PairDesk` (Windows), `~/.config/pairdesk` (Linux) |
| Phone | **Ed25519** key pair, created on first launch. The phone's ID is its 32-byte public key, base64url without padding. | Android encrypted storage (Keystore-backed); excluded from backups |

The phone never trusts a certificate authority. It accepts exactly one certificate:
the one whose fingerprint it learned from the pairing QR code.

All binary values on the wire are **base64url without padding**.

## Pairing link (QR code)

The computer's settings page shows this link as a QR code:

```text
pairdesk://pair?v=2&n=<name>&fp=<fingerprint>&t=<code>&p=<port>&a=<ip>,<ip>
```

| Field | Meaning |
| --- | --- |
| `v` | Protocol version (2) |
| `n` | Computer name, percent-encoded |
| `fp` | SHA-256 certificate fingerprint (32 bytes) |
| `t` | One-time pairing code: 16 random bytes, valid **10 minutes**, usable **once** |
| `p` | Port |
| `a` | The computer's LAN IPv4 addresses, comma-separated |

| `r` | *(since 0.11)* The computer's relay route `host:port/id`, percent-encoded, when it's connected to a relay |
| `h` | *(since 0.11)* `1` for a "Get help" link: the phone gets temporary, limited access (see below) |

Seeing the QR code is what proves the person is at the computer. Showing a new
code replaces the previous one.

### Share link (since 0.11)

The same query can be sent as a web link instead of shown as a QR code:

```text
https://pairdesk.madhushan.me/p#v=2&n=<name>&fp=…&t=…&p=…&a=…&r=…&h=1
```

Everything is after `#`, so it never reaches the web server. Android opens
the link in PairDesk directly (verified app link, `/.well-known/assetlinks.json`);
otherwise `site/p.html` offers "Open in PairDesk" (`intent://pair?…`) and the
download. The app also accepts either link pasted or shared into it.

Links only go **from the computer to the phone**: the phone connects to the
computer, so the computer is the one that must hand out its fingerprint,
addresses and a one-time code. Whoever has the link within its 10 minutes
can pair once, so it should be sent privately (a chat, not a public post).

### Get help (since 0.11)

"Get help" on the computer makes a link with `h=1`. A phone that pairs
with it:

- is stored with `help_until` = pairing time + **2 hours**, and removed then,
  or 5 minutes after it disconnects, or when the person presses *End help*;
- gets `power`, `session`, `files`, `audio` and `mic` turned off whatever
  the computer's switches say (screen, control, clipboard and apps follow
  the switches);
- is shown on the computer in a banner while connected.

A phone that was already paired normally keeps its full access if it pairs
again through a help link. The phone forgets a helping computer when the
agent answers `not_paired`.

## Sign-in handshake

```text
1. phone ── TLS (certificate fingerprint must equal the pinned one) ──▶ agent
2. phone → {"t":"pair","v":2,"token":"<code>","id":"<phone public key>","name":"Pixel 7"}   first time
      or → {"t":"hello","v":2,"id":"<phone public key>","name":"Pixel 7"}                 afterwards
3. agent → {"t":"challenge","nonce":"<32 random bytes>","v":2}
4. phone → {"t":"auth","sig":"<Ed25519 signature>"}
5. agent → {"t":"welcome","name":"SANDUN-LAPTOP","os":"windows","v":2,"version":"0.5.1","paired":true}
```

The signature covers:

```text
"pairdesk-auth-v2" || 0x00 || certificate fingerprint (32) || nonce (32) || phone public key (32)
```

- The **nonce** is fresh for every connection, so a recorded signature can't be replayed.
- The **fingerprint** ties the signature to this computer, so a look-alike server
  can't pass it on to the real one.
- The pairing code is used up only after the signature checks out, so a failed
  attempt doesn't burn it. Once used, it can't pair a second phone.

The phone has 15 seconds to finish TLS and the handshake. Failed attempts are
answered after a short delay, and at most 16 connections may be in the
handshake at once.

Input commands sent before `welcome` are refused and the connection is closed.

## Phone → agent (after `welcome`)

| `t` | Fields | Meaning |
| --- | --- | --- |
| `ping` | — | Keep-alive; agent answers `pong` |
| `move` | `dx`, `dy` (int, pixels) | Relative mouse move. Clamped to ±4000 |
| `click` | `b`: `left` \| `right` \| `middle` | Press and release a button |
| `down` | `b` | Press and hold a button (dragging) |
| `up` | `b` | Release a held button |
| `scroll` | `dx`, `dy` (int, lines; missing = 0) | Positive `dy` scrolls down, positive `dx` right. Clamped to ±50 |
| `text` | `s` (string) | Type text. Truncated to 2000 characters |
| `key` | `k` (see below) | Press and release a named key |
| `combo` | `mods` (list of `ctrl`, `alt`, `shift`, `meta`), and `k` (named key) **or** `c` (one visible character), or neither | Keyboard shortcut: hold the modifiers, press the key, release. With no key, the modifiers alone are tapped (e.g. `meta` opens the Start menu) |
| `power` | `a`: `lock` \| `sleep` \| `screen_off` \| `sign_out` \| `restart` \| `shut_down`; `id` | Power and session actions. Answered with `ack` |
| `apps` | `id` | Asks for the apps and shortcuts that can be opened. Answered with `apps` |
| `launch` | `app` (an ID from `apps`), `id` | Opens an app or shortcut. Answered with `ack` |
| `clip_get` | `id` | Asks for the computer's clipboard text. Answered with `clip` |
| `clip_set` | `id`, `text` (≤ 200 KB UTF-8), `paste` (optional bool) | Puts text on the computer's clipboard; with `paste`, then presses Ctrl+V there. Answered with `ack` |
| `file_*` | see [Files](#files) | Files both ways |
| `audio_start` | `id`, `sound` (bool), `mic` (bool), `codecs` (e.g. `["opus","pcm"]`) | Listen to the computer's sound and/or microphone (since 0.10). Answered with `audio` |
| `audio_stop` | — | Stop listening |

Named keys: `enter`, `backspace`, `escape`, `tab`, `space`, `delete`, `up`, `down`,
`left`, `right`, `home`, `end`, `page_up`, `page_down`, `volume_up`, `volume_down`,
`mute`, `play_pause`, `next`, `prev`, `insert`, `print_screen`, `f1` … `f12`.

`id` is a number chosen by the phone; the answer carries the same `id`.

A phone can't send a command line, a path or a URL: `launch` only accepts IDs
from the list the computer gave it, and the list contains the computer's
installed apps plus shortcuts the owner set up on the settings page.

## Agent → phone

| `t` | Fields | Meaning |
| --- | --- | --- |
| `challenge` | `nonce`, `v` | Sign this (see above) |
| `welcome` | `name`, `os` (`windows`, `linux`, …), `v`, `version` (the agent's release, since 0.5.1; phones use it to explain what to update), `paired` (true right after pairing), `features` (e.g. `["combo","power","apps"]`), `allow` (`{"power":bool,"session":bool,"apps":bool}`), `addrs` (see below) | Signed in; input is accepted |
| `ack` | `id`, `ok`, and when not ok: `code` (`not_allowed`, `not_found`, `failed`) and `msg` | Answer to `power` or `launch` |
| `apps` | `id`, `shortcuts`, `apps`: lists of `{"id","name","kind"}`, kind `app`, `url`, `folder`, `file` or `program` | Answer to `apps` |
| `clip` | `id`, `text` | Answer to `clip_get` (`""` when the clipboard holds no text) |
| `file_*` | see [Files](#files) | Files both ways |
| `audio` | `id`, `codec` (`opus` or `pcm`), `rate`, `channels`, `frame_ms`, `pre_skip`, `sound`, `mic` | Answer to `audio_start`; "PDA1" messages follow (see [Sound](#sound)) |
| `audio_stopped` | `msg` | Listening ended on the computer's side |
| `pong` | — | Reply to `ping` |
| `notice` | `msg` | Something for the person to read, e.g. "approve PairDesk on the computer" (since 0.6; older phones ignore it) |
| `error` | `code`, `msg` | See below |

Error codes. Every code except `bad_message` is followed by the agent closing
the connection.

| `code` | Meaning |
| --- | --- |
| `version` | Different protocol version; update the app or the computer |
| `not_paired` | This phone isn't paired, or was just removed on the computer |
| `bad_token` | The pairing code is wrong, used, replaced or expired |
| `bad_signature` | The signature didn't verify |
| `unexpected` | Wrong message for this point in the handshake |
| `bad_message` | A message couldn't be understood (connection stays open) |

## Screen view

| Direction | `t` | Fields | Meaning |
| --- | --- | --- | --- |
| phone → agent | `screen_start` | `id`, `monitor` (optional), `quality`: `low` \| `medium` \| `high`, `codecs` (optional, since 0.9: e.g. `["h264"]`) | Start (or restart) screen view. Answered with `screen`, or `ack` with `not_allowed` / `failed` |
| agent → phone | `screen` | `id`, `monitors` (`[{index,name,width,height,primary}]`), `monitor`, `width`, `height`, `codec` (`jpeg` \| `h264`, since 0.9) | Started; binary frames of `width`×`height` follow |
| phone → agent | `screen_ack` | `seq` | Frame `seq` is shown |
| phone → agent | `screen_refresh` | — | Send the whole screen again |
| phone → agent | `screen_stop` | — | Stop |
| phone → agent | `move_to` | `x`, `y` (0..1 on the viewed monitor) | Move the pointer there (clamped) |
| agent → phone | `screen_stopped` | `msg` | Stopped on the computer (owner pressed Stop, permission turned off, or the phone stopped answering) |

Frames are WebSocket **binary** messages (little-endian):

```text
"PDS1" | seq u32 | width u16 | height u16 | cursor_x i16 | cursor_y i16 | count u16
then `count` times: x u16 | y u16 | w u16 | h u16 | len u32 | JPEG bytes
```

### Video (since 0.9, feature `video`)

A phone with an H.264 decoder sends `codecs: ["h264"]`; the agent answers
`codec: "h264"` and sends video frames instead of JPEG rectangles:

```text
"PDV1" | seq u32 | width u16 | height u16 | cursor_x i16 | cursor_y i16 | flags u8 | len u32 | H.264
```

- The H.264 data is one access unit in Annex B form (OpenH264, constrained
  baseline, no B-frames). `flags` bit 0: key frame (IDR with SPS and PPS). The
  first frame, and the first after `screen_refresh`, is a key frame.
- `len` 0: only the cursor moved. A picture is encoded only when the screen
  changed; one tiny repeat follows each change, because some phone decoders show
  a picture only when the next one arrives.
- Low / medium / high: 960 / 1280 / 1920 pixels wide, 1 / 2.5 / 5 Mbit/s,
  up to 15 / 24 / 30 frames a second. Same acks and flow control as JPEG.
- The phone (Android MediaCodec onto a Flutter texture) falls back to JPEG for
  good if its decoder fails, and asks for JPEG when it has no H.264 decoder.

### JPEG rectangles

- The agent scales the monitor to at most 960 / 1280 / 1920 pixels wide (low /
  medium / high; JPEG quality 50 / 65 / 80; up to 8 / 12 / 15 frames a second).
- It compares each frame with the last one in 64×64 tiles and sends only the
  changed tiles, merged into rectangles; above half the screen it sends one
  full frame. The first frame after `screen_start` or `screen_refresh` is whole.
- A frame with no rectangles only moves the cursor (`-1, -1` = on another monitor).
  Between frames the agent checks the pointer every 16 ms and sends such a frame
  when it moved (within the same two-frame limit), so the pointer drawn on the
  phone keeps up with the finger.
- The phone moves the pointer either with `move` (touchpad style: relative, with
  tap-and-drag sent as `down` / `up`) or with `move_to` (tap to point).
- **Flow control:** at most two frames are unacknowledged; then the agent waits
  for `screen_ack`, so a slow link gets fewer frames instead of growing delay.
  With no ack for 15 s the agent stops.
- Capture: Windows GDI (`BitBlt`, per-monitor DPI aware; `SetCursorPos` for
  `move_to`), Linux X11 `GetImage` + RandR monitors, Linux Wayland the portal's
  screen cast through PipeWire (see below). The lock screen and UAC prompts
  can't be captured.
- On the computer, the tray icon gets a red dot and the settings page shows who is
  viewing, with a **Stop** button.

## Permissions

The settings page on the computer has three switches, all on by default:

| Switch | Covers |
| --- | --- |
| `power` | `lock`, `sleep`, `screen_off` |
| `session` | `sign_out`, `restart`, `shut_down` |
| `apps` | `apps`, `launch` |
| `screen` | `screen_start` (turning it off also stops current viewers) |
| `clipboard` | `clip_get`, `clip_set` |
| `files` | `file_offer` from a phone (files sent from the computer need no permission: the owner sends them) |
| `audio` | `audio_start` with `sound`, and the phone's voice ("PDM1"). Turning it off stops current listeners |
| `mic` | `audio_start` with `mic`. **Off by default.** Turning it off stops phones that hear the microphone |

Phones paired through "Get help" never get `power`, `session`, `files`,
`audio` or `mic`, and their `allow` says so.

Each request is checked against the current switches when it arrives, so a
change applies at once. The phone also asks for confirmation before
`sign_out`, `restart` and `shut_down`. For `lock` and `screen_off` the `ack`
reports the real result; for the others the agent answers first and acts
about half a second later, because the computer is about to go away.

Phones from 0.2 don't know these messages and ignore `features` and `allow`;
they keep working. Phones check `features` before offering the new tabs.

## Behaviour

- Removing a phone in the settings page disconnects it immediately with `not_paired`.
- The agent merges bursts of `move` messages, so the phone can send one per touch event.
- If a phone disconnects while holding a button (`down` without `up`), the agent releases it.
- The phone pings every 3 s and treats 10 s of silence as a lost connection.
- Messages larger than 512 KiB are refused.

## Sound

Since 0.10 (feature `audio`). Two directions, independent of each other:

**Listening** (computer → phone). `audio_start` with `sound` (whatever the
computer plays: WASAPI loopback on Windows, the default output's monitor on
Linux through PulseAudio/PipeWire) and/or `mic` (the default microphone).
Both are mixed into one stream of 20 ms packets, 48 kHz stereo:

```
"PDA1" | seq u32 BE | payload
```

The payload is one Opus packet (`codec: opus`, 96 kbit/s with sound, 48 with
the microphone only), or 16-bit little-endian PCM (`codec: pcm`) for phones
without an Opus decoder. **An empty payload is 20 ms of silence**: nothing is
encoded or sent while nothing plays. `pre_skip` is the Opus encoder's delay in
samples, for the decoder's `OpusHead`. When the network is slow, packets are
dropped rather than delayed. Sending `audio_start` again changes what is heard.

**Talking** (phone → computer). The phone sends its microphone as

```
"PDM1" | 16 kHz mono G.711 µ-law
```

in 20 ms messages (320 bytes). The agent plays them on the default output; the
speakers open with the first message and close after 3 s without one.

Both directions work at once (since 0.10.1). The phone's voice comes back to
the computer through its microphone and, digitally, through the recorded
computer sound; the agent removes it with an echo canceller (WebRTC AEC3),
using the received voice as the reference, while the phone has talked in the
last 3 s. Phones use the call audio path while talking, so the phone's own
echo cancelling removes the computer's sound from its microphone.

While a phone hears the microphone, the tray icon shows the red dot and the
settings page says so, with a Stop button (`api/stop-audio`).

## Clipboard

Text only. Windows and X11 use the system clipboard directly. In a Wayland
session the agent asks the remote desktop portal for clipboard access
(`Clipboard.RequestClipboard` before `Start`; the desktop's dialog shows "Allow
Clipboard Access") and then uses `SetSelection` / `SelectionWrite` /
`SelectionRead`. Where the portal has no clipboard, the Xwayland clipboard is
used instead.

## Files

Files go both ways over the same connection, with the same messages in each
direction. File ids (`fid`) are chosen by the sender: below 2³¹ for phones, from
2³¹ for the computer.

```text
sender   → file_offer    {fid, name, size}
receiver → file_accept   {fid}                    or file_cancel {fid, msg}
sender   → binary chunks "PDF1" | fid u32 | offset u64 | bytes   (little-endian, ≤ 128 KiB each)
receiver → file_progress {fid, received}          every MiB, and when it has every byte
sender   → file_end      {fid, sha256}            only after "received" equals size
receiver → file_done     {fid, ok, name?, msg?}   name: what it was saved as
either   → file_cancel   {fid, msg?}              stops it; the receiver deletes the part file
```

- **Flow control:** the sender keeps at most 4 MiB unacknowledged, so a slow link
  doesn't fill memory or delay the touchpad.
- **Integrity:** the receiver checks the size and the SHA-256 before the file gets
  its name; until then it's a hidden part file, removed if anything goes wrong or
  the connection drops.
- **On the computer:** files from phones go to `Downloads/PairDesk`
  (`PAIRDESK_DOWNLOADS` overrides it). Names are cleaned (no folders, no
  characters Windows forbids, no device names like `CON`) and never overwrite an
  existing file (`photo (2).jpg`).
- **On the phone:** files from the computer go to `Download/PairDesk` (Android 10+,
  through MediaStore; older Android: the app's own Download/PairDesk folder).
- **Sending from the computer:** the settings page's drop zone (`POST
  api/upload?name=…&phone=…` with the file as the body), or `pairdesk-agent --send
  FILE…`, which hands the paths to the running agent (`POST api/send-paths`). On
  start the agent adds that command to the file manager: a "PairDesk phone"
  shortcut in Windows' Send To folder, a GNOME Files script and a Dolphin service
  menu. Files go to every connected phone, or the one chosen.

## Reaching the computer from anywhere (Tailscale)

Away from home PairDesk uses [Tailscale](https://tailscale.com) when the
owner installed it on the computer and the phone, or else a PairDesk relay
(below). Both carry the same `wss://` connection; pinning and the signed
sign-in are unchanged.

- `welcome.addrs` lists every address the phone may use: home-network IPv4
  addresses first, then Tailscale addresses (100.64.0.0/10) and, when
  MagicDNS is on, the Tailscale name (`*.ts.net`). Adapters that only exist
  inside the computer (Docker, WSL, VirtualBox, VMware…) are left out.
- The phone keeps up to 8 addresses: the one that worked last, then the
  computer's current list, then older ones; the computer's newest relay
  route is always kept, last. Anything other than an IPv4 address, a
  `*.ts.net` name or a `relay:` route is ignored.
- To connect, the phone starts an attempt at each address 250 ms apart and
  uses the first that passes the certificate check. Home addresses get 3 s,
  Tailscale ones 8 s (a relayed first connection can be slow).
- The agent reads `tailscale status --json` (when the command exists) for its
  settings page and for the Tailscale name; it never changes Tailscale.
- Optional *keep this computer awake* (settings page): Windows
  `SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_CONTINUOUS)`, Linux
  `systemd-inhibit --what=sleep:idle`. Off by default.

## Relay

Since 0.11, when the phone can't reach the computer directly, both meet at a
relay (`relay/` in this repository; hosting: [RELAY.md](RELAY.md)). The
default is `relay.pairdesk.madhushan.me:443`; the owner can change it or
turn it off in the computer's settings.

The relay speaks a one-line text handshake, after which it copies bytes in
both directions untouched. Lines end with `\n` and are at most 256 bytes.

| From | Line | Answer |
| --- | --- | --- |
| Computer (control connection) | `PDR1 HOST <token>` | `OK <id>`: `id` = first 16 bytes of SHA-256(`token`), hex. A newer registration for the same id replaces the old one |
| Phone | `PDR1 CONNECT <id>` | `OK` once joined, or `ERR offline` / `ERR no answer` |
| Relay → computer (control) | `INCOMING <nonce>` | the computer opens a new connection: |
| Computer (new connection) | `PDR1 ACCEPT <token> <nonce>` | `OK`; the relay sends `OK` to the phone and joins the two |
| Relay ↔ computer (control) | `PING` every 25 s | `PONG` |

`token` is 32 random bytes kept in the computer's data folder
(`relay-token`), so only that computer can register its id. Idle
connections close after 90 s; one IP address may hold 64 connections.

On the phone the route is the address `relay:host:port/id` (`r=` in the
pairing link, and last in `welcome.addrs` while the computer is connected to
the relay). The phone starts relay attempts 1.5 s after the direct ones, so
a direct path wins when there is one. It connects to the relay, sends
`CONNECT`, and after `OK` runs TLS over that connection through a forwarder
on 127.0.0.1, checking the certificate fingerprint as usual. The relay
therefore sees only TLS records, sizes and IP addresses.

## Finding the computer again

The agent announces itself with mDNS / DNS-SD as `_pairdesk._tcp` with TXT
records `id=<first 8 bytes of the fingerprint, hex>` and `v=2`. When none of the
saved addresses answer, the phone looks for its computer's `id` on the network
and tries the addresses found. Discovery is only a hint: the certificate is
still checked.

## Linux Wayland

Wayland doesn't let apps inject input or read the screen directly. In a Wayland
session (`XDG_SESSION_TYPE=wayland`) the agent uses the desktop's
[remote desktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html):

- One portal session holds pointer + keyboard (`RemoteDesktop.SelectDevices`,
  `persist_mode` 2) and every chosen monitor (`ScreenCast.SelectSources`,
  monitors, `multiple`, cursor as metadata when offered).
- The first `Start` shows the desktop's dialog. The returned `restore_token` is
  saved (`wayland-restore-token` in the data folder) and used next time, so later
  sessions start without a dialog. Tokens are single-use; each start saves the new one.
- The session starts when a phone connects (or right away when the owner starts
  the agent by hand) and closes 15 s after the last phone leaves. Desktops that
  return no token keep it open while the agent runs, so they ask once per sign-in.
- Input: `move` → `NotifyPointerMotion`, `move_to` → `NotifyPointerMotionAbsolute`
  on the monitor's stream, buttons → `NotifyPointerButton` (evdev codes), `scroll`
  → `NotifyPointerAxisDiscrete`, text and keys → `NotifyKeyboardKeysym`.
- Screen: `OpenPipeWireRemote`, then a PipeWire stream on the monitor's node
  (raw BGRx/BGRA/RGBx/RGBA in memory; pointer from `SPA_META_Cursor`). libpipewire
  is loaded at run time, so the agent also starts where it's missing.
- If the owner refuses or stops sharing, phones get a `notice`; the agent doesn't
  ask again by itself until a phone reconnects or the owner presses **Allow
  control** on the settings page.

## Updating the agent

Only one agent runs per computer: the second one finds the port taken. It then
reads `settings-url.txt` and asks the running agent for `api/state`. If that
agent is an older release it sends `POST api/quit` (with `X-PairDesk: 1`), waits
up to 20 s for the port and takes over; otherwise it opens the running agent's
settings page and exits. On every start, if start-at-sign-in is on, its entry is
rewritten to point to the running program file (quoted, so paths with spaces work).

## Settings page (computer only)

The agent serves its settings page on `127.0.0.1` at a random port, under a
random secret path (stored in `settings-url.txt` in the data folder while the
agent runs). It refuses requests with any other `Host` header, and changes need
an `X-PairDesk: 1` header, which other websites can't send without a CORS
preflight that the agent never approves. It isn't reachable from the network.

## Updates (since 0.8.0)

Not part of the phone protocol: how PairDesk finds and checks new releases.

Each GitHub release carries `latest.json` and `latest.json.sig`, read from
`https://github.com/sandunMadhushan/pairdesk/releases/latest/download/`:

```json
{
  "version": "0.8.0",
  "date": "2026-10-29",
  "notes_url": "https://github.com/sandunMadhushan/pairdesk/releases/tag/v0.8.0",
  "assets": {
    "windows-x64-setup": {"url": "https://…/PairDesk-Setup-0.8.0-x64.exe", "sha256": "…", "size": 2509594},
    "windows-x64": {…}, "linux-x64": {…}, "linux-x64-appimage": {…},
    "linux-x64-deb": {…}, "linux-x64-rpm": {…},
    "android-arm64": {…}, "android-armv7": {…}, "android-x86_64": {…}
  }
}
```

`latest.json.sig` is the base64 Ed25519 signature of the exact bytes of
`latest.json` (`openssl pkeyutl -sign -rawin`), made by the release workflow
with the `UPDATE_SIGNING_KEY` secret. The public key is built into the agent
(`agent/src/update.rs`) and the app (`mobile/lib/update_check.dart`).

The agent ignores manifests whose signature doesn't verify and downloads
that aren't HTTPS, and checks each download's size and SHA-256 before using
it. How it installs depends on how it was installed:

| Install | Asset | Update |
|---|---|---|
| Windows setup (uninstaller next to the program) | `windows-x64-setup` | runs the setup with `/S /UPDATE`; the setup stops PairDesk (`--quit`), replaces it and starts it with `--background --updated` |
| Program file (Windows, Linux) | `windows-x64`, `linux-x64` | downloads next to the program, renames the running file to `.<name>.old`, moves the new one in and starts it with `--background --updated` (plus the old `--port`, `--bind`, `--no-tray`); it takes over the port |
| AppImage | `linux-x64-appimage` | the same, on the AppImage file |
| .deb / .rpm | – | the settings page links to the release |
| Microsoft Store, Flatpak | – | the store updates it; no checks |

`--updated` always takes over from the running copy, whatever its version.
Leftover `.old` files and downloaded setups are deleted at the next start.

## Windows helper service (since 0.9)

Optional, turned on from the settings page ("Sign-in screen and admin
prompts"); Windows asks for administrator permission. See `agent/src/winsys`.

- `pairdesk-agent --install-service` (elevated) copies the program to
  `%ProgramFiles%\PairDesk` and registers the `PairDesk` service (LocalSystem,
  automatic start, restarted on failure). `%ProgramData%\PairDesk` is limited
  to SYSTEM and administrators. `--uninstall-service` removes both.
- The service keeps `--session-helper` running as SYSTEM in the session at
  the screen (all its children end with the service through a job object),
  copies the signed-in user's `identity-*.der`, `paired-phones.json` and
  `settings.json` to `%ProgramData%\PairDesk\system`, and updates itself
  from the signed manifest (asset `windows-x64`).
- The helper listens on 127.0.0.1 (random port) with a random token, written
  to `%ProgramData%\PairDesk\bridge\session-<n>.json`, readable by SYSTEM,
  administrators and that session's user only. The agent connects when the
  input desktop isn't reachable (lock screen, sign-in, UAC) and sends input
  and asks for screen pictures through it. Messages: `u32 json length | JSON |
  u32 data length | data`; requests `hello {token, version}`, `input {cmd}`,
  `capture {x, y, width, height}` (answered with `frame` + BGRA), `desktop`.
- While nobody is signed in, the helper runs `--system-mode`: the phone
  server with the copied pairing (same identity, so paired phones connect as
  usual), input and capture following the input desktop. It is stopped as
  soon as someone signs in; their PairDesk waits up to 30 s for the port.
