// SPDX-License-Identifier: GPL-3.0-or-later
// "A new version is available" for the APK from GitHub Releases.
//
// Only in builds made with --dart-define=PAIRDESK_UPDATES=github (the
// release workflow's APKs). F-Droid builds leave it off: F-Droid updates
// the app itself.
//
// The app reads the same signed latest.json as the computer, checks the
// Ed25519 signature against the project's key, and offers the APK for this
// phone's processor. Android installs it over the old one only if it is
// signed with the same key, so a download link is all the app needs.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const updatesFrom = String.fromEnvironment('PAIRDESK_UPDATES');
const manifestUrl = 'https://github.com/sandunMadhushan/pairdesk/releases/latest/download/latest.json';

/// The release workflow's public key (raw Ed25519, base64); the same as the
/// computer's (agent/src/update.rs).
const updatePublicKey = 'mPqsTySowXha+X+KMh49/y3HgcepbYP8QvYdpIGnwaU=';

class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.download,
    required this.notes,
    this.sha256 = '',
    this.size = 0,
  });
  final String version;

  /// The APK for this phone.
  final Uri download;

  /// The release page.
  final Uri notes;

  /// What the signed manifest says the APK should be, so a download that
  /// was changed on the way is thrown away instead of installed.
  final String sha256;
  final int size;
}

/// True when [a] is an older version than [b] ("0.7.0" < "0.10.0").
bool isOlderVersion(String a, String b) {
  List<int>? parts(String v) {
    final p = v.trim().split(RegExp(r'[.+-]')).take(3).map(int.tryParse).toList();
    return p.contains(null) || p.length < 3 ? null : p.cast<int>();
  }

  final x = parts(a), y = parts(b);
  if (x == null || y == null) return false;
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] < y[i];
  }
  return false;
}

/// The manifest's asset key for the best APK for these ABIs.
String? apkAssetFor(List<String> abis) {
  for (final abi in abis) {
    switch (abi) {
      case 'arm64-v8a':
        return 'android-arm64';
      case 'armeabi-v7a':
        return 'android-armv7';
      case 'x86_64':
        return 'android-x86_64';
    }
  }
  return null;
}

class UpdateChecker extends ChangeNotifier {
  UpdateChecker({
    required this.currentVersion,
    required this.abis,
    Future<List<int>> Function(Uri url)? fetch,
    this.publicKey = updatePublicKey,
    this.enabled = updatesFrom == 'github',
    this.every = const Duration(hours: 20),
  }) : _fetch = fetch ?? _httpGet;

  final String currentVersion;
  final List<String> abis;
  final String publicKey;
  final bool enabled;
  final Duration every;
  final Future<List<int>> Function(Uri url) _fetch;

  AvailableUpdate? _available;
  AvailableUpdate? get available => _available;

  static const _lastCheckKey = 'update.lastCheck';
  static const _dismissedKey = 'update.dismissed';
  static const _foundKey = 'update.found';

  /// Checks at most once per [every]; remembers what it found in between.
  Future<void> checkIfDue({DateTime? now}) async {
    if (!enabled) return;
    final prefs = await SharedPreferences.getInstance();
    now ??= DateTime.now();
    final last = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_lastCheckKey) ?? 0);
    if (now.difference(last) < every) {
      _set(_restore(prefs));
      return;
    }
    try {
      final found = await check();
      await prefs.setInt(_lastCheckKey, now.millisecondsSinceEpoch);
      if (found == null) {
        await prefs.remove(_foundKey);
      } else {
        await prefs.setString(
          _foundKey,
          jsonEncode({
            'v': found.version,
            'd': '${found.download}',
            'n': '${found.notes}',
            's': found.sha256,
            'z': found.size,
          }),
        );
      }
      _set(found != null && prefs.getString(_dismissedKey) != found.version ? found : null);
    } catch (e) {
      debugPrint('update check failed: $e');
    }
  }

  /// "Check for updates" in Settings: asks now, whatever the timer and
  /// any earlier "Not now" said. Returns the update, or null when this is
  /// the newest. Throws if the check failed.
  Future<AvailableUpdate?> checkNow({DateTime? now}) async {
    final found = await check();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckKey, (now ?? DateTime.now()).millisecondsSinceEpoch);
    await prefs.remove(_dismissedKey);
    if (found == null) {
      await prefs.remove(_foundKey);
    } else {
      await prefs.setString(
        _foundKey,
        jsonEncode({
          'v': found.version,
          'd': '${found.download}',
          'n': '${found.notes}',
          's': found.sha256,
          'z': found.size,
        }),
      );
    }
    _set(found);
    return found;
  }

  AvailableUpdate? _restore(SharedPreferences prefs) {
    final raw = prefs.getString(_foundKey);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final u = AvailableUpdate(
        version: m['v'] as String,
        download: Uri.parse(m['d'] as String),
        notes: Uri.parse(m['n'] as String),
        sha256: m['s'] as String? ?? '',
        size: m['z'] as int? ?? 0,
      );
      if (!isOlderVersion(currentVersion, u.version)) return null;
      return prefs.getString(_dismissedKey) == u.version ? null : u;
    } catch (_) {
      return null;
    }
  }

  /// "Not now": hides this version's notice.
  Future<void> dismiss() async {
    final v = _available?.version;
    if (v == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedKey, v);
    _set(null);
  }

  void _set(AvailableUpdate? u) {
    if (u?.version == _available?.version) return;
    _available = u;
    notifyListeners();
  }

  /// Fetches and verifies the manifest. Null when this is the newest or
  /// there's no APK for this phone. Throws if the signature is wrong.
  Future<AvailableUpdate?> check() async {
    final url = Uri.parse(manifestUrl);
    final body = await _fetch(url);
    final sig = await _fetch(Uri.parse('$manifestUrl.sig'));
    final ok = await Ed25519().verify(
      body,
      signature: Signature(
        base64.decode(utf8.decode(sig).trim()),
        publicKey: SimplePublicKey(base64.decode(publicKey), type: KeyPairType.ed25519),
      ),
    );
    if (!ok) throw const FormatException('the update information is not signed by PairDesk');
    final m = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    final version = m['version'] as String;
    if (!isOlderVersion(currentVersion, version)) return null;
    final key = apkAssetFor(abis);
    final asset = (m['assets'] as Map<String, dynamic>)[key] as Map<String, dynamic>?;
    if (asset == null) return null;
    final download = Uri.parse(asset['url'] as String);
    if (download.scheme != 'https') return null;
    final notes = Uri.tryParse(m['notes_url'] as String? ?? '');
    return AvailableUpdate(
      version: version,
      download: download,
      sha256: asset['sha256'] as String? ?? '',
      size: asset['size'] as int? ?? 0,
      notes: notes != null && notes.scheme == 'https'
          ? notes
          : Uri.parse('https://github.com/sandunMadhushan/pairdesk/releases/latest'),
    );
  }

  static Future<List<int>> _httpGet(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: url);
      final out = BytesBuilder(copy: false);
      await for (final chunk in res) {
        out.add(chunk);
        if (out.length > 64 * 1024) throw const HttpException('too large');
      }
      return out.takeBytes();
    } finally {
      client.close();
    }
  }
}
