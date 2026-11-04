// SPDX-License-Identifier: GPL-3.0-or-later
// The `pairdesk://pair?...` link inside the QR code on the computer, and
// the same as `https://pairdesk.madhushan.me/p#...` to send in a message
// (the part after `#` never leaves the phone).

import 'dart:typed_data';

import 'codec.dart';
import 'host.dart';
import 'relay_route.dart';

/// Where shared links point.
const shareLinkHost = 'pairdesk.madhushan.me';

/// Protocol version this app speaks (see docs/PROTOCOL.md).
const int protocolVersion = 2;

class PairingInfo {
  PairingInfo({
    required this.name,
    required this.fingerprint,
    required this.token,
    required this.port,
    required this.addresses,
    this.help = false,
  });

  /// The computer's name.
  final String name;

  /// SHA-256 of the computer's certificate; pinned from now on.
  final Uint8List fingerprint;

  /// One-time pairing code.
  final String token;
  final int port;

  /// IPv4 addresses to try, best first, then the relay route if any.
  final List<String> addresses;

  /// A "Get help" link: someone asks you to help on their computer, with
  /// temporary access.
  final bool help;
}

/// Thrown when a scanned code isn't a usable PairDesk pairing link.
class PairingLinkException implements Exception {
  PairingLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

PairingInfo parsePairingLink(String text) {
  final Uri uri;
  try {
    uri = Uri.parse(text.trim());
  } on FormatException {
    throw PairingLinkException('This isn\'t a PairDesk code.');
  }
  final Map<String, String> q;
  if (uri.scheme == 'pairdesk' && uri.host == 'pair') {
    q = uri.queryParameters;
  } else if (uri.scheme == 'https' &&
      uri.host == shareLinkHost &&
      uri.path == '/p' &&
      uri.fragment.isNotEmpty) {
    try {
      q = Uri.splitQueryString(uri.fragment);
    } on ArgumentError {
      throw PairingLinkException('This PairDesk link is damaged.');
    }
  } else {
    throw PairingLinkException('This isn\'t a PairDesk code.');
  }

  final v = int.tryParse(q['v'] ?? '');
  if (v == null) throw PairingLinkException('This PairDesk code is incomplete.');
  if (v > protocolVersion) {
    throw PairingLinkException('The computer runs a newer PairDesk. Update this app first.');
  }
  if (v < protocolVersion) {
    throw PairingLinkException('The computer runs an older PairDesk. Update it on the computer first.');
  }

  final fp = b64Decode(q['fp'] ?? '');
  final token = q['t'] ?? '';
  final port = int.tryParse(q['p'] ?? '');
  if (fp == null || fp.length != 32 || token.length < 16 || port == null || port < 1 || port > 65535) {
    throw PairingLinkException('This PairDesk code is damaged. Show a new code on the computer.');
  }

  final addresses = (q['a'] ?? '').split(',').map((a) => a.trim()).where(isUsableHost).toList();
  if (q['r'] case final r? when r.isNotEmpty) {
    final route = RelayRoute.tryParse(r);
    if (route != null) addresses.add(route.toString());
  }

  var name = (q['n'] ?? '').replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (name.isEmpty) name = 'Computer';
  if (name.length > 64) name = name.substring(0, 64);

  return PairingInfo(
    name: name,
    fingerprint: fp,
    token: token,
    port: port,
    addresses: addresses,
    help: q['h'] == '1',
  );
}
