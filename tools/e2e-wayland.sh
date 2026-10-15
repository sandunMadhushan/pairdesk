#!/usr/bin/env bash
# End-to-end test of the agent in a GNOME Wayland session: headless mutter
# with a 1280×800 virtual monitor, the real xdg-desktop-portal(-gnome),
# PipeWire and WirePlumber. A GTK 4 window records the input it gets.
#
# Needs (Ubuntu 24.04): mutter xdg-desktop-portal xdg-desktop-portal-gnome
# pipewire wireplumber python3-gi gir1.2-atspi-2.0 at-spi2-core, Flutter, and
# a built agent:
#
#   cargo build --release --manifest-path agent/Cargo.toml && tools/e2e-wayland.sh
#
# Stages, each with the real portal dialog answered through accessibility:
#   1. first start at the computer: the dialog appears and is approved;
#      screen, pointer, buttons, scroll and keyboard are checked;
#   2. agent restarted at sign-in (--background): no dialog, the phone
#      connects and it all works (the permission was remembered);
#   3. permission forgotten and the owner presses Cancel: the phone is told.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${PAIRDESK_IN_SESSION:-}" ]; then
  exec env PAIRDESK_IN_SESSION=1 dbus-run-session -- "$0" "$@"
fi
AGENT=${AGENT:-$ROOT/agent/target/release/pairdesk-agent}
PORT=${PORT:-47812}
DATA=$(mktemp -d)
PY=$(command -v python3.12 || command -v python3)
export XDG_RUNTIME_DIR=$DATA/run
mkdir -p "$XDG_RUNTIME_DIR"
cleanup() { kill ${APID:-} ${APPPID:-} ${ATSPI:-} $(cat "$XDG_RUNTIME_DIR/pids" 2>/dev/null) 2>/dev/null || true; pkill -P $$ 2>/dev/null || true; if [ -n "${KEEP:-}" ]; then echo "kept $DATA"; else rm -rf "$DATA"; fi; }
trap cleanup EXIT

"$ROOT/tools/wayland-stack.sh" "$DATA/env.sh"
. "$DATA/env.sh"
/usr/libexec/at-spi-bus-launcher --launch-immediately >/dev/null 2>&1 & ATSPI=$!
sleep 1

start_agent() {
  PAIRDESK_HOME="$DATA/home" BROWSER=true "$AGENT" --no-tray --port "$PORT" "$@" >>"$DATA/agent.txt" 2>&1 &
  APID=$!
  for _ in $(seq 50); do [ -s "$DATA/home/settings-url.txt" ] && break; sleep 0.2; done
  SETTINGS=$(cat "$DATA/home/settings-url.txt")
}
stop_agent() {
  curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/quit" >/dev/null
  for _ in $(seq 50); do kill -0 $APID 2>/dev/null || break; sleep 0.2; done
  ! kill -0 $APID 2>/dev/null || { echo "agent did not stop"; exit 1; }
}
new_link() {
  curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/pair" |
    "$PY" -c 'import json,sys; print(json.load(sys.stdin)["pairing"]["link"])'
}
wayland_status() {
  curl -sf "${SETTINGS}api/state" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["wayland"]["status"])'
}
phone() {
  (cd "$ROOT/mobile" && PAIRDESK_E2E_LINK="$1" PAIRDESK_E2E_STAGE="$2" \
    PAIRDESK_E2E_APP_LOG="$DATA/app.log" PAIRDESK_E2E_SCREEN_SIGNAL="$DATA/turn-green" \
    flutter test test/e2e_wayland_test.dart)
}

echo "== 1. first start: the desktop asks, the owner approves"
mkdir -p "$DATA/home"
"$PY" "$ROOT/tools/wayland/approve_portal.py" 30 >"$DATA/approve1.txt" 2>&1 & APPROVER=$!
start_agent
wait $APPROVER || { echo "approving failed:"; cat "$DATA/approve1.txt"; exit 1; }
for _ in $(seq 50); do [ "$(wayland_status)" = ready ] && break; sleep 0.2; done
[ "$(wayland_status)" = ready ] || { echo "not ready"; cat "$DATA/agent.txt"; exit 1; }
[ -s "$DATA/home/wayland-restore-token" ] || { echo "permission not remembered"; exit 1; }
${APP_ENV:-} "$PY" "$ROOT/tools/wayland/test_app.py" "$DATA/app.log" "$DATA/turn-green" >"$DATA/app.txt" 2>&1 & APPPID=$!
for _ in $(seq 50); do grep -q ready "$DATA/app.log" 2>/dev/null && break; sleep 0.2; done
phone "$(new_link)" first
echo "stage 1: ok"
stop_agent

echo "== 2. started at sign-in: no dialog, it just works"
"$PY" "$ROOT/tools/wayland/approve_portal.py" 12 >"$DATA/approve2.txt" 2>&1 & APPROVER=$!
start_agent --background
[ "$(wayland_status)" = idle ] || { echo "should wait for a phone"; exit 1; }
phone "$(new_link)" again
if wait $APPROVER; then echo "a dialog appeared although the permission was remembered"; exit 1; fi
grep -q "remembered" "$DATA/agent.txt"
echo "stage 2: ok"
stop_agent

echo "== 3. permission forgotten, the owner presses Cancel: the phone is told"
rm -f "$DATA/home/wayland-restore-token"
"$PY" "$ROOT/tools/wayland/approve_portal.py" 30 --cancel >"$DATA/approve3.txt" 2>&1 & APPROVER=$!
start_agent --background
LINK=$(new_link)
(cd "$ROOT/mobile" && PAIRDESK_E2E_LINK="$LINK" PAIRDESK_E2E_STAGE=cancel \
  flutter test test/e2e_wayland_notice_test.dart)
wait $APPROVER
for _ in $(seq 25); do [ "$(wayland_status)" = denied ] && break; sleep 0.2; done
[ "$(wayland_status)" = denied ] || { echo "status should be denied: $(wayland_status)"; exit 1; }
echo "stage 3: ok"
stop_agent

echo "--- agent log ---"
grep -v "^$" "$DATA/agent.txt" | grep -i "wayland\|remote desktop\|screen" | tail -15
echo "WAYLAND E2E PASSED"
