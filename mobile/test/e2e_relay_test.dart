// SPDX-License-Identifier: GPL-3.0-or-later
// "Get help" through the relay, against the real agent and relay. Run
// through tools/e2e-relay.sh.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

void main() {
  final env = Platform.environment;
  final link = env['PAIRDESK_E2E_HELP_LINK'];
  final settings = env['PAIRDESK_E2E_SETTINGS'];
  final skip = link == null || settings == null ? 'run through tools/e2e-relay.sh' : null;

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

  test(
    'help a friend through the relay',
    () async {
      final info = parsePairingLink(link!);
      expect(info.help, isTrue);
      // As from another network: the computer's own addresses don't answer;
      // only the relay route is left.
      if (env['E2E_DIRECT'] == null) info.addresses.removeWhere((a) => !a.startsWith('relay:'));
      if (env['E2E_DIRECT'] == null) expect(info.addresses, hasLength(1));

      final me = await PhoneIdentity.fromSeed(List.filled(32, 9));
      final conn = AgentConnection(pingInterval: const Duration(seconds: 1));
      final laptop = await conn.pair(info, me, phoneName: 'Helper');
      expect(conn.status, ConnectionStatus.connected);
      if (env['E2E_DIRECT'] == null) expect(conn.address, startsWith('relay:'));
      expect(laptop.helping, isTrue);
      // A helper: the screen and control, not power, files or sound.
      expect(conn.allowed.screen, isTrue);
      expect(conn.allowed.power || conn.allowed.files || conn.allowed.audio, isFalse);

      // Real traffic through the relay: a screen view picture (a still
      // screen sends one, then more only when something changes).
      var got = 0;
      final first = Completer<void>();
      final sub = conn.screenFrames.listen((f) {
        conn.ackScreen(f.seq); // the computer sends the next one after this
        if (++got == 1 && !first.isCompleted) first.complete();
      });
      await conn.startScreen(quality: 'low');
      await first.future.timeout(const Duration(seconds: 15));
      await sub.cancel();
      conn.stopScreen();
      await expectLater(conn.power(PowerAction.lock), throwsA(isA<RequestException>()));

      // The computer shows who is helping.
      final phone = ((await state())['phones'] as List).cast<Map<String, dynamic>>().single;
      expect(phone['helping_until'], isA<int>());
      expect(phone['connected'], isTrue);
      expect(phone['address'], 'the relay');

      // Reconnecting later, still from elsewhere, works through the relay
      // too. (The phone has learned the computer's home addresses by now;
      // here they'd answer, so leave them out as if away from home.)
      await conn.disconnect();
      if (env['E2E_DIRECT'] == null) laptop.addresses.removeWhere((a) => !a.startsWith('relay:'));
      if (env['E2E_DIRECT'] == null) expect(laptop.addresses, isNotEmpty);
      await conn.connect(laptop, me, phoneName: 'Helper');
      if (env['E2E_DIRECT'] == null) expect(conn.address, startsWith('relay:'));

      // The person ends help: the helper is disconnected and can't return.
      await post('api/remove', {'id': me.id});
      for (var i = 0; i < 50 && conn.status == ConnectionStatus.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(conn.status, isNot(ConnectionStatus.connected));
      await expectLater(
        conn.connect(laptop, me, phoneName: 'Helper'),
        throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.notPaired)),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
