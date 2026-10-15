# PairDesk protocol (v1)

The phone app talks to the desktop agent over a WebSocket. Every message is one
JSON text frame with a `t` (type) field. Unknown types and unknown key names are
rejected, so the phone can only do what is listed here.

> **Phase 0:** plain `ws://` on the local network, port **47800**, no pairing and
> no encryption. Phase 1 adds key-based pairing and TLS; message shapes stay the same.

## Phone → agent

| `t` | Fields | Meaning |
| --- | --- | --- |
| `hello` | `name` (string, optional), `v` (int, optional) | First message after connecting |
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

An optional `v` field may be added to any message; the agent ignores it for now.

## Agent → phone

| `t` | Fields | Meaning |
| --- | --- | --- |
| `hello` | `name` (computer name), `os` (`windows`, `linux`, …), `v` (protocol version) | Reply to `hello` |
| `pong` | — | Reply to `ping` |
| `error` | `msg` | A message could not be understood |

## Behaviour

- The agent merges bursts of `move` messages, so the phone can send one per touch event.
- If a phone disconnects while holding a button (`down` without `up`), the agent releases it.
- The phone pings every 3 s and treats 10 s of silence as a lost connection.
- Frames larger than 64 KiB are refused.

## Example

```text
phone → {"t":"hello","name":"PairDesk phone","v":1}
agent → {"t":"hello","name":"SANDUN-LAPTOP","os":"windows","v":1}
phone → {"t":"move","dx":4,"dy":-2}
phone → {"t":"click","b":"left"}
phone → {"t":"ping"}
agent → {"t":"pong"}
```
