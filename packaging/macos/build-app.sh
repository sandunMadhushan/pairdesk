#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds PairDesk.app (Apple silicon + Intel in one) and PairDesk-<version>-mac.dmg.
# Runs on macOS (the CI runner): needs Rust with both Mac targets.
#
#   packaging/macos/build-app.sh 0.13.0 out/
#
# The app is ad-hoc signed: macOS asks once before opening it (System
# Settings → Privacy & Security → Open Anyway). With an Apple developer
# account, set MAC_SIGN_IDENTITY to a "Developer ID Application" identity
# to sign it properly (then notarize the .dmg).
set -euo pipefail
version=${1:?version}
out=${2:-out}
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

cd "$root/agent"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  MACOSX_DEPLOYMENT_TARGET=11.0 cargo build --release --target "$target" --bin pairdesk-agent
done

work=$(mktemp -d)
app="$work/PairDesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$app/Contents/MacOS/pairdesk-agent" \
  target/aarch64-apple-darwin/release/pairdesk-agent \
  target/x86_64-apple-darwin/release/pairdesk-agent
iconutil -c icns -o "$app/Contents/Resources/PairDesk.icns" "$root/packaging/macos/PairDesk.iconset"
sed "s/@VERSION@/$version/g" "$root/packaging/macos/Info.plist" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

if [ -n "${MAC_SIGN_IDENTITY:-}" ]; then
  # Developer ID: hardened runtime and a timestamp, as notarization needs.
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$root/packaging/macos/entitlements.plist" \
    --sign "$MAC_SIGN_IDENTITY" "$app"
else
  codesign --force --deep --sign - "$app"
fi
codesign --verify --deep --strict "$app"

# The disk image: the app and a shortcut to Applications to drag it onto.
stage="$work/dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$out/PairDesk-$version-mac.dmg"
rm -f "$dmg"
hdiutil create -volname "PairDesk" -srcfolder "$stage" -ov -format UDZO "$dmg"
ls -lh "$dmg"
