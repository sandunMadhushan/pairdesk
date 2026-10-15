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
5. agent → {"t":"welcome","name":"SANDUN-LAPTOP","os":"windows","v":2,"paired":true}
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

Named keys: `enter`, `backspace`, `escape`, `tab`, `space`, `delete`, `up`, `down`,
`left`, `right`, `home`, `end`, `page_up`, `page_down`, `volume_up`, `volume_down`,
`mute`, `play_pause`, `next`, `prev`.

## Agent → phone

| `t` | Fields | Meaning |
| --- | --- | --- |
| `challenge` | `nonce`, `v` | Sign this (see above) |
| `welcome` | `name`, `os` (`windows`, `linux`, …), `v`, `paired` (true right after pairing) | Signed in; input is accepted |
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

## Behaviour

- Removing a phone in the settings page disconnects it immediately with `not_paired`.
- The agent merges bursts of `move` messages, so the phone can send one per touch event.
- If a phone disconnects while holding a button (`down` without `up`), the agent releases it.
- The phone pings every 3 s and treats 10 s of silence as a lost connection.
- Frames larger than 64 KiB are refused.

## Finding the computer again

The agent announces itself with mDNS / DNS-SD as `_pairdesk._tcp` with TXT
records `id=<first 8 bytes of the fingerprint, hex>` and `v=2`. When none of the
saved addresses answer, the phone looks for its computer's `id` on the network
and tries the addresses found. Discovery is only a hint: the certificate is
still checked.

## Settings page (computer only)

The agent serves its settings page on `127.0.0.1` at a random port, under a
random secret path (stored in `settings-url.txt` in the data folder while the
agent runs). It refuses requests with any other `Host` header, and changes need
an `X-PairDesk: 1` header, which other websites can't send without a CORS
preflight that the agent never approves. It isn't reachable from the network.
