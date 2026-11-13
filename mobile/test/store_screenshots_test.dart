// SPDX-License-Identifier: GPL-3.0-or-later
// Store screenshots (F-Droid, the website), rendered from the real screens
// with real fonts. Skipped unless asked for:
//
//   PAIRDESK_SCREENSHOTS=../fastlane/metadata/android/en-US/images/phoneScreenshots \
//     flutter test test/store_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/app_model.dart';
import 'package:pairdesk/files/native_files.dart';
import 'package:pairdesk/files/share_inbox.dart';
import 'package:pairdesk/files/transfers.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/laptop.dart';
import 'package:pairdesk/screens/control_screen.dart';
import 'package:pairdesk/screens/home_screen.dart';
import 'package:pairdesk/screens/remote_help_screen.dart';
import 'package:pairdesk/screens/splash_screen.dart';
import 'package:pairdesk/settings/app_settings.dart';
import 'package:pairdesk/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

final outDir = Platform.environment['PAIRDESK_SCREENSHOTS'];

class ShowcaseConnection extends AgentConnection {
  ShowcaseConnection({required super.tempDir})
    : super(
        saveFile: (temp, name) async => SavedFile(where: 'Download/PairDesk/$name', uri: 'content://x'),
      );

  @override
  ConnectionStatus get status => ConnectionStatus.connected;
  @override
  Set<String> get features => {'combo', 'power', 'apps', 'screen', 'clipboard', 'files', 'audio'};
  @override
  Allowed get allowed => const Allowed(
    power: true,
    session: true,
    apps: true,
    screen: true,
    clipboard: true,
    files: true,
    audio: true,
    mic: true,
  );
  @override
  String? get agentOs => 'windows';
  @override
  String? get agentName => 'Sandun-Laptop';

  @override
  Future<AppsList> fetchApps() async => const AppsList(
    shortcuts: [
      RemoteApp(id: 's1', name: 'Lecture slides', kind: 'folder'),
      RemoteApp(id: 's2', name: 'University portal', kind: 'url'),
    ],
    apps: [
      RemoteApp(id: 'a1', name: 'Calculator', kind: 'app'),
      RemoteApp(id: 'a2', name: 'File Explorer', kind: 'app'),
      RemoteApp(id: 'a3', name: 'Firefox', kind: 'app'),
      RemoteApp(id: 'a4', name: 'LibreOffice Impress', kind: 'app'),
      RemoteApp(id: 'a5', name: 'Spotify', kind: 'app'),
      RemoteApp(id: 'a6', name: 'Visual Studio Code', kind: 'app'),
      RemoteApp(id: 'a7', name: 'VLC media player', kind: 'app'),
    ],
  );
}

Future<void> loadFonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String name) async => ByteData.sublistView(await File('$dir/$name').readAsBytes());
  Future<ByteData> asset(String name) async =>
      ByteData.sublistView(await File('assets/fonts/$name').readAsBytes());
  await (FontLoader('Urbanist')
        ..addFont(asset('Urbanist-Regular.ttf'))
        ..addFont(asset('Urbanist-Medium.ttf'))
        ..addFont(asset('Urbanist-SemiBold.ttf'))
        ..addFont(asset('Urbanist-Bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(f('MaterialIcons-Regular.otf'))).load();
  // Phones fall back to other fonts for symbols such as →; so does this.
  const dejavu = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
  if (File(dejavu).existsSync()) {
    await (FontLoader(
      'Fallback',
    )..addFont(File(dejavu).readAsBytes().then((b) => ByteData.sublistView(b)))).load();
  }
}

ThemeData theme(Brightness b) =>
    pdTheme(b).copyWith(textTheme: pdTheme(b).textTheme.apply(fontFamilyFallback: const ['Fallback']));

void main() {
  final shotKey = GlobalKey();
  late Directory tmp;

  setUpAll(() async {
    if (outDir != null) await loadFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('pairdesk-shots');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> phone(WidgetTester tester, Widget home, {Brightness b = Brightness.light}) async {
    // A touch screen: no keyboard focus rings; real shadows, not the test
    // framework's outlines.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(b),
          darkTheme: theme(Brightness.dark),
          themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    File('$outDir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!);
  }

  Widget control(AgentConnection c) => ControlScreen(
    connection: c,
    laptopKey: 'k',
    inbox: ShareInbox(take: () async => const SharedItems()),
  );

  Future<AppModel> model(WidgetTester tester, {bool empty = false}) async => (await tester.runAsync(
    () async => AppModel(
      identity: await PhoneIdentity.fromSeed(List.filled(32, 1)),
      store: LaptopStore(),
      laptops: empty
          ? []
          : [
              Laptop(
                fingerprint: Uint8List(32),
                name: 'Sandun-Laptop',
                port: 47800,
                addresses: ['192.168.1.5', 'relay:relay.pairdesk.madhushan.me:443/abcd'],
                os: 'windows',
              ),
              Laptop(
                fingerprint: Uint8List.fromList(List.filled(32, 2)),
                name: 'ubuntu-desktop',
                port: 47800,
                addresses: ['192.168.1.9'],
                os: 'linux',
              ),
            ],
      phoneName: 'Pixel 8',
      connection: AgentConnection(),
      settings: await AppSettings.load(),
    )..autoConnectDone = true,
  ))!;

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  for (final b in Brightness.values) {
    final dark = b == Brightness.dark;
    final p = dark ? 'dark_' : '';
    testWidgets('screenshots ${b.name}', skip: outDir == null, (tester) async {
      await phone(tester, const SplashScreen(), b: b);
      await shoot(tester, '${p}01_splash');

      if (!dark) {
        await phone(tester, HomeScreen(model: await model(tester, empty: true)), b: b);
        await shoot(tester, '${p}02_first_run');
      }

      final m = await model(tester);
      await phone(tester, HomeScreen(model: m), b: b);
      await shoot(tester, '${p}03_computers');

      await tester.tap(find.byTooltip('Add a computer'));
      await tester.pumpAndSettle();
      await shoot(tester, '${p}04_add_computer');
      await tester.tapAt(const Offset(20, 40));
      await tester.pumpAndSettle();

      await tab(tester, 'Settings');
      await shoot(tester, '${p}05_settings');

      final conn = ShowcaseConnection(tempDir: tmp);
      await phone(tester, control(conn), b: b);
      await shoot(tester, '${p}06_touchpad');

      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pumpAndSettle();
      await shoot(tester, '${p}07_typing');
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();

      await tab(tester, 'Shortcuts');
      await shoot(tester, '${p}08_shortcuts');
      if (!dark) {
        await tester.tap(find.text('Apps'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await shoot(tester, '${p}09_apps');
      }

      await tab(tester, 'Files');
      await shoot(tester, '${p}10_files');

      await tab(tester, 'Sound');
      await shoot(tester, '${p}11_sound');

      await tester.tap(find.byTooltip('Power'));
      await tester.pumpAndSettle();
      await shoot(tester, '${p}12_power');
      await tester.tapAt(const Offset(20, 40));
      await tester.pumpAndSettle();

      if (!dark) {
        await phone(tester, const RemoteHelpScreen(), b: b);
        await shoot(tester, '${p}13_anywhere');
      }
      debugDisableShadows = true; // the framework checks it is back to normal
    });
  }
}
