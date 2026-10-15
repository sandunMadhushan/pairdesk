// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/buttons/custom_button.dart';
import 'package:pairdesk/screens/button_editor.dart';
import 'package:pairdesk/screens/remote_help_screen.dart';
import 'package:pairdesk/screens/settings_screen.dart';
import 'package:pairdesk/screens/tabs/apps_tab.dart';
import 'package:pairdesk/screens/tabs/buttons_tab.dart';
import 'package:pairdesk/screens/tabs/power_tab.dart';
import 'package:pairdesk/settings/app_lock.dart';
import 'package:pairdesk/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the screens ask the computer to do.
class FakeConnection extends AgentConnection {
  FakeConnection({this.allow = const Allowed(power: true, session: true, apps: true)});
  final Allowed allow;
  final calls = <String>[];

  @override
  Set<String> get features => {'combo', 'power', 'apps'};
  @override
  Allowed get allowed => allow;
  @override
  String? get agentOs => 'windows';
  @override
  String? get agentName => 'Test-PC';

  @override
  void combo(List<Modifier> mods, {AgentKey? key, String? char}) =>
      calls.add('combo ${mods.map((m) => m.name).join('+')} ${key?.wire ?? char}');
  @override
  void typeText(String s) => calls.add('text $s');
  @override
  Future<void> power(PowerAction action) async => calls.add('power ${action.wire}');
  @override
  Future<AppsList> fetchApps() async => const AppsList(
    shortcuts: [RemoteApp(id: 's1', name: 'Class notes', kind: 'folder')],
    apps: [
      RemoteApp(id: 'a1', name: 'Calculator', kind: 'app'),
      RemoteApp(id: 'a2', name: 'Firefox', kind: 'app'),
    ],
  );
  @override
  Future<void> launch(String appId) async {
    if (appId == 'a2') throw RequestException('failed', 'Firefox failed to start');
    calls.add('launch $appId');
  }
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Runs widget tests at a typical phone size (1080×2340, 3× density).
void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('power tab', () {
    testWidgets('greys out what the owner turned off', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection(allow: const Allowed(power: true, session: false, apps: true));
      await tester.pumpWidget(host(PowerTab(connection: conn)));
      await tester.tap(find.text('Shut down'));
      await tester.pumpAndSettle();
      expect(conn.calls, isEmpty);
      expect(find.textContaining('turned off in PairDesk settings'), findsOneWidget);
      await tester.tap(find.text('Lock'));
      await tester.pumpAndSettle();
      expect(conn.calls, ['power lock']);
    });

    testWidgets('asks before shutting down', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection();
      await tester.pumpWidget(host(PowerTab(connection: conn)));
      await tester.tap(find.text('Shut down'));
      await tester.pumpAndSettle();
      expect(find.text('Shut down Test-PC?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(conn.calls, isEmpty);

      await tester.tap(find.text('Restart'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restart'));
      await tester.pumpAndSettle();
      expect(conn.calls, ['power restart']);
    });
  });

  group('buttons tab', () {
    testWidgets('default buttons send shortcuts; buttons can be removed', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection();
      await tester.pumpWidget(host(ButtonsTab(connection: conn)));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl + C'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.tap(find.text('Switch app'));
      await tester.pump();
      expect(conn.calls, ['combo ctrl c', 'combo alt tab']);

      await tester.longPress(find.text('Copy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsNothing);
      final saved = await tester.runAsync(() => ButtonStore().load());
      expect(saved!.map((b) => b.label), isNot(contains('Copy')));
    });

    testWidgets('editor builds a text button with an automatic label', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection();
      CustomButton? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await Navigator.of(context)
                      .push<CustomButton>(MaterialPageRoute(builder: (_) => ButtonEditor(connection: conn))),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Saving with nothing chosen explains what's missing.
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Choose a key or at least one modifier.'), findsOneWidget);

      await tester.tap(find.text('Text'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Text to type'), 'hello@example.com');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result!.label, 'hello@example.co…');
      expect((result!.action as TextAction).text, 'hello@example.com');
    });

    testWidgets('editor builds a modifier-only shortcut', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection();
      await tester.pumpWidget(MaterialApp(home: ButtonEditor(connection: conn)));
      await tester.tap(find.widgetWithText(FilterChip, 'Win'));
      await tester.pumpAndSettle();
      expect(find.text('Sends Win'), findsOneWidget);
    });
  });

  group('apps tab', () {
    testWidgets('searches, launches and keeps favourites', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection();
      await tester.pumpWidget(host(AppsTab(connection: conn, laptopKey: 'pc1')));
      await tester.pumpAndSettle();
      expect(find.text('Shortcuts'), findsOneWidget);
      expect(find.text('All apps'), findsOneWidget);
      expect(find.text('Class notes'), findsOneWidget);

      await tester.enterText(find.byType(SearchBar), 'calc');
      await tester.pumpAndSettle();
      expect(find.text('Firefox'), findsNothing);
      await tester.tap(find.text('Calculator'));
      await tester.pumpAndSettle();
      expect(conn.calls, ['launch a1']);
      expect(find.text('Opening Calculator'), findsOneWidget);

      await tester.tap(find.byTooltip('Add to favourites'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(SearchBar), '');
      await tester.pumpAndSettle();
      expect(find.text('Favourites'), findsOneWidget);
      expect(await tester.runAsync(() => FavouriteStore().load('pc1')), ['a1']);
    });

    testWidgets('shows why a launch failed', (tester) async {
      phoneSize(tester);
      final conn = FakeConnection();
      await tester.pumpWidget(host(AppsTab(connection: conn, laptopKey: 'pc1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Firefox'));
      await tester.pumpAndSettle();
      expect(find.text('Firefox failed to start'), findsOneWidget);
    });
  });

  group('app lock', () {
    testWidgets('covers the app until unlocked', (tester) async {
      phoneSize(tester);
      final settings = (await tester.runAsync(AppSettings.load))!;
      await tester.runAsync(() => settings.setAppLock(true));
      var asked = 0;
      var allow = false;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppLockGate(
            settings: settings,
            authenticate: (_) async {
              asked++;
              return allow;
            },
            child: child!,
          ),
          home: const Scaffold(body: Text('secret controls')),
        ),
      );
      await tester.pumpAndSettle();
      expect(asked, 1, reason: 'asks straight away on open');
      expect(find.text('PairDesk is locked'), findsOneWidget);

      allow = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('PairDesk is locked'), findsNothing);
      expect(find.text('secret controls'), findsOneWidget);

      // Background, then back after the delay: locked again.
      await tester.runAsync(() => settings.setLockAfter(LockAfter.immediately));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(asked, 3);
      expect(find.text('PairDesk is locked'), findsNothing, reason: 'the fake unlock said yes');
    });

    testWidgets('settings turn the lock on only after a successful check', (tester) async {
      phoneSize(tester);
      final settings = (await tester.runAsync(AppSettings.load))!;
      var ok = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            settings: settings,
            authenticate: (_) async => ok,
            canAuthenticate: () async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('App lock'));
      await tester.pumpAndSettle();
      expect(settings.appLock, isFalse);
      ok = true;
      await tester.tap(find.text('App lock'));
      await tester.pumpAndSettle();
      expect(settings.appLock, isTrue);
      expect(find.text('Lock again'), findsOneWidget);
    });

    testWidgets('explains when the phone has no screen lock', (tester) async {
      phoneSize(tester);
      final settings = (await tester.runAsync(AppSettings.load))!;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            settings: settings,
            authenticate: (_) async => true,
            canAuthenticate: () async => false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('App lock'));
      await tester.pumpAndSettle();
      expect(find.text('Set a screen lock first'), findsOneWidget);
      expect(settings.appLock, isFalse);
    });
  });

  testWidgets('connect-from-anywhere guide fits a phone screen', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(const MaterialApp(home: RemoteHelpScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Connect from anywhere'), findsOneWidget);
    expect(find.text('Google Play'), findsOneWidget);
    expect(find.text('F-Droid'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Keep this computer awake'), 200);
    expect(tester.takeException(), isNull);
  });
}
