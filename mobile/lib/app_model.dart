// SPDX-License-Identifier: GPL-3.0-or-later
// App-wide state: this phone's identity, the paired computers and the
// connection.

import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'agent_connection.dart';
import 'pairing/discovery.dart';
import 'pairing/identity.dart';
import 'pairing/laptop.dart';
import 'pairing/pairing_link.dart';
import 'settings/app_settings.dart';

class AppModel extends ChangeNotifier {
  AppModel({
    required this.identity,
    required this.store,
    required List<Laptop> laptops,
    required this.phoneName,
    required this.connection,
    this.settings,
  }) : _laptops = List.of(laptops) {
    _sort();
  }

  static Future<AppModel> load() async {
    final store = LaptopStore();
    final results = await Future.wait([
      PhoneIdentity.loadOrCreate(SecureKeyVault()),
      store.load(),
      _deviceName(),
      AppSettings.load(),
    ]);
    return AppModel(
      identity: results[0] as PhoneIdentity,
      store: store,
      laptops: results[1] as List<Laptop>,
      phoneName: results[2] as String,
      connection: AgentConnection(finder: NsdLaptopFinder()),
      settings: results[3] as AppSettings,
    );
  }

  static Future<String> _deviceName() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        final maker = info.manufacturer.trim();
        final model = info.model.trim();
        if (model.toLowerCase().startsWith(maker.toLowerCase())) return model;
        final m = maker.isEmpty ? '' : '${maker[0].toUpperCase()}${maker.substring(1)} ';
        return '$m$model'.trim();
      }
    } catch (_) {}
    return 'Phone';
  }

  final PhoneIdentity identity;
  final LaptopStore store;
  final String phoneName;
  final AgentConnection connection;

  /// Phone preferences. Null only in tests.
  final AppSettings? settings;

  List<Laptop> _laptops;
  List<Laptop> get laptops => List.unmodifiable(_laptops);

  /// Auto-connect happens once per app start, not after every disconnect.
  bool autoConnectDone = false;

  void _sort() {
    _laptops.sort((a, b) => (b.lastUsed ?? b.pairedAt).compareTo(a.lastUsed ?? a.pairedAt));
  }

  Future<void> _save() async {
    _sort();
    notifyListeners();
    await store.save(_laptops);
  }

  /// Saves addresses the computer sent while connected (Tailscale coming
  /// up, a new Wi-Fi address, the relay starting), so the next connection
  /// from another network has a route to try.
  StreamSubscription<void>? _addressSub;

  void _watchAddresses() {
    _addressSub ??= connection.addressUpdates.listen((_) => _save());
  }

  /// Adds an address the owner typed in, e.g. the computer's Tailscale
  /// address copied from its PairDesk page. Returns false if it isn't one
  /// PairDesk can dial.
  Future<bool> addAddress(Laptop laptop, String address) async {
    final host = address.trim();
    if (host.isEmpty || !isTypedHost(host)) return false;
    laptop.rememberAddress(host);
    await _save();
    return true;
  }

  Future<void> connect(Laptop laptop) async {
    _watchAddresses();
    await connection.connect(laptop, identity, phoneName: phoneName);
    await _save();
  }

  Future<Laptop> pair(PairingInfo info) async {
    _watchAddresses();
    final laptop = await connection.pair(info, identity, phoneName: phoneName);
    _laptops = [laptop, ..._laptops.where((l) => l.key != laptop.key)];
    await _save();
    return laptop;
  }

  Future<void> forget(Laptop laptop) async {
    _laptops = _laptops.where((l) => l.key != laptop.key).toList();
    await _save();
  }

  Future<void> rename(Laptop laptop, String name) async {
    laptop.name = name;
    await _save();
  }
}
