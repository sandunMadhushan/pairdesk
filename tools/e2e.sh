#!/usr/bin/env bash
# End-to-end test: the phone app's connection code against the real agent,
# on a virtual X display. Needs Xvfb, python3-xlib, xclip, curl, Flutter and
# a built agent.
#
#   cargo build --release --manifest-path agent/Cargo.toml && tools/e2e.sh
#
# Windows build under Wine (exercises the tray message loop too):
#   WINE=1 AGENT=agent/target/x86_64-pc-windows-gnu/release/pairdesk-agent.exe tools/e2e.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=$(realpath "${AGENT:-$ROOT/agent/target/release/pairdesk-agent}")
PORT=${PORT:-47811}
DATA=$(mktemp -d)
export DISPLAY=:97
cleanup() { kill ${APID:-} ${SCREENPID:-} ${XPID:-} 2>/dev/null || true; [ -n "${WINE:-}" ] && { command -v wineserver >/dev/null && wineserver -k || /usr/lib/wine/wineserver -k; } 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "kept $DATA"; else rm -rf "$DATA"; fi; }
trap cleanup EXIT

Xvfb :97 -noreset -screen 0 1280x800x24 >/dev/null 2>&1 & XPID=$!
sleep 1
python3 - <<'PY'
from Xlib import display
d = display.Display(); d.screen().root.warp_pointer(100, 100); d.sync()
PY

# Something to look at for screen view: a red window, turned green when
# the phone test asks (by creating $DATA/turn-green).
python3 - "$DATA/turn-green" <<'PY' & SCREENPID=$!
import os, sys, time
from Xlib import X, display
d = display.Display()
s = d.screen()
w = s.root.create_window(0, 0, 400, 300, 0, s.root_depth, X.InputOutput, X.CopyFromParent,
                         background_pixel=0xFF0000, override_redirect=True)
w.map(); d.sync()
while not os.path.exists(sys.argv[1]):
    time.sleep(0.05)
w.change_attributes(background_pixel=0x00FF00); w.clear_area(); d.sync()
while True:
    time.sleep(1)
PY
sleep 0.5

# Power actions are logged, not performed.
export PAIRDESK_POWER_DRY_RUN=1
# Files from the phone land here.
mkdir -p "$DATA/downloads"

if [ -n "${WINE:-}" ]; then
  WINDATA="Z:${DATA//\//\\}"
  E2E_PROGRAM='C:\windows\system32\cmd.exe'
  E2E_ARGS="/c \"echo ok > $WINDATA\\shortcut-ran\""
  E2E_APP=""
  export WINEDEBUG=-all WINEPREFIX="$DATA/wine" WINEDLLOVERRIDES="mscoree,mshtml="
  WINEBIN=$(command -v wine || command -v wine64 || echo /usr/lib/wine/wine64)
  if [ -n "${HELPER:-}" ]; then
    # Windows helper service (sign-in screen and UAC): installed first; the
    # agent then acts as if the secure desktop were up, so every pointer and
    # key press and every screen picture goes through the SYSTEM helper.
    "$WINEBIN" wineboot -i >/dev/null 2>&1
    # Wine has no secure desktop: let the helper act on the normal one
    # (a marker only administrators can create; see winsys/helper.rs).
    mkdir -p "$WINEPREFIX/drive_c/ProgramData/PairDesk"
    touch "$WINEPREFIX/drive_c/ProgramData/PairDesk/allow-normal-desktop"
    "$WINEBIN" "$AGENT" --install-service >"$DATA/install.txt" 2>&1 ||
      { echo "installing the helper service failed:"; cat "$DATA/install.txt"; exit 1; }
    for _ in $(seq 300); do
      ls "$WINEPREFIX/drive_c/ProgramData/PairDesk/bridge/"session-*.json >/dev/null 2>&1 && break
      sleep 0.2
    done
    ls "$WINEPREFIX/drive_c/ProgramData/PairDesk/bridge/"session-*.json >/dev/null 2>&1 ||
      { echo "the helper didn't start"; cat "$WINEPREFIX/drive_c/ProgramData/PairDesk/"*.log; exit 1; }
    export PAIRDESK_TEST_SECURE_DESKTOP=1
  fi
  PAIRDESK_DOWNLOADS="Z:${DATA//\//\\}\\downloads" PAIRDESK_HOME="Z:${DATA//\//\\}" "$WINEBIN" "$AGENT" --background --port "$PORT" >"$DATA/out.txt" 2>&1 & APID=$!
  WAIT=600
  # "Send to phone" as Explorer runs it, with the file as a Windows path.
  cat >"$DATA/send.sh" <<SEND
#!/bin/sh
p=\$(printf '%s' "\$1" | tr '/' '\\\\')
export WINEDEBUG=-all WINEPREFIX='$WINEPREFIX' WINEDLLOVERRIDES='mscoree,mshtml=' PAIRDESK_HOME='Z:${DATA//\//\\}'
exec '$WINEBIN' '$AGENT' --send "Z:\$p"
SEND
  chmod +x "$DATA/send.sh"
  E2E_SEND_CMD="$DATA/send.sh"
else
  # An installed app for the agent to find: a .desktop file in XDG_DATA_HOME.
  mkdir -p "$DATA/xdg/applications"
  printf '[Desktop Entry]\nType=Application\nName=PairDesk E2E App\nExec=sh -c "touch %s/app-ran" %%U\n' "$DATA" \
    >"$DATA/xdg/applications/pairdesk-e2e.desktop"
  export XDG_DATA_HOME="$DATA/xdg"
  E2E_PROGRAM=/bin/sh
  E2E_ARGS="-c \"touch '$DATA/shortcut-ran'\""
  E2E_APP="PairDesk E2E App"
  # A stand-in `tailscale` command, so the agent reports a Tailscale address.
  mkdir -p "$DATA/bin"
  cat >"$DATA/bin/tailscale" <<'TS'
#!/bin/sh
[ "$1 $2" = "status --json" ] || exit 2
echo '{"BackendState":"Running","Self":{"DNSName":"e2e-pc.tail1234.ts.net.","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1"]},"CurrentTailnet":{"Name":"e2e","MagicDNSEnabled":true}}'
TS
  chmod +x "$DATA/bin/tailscale"
  E2E_TAILSCALE=1
  # Clipboard checked with another X program; files sent like the file manager does.
  E2E_CLIP_CHECK="xclip -o -selection clipboard"
  E2E_CLIP_SET="printf 'copied on the computer' | xclip -selection clipboard >/dev/null 2>&1"
  E2E_SEND_CMD="PAIRDESK_HOME='$DATA' '$AGENT' --send"
  PATH="$DATA/bin:$PATH" PAIRDESK_DOWNLOADS="$DATA/downloads" PAIRDESK_HOME="$DATA" "$AGENT" --background --no-tray --port "$PORT" >"$DATA/out.txt" 2>&1 & APID=$!
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
  PAIRDESK_E2E_TAILSCALE="${E2E_TAILSCALE:-}" PAIRDESK_E2E_SCREEN_SIGNAL="$DATA/turn-green" \
  PAIRDESK_E2E_DOWNLOADS="$DATA/downloads" PAIRDESK_E2E_CLIP_CHECK="${E2E_CLIP_CHECK:-}" \
  PAIRDESK_E2E_CLIP_SET="${E2E_CLIP_SET:-}" PAIRDESK_E2E_SEND_CMD="${E2E_SEND_CMD:-}" \
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
if [ -n "${HELPER:-}" ]; then
  grep -q "sign-in screen and admin prompts work" "$DATA/agent.log" "$DATA/out.txt" 2>/dev/null ||
    { echo "the agent didn't use the helper"; exit 1; }
fi
echo "E2E PASSED${WINE:+ (Windows build under Wine)}${HELPER:+, through the SYSTEM helper}"
