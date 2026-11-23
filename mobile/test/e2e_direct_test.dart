// SPDX-License-Identifier: GPL-3.0-or-later
// Direct connections against the real agent and relay: the phone reaches
// the computer only through the relay's introduction, then over a direct
// UDP path. Run through tools/e2e-direct.sh.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/files/transfers.dart';
import 'package:pairdesk/pairing/direct.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/laptop.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

void main() {
  final env = Platform.environment;
  final link = env['PAIRDESK_E2E_LINK'];
  final settings = env['PAIRDESK_E2E_SETTINGS'];
  final skip = link == null || settings == null ? 'run through tools/e2e-direct.sh' : null;

  Future<Map<String, dynamic>> state() async {
    final client = HttpClient();
    try {
      final res = await (await client.getUrl(Uri.parse('${settings}api/state'))).close();
      return jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> post(String path, Object body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$settings$path'));
      req.headers.set('X-PairDesk', '1');
      req.write(jsonEncode(body));
      expect((await req.close()).statusCode, 200);
    } finally {
      client.close();
    }
  }

  Future<String> phoneAddress() async =>
      ((await state())['phones'] as List).cast<Map<String, dynamic>>().single['address'] as String;

  // As from another network: only the relay route.
  void awayFromHome(Laptop l) => l.addresses.removeWhere((a) => !a.startsWith('relay:'));

  test(
    'the relay introduces, the screen goes direct',
    () async {
      directIncludeLoopback = true;
      final info = parsePairingLink(link!);
      info.addresses.removeWhere((a) => !a.startsWith('relay:'));
      final me = await PhoneIdentity.fromSeed(List.filled(32, 5));
      final conn = AgentConnection(pingInterval: const Duration(seconds: 1));

      // Pairing goes through the relay (the phone doesn't know yet that the
      // computer can do direct paths), and teaches the phone that it can.
      final laptop = await conn.pair(info, me, phoneName: 'Traveller');
      expect(conn.viaDirect, isFalse);
      expect(laptop.direct, isTrue);
      await conn.disconnect();

      // Next time: direct.
      awayFromHome(laptop);
      await conn.connect(laptop, me, phoneName: 'Traveller');
      expect(conn.address, startsWith('relay:'));
      expect(conn.viaDirect, isTrue);
      expect(await phoneAddress(), endsWith('(direct)'));
      final s = (await state())['direct'] as Map<String, dynamic>;
      expect((s['last'] as Map)['direct'], isTrue);

      // Real traffic over the direct path: a screen picture (a still screen
      // sends one) and a file.
      final frames = Completer<void>();
      final sub = conn.screenFrames.listen((f) {
        conn.ackScreen(f.seq);
        if (!frames.isCompleted) frames.complete();
      });
      await conn.startScreen(quality: 'low');
      await frames.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
      conn.stopScreen();
      final dir = Directory.systemTemp.createTempSync('pd-direct');
      final file = File('${dir.path}/big.bin');
      final bytes = List.generate(3000000, (i) => (i * 13) & 0xff);
      file.writeAsBytesSync(bytes);
      final sw = Stopwatch()..start();
      final sent = await conn.sendFile(file);
      expect(sent.state, TransferState.done);
      expect(File('${env['PAIRDESK_E2E_DOWNLOADS']}/big.bin').readAsBytesSync(), bytes);
      debugPrint('e2e: 3 MB over the direct path in ${sw.elapsedMilliseconds} ms');
      await conn.disconnect();

      // Turned off on the computer: the relay carries it, as before.
      await post('api/direct', {'enabled': false});
      awayFromHome(laptop);
      await conn.connect(laptop, me, phoneName: 'Traveller');
      expect(conn.viaDirect, isFalse);
      expect(await phoneAddress(), 'the relay');
      expect(await conn.clipboardGet(), isA<String>());
      await conn.disconnect();

      // And back on.
      await post('api/direct', {'enabled': true});
      awayFromHome(laptop);
      await conn.connect(laptop, me, phoneName: 'Traveller');
      expect(conn.viaDirect, isTrue);
      await conn.disconnect();

      // A phone that chooses not to try goes through the relay too (old phones).
      final plain = AgentConnection(pingInterval: const Duration(seconds: 1), directPaths: false);
      awayFromHome(laptop);
      await plain.connect(laptop, me, phoneName: 'Traveller');
      expect(plain.viaDirect, isFalse);
      expect(await phoneAddress(), 'the relay');
      await plain.disconnect();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
