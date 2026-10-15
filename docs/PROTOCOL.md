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

Seeing the QR code is what proves the person is at the computer. Showing a new
code replaces the previous one.

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
| `pong` | — | Reply to `ping` |
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
| phone → agent | `screen_start` | `id`, `monitor` (optional), `quality`: `low` \| `medium` \| `high` | Start (or restart) screen view. Answered with `screen`, or `ack` with `not_allowed` / `failed` |
| agent → phone | `screen` | `id`, `monitors` (`[{index,name,width,height,primary}]`), `monitor`, `width`, `height` | Started; binary frames of `width`×`height` follow |
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
  `move_to`), Linux X11 `GetImage` + RandR monitors. Wayland is refused with a
  clear message. The lock screen and UAC prompts can't be captured.
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
- Frames larger than 64 KiB are refused.

## Reaching the computer from anywhere (Tailscale)

PairDesk doesn't run its own relay. Away from home it uses
[Tailscale](https://tailscale.com), which the owner installs on the computer
and the phone and signs in to with the same account. Tailscale carries the
same `wss://` connection; pinning and the signed sign-in are unchanged.

- `welcome.addrs` lists every address the phone may use: home-network IPv4
  addresses first, then Tailscale addresses (100.64.0.0/10) and, when
  MagicDNS is on, the Tailscale name (`*.ts.net`). Adapters that only exist
  inside the computer (Docker, WSL, VirtualBox, VMware…) are left out.
- The phone keeps up to 8 addresses: the one that worked last, then the
  computer's current list, then older ones. Anything other than an IPv4
  address or a `*.ts.net` name is ignored.
- To connect, the phone starts an attempt at each address 250 ms apart and
  uses the first that passes the certificate check. Home addresses get 3 s,
  Tailscale ones 8 s (a relayed first connection can be slow).
- The agent reads `tailscale status --json` (when the command exists) for its
  settings page and for the Tailscale name; it never changes Tailscale.
- Optional *keep this computer awake* (settings page): Windows
  `SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_CONTINUOUS)`, Linux
  `systemd-inhibit --what=sleep:idle`. Off by default.

## Finding the computer again

The agent announces itself with mDNS / DNS-SD as `_pairdesk._tcp` with TXT
records `id=<first 8 bytes of the fingerprint, hex>` and `v=2`. When none of the
saved addresses answer, the phone looks for its computer's `id` on the network
and tries the addresses found. Discovery is only a hint: the certificate is
still checked.

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
