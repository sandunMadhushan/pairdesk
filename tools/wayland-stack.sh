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
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep 0.1; done
/usr/libexec/xdg-desktop-portal-gnome >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
sleep 0.5
/usr/libexec/xdg-desktop-portal >>"$LOG" 2>&1 &
echo $! >>"$XDG_RUNTIME_DIR/pids"
for _ in $(seq 100); do
  gdbus introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop 2>/dev/null |
    grep -q org.freedesktop.portal.RemoteDesktop && break
  sleep 0.1
done
cat >"$OUT" <<EOF
export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=$WAYLAND_DISPLAY
EOF
