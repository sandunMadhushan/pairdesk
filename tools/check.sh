#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The checks CI runs, in one command, so nothing reaches a pull request
# that GitHub Actions would reject. Run it before every commit.
#
#   tools/check.sh          agent, relay and phone app
#   tools/check.sh phone    only the phone app (fastest)
#   tools/check.sh agent    only the Rust agent
#
# It does NOT build the APK or the release binaries: CI does that, and it
# takes minutes. `tools/check.sh phone apk` adds the APK build.
set -euo pipefail

cd "$(dirname "$0")/.."
want=${1:-all}
extra=${2:-}
fail=0

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
step() {
  printf '  %s ... ' "$1"
  shift
  if out=$("$@" 2>&1); then
    printf 'ok\n'
  else
    printf 'FAILED\n'
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
  fi
}

if [ "$want" = all ] || [ "$want" = agent ]; then
  say "Agent (Rust)"
  (
    cd agent
    step "cargo fmt --check" cargo fmt --check
    step "cargo clippy -D warnings" cargo clippy --release -- -D warnings
    step "cargo test" cargo test --quiet
    exit "$fail"
  ) || fail=1
fi

if [ "$want" = all ] || [ "$want" = relay ]; then
  say "Relay (Rust)"
  (
    cd relay
    step "cargo fmt --check" cargo fmt --check
    step "cargo clippy -D warnings" cargo clippy --release -- -D warnings
    step "cargo test" cargo test --quiet
    exit "$fail"
  ) || fail=1
fi

if [ "$want" = all ] || [ "$want" = phone ]; then
  # Flutter isn't on PATH in every shell here.
  [ -d /opt/flutter/bin ] && PATH=$PATH:/opt/flutter/bin
  say "Phone app (Flutter)"
  (
    cd mobile
    step "flutter pub get" flutter pub get
    # CI fails on any reformatting, and on analyzer infos as well as warnings.
    step "dart format -l 110" dart format -l 110 --output=none --set-exit-if-changed lib test
    step "flutter analyze" flutter analyze
    step "flutter test" flutter test
    if [ "$extra" = apk ]; then
      step "flutter build apk" env PAIRDESK_UNSIGNED=1 flutter build apk --release \
        --split-per-abi --target-platform=android-arm64
    fi
    exit "$fail"
  ) || fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All good."
else
  echo "Something CI would reject. Fix it before you push."
fi
exit "$fail"
