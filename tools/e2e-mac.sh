#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test on a Mac: the phone app's connection code against the real
# Mac agent (pairing, reconnecting, clipboard, files, apps, screen view).
# Needs Flutter and a built agent:
#
#   cargo build --release --manifest-path agent/Cargo.toml && tools/e2e-mac.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=${AGENT:-$ROOT/agent/target/release/pairdesk-agent}
PORT=${PORT:-47813}
DATA=$(mktemp -d)
cleanup() { kill ${APID:-} 2>/dev/null || true; if [ -n "${KEEP:-}" ]; then echo "kept $DATA"; else rm -rf "$DATA"; fi; }
trap cleanup EXIT

export PAIRDESK_POWER_DRY_RUN=1
mkdir -p "$DATA/downloads"
PAIRDESK_DOWNLOADS="$DATA/downloads" PAIRDESK_HOME="$DATA" "$AGENT" --background --no-tray --port "$PORT" \
  >"$DATA/out.txt" 2>&1 & APID=$!
for _ in $(seq 50); do [ -s "$DATA/settings-url.txt" ] && break; sleep 0.2; done
SETTINGS=$(cat "$DATA/settings-url.txt" 2>/dev/null || true)
[ -n "$SETTINGS" ] || { echo "agent did not start"; cat "$DATA/out.txt" "$DATA/agent.log" 2>/dev/null; exit 1; }

curl -sf "${SETTINGS}api/state" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print("os:", s["os"], "| mac permissions:", s["mac"])
assert s["os"] == "macos" and set(s["mac"]) == {"accessibility", "screen"}'
curl -sf "${SETTINGS}" | grep -q "Allow PairDesk on this Mac"
curl -sf -o /dev/null "${SETTINGS}fonts/urbanist-700.ttf"

LINK=$(curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/pair" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["pairing"]["link"])')

(cd "$ROOT/mobile" && PAIRDESK_E2E_LINK="$LINK" PAIRDESK_E2E_SETTINGS="$SETTINGS" \
  PAIRDESK_E2E_DOWNLOADS="$DATA/downloads" flutter test test/e2e_mac_test.dart) || {
  echo "--- agent log ---"; tail -40 "$DATA/agent.log" "$DATA/out.txt" 2>/dev/null; exit 1; }

curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/quit" >/dev/null || true
for _ in $(seq 25); do kill -0 $APID 2>/dev/null || break; sleep 0.2; done
! kill -0 $APID 2>/dev/null || { echo "agent did not stop"; exit 1; }
echo "--- agent log ---"
cat "$DATA/agent.log" "$DATA/out.txt" 2>/dev/null | grep -iE "screen|input|listening|mac|warn" | tail -15 || true
echo "MAC E2E PASSED"
