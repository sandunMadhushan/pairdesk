#!/usr/bin/env bash
# Starts a throwaway GNOME Wayland session for tests: headless mutter with a
# 1280×800 virtual monitor, PipeWire, WirePlumber and the GNOME portals.
# Run inside dbus-run-session; leaves env in $1 (sourceable) and the started
# processes in $XDG_RUNTIME_DIR/pids (kill them when done).
set -eu
OUT=$1
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-$(mktemp -d)}
chmod 700 "$XDG_RUNTIME_DIR"
export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-pd
export GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=0 GTK_A11Y=atspi
LOG=$XDG_RUNTIME_DIR/stack.log
pipewire >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.1; done
wireplumber >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
sleep 0.5
mutter --headless --wayland --no-x11 --wayland-display "$WAYLAND_DISPLAY" --virtual-monitor 1280x800 >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
# Waits (up to 60 s) until a D-Bus name has an owner.
wait_name() {
  for _ in $(seq 600); do
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -q true && return 0
    sleep 0.1
  done
  echo "wayland-stack: $1 never appeared" >&2
  tail -20 "$LOG" >&2
  exit 1
}
for _ in $(seq 600); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep 0.1; done
# The GNOME portal only offers remote desktop and screen cast if mutter's
# services are already there when it starts; slow machines (CI) need the wait.
wait_name org.gnome.Mutter.RemoteDesktop
wait_name org.gnome.Mutter.ScreenCast
/usr/libexec/xdg-desktop-portal-gnome >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
wait_name org.freedesktop.impl.portal.desktop.gnome
/usr/libexec/xdg-desktop-portal >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
# (Introspecting before it owns its name would start a second one.)
wait_name org.freedesktop.portal.Desktop
ok=
for _ in $(seq 600); do
  if gdbus introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop 2>/dev/null |
    grep -q org.freedesktop.portal.RemoteDesktop; then ok=1; break; fi
  sleep 0.1
done
[ -n "$ok" ] || { echo "wayland-stack: no RemoteDesktop portal" >&2; tail -20 "$LOG" >&2; exit 1; }
cat >"$OUT" <<EOF
export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=$WAYLAND_DISPLAY
EOF
