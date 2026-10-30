#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs the PairDesk relay on a Linux server (x64 or arm64) as a
# systemd service listening on ports 443 and 47900. Run as root:
#   curl -fsSL https://raw.githubusercontent.com/sandunMadhushan/pairdesk/main/packaging/relay/install.sh | sh
# See docs/RELAY.md.
set -eu
repo=sandunMadhushan/pairdesk
case "$(uname -m)" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported processor: $(uname -m)" >&2; exit 1 ;;
esac
[ "$(id -u)" = 0 ] || { echo "run as root (sudo sh)" >&2; exit 1; }
url="https://github.com/$repo/releases/latest/download/pairdesk-relay-linux-$arch"
echo "Downloading $url"
tmp=$(mktemp)
curl -fsSL -o "$tmp" "$url"
install -m 0755 "$tmp" /usr/local/bin/pairdesk-relay
rm -f "$tmp"
curl -fsSL -o /etc/systemd/system/pairdesk-relay.service \
  "https://raw.githubusercontent.com/$repo/main/packaging/relay/pairdesk-relay.service"
systemctl daemon-reload
systemctl enable --now pairdesk-relay
systemctl restart pairdesk-relay
sleep 1
systemctl --no-pager status pairdesk-relay | head -5
echo
echo "Done. Open TCP ports 443 and 47900 in the server's firewall (and the cloud"
echo "provider's security list), then point your relay's DNS name at this server."
