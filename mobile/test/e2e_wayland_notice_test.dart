// SPDX-License-Identifier: GPL-3.0-or-later
// Part of tools/e2e-wayland.sh: when the owner refuses on the computer, the
// phone is told what happened.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

void main() {
  final link = Platform.environment['PAIRDESK_E2E_LINK'];
  test(
    'the phone hears that control was refused',
    () async {
      final info = parsePairingLink(link!);
      info.addresses.insert(0, '127.0.0.1');
      final me = await PhoneIdentity.fromSeed(List.filled(32, 52));
      final conn = AgentConnection(pingInterval: const Duration(seconds: 1));
      final notices = <String>[];
      conn.notices.listen(notices.add);
      await conn.pair(info, me, phoneName: 'Wayland E2E cancel');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline) && !notices.any((n) => n.contains("wasn't allowed"))) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(notices.first, contains('Approve PairDesk on the computer'));
      expect(notices.last, contains("Control wasn't allowed on the computer"));
      // Screen view says so too, instead of hanging.
      await expectLater(conn.startScreen(), throwsA(isA<RequestException>()));
      await conn.disconnect();
    },
    skip: link == null ? 'run through tools/e2e-wayland.sh' : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
