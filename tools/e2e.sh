#!/usr/bin/env bash
# End-to-end test: the phone app's connection code against the real agent,
# on a virtual X display. Needs Xvfb, python3-xlib, curl, Flutter and a
# built agent.
#
#   cargo build --release --manifest-path agent/Cargo.toml && tools/e2e.sh
#
# Windows build under Wine (exercises the tray message loop too):
#   WINE=1 AGENT=agent/target/x86_64-pc-windows-gnu/release/pairdesk-agent.exe tools/e2e.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=${AGENT:-$ROOT/agent/target/release/pairdesk-agent}
PORT=${PORT:-47811}
DATA=$(mktemp -d)
export DISPLAY=:97
cleanup() { kill ${APID:-} ${XPID:-} 2>/dev/null || true; [ -n "${WINE:-}" ] && { command -v wineserver >/dev/null && wineserver -k || /usr/lib/wine/wineserver -k; } 2>/dev/null; rm -rf "$DATA"; }
trap cleanup EXIT

Xvfb :97 -noreset -screen 0 1280x800x24 >/dev/null 2>&1 & XPID=$!
sleep 1
python3 - <<'PY'
from Xlib import display
d = display.Display(); d.screen().root.warp_pointer(100, 100); d.sync()
PY

# Power actions are logged, not performed.
export PAIRDESK_POWER_DRY_RUN=1

if [ -n "${WINE:-}" ]; then
  WINDATA="Z:${DATA//\//\\}"
  E2E_PROGRAM='C:\windows\system32\cmd.exe'
  E2E_ARGS="/c \"echo ok > $WINDATA\\shortcut-ran\""
  E2E_APP=""
  export WINEDEBUG=-all WINEPREFIX="$DATA/wine" WINEDLLOVERRIDES="mscoree,mshtml="
  WINEBIN=$(command -v wine || command -v wine64 || echo /usr/lib/wine/wine64)
  PAIRDESK_HOME="Z:${DATA//\//\\}" "$WINEBIN" "$AGENT" --background --port "$PORT" >"$DATA/out.txt" 2>&1 & APID=$!
  WAIT=600
else
  # An installed app for the agent to find: a .desktop file in XDG_DATA_HOME.
  mkdir -p "$DATA/xdg/applications"
  printf '[Desktop Entry]\nType=Application\nName=PairDesk E2E App\nExec=sh -c "touch %s/app-ran" %%U\n' "$DATA" \
    >"$DATA/xdg/applications/pairdesk-e2e.desktop"
  export XDG_DATA_HOME="$DATA/xdg"
  E2E_PROGRAM=/bin/sh
  E2E_ARGS="-c \"touch '$DATA/shortcut-ran'\""
  E2E_APP="PairDesk E2E App"
  PAIRDESK_HOME="$DATA" "$AGENT" --background --no-tray --port "$PORT" >"$DATA/out.txt" 2>&1 & APID=$!
  WAIT=50
fi
for _ in $(seq $WAIT); do [ -s "$DATA/settings-url.txt" ] && break; sleep 0.2; done
SETTINGS=$(cat "$DATA/settings-url.txt" 2>/dev/null || true)
[ -n "$SETTINGS" ] || { echo "agent did not start"; cat "$DATA/out.txt" "$DATA/agent.log" 2>/dev/null; exit 1; }

# Ask the agent for a pairing code, the way the settings page does.
LINK=$(curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/pair" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["pairing"]["link"])')
echo "agent link: ${LINK%%&t=*}&t=…"

(cd "$ROOT/mobile" && PAIRDESK_E2E_LINK="$LINK" PAIRDESK_E2E_SETTINGS="$SETTINGS" \
  PAIRDESK_E2E_OS="${WINE:+windows}" PAIRDESK_E2E_PROGRAM="$E2E_PROGRAM" \
  PAIRDESK_E2E_PROGRAM_ARGS="$E2E_ARGS" PAIRDESK_E2E_APP="$E2E_APP" \
  flutter test test/e2e_real_agent_test.dart)

# Launched from the phone: the shortcut (and, on Linux, the installed app) ran.
for _ in $(seq 50); do [ -e "$DATA/shortcut-ran" ] && break; sleep 0.2; done
[ -e "$DATA/shortcut-ran" ] || { echo "shortcut did not run"; exit 1; }
echo "shortcut launched from the phone: ok"
if [ -z "${WINE:-}" ]; then
  for _ in $(seq 50); do [ -e "$DATA/app-ran" ] && break; sleep 0.2; done
  [ -e "$DATA/app-ran" ] || { echo "installed app did not run"; exit 1; }
  echo "installed app launched from the phone: ok"
fi
grep -q "Lock (dry run" "$DATA/out.txt" "$DATA/agent.log" 2>/dev/null && echo "power actions reached the agent: ok"

python3 - <<'PY'
from Xlib import display
p = display.Display().screen().root.query_pointer()
print(f"cursor at {p.root_x},{p.root_y}")
assert (p.root_x, p.root_y) == (140, 130), "cursor did not move by (40, 30)"
PY

# Stopping from the settings page must end the process cleanly.
curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/quit" >/dev/null
for _ in $(seq 50); do kill -0 $APID 2>/dev/null || break; sleep 0.2; done
if kill -0 $APID 2>/dev/null; then echo "agent did not stop after quit"; exit 1; fi
[ -e "$DATA/settings-url.txt" ] && { echo "settings-url.txt left behind"; exit 1; }

echo "--- agent log ---"
{ cat "$DATA/out.txt" "$DATA/agent.log" 2>/dev/null || true; } | tail -12
echo "E2E PASSED${WINE:+ (Windows build under Wine)}"
