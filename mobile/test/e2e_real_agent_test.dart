// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end test against the real Rust agent. Skipped unless
// PAIRDESK_E2E_LINK (a pairing link from the agent's settings page)
// and PAIRDESK_E2E_SETTINGS (its settings page address) are set.
// Run through tools/e2e.sh.

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/files/transfers.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';
import 'package:pairdesk/screen/compositor.dart';
import 'package:pairdesk/screen/video.dart';

void main() {
  final link = Platform.environment['PAIRDESK_E2E_LINK'];
  final settings = Platform.environment['PAIRDESK_E2E_SETTINGS'];
  final skip = link == null || settings == null ? 'set PAIRDESK_E2E_LINK and PAIRDESK_E2E_SETTINGS' : null;

  Future<(int, String)> call(String method, String path, {Map<String, String>? headers, Object? body}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('$settings$path'));
      headers?.forEach(req.headers.set);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }

  test(
    'pair, reconnect, move the cursor, then get removed',
    () async {
      final env = Platform.environment;
      final info = parsePairingLink(link!);
      // The agent runs on this machine; use loopback in case the link lists none.
      info.addresses.insert(0, '127.0.0.1');
      final me = await PhoneIdentity.fromSeed(List.filled(32, 42));
      final inbox = Directory.systemTemp.createTempSync('pairdesk-e2e-phone');
      final saved = <String, List<int>>{};
      final conn = AgentConnection(
        pingInterval: const Duration(seconds: 1),
        tempDir: inbox,
        saveFile: (temp, name) async {
          saved[name] = await temp.readAsBytes();
          await temp.delete();
          return SavedFile(where: 'Download/PairDesk/$name');
        },
      );

      final laptop = await conn.pair(info, me, phoneName: 'E2E phone');
      expect(conn.status, ConnectionStatus.connected);
      expect(
        laptop.os,
        Platform.environment['PAIRDESK_E2E_OS']?.isNotEmpty == true
            ? Platform.environment['PAIRDESK_E2E_OS']
            : 'linux',
      );

      // The pairing code is single use.
      final second = AgentConnection();
      final other = await PhoneIdentity.fromSeed(List.filled(32, 43));
      await expectLater(
        second.pair(info, other, phoneName: 'Intruder'),
        throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.badToken)),
      );

      await conn.disconnect();

      // Later: connect without any code.
      await conn.connect(laptop, me, phoneName: 'E2E phone');
      expect(conn.status, ConnectionStatus.connected);

      // ---- Phase 4: screen view, checked pixel by pixel ----
      debugPrint('e2e: Phase 4: screen view, checked pixel by pixel');
      expect(conn.features, contains('screen'));
      final compositor = ScreenCompositor();
      final frames = StreamIterator(conn.screenFrames);
      final screen = await conn.startScreen(quality: 'high');
      expect((screen.width, screen.height), (1280, 800), reason: 'Xvfb is 1280×800; no scaling at high');
      Future<Color> pixelAt(int x, int y) async {
        final img = compositor.image!;
        final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final i = (y * img.width + x) * 4;
        return Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
      }

      Future<void> waitForColour(bool Function(Color) ok, String what) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          expect(await frames.moveNext().timeout(const Duration(seconds: 10)), isTrue);
          await compositor.apply(frames.current);
          conn.ackScreen(frames.current.seq);
          if (compositor.image != null && ok(await pixelAt(100, 100))) return;
        }
        fail('screen never showed $what');
      }

      bool isRed(Color c) => (c.r * 255) > 200 && (c.g * 255) < 60 && (c.b * 255) < 60;
      bool isGreen(Color c) => (c.g * 255) > 200 && (c.r * 255) < 60 && (c.b * 255) < 60;
      await waitForColour(isRed, 'the red window');
      final firstWidth = compositor.image!.width;
      // The window turns green; only the changed part should be sent.
      File(Platform.environment['PAIRDESK_E2E_SCREEN_SIGNAL']!).writeAsStringSync('go');
      await waitForColour(isGreen, 'the window turning green');
      expect(compositor.image!.width, firstWidth);
      expect(await pixelAt(1000, 700), isNot(predicate<Color>(isGreen)), reason: 'outside the window');
      // Tapping a spot on the picture puts the real pointer there.
      conn.moveTo(300 / 1279, 200 / 799);
      // The pointer's new place reaches the phone on its own, quickly,
      // without waiting for a picture change.
      final watch = Stopwatch()..start();
      while (true) {
        expect(await frames.moveNext().timeout(const Duration(seconds: 3)), isTrue);
        final f = frames.current;
        conn.ackScreen(f.seq);
        await compositor.apply(f);
        if (f.cursorX == 300 && f.cursorY == 200) break;
      }
      expect(watch.elapsedMilliseconds, lessThan(1000));
      // Touchpad-style moves in the screen view are relative, like the touchpad.
      conn.move(25, 10);
      while (true) {
        expect(await frames.moveNext().timeout(const Duration(seconds: 3)), isTrue);
        final f = frames.current;
        conn.ackScreen(f.seq);
        if (f.cursorX == 325 && f.cursorY == 210) break;
      }
      conn.moveTo(100 / 1279, 100 / 799);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      conn.stopScreen();

      // ---- 0.9: the same screen as H.264 video ----
      debugPrint('e2e: screen view as H.264 video');
      expect(conn.features, contains('video'));
      final video = await conn.startScreen(quality: 'medium', codecs: const ['h264']);
      expect(video.codec, 'h264');
      expect((video.width, video.height), (1280, 800), reason: 'medium is up to 1280 wide');
      while (true) {
        expect(await frames.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final f = frames.current;
        conn.ackScreen(f.seq);
        if (!f.isVideo || f.video!.isEmpty) continue; // JPEG left over, or the cursor
        expect(f.keyframe, isTrue, reason: 'video starts with a key frame');
        expect((f.width, f.height), (1280, 800));
        final parts = splitParameterSets(f.video!);
        expect(parts.config, isNotNull, reason: 'the key frame carries SPS and PPS');
        expect(parts.frame[0] == 0 && parts.frame[1] == 0, isTrue, reason: 'Annex B');
        break;
      }
      conn.stopScreen();
      await frames.cancel();
      compositor.dispose();

      conn.move(40, 30);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // ---- Phase 6: clipboard ----
      debugPrint('e2e: Phase 6: clipboard');
      expect(conn.features, containsAll(['clipboard', 'files']));
      expect(conn.allowed.clipboard, isTrue);
      await conn.clipboardSet('PairDesk E2E ✓ clipboard');
      expect(await conn.clipboardGet(), 'PairDesk E2E ✓ clipboard');
      final checkClip = env['PAIRDESK_E2E_CLIP_CHECK'];
      if (checkClip != null && checkClip.isNotEmpty) {
        // Another program on the computer sees it too.
        final r = await Process.run('sh', ['-c', checkClip]);
        expect((r.stdout as String).trim(), 'PairDesk E2E ✓ clipboard');
        // ... and what another program copies reaches the phone.
        await Process.run('sh', ['-c', env['PAIRDESK_E2E_CLIP_SET']!]);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(await conn.clipboardGet(), 'copied on the computer');
      }

      // ---- Phase 6: files, phone → computer ----
      debugPrint('e2e: Phase 6: files, phone → computer');
      final out = File('${inbox.path}/holiday photo.jpg');
      final bytes = List.generate(2500000, (i) => (i * 31) & 0xff);
      out.writeAsBytesSync(bytes);
      final sent = await conn.sendFile(out);
      expect(sent.state, TransferState.done);
      expect(sent.name, 'holiday photo.jpg');
      final downloads = env['PAIRDESK_E2E_DOWNLOADS']!;
      expect(File('$downloads/holiday photo.jpg').readAsBytesSync(), bytes);
      // The same name again doesn't overwrite.
      expect((await conn.sendFile(out)).name, 'holiday photo (2).jpg');

      // ---- Phase 6: files, computer → phone (the settings page's drop zone) ----
      debugPrint('e2e: Phase 6: files, computer → phone (the settings pages drop zone)');
      final got = conn.transfers.received.first;
      final upload = await HttpClient().openUrl(
        'POST',
        Uri.parse('${settings}api/upload?name=from%20the%20PC.txt'),
      );
      upload.headers.set('X-PairDesk', '1');
      upload.add(utf8.encode('hello from the computer\n' * 50000));
      final res = await upload.close();
      expect(res.statusCode, 200, reason: await res.transform(utf8.decoder).join());
      final t = await got.timeout(const Duration(seconds: 20));
      expect(t.name, 'from the PC.txt');
      expect(utf8.decode(saved['from the PC.txt']!), 'hello from the computer\n' * 50000);
      // ... and "Send to phone" in the file manager.
      debugPrint('e2e: and "Send to phone" in the file manager');
      final sendCmd = env['PAIRDESK_E2E_SEND_CMD'];
      if (sendCmd != null && sendCmd.isNotEmpty) {
        final got2 = conn.transfers.received.first;
        final r = await Process.run('sh', ['-c', '$sendCmd "\$1"', 'sh', out.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        await got2.timeout(const Duration(seconds: 20));
        expect(saved['holiday photo.jpg'], bytes);
      }

      expect(laptop.addresses.first, '127.0.0.1', reason: 'the address that worked comes first');
      expect(
        laptop.addresses.length,
        greaterThanOrEqualTo(2),
        reason: 'learned the computer\'s own addresses',
      );
      expect(conn.viaTailscale, isFalse);
      if (Platform.environment['PAIRDESK_E2E_TAILSCALE'] == '1') {
        // The agent saw Tailscale running and told the phone how to reach it.
        expect(laptop.addresses, containsAll(['100.101.102.103', 'e2e-pc.tail1234.ts.net']));
        expect(laptop.reachableAnywhere, isTrue);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(conn.latency, isNotNull, reason: 'ping round trip measured');

      // ---- Phase 2: shortcuts, power, apps ----
      debugPrint('e2e: Phase 2: shortcuts, power, apps');
      expect(conn.features, containsAll(['combo', 'power', 'apps']));
      conn.combo([Modifier.ctrl], char: 'c');
      conn.combo([Modifier.alt], key: AgentKey.tab);
      // The agent runs with PAIRDESK_POWER_DRY_RUN, so nothing really locks.
      await conn.power(PowerAction.lock);
      await conn.power(PowerAction.sleep);

      // The owner turns off restart/shut down on the settings page: refused at once.
      var (status, body) = await call(
        'POST',
        'api/permissions',
        headers: {'X-PairDesk': '1'},
        body: {'power': true, 'session': false, 'apps': true},
      );
      expect(status, 200);
      await expectLater(
        conn.power(PowerAction.shutDown),
        throwsA(isA<RequestException>().having((e) => e.code, 'code', 'not_allowed')),
      );

      // A program shortcut added on the settings page can be opened from the phone.
      (status, body) = await call(
        'POST',
        'api/shortcuts/add',
        headers: {'X-PairDesk': '1'},
        body: {
          'name': 'E2E marker',
          'kind': 'program',
          'target': env['PAIRDESK_E2E_PROGRAM']!,
          'args': env['PAIRDESK_E2E_PROGRAM_ARGS']!,
        },
      );
      expect(status, 200, reason: body);
      final apps = await conn.fetchApps();
      final shortcut = apps.shortcuts.singleWhere((a) => a.name == 'E2E marker');
      expect(shortcut.kind, 'program');
      await conn.launch(shortcut.id);
      await expectLater(
        conn.launch('not-an-id'),
        throwsA(isA<RequestException>().having((e) => e.code, 'code', 'not_found')),
      );
      final appName = env['PAIRDESK_E2E_APP'];
      if (appName != null && appName.isNotEmpty) {
        final installed = apps.apps.singleWhere((a) => a.name == appName);
        await conn.launch(installed.id);
      }

      // The settings page lists the phone as connected.
      (status, body) = await call('GET', 'api/state');
      expect(status, 200);
      final state = jsonDecode(body) as Map<String, dynamic>;
      final phones = state['phones'] as List;
      expect([
        'running',
        'not_installed',
        'not_connected',
        'checking',
        'unknown',
      ], contains(state['remote']['status']));
      expect(state['keep_awake'], isFalse);
      expect(phones.single['name'], 'E2E phone');
      expect(phones.single['connected'], true);

      // The settings page refuses changes without its header.
      (status, _) = await call('POST', 'api/remove', body: {'id': me.id});
      expect(status, 403);
      // ... and requests that claim another Host (DNS rebinding).
      (status, _) = await call('GET', 'api/state', headers: {'Host': 'evil.example:80'});
      expect(status, 403);
      // ... and paths without the secret.
      final noSecret = Uri.parse(settings!).replace(path: '/api/state');
      final c = HttpClient();
      final r = await (await c.getUrl(noSecret)).close();
      expect(r.statusCode, 404);
      c.close();

      // Removing the phone on the computer disconnects it right away.
      (status, _) = await call('POST', 'api/remove', headers: {'X-PairDesk': '1'}, body: {'id': me.id});
      expect(status, 200);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(conn.status, ConnectionStatus.disconnected);
      expect(conn.lastError?.kind, FailureKind.notPaired);

      await expectLater(
        conn.connect(laptop, me, phoneName: 'E2E phone'),
        throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.notPaired)),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
