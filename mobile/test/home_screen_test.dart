// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/app_model.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/laptop.dart';
import 'package:pairdesk/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppModel> model(List<Laptop> laptops) async => AppModel(
  identity: await PhoneIdentity.fromSeed(List.filled(32, 1)),
  store: LaptopStore(),
  laptops: laptops,
  phoneName: 'Test phone',
  connection: AgentConnection(),
)..autoConnectDone = true;

Widget app(AppModel m) => MaterialApp(home: HomeScreen(model: m));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first launch explains pairing', (tester) async {
    final m = await tester.runAsync(() => model([]));
    await tester.pumpWidget(app(m!));
    expect(find.text('Pair your computer'), findsOneWidget);
    expect(find.text('Scan pairing code'), findsOneWidget);
  });

  testWidgets('lists paired computers and can remove one', (tester) async {
    final laptop = Laptop(
      fingerprint: Uint8List(32),
      name: 'Sandun-PC',
      port: 47800,
      addresses: ['192.168.1.5'],
      os: 'windows',
    );
    final m = await tester.runAsync(() => model([laptop]));
    await tester.pumpWidget(app(m!));
    expect(find.text('Sandun-PC'), findsOneWidget);
    expect(find.text('Windows · tap to connect'), findsOneWidget);
    laptop.addresses = ['192.168.1.5', '100.101.102.103'];
    await tester.pumpWidget(app(m));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(m));
    expect(find.text('Windows · here or away'), findsOneWidget);
    expect(find.text('Scan pairing code'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Sandun-PC?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Sandun-PC'), findsNothing);
    expect(find.text('Pair your computer'), findsOneWidget);
  });
}
