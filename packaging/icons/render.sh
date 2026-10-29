#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders every icon PairDesk ships from the SVGs in this folder.
# Needs rsvg-convert (librsvg2-bin) and icotool (icoutils). The results are
# committed, so builds don't need these tools.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# Linux (hicolor theme) and the website.
for s in 16 24 32 48 64 128 256 512; do
  mkdir -p hicolor/${s}x${s}/apps
  png pairdesk.svg $s hicolor/${s}x${s}/apps/me.madhushan.pairdesk.png
done
mkdir -p hicolor/scalable/apps && cp pairdesk.svg hicolor/scalable/apps/me.madhushan.pairdesk.svg

# Windows .ico (installer and the agent's .exe).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for s in 16 20 24 32 40 48 64 256; do png pairdesk.svg $s "$tmp/$s.png"; done
icotool -c -o pairdesk.ico "$tmp"/{16,20,24,32,40,48,64}.png -r "$tmp/256.png"
cp pairdesk.ico "$ROOT/agent/pairdesk.ico"

# MSIX (Microsoft Store) logos.
mkdir -p msix
png pairdesk.svg 44 msix/Square44x44Logo.png
png pairdesk.svg 150 msix/Square150x150Logo.png
png pairdesk.svg 50 msix/StoreLogo.png
for s in 16 24 32 48 256; do
  png pairdesk.svg $s msix/Square44x44Logo.targetsize-${s}.png
  cp msix/Square44x44Logo.targetsize-${s}.png msix/Square44x44Logo.targetsize-${s}_altform-unplated.png
done

# Android launcher: legacy square icons and adaptive layers.
RES="$ROOT/mobile/android/app/src/main/res"
declare -A dens=([mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192)
for d in "${!dens[@]}"; do
  s=${dens[$d]}
  png pairdesk.svg $s "$RES/mipmap-$d/ic_launcher.png"
  # Adaptive layers are 108 dp: 2.25 × the 48 dp icon.
  f=$((s * 9 / 4))
  png pairdesk-foreground.svg $f "$RES/mipmap-$d/ic_launcher_foreground.png"
  png pairdesk-monochrome.svg $f "$RES/mipmap-$d/ic_launcher_monochrome.png"
done
# Store listing icon (F-Droid, Microsoft Store).
mkdir -p "$ROOT/fastlane/metadata/android/en-US/images"
png pairdesk.svg 512 "$ROOT/fastlane/metadata/android/en-US/images/icon.png"
png pairdesk.svg 300 msix/StoreListing300.png
echo "icons rendered"
