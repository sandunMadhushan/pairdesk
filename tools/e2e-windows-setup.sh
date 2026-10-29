#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests the Windows setup under Wine:
#   1. silent install: files, Start menu, Settings → Apps entry, PairDesk starts;
#   2. the running agent updates itself through a newer setup (signed
#      manifest from a local server): the setup stops it, replaces it and
#      starts the new version;
#   3. silent uninstall removes everything but the user's settings.
#
#   SETUP=PairDesk-Setup.exe tools/e2e-windows-setup.sh
set -euo pipefail
SETUP=$(realpath "${SETUP:?SETUP=path to the setup .exe}")
WINE=${WINE:-$(command -v wine || echo /usr/lib/wine/wine64)}
if [ -z "${DISPLAY:-}" ]; then exec xvfb-run -a "$0" "$@"; fi
T=$(mktemp -d)
export WINEPREFIX=$T/wine WINEDEBUG=-all
cleanup() {
  [ -n "${HTTPD:-}" ] && kill "$HTTPD" 2>/dev/null || true
  wineserver -k 2>/dev/null || /usr/lib/wine/wineserver -k 2>/dev/null || true
  if [ -n "${KEEP:-}" ]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; ls -la "$INST" 2>/dev/null; cat "$DATA/update.log" 2>/dev/null; exit 1; }

"$WINE" wineboot -i >/dev/null 2>&1
U=$(ls "$WINEPREFIX/drive_c/users" | grep -v Public | head -1)
INST="$WINEPREFIX/drive_c/users/$U/AppData/Local/Programs/PairDesk"
DATA="$WINEPREFIX/drive_c/users/$U/AppData/Roaming/PairDesk"
reg() { "$WINE" reg query "$@" 2>/dev/null | tr -d '\r'; }
running() { [ -s "$DATA/settings-url.txt" ] && curl -sf "$(cat "$DATA/settings-url.txt")api/state" >/dev/null; }
wait_running() { for _ in $(seq 150); do running && return 0; sleep 0.2; done; return 1; }

echo "== 1. silent install"
"$WINE" "$SETUP" /S
[ -f "$INST/pairdesk-agent.exe" ] || fail "not installed"
[ -f "$INST/Uninstall PairDesk.exe" ] || fail "no uninstaller"
SM=$(find "$WINEPREFIX/drive_c/users/$U" -name 'PairDesk.lnk' | head -1)
[ -n "$SM" ] || fail "no Start menu shortcut"
reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\PairDesk' /v DisplayVersion | grep -q REG_SZ || fail "no Settings → Apps entry"
wait_running || fail "PairDesk didn't start after a silent install"
V1=$(curl -sf "$(cat "$DATA/settings-url.txt")api/state" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["version"], d["update"]["kind"])')
echo "   running: $V1"
case "$V1" in *windows-setup) ;; *) fail "not recognised as a setup install: $V1" ;; esac

echo "== 2. update through a newer setup"
mkdir -p "$T/srv"
cp "$SETUP" "$T/srv/setup.exe"
openssl genpkey -algorithm ed25519 -out "$T/key.pem" 2>/dev/null
PUB=$(openssl pkey -in "$T/key.pem" -pubout -outform DER | tail -c 32 | base64)
HTTP_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
BASE="http://127.0.0.1:$HTTP_PORT"
cat >"$T/srv/latest.json" <<EOF
{"version":"9.9.9","assets":{"windows-x64-setup":{"url":"$BASE/setup.exe",
 "sha256":"$(sha256sum "$T/srv/setup.exe" | cut -d' ' -f1)","size":$(stat -c %s "$T/srv/setup.exe")}}}
EOF
openssl pkeyutl -sign -inkey "$T/key.pem" -rawin -in "$T/srv/latest.json" | base64 -w0 >"$T/srv/latest.json.sig"
(cd "$T/srv" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >"$T/http.log" 2>&1) &
HTTPD=$!
# Restart the installed agent with the test update source.
"$WINE" "$INST/pairdesk-agent.exe" --quit || fail "--quit failed"
running && fail "still running after --quit"
PAIRDESK_UPDATE_MANIFEST="$BASE/latest.json" PAIRDESK_UPDATE_KEY="$PUB" \
  "$WINE" "$INST/pairdesk-agent.exe" --background >/dev/null 2>&1 &
wait_running || fail "didn't restart"
URL=$(cat "$DATA/settings-url.txt")
post() { curl -sf -X POST -H 'X-PairDesk: 1' -H 'Content-Type: application/json' -d '{}' "${URL}api/$1"; }
post update-check | grep -q '"latest":"9.9.9"' || fail "update not found"
post update-install >/dev/null || fail "install refused"
for _ in $(seq 300); do
  NEW=$(cat "$DATA/settings-url.txt" 2>/dev/null || true)
  [ -n "$NEW" ] && [ "$NEW" != "$URL" ] && curl -sf "${NEW}api/state" >/dev/null && break
  sleep 0.2
done
[ "$NEW" != "$URL" ] || fail "PairDesk didn't come back after the setup ran"
grep -q "setup.exe" "$T/http.log" || fail "the setup wasn't downloaded"
grep -rq "updated to" "$DATA/agent.log" || fail "the new copy wasn't started as an update"
echo "   back up after the update"

echo "== 3. silent uninstall"
"$WINE" "$INST/Uninstall PairDesk.exe" /S
for _ in $(seq 50); do [ -f "$INST/pairdesk-agent.exe" ] || break; sleep 0.2; done
[ -f "$INST/pairdesk-agent.exe" ] && fail "program still there"
running && fail "PairDesk still running after uninstall"
reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\PairDesk' >/dev/null && fail "Settings → Apps entry left behind"
reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' /v PairDesk | grep -q PairDesk && fail "start at sign-in left behind"
[ -z "$(find "$WINEPREFIX/drive_c/users/$U" -name 'PairDesk.lnk')" ] || fail "Start menu shortcut left behind"
[ -f "$DATA/identity-key.der" ] || fail "a silent uninstall must keep the settings"
echo "windows setup e2e: ok"
