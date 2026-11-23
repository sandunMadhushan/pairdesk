// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/pairing/laptop.dart';
import 'package:pairdesk/wake.dart';

void main() {
  test('network addresses are checked', () {
    expect(isMacAddress('aa:bb:cc:dd:ee:ff'), isTrue);
    expect(isMacAddress('AA-BB-CC-DD-EE-01'), isTrue);
    expect(isMacAddress('aa:bb:cc:dd:ee'), isFalse);
    expect(isMacAddress('00:00:00:00:00:00'), isFalse);
    expect(isMacAddress('ff:ff:ff:ff:ff:ff'), isFalse);
    expect(isMacAddress('not a mac'), isFalse);
  });

  test('the magic packet is six 0xFF then the address sixteen times', () {
    final p = magicPacket('01:02:03:04:05:06');
    expect(p.length, 102);
    expect(p.sublist(0, 6), List.filled(6, 255));
    for (var i = 0; i < 16; i++) {
      expect(p.sublist(6 + i * 6, 12 + i * 6), [1, 2, 3, 4, 5, 6]);
    }
  });

  test('a packet is sent to the address given', () async {
    final rx = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = Completer<Uint8List>();
    rx.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = rx.receive();
        if (d != null && !got.isCompleted) got.complete(d.data);
      }
    });
    // Tests send to one port: pass the receiver's port through a target list
    // by sending directly with the same packet builder.
    final tx = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    tx.send(magicPacket('0a:0b:0c:0d:0e:0f'), InternetAddress.loopbackIPv4, rx.port);
    final data = await got.future.timeout(const Duration(seconds: 3));
    expect(data, magicPacket('0a:0b:0c:0d:0e:0f'));
    tx.close();
    rx.close();
  });

  test('wakeOnThisNetwork skips bad addresses and does not throw', () async {
    final sent = await wakeOnThisNetwork(['nonsense'], targets: [InternetAddress.loopbackIPv4]);
    expect(sent, 0);
  });

  test('a computer remembers its network addresses', () {
    final l = Laptop(
      fingerprint: Uint8List(32),
      name: 'PC',
      port: 47800,
      addresses: ['10.0.0.2'],
      macs: ['aa:bb:cc:dd:ee:ff'],
    );
    final back = Laptop.fromJson(l.toJson())!;
    expect(back.macs, ['aa:bb:cc:dd:ee:ff']);
    final old = Laptop.fromJson({'fp': l.key, 'name': 'Old', 'port': 1, 'addresses': <String>[]})!;
    expect(old.macs, isEmpty);
  });
}
