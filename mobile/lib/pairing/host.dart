// SPDX-License-Identifier: GPL-3.0-or-later
// Which hosts the phone will dial: IPv4 addresses, names (Tailscale's
// MagicDNS, or a name of your own pointing at your home connection) and
// relay routes. Shared by the pairing link and the connection so a link
// and a Welcome message accept exactly the same things.
//
// An address may carry its own port, "home.example.org:47800", for a
// router that forwards a different port than the one the computer
// listens on. Without one the computer's own port is used.
//
// Letting a name through is safe: the phone checks the computer's
// certificate against the fingerprint it stored when pairing, so an
// address that points somewhere else simply fails to connect.

import 'dart:io';

import 'relay_route.dart';

final _name = RegExp(r'^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$', caseSensitive: false);

/// Tailscale addresses (100.64.0.0/10) and MagicDNS names (*.ts.net).
bool isTailscaleAddress(String host) {
  final name = splitHostPort(host).host;
  if (name.toLowerCase().endsWith('.ts.net')) return true;
  final parts = name.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]), b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

/// Splits "host" or "host:port" (IPv6 as "[addr]" or "[addr]:port"; the
/// host comes back without brackets). The port is null when there isn't
/// one, and when what follows the colon isn't a port number.
({String host, int? port}) splitHostPort(String value) {
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close > 1) {
      final host = value.substring(1, close);
      final rest = value.substring(close + 1);
      if (rest.isEmpty) return (host: host, port: null);
      final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
      if (port != null && port >= 1 && port <= 65535) return (host: host, port: port);
    }
    return (host: value, port: null);
  }
  final at = value.lastIndexOf(':');
  if (at <= 0 || at == value.length - 1) return (host: value, port: null);
  final port = int.tryParse(value.substring(at + 1));
  if (port == null || port < 1 || port > 65535) return (host: value, port: null);
  return (host: value.substring(0, at), port: port);
}

/// Addresses the phone accepts **from a computer or a pairing link**:
/// IPv4 addresses, global IPv6 addresses (in brackets), Tailscale MagicDNS
/// names and relay routes, each with an optional port. Deliberately narrow — a link can come from someone
/// else, and there is no reason for a computer to name anything else.
bool isUsableHost(String value) {
  if (RelayRoute.looksLike(value)) return RelayRoute.tryParse(value) != null;
  final (host: host, port: _) = splitHostPort(value);
  final ip = InternetAddress.tryParse(host);
  if (ip != null && ip.type == InternetAddressType.IPv6) return value.startsWith('[') && isGlobalIPv6(ip);
  if (ip != null) return ip.type == InternetAddressType.IPv4 && !ip.isLoopback;
  return host.toLowerCase().endsWith('.ts.net') && _isName(host);
}

/// Addresses the **owner types in** ("Add an address"). Any full name is
/// allowed here, so a name of your own pointing at your home connection
/// works without Tailscale or the relay, with the router forwarding the
/// port. The person typing it is the one trusting it, and the phone still
/// checks the computer's certificate, so a name that points elsewhere
/// just fails to connect.
bool isTypedHost(String value) {
  if (isUsableHost(value)) return true;
  if (RelayRoute.looksLike(value)) return false;
  final (host: host, port: _) = splitHostPort(value);
  // An IP address was already judged above: 127.0.0.1 looks like a name to
  // the pattern below, so decide it here and don't fall through.
  if (InternetAddress.tryParse(host) != null) return false;
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower.endsWith('.localhost')) return false;
  return _isName(host);
}

/// 2000::/3 (the internet), minus the documentation range.
bool isGlobalIPv6(InternetAddress ip) {
  final b = ip.rawAddress;
  return b.length == 16 &&
      (b[0] & 0xe0) == 0x20 &&
      !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8);
}

bool _isName(String host) => host.length <= 253 && _name.hasMatch(host);
