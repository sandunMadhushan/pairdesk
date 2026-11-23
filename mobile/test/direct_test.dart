// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's side of direct connections: the reliable stream over UDP on
// a simulated bad link, STUN answers, candidates and the offer line.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/pairing/direct.dart';
import 'package:pairdesk/pairing/direct_conn.dart';
import 'package:pairdesk/pairing/host.dart';
import 'package:pairdesk/pairing/identity.dart';

/// Two streams joined by a simulated link that loses, reorders and delays.
(Uint8List, ConnState, ConnState) runLink(Uint8List data, double loss, Duration delay, int seed) {
  final token = Uint8List.fromList('tokentok'.codeUnits);
  var now = DateTime(2026);
  final a = DirectConn(token, now), b = DirectConn(token, now);
  final rng = Random(seed);
  final wire = <(DateTime, bool, Uint8List)>[];
  var sent = 0;
  final got = BytesBuilder();
  for (var step = 0; step < 300000; step++) {
    if (sent < data.length) {
      sent += a.write(Uint8List.sublistView(data, sent));
    } else {
      a.close();
    }
    for (final (fromA, c) in [(true, a), (false, b)]) {
      while (true) {
        final p = c.pollTransmit(now);
        if (p == null) break;
        if (rng.nextDouble() >= loss) {
          wire.add((now.add(delay + Duration(microseconds: rng.nextInt(4000))), fromA, p));
        }
      }
    }
    final due = wire.where((w) => !w.$1.isAfter(now)).toList();
    wire.removeWhere((w) => !w.$1.isAfter(now));
    for (final (_, toB, p) in due) {
      (toB ? b : a).onPacket(p, now);
    }
    got.add(b.read());
    if (b.peerFinished) b.close();
    a.onTimeout(now);
    b.onTimeout(now);
    if (a.state != ConnState.open && b.state != ConnState.open) break;
    now = now.add(const Duration(milliseconds: 1));
  }
  return (got.takeBytes(), a.state, b.state);
}

Uint8List sample(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + i ~/ 1000) & 0xff));

void main() {
  test('the stream delivers everything in order on a clean link', () {
    final data = sample(300000);
    final (got, a, b) = runLink(data, 0, const Duration(milliseconds: 20), 1);
    expect(got, data);
    expect((a, b), (ConnState.closed, ConnState.closed));
  });

  test('loss and reordering are repaired', () {
    final data = sample(150000);
    for (var seed = 1; seed < 4; seed++) {
      final (got, a, b) = runLink(data, 0.1, const Duration(milliseconds: 30), seed);
      expect(got.length, data.length, reason: 'seed $seed');
      expect(got, data, reason: 'seed $seed');
      expect((a, b), (ConnState.closed, ConnState.closed));
    }
  });

  test('a narrow link that drops whole bursts is used well', () {
    final token = Uint8List(8);
    final start = DateTime(2026);
    var now = start;
    final a = DirectConn(token, now), b = DirectConn(token, now);
    final data = sample(1000000);
    // 2 packets per ms, 40 packets of queue, 15 ms each way (as in conn.rs).
    final queue = <Uint8List>[];
    final flight = <(DateTime, Uint8List)>[], back = <(DateTime, Uint8List)>[];
    const delay = Duration(milliseconds: 15);
    var sent = 0;
    final got = BytesBuilder();
    while (got.length < data.length && now.difference(start) < const Duration(seconds: 30)) {
      if (sent < data.length) sent += a.write(Uint8List.sublistView(data, sent));
      for (var p = a.pollTransmit(now); p != null; p = a.pollTransmit(now)) {
        if (queue.length < 40) queue.add(p);
      }
      for (var i = 0; i < 2 && queue.isNotEmpty; i++) {
        flight.add((now.add(delay), queue.removeAt(0)));
      }
      while (flight.isNotEmpty && !flight.first.$1.isAfter(now)) {
        b.onPacket(flight.removeAt(0).$2, now);
      }
      got.add(b.read());
      for (var p = b.pollTransmit(now); p != null; p = b.pollTransmit(now)) {
        back.add((now.add(delay), p));
      }
      while (back.isNotEmpty && !back.first.$1.isAfter(now)) {
        a.onPacket(back.removeAt(0).$2, now);
      }
      a.onTimeout(now);
      b.onTimeout(now);
      now = now.add(const Duration(milliseconds: 1));
    }
    expect(got.takeBytes(), data);
    // The link's best is half a second.
    expect(now.difference(start), lessThan(const Duration(milliseconds: 1500)));
  });

  test('a quiet peer fails the stream, a reset ends it', () {
    final t = DateTime(2026);
    final a = DirectConn(Uint8List(8), t)..write([1, 2, 3]);
    a.onTimeout(t.add(idleTimeout + const Duration(seconds: 1)));
    expect(a.state, ConnState.failed);
    final b = DirectConn(Uint8List(8), t);
    b.onPacket(packetHeader(kReset, Uint8List(8)), t);
    expect(b.state, ConnState.failed);
    // Another stream's packets are ignored.
    expect(b.onPacket(packetHeader(kPing, Uint8List.fromList(List.filled(8, 1))), t), isFalse);
  });

  test('STUN answers are read', () {
    final txid = Uint8List.fromList(List.generate(12, (i) => i));
    // 203.0.113.7:40000, XORed with the magic cookie.
    final ip = (203 << 24 | 0 << 16 | 113 << 8 | 7) ^ 0x2112A442;
    final port = 40000 ^ 0x2112;
    final p = Uint8List(32);
    final bd = p.buffer.asByteData();
    bd.setUint16(0, 0x0101);
    bd.setUint16(2, 12);
    bd.setUint32(4, 0x2112A442);
    p.setRange(8, 20, txid);
    bd.setUint16(20, 0x0020);
    bd.setUint16(22, 8);
    p[25] = 1;
    bd.setUint16(26, port);
    bd.setUint32(28, ip);
    final got = parseStunAnswer(p, txid)!;
    expect(got.$1.address, '203.0.113.7');
    expect(got.$2, 40000);
    expect(parseStunAnswer(p, Uint8List(12)), isNull, reason: 'another request');
  });

  test('candidates leave out addresses nobody should get packets', () {
    final c = parseCandidates('0.0.0.0:5,224.0.0.1:5,255.255.255.255:9,1.2.3.4:0,1.2.3.4:5,junk,127.0.0.1:7');
    expect(c.map((e) => '${e.$1.address}:${e.$2}'), ['1.2.3.4:5']);
    expect(parseCandidates('-'), isEmpty);
  });

  test('the offer line carries a signature over the computer and the moment', () async {
    final me = await PhoneIdentity.fromSeed(List.filled(32, 3));
    final line = await offerLine(
      DirectOffer(identity: me, fingerprint: List.filled(32, 7)),
      Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      ['203.0.113.5:4000'],
      time: 1700000000,
    );
    final parts = line.trim().split(' ');
    expect(parts.sublist(0, 5), ['PDD1', me.id, '1700000000', '0102030405060708', '203.0.113.5:4000']);
    expect(line.endsWith('\n'), isTrue);
    expect(base64Url.normalize(parts[5]).length, 88); // 64 bytes
  });

  test('IPv6 addresses from the computer are accepted in brackets', () {
    expect(splitHostPort('[2a02:1234::5]'), (host: '2a02:1234::5', port: null));
    expect(splitHostPort('[2a02:1234::5]:8443'), (host: '2a02:1234::5', port: 8443));
    expect(isUsableHost('[2a02:1234::5]'), isTrue);
    expect(isUsableHost('[fe80::1]'), isFalse);
    expect(isUsableHost('[2001:db8::1]'), isFalse);
    expect(isUsableHost('2a02:1234::5'), isFalse, reason: 'brackets, so a port is never mistaken');
    expect(isUsableHost('203.0.113.9:47801'), isTrue);
  });

  test('a failed direct path is skipped for a while', () {
    forgetDirectFailures();
    expect(directRecentlyFailed('r'), isFalse);
    directFailed('r');
    expect(directRecentlyFailed('r'), isTrue);
    directWorked('r');
    expect(directRecentlyFailed('r'), isFalse);
  });

  test('a UDP socket can learn its address from a STUN server', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((e) {
      final d = server.receive();
      if (d == null) return;
      final p = Uint8List(32);
      final bd = p.buffer.asByteData();
      bd.setUint16(0, 0x0101);
      bd.setUint16(2, 12);
      p.setRange(4, 20, d.data.sublist(4, 20));
      bd.setUint16(20, 0x0020);
      bd.setUint16(22, 8);
      p[25] = 1;
      bd.setUint16(26, d.port ^ 0x2112);
      bd.setUint32(28, (127 << 24 | 1) ^ 0x2112A442);
      server.send(p, d.address, d.port);
    });
    final s = await DirectSocket.bind();
    final got = await stun(s, InternetAddress.loopbackIPv4, server.port);
    expect(got?.$2, s.port);
    s.close();
    server.close();
  });
}
