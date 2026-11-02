#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the Linux downloads from a release binary:
#   pairdesk_<v>_amd64.deb, pairdesk-<v>-1.x86_64.rpm, PairDesk-<v>-x86_64.AppImage
#
#   packaging/linux/build-packages.sh <version> <pairdesk-agent binary> <out dir>
#
# Needs dpkg-deb, rpmbuild and appimagetool (APPIMAGETOOL=path, or it is
# downloaded). The binary should be the glibc 2.31 build (cargo zigbuild).
set -euo pipefail
VERSION=$1
BIN=$(realpath "$2")
OUT=$(mkdir -p "$3" && realpath "$3")
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ID=me.madhushan.pairdesk
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The files every package installs, under a /usr prefix.
stage() {
  local d=$1
  install -Dm755 "$BIN" "$d/usr/bin/pairdesk-agent"
  install -Dm644 "$HERE/$ID.desktop" "$d/usr/share/applications/$ID.desktop"
  install -Dm644 "$HERE/$ID.metainfo.xml" "$d/usr/share/metainfo/$ID.metainfo.xml"
  for s in 16 24 32 48 64 128 256 512; do
    install -Dm644 "$ROOT/packaging/icons/hicolor/${s}x${s}/apps/$ID.png" \
      "$d/usr/share/icons/hicolor/${s}x${s}/apps/$ID.png"
  done
  install -Dm644 "$ROOT/packaging/icons/pairdesk.svg" "$d/usr/share/icons/hicolor/scalable/apps/$ID.svg"
  install -Dm644 "$ROOT/LICENSE" "$d/usr/share/licenses/pairdesk/LICENSE"
}

# --- .deb
D=$WORK/deb
stage "$D"
mkdir -p "$D/DEBIAN" "$D/usr/share/doc/pairdesk"
cat >"$D/usr/share/doc/pairdesk/copyright" <<C
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: PairDesk
Source: https://github.com/sandunMadhushan/pairdesk

Files: *
Copyright: Sandun Madhushan
License: GPL-3.0-or-later
 On Debian systems the full text is in /usr/share/common-licenses/GPL-3.
C
SIZE=$(du -sk "$D/usr" | cut -f1)
cat >"$D/DEBIAN/control" <<C
Package: pairdesk
Version: $VERSION
Architecture: amd64
Maintainer: Sandun Madhushan <contact@madhushan.me>
Installed-Size: $SIZE
Depends: libc6 (>= 2.31)
Recommends: xdg-desktop-portal, libpipewire-0.3-0
Suggests: xclip
Section: net
Priority: optional
Homepage: https://pairdesk.madhushan.me
Description: Control this computer from your phone
 PairDesk turns your Android phone into a touchpad, keyboard and screen
 viewer for this computer. Pair once by scanning a code; the phone then
 connects by itself on the same Wi-Fi or from anywhere with Tailscale.
 Connections are encrypted and only paired phones can connect.
C
# Refresh menus and icons after (un)installing.
for s in postinst postrm; do
  cat >"$D/DEBIAN/$s" <<'C'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
C
  chmod 755 "$D/DEBIAN/$s"
done
dpkg-deb --root-owner-group -Zxz --build "$D" "$OUT/pairdesk_${VERSION}_amd64.deb" >/dev/null

# --- .rpm
R=$WORK/rpm
mkdir -p "$R"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,root}
stage "$R/root"
cat >"$R/SPECS/pairdesk.spec" <<C
Name: pairdesk
Version: ${VERSION//-/~}
Release: 1
Summary: Control this computer from your phone
License: GPL-3.0-or-later
URL: https://pairdesk.madhushan.me
BuildArch: x86_64
Requires: glibc >= 2.31
Recommends: xdg-desktop-portal, pipewire-libs
AutoReqProv: no

%description
PairDesk turns your Android phone into a touchpad, keyboard and screen
viewer for this computer. Pair once by scanning a code; the phone then
connects by itself on the same Wi-Fi or from anywhere with Tailscale.

%install
cp -a $R/root/. %{buildroot}/

%files
%license /usr/share/licenses/pairdesk/LICENSE
/usr/bin/pairdesk-agent
/usr/share/applications/$ID.desktop
/usr/share/metainfo/$ID.metainfo.xml
/usr/share/icons/hicolor/*/apps/$ID.*
C
rpmbuild --quiet --define "_topdir $R" --define "_build_id_links none" -bb "$R/SPECS/pairdesk.spec"
cp "$R"/RPMS/x86_64/pairdesk-*.rpm "$OUT/"

# --- AppImage
A=$WORK/PairDesk.AppDir
stage "$A"
ln -s usr/bin/pairdesk-agent "$A/AppRun"
cp "$HERE/$ID.desktop" "$A/$ID.desktop"
cp "$ROOT/packaging/icons/hicolor/256x256/apps/$ID.png" "$A/$ID.png"
ln -s "$ID.png" "$A/.DirIcon"
TOOL=${APPIMAGETOOL:-}
if [ -z "$TOOL" ]; then
  TOOL=$WORK/appimagetool
  curl -sSfL -o "$TOOL" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOL"
fi
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$TOOL" --no-appstream "$A" "$OUT/PairDesk-$VERSION-x86_64.AppImage" >"$WORK/appimagetool.log" 2>&1 ||
  { cat "$WORK/appimagetool.log"; exit 1; }

ls -la "$OUT"
