// SPDX-License-Identifier: GPL-3.0-or-later
// Paired computers, saved on the phone. Nothing here is secret: the
// fingerprint only lets the phone recognise the computer.

import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'codec.dart';

/// Same test as the connection uses (100.64.0.0/10 or *.ts.net).
bool isTailscaleAddress(String host) {
  if (host.toLowerCase().endsWith('.ts.net')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]), b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

class Laptop {
  Laptop({
    required this.fingerprint,
    required this.name,
    required this.port,
    required this.addresses,
    this.os,
    int? pairedAt,
    this.lastUsed,
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
    addresses = merged.take(maxAddresses).toList();
  }

  /// True when the phone knows a Tailscale route to this computer.
  bool get reachableAnywhere => addresses.any(isTailscaleAddress);

  Map<String, Object?> toJson() => {
    'fp': key,
    'name': name,
    'port': port,
    'addresses': addresses,
    'os': os,
    'pairedAt': pairedAt,
    'lastUsed': lastUsed,
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
