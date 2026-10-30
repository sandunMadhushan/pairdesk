#!/usr/bin/env bash
# End-to-end test of two-way sound: the phone app's code against the real
# agent, with a private PipeWire sound server (and its PulseAudio
# interface) whose only output is a virtual sink.
#
#   - computer sound → phone: a 440 Hz tone is played on the computer;
#     the phone must receive Opus packets that aren't silence;
#   - phone voice → computer: the phone sends a 1 kHz tone; it must come
#     out of the computer's (virtual) speakers;
#   - the computer's microphone: refused until allowed, then heard;
#   - turning sound off on the computer stops a phone that listens.
#
#   cargo build --release --manifest-path agent/Cargo.toml && tools/e2e-audio.sh
# (run inside dbus-run-session if there's no session bus)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AGENT=$(realpath "${AGENT:-$ROOT/agent/target/release/pairdesk-agent}")
PORT=${PORT:-47812}
DATA=$(mktemp -d)
export XDG_RUNTIME_DIR="$DATA/run"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export DISPLAY=:96
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null || true; if [ -n "${KEEP:-}" ]; then echo "kept $DATA"; else rm -rf "$DATA"; fi; }
trap cleanup EXIT

Xvfb :96 -noreset -screen 0 1024x768x24 >/dev/null 2>&1 & PIDS+=($!)
pipewire >"$DATA/pw.log" 2>&1 & PIDS+=($!)
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.1; done
wireplumber >>"$DATA/pw.log" 2>&1 & PIDS+=($!)
pipewire-pulse >>"$DATA/pw.log" 2>&1 & PIDS+=($!)
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 0.1; done
[ -S "$XDG_RUNTIME_DIR/pulse/native" ] || { echo "pipewire-pulse didn't start"; cat "$DATA/pw.log"; exit 1; }
# The computer's "speakers": a virtual sink, made the default output.
pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=e2e-speakers node.description=e2e-speakers
  media.class=Audio/Sink object.linger=true audio.position=[ FL FR ] }' >/dev/null
for _ in $(seq 50); do
  ID=$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | grep -m1 'e2e-speakers' | grep -o '[0-9]\+\.' | head -1 | tr -d . || true)
  [ -n "${ID:-}" ] && break; sleep 0.2
done
[ -n "${ID:-}" ] || { echo "virtual sink missing"; wpctl status; exit 1; }
for _ in $(seq 25); do wpctl set-default "$ID" 2>/dev/null && break; sleep 0.2; done
# The computer's "microphone": a virtual source (silent), the default input.
pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=e2e-mic node.description=e2e-mic
  media.class=Audio/Source object.linger=true audio.position=[ FL FR ] }' >/dev/null
for _ in $(seq 50); do
  MIC=$(wpctl status 2>/dev/null | sed -n '/Sources:/,/Streams:/p' | grep -m1 'e2e-mic' | grep -o '[0-9]\+\.' | head -1 | tr -d . || true)
  [ -n "${MIC:-}" ] && break; sleep 0.2
done
[ -n "${MIC:-}" ] || { echo "virtual microphone missing"; wpctl status; exit 1; }
for _ in $(seq 25); do wpctl set-default "$MIC" 2>/dev/null && break; sleep 0.2; done
sleep 0.5

if [ -n "${WINE:-}" ]; then
  # The Windows build: WASAPI through Wine's PulseAudio driver.
  export WINEDEBUG=-all WINEPREFIX="$DATA/wine" WINEDLLOVERRIDES="mscoree,mshtml="
  WINEBIN=$(command -v wine || command -v wine64 || echo /usr/lib/wine/wine64)
  "$WINEBIN" wineboot -i >/dev/null 2>&1
  PAIRDESK_HOME="Z:${DATA//\//\\}" "$WINEBIN" "$AGENT" --background --no-tray --port "$PORT" >"$DATA/out.txt" 2>&1 & PIDS+=($!)
  WAIT=600
else
  PAIRDESK_HOME="$DATA" "$AGENT" --background --no-tray --port "$PORT" >"$DATA/out.txt" 2>&1 & PIDS+=($!)
  WAIT=50
fi
for _ in $(seq $WAIT); do [ -s "$DATA/settings-url.txt" ] && break; sleep 0.2; done
[ -s "$DATA/settings-url.txt" ] || { echo "agent did not start"; cat "$DATA/out.txt"; exit 1; }
SETTINGS=$(cat "$DATA/settings-url.txt")
LINK=$(curl -sf -X POST -H 'X-PairDesk: 1' "${SETTINGS}api/pair" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["pairing"]["link"])')

# Plays the computer's tone when the test asks; records the speakers
# while the phone talks.
# Wine's sound driver can't record what's playing (loopback); real Windows
# can. Under Wine the computer-sound part is skipped.
LOOPBACK=${WINE:+0}
python3 - "$DATA" "${LOOPBACK:-1}" <<'PY' & PIDS+=($!)
import math, os, struct, subprocess, sys, time, wave
d = sys.argv[1]
def tone(path, freq, secs):
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
        frames = b"".join(struct.pack("<hh", v, v) for v in
                          (int(12000 * math.sin(2 * math.pi * freq * i / 48000)) for i in range(int(48000 * secs))))
        w.writeframes(frames)
tone(f"{d}/440.wav", 440, 2.0)
if sys.argv[2] == "1":
    while not os.path.exists(f"{d}/play"): time.sleep(0.05)
    subprocess.run(["pw-play", f"{d}/440.wav"], check=True)
    open(f"{d}/played", "w").close()
while not os.path.exists(f"{d}/record"): time.sleep(0.05)
rec = subprocess.Popen(["pw-record", "--target", "e2e-speakers", "--rate", "48000", "--channels", "1",
                        "--format", "s16", f"{d}/heard.wav"],
                       env={**os.environ, "PIPEWIRE_PROPS": "{ stream.capture.sink=true }"})
open(f"{d}/recording", "w").close()
while not os.path.exists(f"{d}/stop-recording"): time.sleep(0.05)
time.sleep(0.5)
rec.terminate(); rec.wait()
open(f"{d}/recorded", "w").close()
PY

(cd "$ROOT/mobile" && PAIRDESK_E2E_LINK="$LINK" PAIRDESK_E2E_SETTINGS="$SETTINGS" PAIRDESK_E2E_AUDIO="$DATA" \
  PAIRDESK_E2E_LOOPBACK="${LOOPBACK:-1}" \
  flutter test test/e2e_audio_test.dart)

for _ in $(seq 50); do [ -e "$DATA/recorded" ] && break; sleep 0.1; done
python3 - "$DATA/heard.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1]) as w:
    data = w.readframes(w.getnframes()); rate = w.getframerate()
s = struct.unpack(f"<{len(data)//2}h", data)
def power(freq):
    # Goertzel over the whole recording.
    k = 2 * math.cos(2 * math.pi * freq / rate); a = b = 0.0
    for x in s:
        a, b = x + k * a - b, a
    return (a * a + b * b - k * a * b) / max(len(s), 1) ** 2
p1k, p440, noise = power(1000), power(440), power(2700)
print(f"speakers: 1 kHz {p1k:.1f}, 440 Hz {p440:.1f}, 2.7 kHz {noise:.1f} ({len(s)/rate:.1f} s recorded)")
assert len(s) > rate, "nothing recorded"
assert p1k > 100 * max(noise, 1e-3), "the phone's voice wasn't heard on the computer"
print("phone voice came out of the computer's speakers: ok")
PY
grep -E "listening|talking|sound" "$DATA/out.txt" "$DATA/agent.log" 2>/dev/null | tail -5 || true
if [ -n "${WINE:-}" ]; then { command -v wineserver >/dev/null && wineserver -k || /usr/lib/wine/wineserver -k; } 2>/dev/null || true; fi
echo "AUDIO E2E PASSED${WINE:+ (Windows build under Wine)}"
