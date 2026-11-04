// SPDX-License-Identifier: GPL-3.0-or-later
// Paired computers, saved on the phone. Nothing here is secret: the
// fingerprint only lets the phone recognise the computer.

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'codec.dart';
import 'host.dart';

export 'host.dart' show isTailscaleAddress, isTypedHost, isUsableHost, splitHostPort;

class Laptop {
  Laptop({
    required this.fingerprint,
    required this.name,
    required this.port,
    required this.addresses,
    this.os,
    int? pairedAt,
    this.lastUsed,
    this.helping = false,
  }) : pairedAt = pairedAt ?? DateTime.now().millisecondsSinceEpoch;

  /// SHA-256 of the computer's certificate. Identifies the computer.
  final Uint8List fingerprint;
  String name;
  int port;

  /// Addresses that worked before, best first.
  List<String> addresses;
  String? os;
  final int pairedAt;
  int? lastUsed;

  /// Paired through a "Get help" link: temporary access to someone
  /// else's computer.
  final bool helping;

  /// Matches the `id` the computer announces on the network.
  String get shortId => hex(fingerprint.sublist(0, 8));

  String get key => b64Encode(fingerprint);

  static const maxAddresses = 8;

  /// Puts [address] first, keeping at most [maxAddresses].
  void rememberAddress(String address) {
    addresses = [address, ...addresses.where((a) => a != address)].take(maxAddresses).toList();
  }

  /// After connecting: the address that worked first, then what the
  /// computer says it has now (e.g. a new Tailscale address), then older ones.
  void learnAddresses({required String working, List<String> fromComputer = const []}) {
    final merged = <String>[];
    for (final a in [working, ...fromComputer, ...addresses]) {
      if (!merged.contains(a)) merged.add(a);
    }
    // Direct routes first; the computer's current relay route always kept
    // (it's what works from anywhere).
    final relay = [
      ...fromComputer.where((a) => a.startsWith('relay:')),
      ...merged.where((a) => a.startsWith('relay:')),
    ].firstOrNull;
    final direct = merged.where((a) => !a.startsWith('relay:')).take(maxAddresses - (relay == null ? 0 : 1));
    addresses = [...direct, ?relay];
  }

  /// True when the phone knows a route from anywhere: Tailscale or a relay.
  bool get reachableAnywhere => addresses.any((a) => isTailscaleAddress(a) || a.startsWith('relay:'));

  Map<String, Object?> toJson() => {
    'fp': key,
    'name': name,
    'port': port,
    'addresses': addresses,
    'os': os,
    'pairedAt': pairedAt,
    'lastUsed': lastUsed,
    if (helping) 'helping': true,
  };

  static Laptop? fromJson(Object? json) {
    if (json is! Map) return null;
    final fp = b64Decode(json['fp'] as String? ?? '');
    final port = json['port'];
    if (fp == null || fp.length != 32 || port is! int) return null;
    return Laptop(
      fingerprint: fp,
      name: json['name'] as String? ?? 'Computer',
      port: port,
      addresses: [
        for (final a in (json['addresses'] as List? ?? const []))
          if (a is String) a,
      ],
      os: json['os'] as String?,
      pairedAt: json['pairedAt'] as int?,
      lastUsed: json['lastUsed'] as int?,
      helping: json['helping'] == true,
    );
  }
}

class LaptopStore {
  static const _prefsKey = 'pairdesk.laptops.v1';

  Future<List<Laptop>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final j in list) ?Laptop.fromJson(j)];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<Laptop> laptops) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode([for (final l in laptops) l.toJson()]));
  }
}
