#!/usr/bin/env bash
# End-to-end test of direct connections: the real relay introduces the
# phone app's code to the real agent, then they talk over a direct UDP path
# (both on this computer, so the path always opens).
#
#   cargo build --manifest-path relay/Cargo.toml
#   cargo build --manifest-path agent/Cargo.toml
#   tools/e2e-direct.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=$(realpath "${AGENT:-$ROOT/agent/target/debug/pairdesk-agent}")
RELAY=$(realpath "${RELAY:-$ROOT/relay/target/debug/pairdesk-relay}")
PORT=${PORT:-47814}
RPORT=${RPORT:-47914}
DATA=$(mktemp -d)
export DISPLAY=:96
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null || true; if [ -n "${KEEP:-}" ]; then echo "kept $DATA"; else rm -rf "$DATA"; fi; }
trap cleanup EXIT

Xvfb :96 -noreset -screen 0 1024x768x24 >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 50); do [ -e /tmp/.X11-unix/X96 ] && break; sleep 0.1; done
"$RELAY" --listen "127.0.0.1:$RPORT" >"$DATA/relay.txt" 2>&1 & PIDS+=($!)
mkdir -p "$DATA/downloads"
PAIRDESK_E2E=1 PAIRDESK_HOME="$DATA" PAIRDESK_DOWNLOADS="$DATA/downloads" \
  "$AGENT" --background --no-tray --port "$PORT" >"$DATA/out.txt" 2>&1 & PIDS+=($!)
for _ in $(seq 50); do [ -s "$DATA/settings-url.txt" ] && break; sleep 0.2; done
SETTINGS=$(cat "$DATA/settings-url.txt")
api() { curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/$1" -d "$2"; }

api router-port '{"enabled":false}' >/dev/null
api relay "{\"on\":true,\"address\":\"127.0.0.1:$RPORT\"}" >/dev/null
for _ in $(seq 50); do
  curl -sf "${SETTINGS}api/state" | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["relay"]["state"]["status"] != "online")' && break
  sleep 0.2
done
LINK=$(api pair '{}' | python3 -c 'import json,sys; p=json.load(sys.stdin)["pairing"]; assert p["relay"]; print(p["link"])')

(cd "$ROOT/mobile" && PAIRDESK_E2E_LINK="$LINK" PAIRDESK_E2E_SETTINGS="$SETTINGS" \
  PAIRDESK_E2E_DOWNLOADS="$DATA/downloads" flutter test test/e2e_direct_test.dart)

grep -q "directly (the relay introduced it)" "$DATA/out.txt" || { echo "the agent didn't see a direct phone"; cat "$DATA/out.txt"; exit 1; }
grep -E "direct|relay" "$DATA/out.txt" | tail -8
echo "DIRECT E2E PASSED"
