// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end test against the real agent in a GNOME Wayland session
// (headless mutter, the real portals and PipeWire). Run through
// tools/e2e-wayland.sh, which sets PAIRDESK_E2E_LINK, PAIRDESK_E2E_STAGE and
// a few file paths.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';
import 'package:pairdesk/screen/compositor.dart';

void main() {
  final env = Platform.environment;
  final link = env['PAIRDESK_E2E_LINK'];
  final stage = env['PAIRDESK_E2E_STAGE'] ?? 'first';
  final skip = link == null ? 'run through tools/e2e-wayland.sh' : null;

  Future<AgentConnection> connect(int seed) async {
    final info = parsePairingLink(link!);
    info.addresses.insert(0, '127.0.0.1');
    final me = await PhoneIdentity.fromSeed(List.filled(32, seed));
    final conn = AgentConnection(pingInterval: const Duration(seconds: 1));
    await conn.pair(info, me, phoneName: 'Wayland E2E $stage');
    expect(conn.status, ConnectionStatus.connected);
    expect(conn.agentVersion, isNotNull);
    expect(conn.features, contains('screen'));
    return conn;
  }

  /// Waits for an app-log line (the test window records what it receives).
  Future<void> appSaw(String line) async {
    final log = File(env['PAIRDESK_E2E_APP_LOG']!);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (log.readAsLinesSync().contains(line)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('the test window never got "$line"; it saw:\n${log.readAsStringSync()}');
  }

  test(
    '$stage: screen, pointer and keyboard through the portal',
    () async {
      final conn = await connect(stage == 'first' ? 50 : 51);
      final compositor = ScreenCompositor();
      final frames = StreamIterator(conn.screenFrames);
      final screen = await conn.startScreen(quality: 'high');
      expect((screen.width, screen.height), (1280, 800), reason: 'the virtual monitor is 1280×800');

      Future<Color> pixelAt(int x, int y) async {
        final img = compositor.image!;
        final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final i = (y * img.width + x) * 4;
        return Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
      }

      Future<ScreenFrameCursor> next() async {
        expect(await frames.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final f = frames.current;
        await compositor.apply(f);
        conn.ackScreen(f.seq);
        return (f.cursorX, f.cursorY);
      }

      Future<void> waitFor(Future<bool> Function(ScreenFrameCursor) ok, String what) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          final c = await next();
          if (compositor.image != null && await ok(c)) return;
        }
        fail('never saw $what');
      }

      bool isRed(Color c) => (c.r * 255) > 200 && (c.g * 255) < 60 && (c.b * 255) < 60;
      bool isGreen(Color c) => (c.g * 255) > 200 && (c.r * 255) < 60 && (c.b * 255) < 60;

      if (stage == 'first') {
        await waitFor((_) async => isRed(await pixelAt(640, 400)), 'the red window');
        File(env['PAIRDESK_E2E_SCREEN_SIGNAL']!).writeAsStringSync('go');
        await waitFor((_) async => isGreen(await pixelAt(640, 400)), 'the window turning green');
      } else {
        await waitFor((_) async => isGreen(await pixelAt(640, 400)), 'the green window');
      }

      // Headless mutter has no real mouse or keyboard: its seat gains them
      // with the first virtual event, and only then do windows listen. Wake
      // both first (a real desktop always has them).
      conn.move(1, 1);
      conn.combo([Modifier.shift]);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      // Tap-to-point puts the pointer exactly there; the phone sees it move.
      conn.moveTo(300 / 1279, 200 / 799);
      await waitFor((c) async => c == (300, 200), 'the pointer at 300,200');
      await appSaw('motion 300 200');

      // Touchpad-style relative movement.
      conn.move(25, 10);
      await waitFor((c) async => c == (325, 210), 'the pointer at 325,210');
      await appSaw('motion 325 210');

      if (stage == 'first') {
        conn.click(MouseBtn.left);
        await appSaw('press 1 325 210');
        await appSaw('release 1 325 210');
        conn.click(MouseBtn.right);
        await appSaw('press 3 325 210');
        conn.scroll(dy: 2);
        await appSaw('scroll 0 1');
        conn.typeText('Hi!');
        await appSaw('key H');
        await appSaw('key i');
        await appSaw('key !');
        conn.combo([Modifier.ctrl], char: 'a');
        await appSaw('key ctrl+a');
        conn.key(AgentKey.enter);
        await appSaw('key Return');

        // Clipboard through the portal: the window sees what the phone sent,
        // and the phone gets what the window copied.
        expect(conn.features, contains('clipboard'));
        await conn.clipboardSet('from the phone ✓');
        await appSaw('clipboard from the phone ✓');
        await conn.clipboardSet('pasted from the phone', paste: true);
        await appSaw('key ctrl+v');
        File('${env['PAIRDESK_E2E_SCREEN_SIGNAL']!}.clip').writeAsStringSync('go');
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        var text = '';
        while (DateTime.now().isBefore(deadline) && text != 'copied in gtk') {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          text = await conn.clipboardGet();
        }
        expect(text, 'copied in gtk');
      }

      conn.stopScreen();
      await frames.cancel();
      compositor.dispose();
      await conn.disconnect();
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

typedef ScreenFrameCursor = (int?, int?);
