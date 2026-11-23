// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/screens/settings_screen.dart';
import 'package:pairdesk/settings/app_settings.dart';
import 'package:pairdesk/update_check.dart';
import 'package:pairdesk/update_install.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Check for updates offers the update right in Settings', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final key = await tester.runAsync(() => Ed25519().newKeyPairFromSeed(List.filled(32, 7)));
    final publicKey = base64.encode((await tester.runAsync(key!.extractPublicKey))!.bytes);
    final body = utf8.encode(
      jsonEncode({
        'version': '0.9.0',
        'assets': {
          'android-arm64': {'url': 'https://example.com/a.apk', 'sha256': '00', 'size': 1},
        },
      }),
    );
    final updates = UpdateChecker(
      currentVersion: '0.8.0',
      abis: const ['arm64-v8a'],
      publicKey: publicKey,
      enabled: true,
      fetch: (url) async => url.path.endsWith('.sig')
          ? utf8.encode(base64.encode((await Ed25519().sign(body, keyPair: key)).bytes))
          : body,
    );
    final settings = (await tester.runAsync(AppSettings.load))!;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(settings: settings, updates: updates, installer: UpdateInstaller()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Version 0.9.0 is ready'), findsNothing);

    await tester.scrollUntilVisible(find.text('Check for updates'), 300);
    await tester.tap(find.text('Check for updates'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    expect(find.text('PairDesk 0.9.0 is available.'), findsOneWidget);
    expect(find.text('Version 0.9.0 is ready'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(find.textContaining('Home screen'), findsNothing);
  });

  testWidgets('no Support row in builds that are not from GitHub', (tester) async {
    final settings = (await tester.runAsync(AppSettings.load))!;
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(settings: settings)));
    await tester.pumpAndSettle();
    expect(find.text('Support PairDesk'), findsNothing);
  });
}
