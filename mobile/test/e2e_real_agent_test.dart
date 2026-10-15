// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end test against the real Rust agent. Skipped unless
// PAIRDESK_E2E_LINK (a pairing link from the agent's settings page)
// and PAIRDESK_E2E_SETTINGS (its settings page address) are set.
// Run through tools/e2e.sh.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

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
      final info = parsePairingLink(link!);
      // The agent runs on this machine; use loopback in case the link lists none.
      info.addresses.insert(0, '127.0.0.1');
      final me = await PhoneIdentity.fromSeed(List.filled(32, 42));
      final conn = AgentConnection(pingInterval: const Duration(seconds: 1));

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
      conn.move(40, 30);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // The settings page lists the phone as connected.
      var (status, body) = await call('GET', 'api/state');
      expect(status, 200);
      final state = jsonDecode(body) as Map<String, dynamic>;
      final phones = state['phones'] as List;
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
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
