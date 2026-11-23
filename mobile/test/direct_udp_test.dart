// SPDX-License-Identifier: GPL-3.0-or-later
// Two direct-path ends on this computer, over real UDP.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/pairing/direct.dart';

void main() {
  test('bytes go both ways over a direct path', () async {
    final a = await DirectSocket.bind(), b = await DirectSocket.bind();
    final token = Uint8List.fromList(List.filled(8, 4));
    final lo = InternetAddress.loopbackIPv4;
    final pa = await forwardDirect(a, (lo, b.port), token, timeout: const Duration(seconds: 5));
    final pb = await forwardDirect(b, (lo, a.port), token, timeout: const Duration(seconds: 5));
    final sa = await Socket.connect(lo, pa), sb = await Socket.connect(lo, pb);
    final data = Uint8List.fromList(List.generate(2000000, (i) => (i * 5) & 0xff));
    final got = BytesBuilder();
    final done = Completer<void>();
    sb.listen((d) {
      got.add(d);
      if (got.length >= data.length && !done.isCompleted) done.complete();
    });
    sa.add(data);
    await done.future.timeout(const Duration(seconds: 20));
    expect(got.takeBytes(), data);
    sa.destroy();
    sb.destroy();
  });
}
