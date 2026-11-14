// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end on a Mac: the phone app's connection code against the real Mac
// agent. Run through tools/e2e-mac.sh (on GitHub's Mac runners in CI), which
// sets PAIRDESK_E2E_LINK and PAIRDESK_E2E_SETTINGS. Accessibility and Screen
// Recording can't be given on those runners, so the screen view only has to
// either work or say plainly what to allow.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/files/transfers.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

void main() {
  final env = Platform.environment;
  final link = env['PAIRDESK_E2E_LINK'];
  final settings = env['PAIRDESK_E2E_SETTINGS'];
  final skip = link == null || settings == null ? 'run through tools/e2e-mac.sh' : null;

  test(
    'pair with a Mac, reconnect, clipboard, files, apps, screen',
    () async {
      final info = parsePairingLink(link!);
      info.addresses.insert(0, '127.0.0.1');
      final me = await PhoneIdentity.fromSeed(List.filled(32, 44));
      final inbox = Directory.systemTemp.createTempSync('pairdesk-e2e-mac');
      final saved = <String, List<int>>{};
      final conn = AgentConnection(
        pingInterval: const Duration(seconds: 1),
        tempDir: inbox,
        saveFile: (temp, name) async {
          saved[name] = await temp.readAsBytes();
          await temp.delete();
          return SavedFile(where: 'Files/PairDesk/$name');
        },
      );

      debugPrint('e2e mac: pairing');
      final laptop = await conn.pair(info, me, phoneName: 'E2E iPhone');
      expect(conn.status, ConnectionStatus.connected);
      expect(laptop.os, 'macos');
      await conn.disconnect();
      await conn.connect(laptop, me, phoneName: 'E2E iPhone');
      expect(conn.status, ConnectionStatus.connected, reason: 'reconnects without a code');
      expect(conn.features, containsAll(['clipboard', 'files', 'apps', 'power']));

      debugPrint('e2e mac: clipboard, both ways with the Mac pasteboard');
      await conn.clipboardSet('PairDesk on a Mac ✓');
      expect(await conn.clipboardGet(), 'PairDesk on a Mac ✓');
      final pasted = await Process.run('pbpaste', []);
      expect((pasted.stdout as String).trim(), 'PairDesk on a Mac ✓');
      final copy = await Process.start('pbcopy', []);
      copy.stdin.write('copied on the Mac');
      await copy.stdin.close();
      await copy.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await conn.clipboardGet(), 'copied on the Mac');

      debugPrint('e2e mac: files, phone → Mac');
      final out = File('${inbox.path}/holiday photo.jpg');
      final bytes = List.generate(1500000, (i) => (i * 31) & 0xff);
      out.writeAsBytesSync(bytes);
      final sent = await conn.sendFile(out);
      expect(sent.state, TransferState.done);
      expect(File('${env['PAIRDESK_E2E_DOWNLOADS']}/holiday photo.jpg').readAsBytesSync(), bytes);

      debugPrint('e2e mac: files, Mac → phone (the window\'s drop area)');
      final got = conn.transfers.received.first;
      final upload = await HttpClient().openUrl(
        'POST',
        Uri.parse('${settings}api/upload?name=from%20the%20Mac.txt'),
      );
      upload.headers.set('X-PairDesk', '1');
      upload.add(utf8.encode('hello from the Mac\n' * 20000));
      final res = await upload.close();
      expect(res.statusCode, 200, reason: await res.transform(utf8.decoder).join());
      await got.timeout(const Duration(seconds: 20));
      expect(utf8.decode(saved['from the Mac.txt']!), 'hello from the Mac\n' * 20000);

      debugPrint('e2e mac: apps from /Applications and /System/Applications');
      final apps = await conn.fetchApps();
      final names = apps.apps.map((a) => a.name).toList();
      expect(
        names,
        anyOf(contains('Calculator'), contains('Safari'), contains('TextEdit')),
        reason: '$names',
      );

      debugPrint('e2e mac: screen view');
      if (conn.features.contains('screen')) {
        try {
          final screen = await conn.startScreen(quality: 'medium');
          expect(screen.width, greaterThan(0));
          final frames = StreamIterator(conn.screenFrames);
          expect(await frames.moveNext().timeout(const Duration(seconds: 15)), isTrue);
          conn.ackScreen(frames.current.seq);
          debugPrint('e2e mac: got a ${screen.width}×${screen.height} picture');
          if (env['PAIRDESK_E2E_INPUT'] == '1') {
            // Accessibility is allowed on the runner: the pointer really
            // moves, and its new place comes back with the pictures.
            final (w, h) = (screen.width, screen.height);
            conn.moveTo(0.25, 0.5);
            final want = ((w - 1) * 0.25).round();
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            var seen = '';
            while (DateTime.now().isBefore(deadline)) {
              expect(await frames.moveNext().timeout(const Duration(seconds: 5)), isTrue);
              final f = frames.current;
              conn.ackScreen(f.seq);
              seen = '${f.cursorX},${f.cursorY}';
              if (f.cursorX != null &&
                  (f.cursorX! - want).abs() <= 2 &&
                  (f.cursorY! - ((h - 1) * 0.5).round()).abs() <= 2) {
                seen = 'ok';
                break;
              }
            }
            expect(seen, 'ok', reason: 'pointer at ${(want, ((h - 1) * 0.5).round())} on a ${w}x$h screen');
            debugPrint('e2e mac: the pointer moved');
          }
          conn.stopScreen();

          final video = await conn.startScreen(quality: 'medium', codecs: const ['h264']);
          expect(video.codec, 'h264');
          while (true) {
            expect(await frames.moveNext().timeout(const Duration(seconds: 10)), isTrue);
            final f = frames.current;
            conn.ackScreen(f.seq);
            if (!f.isVideo || f.video!.isEmpty) continue;
            expect(f.keyframe, isTrue, reason: 'video starts with a key frame');
            break;
          }
          debugPrint('e2e mac: H.264 video from the Mac');
          conn.stopScreen();
          await frames.cancel();
        } on AgentException catch (e) {
          debugPrint('e2e mac: screen view refused: ${e.message}');
          expect(e.message, contains('Screen Recording'));
        }
      }

      await conn.disconnect();
      inbox.deleteSync(recursive: true);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: skip,
  );
}
