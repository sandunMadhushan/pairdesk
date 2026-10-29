// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/files/native_files.dart';
import 'package:pairdesk/files/share_inbox.dart';
import 'package:pairdesk/files/transfers.dart';
import 'package:pairdesk/screens/control_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeConnection extends AgentConnection {
  FakeConnection({this.allow = const Allowed(clipboard: true, files: true), required super.tempDir})
    : super(
        saveFile: (temp, name) async =>
            SavedFile(where: 'Download/PairDesk/$name', uri: 'content://downloads/$name'),
      );
  final Allowed allow;
  final calls = <String>[];
  String computerClipboard = 'from the computer';

  @override
  ConnectionStatus get status => ConnectionStatus.connected;
  @override
  Set<String> get features => {'combo', 'power', 'apps', 'screen', 'clipboard', 'files'};
  @override
  Allowed get allowed => allow;
  @override
  String? get agentOs => 'windows';
  @override
  String? get agentName => 'Test-PC';

  @override
  Future<String> clipboardGet() async {
    if (!allow.clipboard) throw RequestException('not_allowed', 'off');
    return computerClipboard;
  }

  @override
  Future<void> clipboardSet(String text, {bool paste = false}) async => calls.add('clip $text paste=$paste');

  @override
  Future<Transfer> sendFile(File file, {String? name}) async {
    calls.add('send $name ${file.readAsStringSync()}');
    return Transfer(fid: 1, incoming: false, name: name ?? 'x', size: 1)..state = TransferState.done;
  }
}

void main() {
  late Directory tmp;
  late List<Object?> phoneClipboard;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('pairdesk-widgets');
    phoneClipboard = ['on the phone'];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<FakeConnection> show(WidgetTester tester, {Allowed? allow, ShareInbox? inbox}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          phoneClipboard.add((call.arguments as Map)['text']);
        case 'Clipboard.getData':
          return {'text': phoneClipboard.last};
      }
      return null;
    });
    final conn = FakeConnection(allow: allow ?? const Allowed(clipboard: true, files: true), tempDir: tmp);
    await tester.pumpWidget(
      MaterialApp(
        home: ControlScreen(
          connection: conn,
          laptopKey: 'k',
          inbox: inbox ?? ShareInbox(take: () async => const SharedItems()),
        ),
      ),
    );
    await tester.pump();
    return conn;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Clipboard and files'));
    await tester.pumpAndSettle();
  }

  testWidgets('copies the computer\'s clipboard to the phone', (tester) async {
    await show(tester);
    await openSheet(tester);
    await tester.tap(find.text('Copy from computer'));
    await tester.pumpAndSettle();
    expect(phoneClipboard.last, 'from the computer');
    expect(find.textContaining('Copied from the computer'), findsOneWidget);
  });

  testWidgets('sends and pastes the phone\'s clipboard on the computer', (tester) async {
    final conn = await show(tester);
    await openSheet(tester);
    await tester.tap(find.text('Send to computer'));
    await tester.pumpAndSettle();
    await openSheet(tester);
    await tester.tap(find.text('Paste on computer'));
    await tester.pumpAndSettle();
    expect(conn.calls, ['clip on the phone paste=false', 'clip on the phone paste=true']);
    expect(find.text('Pasted on the computer.'), findsOneWidget);
  });

  testWidgets('says when the owner turned the clipboard and files off', (tester) async {
    await show(tester, allow: const Allowed());
    await openSheet(tester);
    expect(find.text('Copy from computer'), findsNothing);
    expect(find.text('Send files to computer'), findsNothing);
    expect(find.text('Turned off in PairDesk settings on the computer.'), findsNWidgets(2));
  });

  testWidgets('"Share → PairDesk" sends shared files and text', (tester) async {
    final f = File('${tmp.path}/share/abc/photo.jpg')..createSync(recursive: true);
    f.writeAsStringSync('jpeg bytes');
    final inbox = ShareInbox(take: () async => const SharedItems());
    inbox.put(SharedItems(files: [PickedFile(f.path, 'photo.jpg')]));
    final conn = await show(tester, inbox: inbox);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(conn.calls, ['send photo.jpg jpeg bytes']);
    expect(inbox.pending, isNull);
    expect(find.textContaining('Downloads\\PairDesk'), findsOneWidget);
    expect(f.parent.existsSync(), isFalse, reason: 'the cache copy is removed');

    inbox.put(const SharedItems(text: 'a link https://example.com'));
    await tester.pumpAndSettle();
    expect(conn.calls.last, 'clip a link https://example.com paste=false');
  });

  testWidgets('a file from the computer shows up with an Open button', (tester) async {
    final conn = await show(tester);
    final data = List.generate(5000, (i) => i & 0xff);
    await tester.runAsync(() async {
      conn.transfers.handleMessage({
        't': 'file_offer',
        'fid': agentFids + 1,
        'name': 'report.pdf',
        'size': data.length,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      conn.transfers.handleChunk(chunkMessage(agentFids + 1, 0, data));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      conn.transfers.handleMessage({
        't': 'file_end',
        'fid': agentFids + 1,
        'sha256': sha256.convert(data).toString(),
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Received report.pdf'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Open'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await openSheet(tester);
    expect(find.text('Saved in Download/PairDesk/report.pdf'), findsOneWidget);
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('Open')), findsOneWidget);
  });
}
