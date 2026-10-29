// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SimpleKeyPair key;
  late String publicKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    key = await Ed25519().newKeyPairFromSeed(List.filled(32, 7));
    publicKey = base64.encode((await key.extractPublicKey()).bytes);
  });

  Map<String, Object> manifest(String version) => {
    'version': version,
    'notes_url': 'https://github.com/sandunMadhushan/pairdesk/releases/tag/v$version',
    'assets': {
      'android-arm64': {'url': 'https://example.com/pairdesk-$version-arm64.apk', 'sha256': '00', 'size': 1},
      'android-armv7': {'url': 'https://example.com/pairdesk-$version-armv7.apk', 'sha256': '00', 'size': 1},
    },
  };

  /// A fake GitHub serving [body], signed with [signWith] (default: [body]).
  Future<List<int>> Function(Uri) github(Map<String, Object> m, {List<int>? signWith, List<Uri>? calls}) {
    final body = utf8.encode(jsonEncode(m));
    return (url) async {
      calls?.add(url);
      if (url.path.endsWith('.sig')) {
        final sig = await Ed25519().sign(signWith ?? body, keyPair: key);
        return utf8.encode('${base64.encode(sig.bytes)}\n');
      }
      return body;
    };
  }

  UpdateChecker checker(Future<List<int>> Function(Uri) fetch, {List<String> abis = const ['arm64-v8a']}) =>
      UpdateChecker(currentVersion: '0.8.0', abis: abis, fetch: fetch, publicKey: publicKey, enabled: true);

  test('accepts what the release workflow signs (openssl pkeyutl -rawin)', () async {
    // The same fixture as agent/src/update.rs: key [7; 32], message "release".
    const sig = '8LdA3PEtQ7ECUHn4blJ5spQzf4BcFaokESZOPU4KAFnAlZzoEPF/T/kMQKVIn0sUJFoP/irgcRA8MNeZ0MpYDw==';
    final ok = await Ed25519().verify(
      utf8.encode('release'),
      signature: Signature(
        base64.decode(sig),
        publicKey: SimplePublicKey(base64.decode(publicKey), type: KeyPairType.ed25519),
      ),
    );
    expect(ok, isTrue);
    expect(base64.decode(updatePublicKey), hasLength(32));
  });

  test('compares versions as numbers', () {
    expect(isOlderVersion('0.8.0', '0.9.0'), isTrue);
    expect(isOlderVersion('0.9.0', '0.10.0'), isTrue);
    expect(isOlderVersion('0.8.0', '0.8.0'), isFalse);
    expect(isOlderVersion('1.0.0', '0.9.9'), isFalse);
    expect(isOlderVersion('0.8.0+9', '0.8.1'), isTrue);
    expect(isOlderVersion('garbage', '0.9.0'), isFalse);
  });

  test('picks the APK for the phone\'s processor', () {
    expect(apkAssetFor(['arm64-v8a', 'armeabi-v7a']), 'android-arm64');
    expect(apkAssetFor(['armeabi-v7a', 'armeabi']), 'android-armv7');
    expect(apkAssetFor(['x86']), isNull);
  });

  test('finds a signed newer release', () async {
    final u = await checker(github(manifest('0.9.0'))).check();
    expect(u!.version, '0.9.0');
    expect(u.download.toString(), 'https://example.com/pairdesk-0.9.0-arm64.apk');
    expect(u.notes.path, endsWith('/v0.9.0'));
    final armv7 = await checker(github(manifest('0.9.0')), abis: ['armeabi-v7a']).check();
    expect(armv7!.download.path, endsWith('armv7.apk'));
  });

  test('ignores older releases and refuses forged ones', () async {
    expect(await checker(github(manifest('0.8.0'))).check(), isNull);
    expect(await checker(github(manifest('0.9.0')), abis: ['x86']).check(), isNull);
    await expectLater(
      checker(github(manifest('0.9.0'), signWith: utf8.encode('something else'))).check(),
      throwsA(isA<FormatException>()),
    );
  });

  test('checks at most once a day, remembers the result and "Not now"', () async {
    final calls = <Uri>[];
    final c = checker(github(manifest('0.9.0'), calls: calls));
    final t0 = DateTime(2026, 10, 29, 9);
    await c.checkIfDue(now: t0);
    expect(c.available?.version, '0.9.0');
    expect(calls, hasLength(2));

    // A new start an hour later: no network, same notice.
    final again = checker(github(manifest('0.9.0'), calls: calls));
    await again.checkIfDue(now: t0.add(const Duration(hours: 1)));
    expect(again.available?.version, '0.9.0');
    expect(calls, hasLength(2));

    await again.dismiss();
    expect(again.available, isNull);
    final later = checker(github(manifest('0.9.0'), calls: calls));
    await later.checkIfDue(now: t0.add(const Duration(days: 1)));
    expect(later.available, isNull, reason: 'dismissed for 0.9.0');
    expect(calls, hasLength(4));

    final newer = checker(github(manifest('0.10.0'), calls: calls));
    await newer.checkIfDue(now: t0.add(const Duration(days: 2)));
    expect(newer.available?.version, '0.10.0', reason: 'a newer release shows again');
  });

  test('off unless built for GitHub releases', () async {
    var called = false;
    final c = UpdateChecker(
      currentVersion: '0.8.0',
      abis: const ['arm64-v8a'],
      fetch: (_) async {
        called = true;
        return [];
      },
    );
    await c.checkIfDue();
    expect(called, isFalse);
  });
}
