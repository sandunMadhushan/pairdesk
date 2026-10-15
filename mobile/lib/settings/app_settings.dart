// SPDX-License-Identifier: GPL-3.0-or-later
// Phone-side preferences: app lock, pointer speed, scroll direction.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long the app may stay in the background before it locks again.
enum LockAfter {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes');

  const LockAfter(this.duration, this.label);
  final Duration duration;
  final String label;
}

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const _kLock = 'pairdesk.settings.appLock';
  static const _kLockAfter = 'pairdesk.settings.lockAfter';
  static const _kSpeed = 'pairdesk.settings.pointerSpeed';
  static const _kNatural = 'pairdesk.settings.naturalScroll';
  static const _kScreenTouchpad = 'pairdesk.settings.screenTouchpad';

  static const minSpeed = 0.5;
  static const maxSpeed = 2.5;

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async => AppSettings._(await SharedPreferences.getInstance());

  bool get appLock => _prefs.getBool(_kLock) ?? false;
  Future<void> setAppLock(bool on) async {
    await _prefs.setBool(_kLock, on);
    notifyListeners();
  }

  LockAfter get lockAfter {
    final name = _prefs.getString(_kLockAfter);
    return LockAfter.values.firstWhere((v) => v.name == name, orElse: () => LockAfter.oneMinute);
  }

  Future<void> setLockAfter(LockAfter v) async {
    await _prefs.setString(_kLockAfter, v.name);
    notifyListeners();
  }

  /// Multiplies the touchpad's cursor speed. 1.0 is the default.
  double get pointerSpeed => (_prefs.getDouble(_kSpeed) ?? 1.0).clamp(minSpeed, maxSpeed);
  Future<void> setPointerSpeed(double v) async {
    await _prefs.setDouble(_kSpeed, v.clamp(minSpeed, maxSpeed));
    notifyListeners();
  }

  /// True: content follows the fingers (like a phone or a Mac trackpad).
  bool get naturalScroll => _prefs.getBool(_kNatural) ?? true;
  Future<void> setNaturalScroll(bool on) async {
    await _prefs.setBool(_kNatural, on);
    notifyListeners();
  }

  /// Screen view: true moves the pointer like a touchpad, false puts it
  /// where you tap.
  bool get screenTouchpad => _prefs.getBool(_kScreenTouchpad) ?? true;
  Future<void> setScreenTouchpad(bool on) async {
    await _prefs.setBool(_kScreenTouchpad, on);
    notifyListeners();
  }
}

/// Whether the app should ask to unlock when it comes back to the front.
/// Pure logic, unit-tested.
bool shouldLock({
  required bool enabled,
  required LockAfter after,
  required DateTime? backgroundedAt,
  required DateTime now,
}) {
  if (!enabled) return false;
  if (backgroundedAt == null) return false;
  return now.difference(backgroundedAt) >= after.duration;
}
