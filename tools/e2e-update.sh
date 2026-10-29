#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the updater with a real agent (Linux program file):
# a local "GitHub" serves a signed latest.json and the new program; the
# agent finds the update, downloads and checks it, swaps its own file, and
# the new copy takes over the port while the old one exits.
#
#   cargo build --manifest-path agent/Cargo.toml && tools/e2e-update.sh
#
# AGENT=path picks the binary (default: the debug build).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=${AGENT:-$ROOT/agent/target/debug/pairdesk-agent}
if [ -z "${DISPLAY:-}" ]; then exec xvfb-run -a "$0" "$@"; fi
T=$(mktemp -d)
PORT=47831
cleanup() {
  [ -n "${HTTPD:-}" ] && kill "$HTTPD" 2>/dev/null || true
  pkill -f "$T/bin/pairdesk-agent" 2>/dev/null || true
  if [ -n "${KEEP:-}" ]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; echo "--- agent log"; cat "$T/agent.log" 2>/dev/null; exit 1; }

mkdir -p "$T/bin" "$T/srv" "$T/home"
cp "$AGENT" "$T/bin/pairdesk-agent"
cp "$AGENT" "$T/srv/agent"
# Mark the "new release" so the swap is visible: same program, one extra
# byte at the end (ELF ignores trailing data).
printf 'N' >>"$T/srv/agent"

# The release key for this test, and the signed manifest.
openssl genpkey -algorithm ed25519 -out "$T/key.pem" 2>/dev/null
PUB=$(openssl pkey -in "$T/key.pem" -pubout -outform DER | tail -c 32 | base64)
HTTP_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$HTTP_PORT"
SHA=$(sha256sum "$T/srv/agent" | cut -d' ' -f1)
SIZE=$(stat -c %s "$T/srv/agent")
cat >"$T/srv/latest.json" <<EOF
{"version":"9.9.9","date":"2026-10-29","notes_url":"https://example.com/notes",
 "assets":{"linux-x64":{"url":"$BASE/agent","sha256":"$SHA","size":$SIZE}}}
EOF
openssl pkeyutl -sign -inkey "$T/key.pem" -rawin -in "$T/srv/latest.json" | base64 -w0 >"$T/srv/latest.json.sig"
(cd "$T/srv" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >"$T/http.log" 2>&1) &
HTTPD=$!

HOME="$T/home" PAIRDESK_HOME="$T/home" BROWSER=true \
  PAIRDESK_UPDATE_MANIFEST="$BASE/latest.json" PAIRDESK_UPDATE_KEY="$PUB" \
  "$T/bin/pairdesk-agent" --no-tray --port "$PORT" >"$T/agent.log" 2>&1 &
OLD=$!
for _ in $(seq 100); do [ -s "$T/home/settings-url.txt" ] && break; sleep 0.1; done
URL=$(cat "$T/home/settings-url.txt")
post() { curl -sf -X POST -H 'X-PairDesk: 1' -H 'Content-Type: application/json' -d "${2:-{\}}" "${URL}api/$1"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }

echo "== the agent finds the signed update"
STATE=$(post update-check)
[ "$(echo "$STATE" | field '["update"]["latest"]')" = 9.9.9 ] || fail "no update found: $STATE"
[ "$(echo "$STATE" | field '["update"]["kind"]')" = portable ] || fail "wrong kind: $STATE"
[ "$(echo "$STATE" | field '["update"]["can_install"]')" = True ] || fail "can't install: $STATE"

echo "== a forged manifest is refused"
cp "$T/srv/latest.json" "$T/srv/good.json"
sed -i 's/9.9.9/9.9.8/' "$T/srv/latest.json"
STATE=$(post update-check)
echo "$STATE" | grep -q "isn't signed by PairDesk" || fail "forged manifest accepted: $STATE"
cp "$T/srv/good.json" "$T/srv/latest.json"
post update-check >/dev/null

echo "== install: download, check, swap, restart"
post update-install >/dev/null
# (A finished child stays a zombie until waited for.)
alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" | cut -c1)" != Z ]; }
for _ in $(seq 150); do alive "$OLD" || break; sleep 0.2; done
alive "$OLD" && fail "the old agent is still running"
cmp -s "$T/bin/pairdesk-agent" "$T/srv/agent" || fail "the program file wasn't replaced"
[ -f "$T/bin/.pairdesk-agent.old" ] || fail "the old file wasn't kept aside"
for _ in $(seq 100); do
  NEW_URL=$(cat "$T/home/settings-url.txt" 2>/dev/null || true)
  [ -n "$NEW_URL" ] && [ "$NEW_URL" != "$URL" ] && break
  sleep 0.2
done
[ "$NEW_URL" != "$URL" ] || fail "the new agent didn't start"
sleep 2 # the old copy has fully exited by now
[ "$(cat "$T/home/settings-url.txt")" = "$NEW_URL" ] || fail "the old copy removed the new address"
curl -sf "${NEW_URL}api/state" >/dev/null || fail "the new agent doesn't answer"
CMD=$(pgrep -af "$T/bin/pairdesk-agent --background --updated" || true)
case "$CMD" in *"--port $PORT"*) ;; *) fail "not started as an update on port $PORT: $CMD" ;; esac
case "$CMD" in *--no-tray*) ;; *) fail "the tray choice was lost: $CMD" ;; esac
grep -q "took over" "$T/home/update.log" || fail "no takeover in update.log"

echo "== leftovers are removed"
for _ in $(seq 75); do [ -f "$T/bin/.pairdesk-agent.old" ] || break; sleep 0.2; done
[ -f "$T/bin/.pairdesk-agent.old" ] && fail "the old file is still there"

echo "== --quit stops it"
PAIRDESK_HOME="$T/home" "$T/bin/pairdesk-agent" --quit || fail "--quit failed"
pgrep -f "$T/bin/pairdesk-agent" >/dev/null && fail "still running after --quit"
echo "update e2e: ok"
