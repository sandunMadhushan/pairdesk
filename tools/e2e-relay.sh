#!/usr/bin/env bash
# End-to-end test of "Get help" through the relay: the real relay, the
# real agent registered with it, and the phone app's code reaching the
# agent ONLY through the relay (as from another network).
#
#   cargo build --manifest-path relay/Cargo.toml
#   cargo build --manifest-path agent/Cargo.toml
#   tools/e2e-relay.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=$(realpath "${AGENT:-$ROOT/agent/target/debug/pairdesk-agent}")
RELAY=$(realpath "${RELAY:-$ROOT/relay/target/debug/pairdesk-relay}")
PORT=${PORT:-47813}
RPORT=${RPORT:-47913}
DATA=$(mktemp -d)
export DISPLAY=:95
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null || true; if [ -n "${KEEP:-}" ]; then echo "kept $DATA"; else rm -rf "$DATA"; fi; }
trap cleanup EXIT

Xvfb :95 -noreset -screen 0 1024x768x24 >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 50); do [ -e /tmp/.X11-unix/X95 ] && break; sleep 0.1; done
"$RELAY" --listen "127.0.0.1:$RPORT" >"$DATA/relay.txt" 2>&1 & PIDS+=($!)
PAIRDESK_HOME="$DATA" "$AGENT" --background --no-tray --port "$PORT" >"$DATA/out.txt" 2>&1 & PIDS+=($!)
for _ in $(seq 50); do [ -s "$DATA/settings-url.txt" ] && break; sleep 0.2; done
SETTINGS=$(cat "$DATA/settings-url.txt")
api() { curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/$1" -d "$2"; }

# Point the agent at the local relay and wait until it's registered.
api relay "{\"on\":true,\"address\":\"127.0.0.1:$RPORT\"}" >/dev/null
for _ in $(seq 50); do
  curl -sf "${SETTINGS}api/state" | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["relay"]["state"]["status"] != "online")' && break
  sleep 0.2
done
curl -sf "${SETTINGS}api/state" | python3 -c 'import json,sys; s=json.load(sys.stdin)["relay"]["state"]; print("relay:", s); assert s["status"]=="online"'

# "Get help": the link the person sends.
SHARE=$(api pair '{"help":true}' | python3 -c 'import json,sys; p=json.load(sys.stdin)["pairing"]; assert p["help"] and p["relay"]; print(p["share"])')
echo "help link: ${SHARE%%&t=*}&t=…"

(cd "$ROOT/mobile" && PAIRDESK_E2E_HELP_LINK="$SHARE" PAIRDESK_E2E_SETTINGS="$SETTINGS" \
  flutter test test/e2e_relay_test.dart)

grep -q "through the relay (helping)" "$DATA/out.txt" || { echo "the agent didn't see a relayed helper"; cat "$DATA/out.txt"; exit 1; }
grep -q "joined to computer" "$DATA/relay.txt" || { echo "the relay didn't join them"; cat "$DATA/relay.txt"; exit 1; }
grep -E "relay|help" "$DATA/out.txt" | tail -6
echo "RELAY E2E PASSED"
