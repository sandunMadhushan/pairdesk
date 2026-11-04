// SPDX-License-Identifier: GPL-3.0-or-later
// Which hosts the phone will dial: IPv4 addresses, Tailscale MagicDNS
// names and relay routes. Shared by the pairing link and the connection
// so a link and a Welcome message accept exactly the same things.

import 'dart:io';

import 'relay_route.dart';

final _magicDns = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$', caseSensitive: false);

/// Tailscale addresses (100.64.0.0/10) and MagicDNS names (*.ts.net).
bool isTailscaleAddress(String host) {
  if (host.toLowerCase().endsWith('.ts.net')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]), b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

/// IPv4 addresses, Tailscale names and relay routes; anything else from
/// the computer is ignored.
bool isUsableHost(String host) {
  if (RelayRoute.looksLike(host)) return RelayRoute.tryParse(host) != null;
  final ip = InternetAddress.tryParse(host);
  if (ip != null) return ip.type == InternetAddressType.IPv4 && !ip.isLoopback;
  return _magicDns.hasMatch(host) && host.length < 254;
}
