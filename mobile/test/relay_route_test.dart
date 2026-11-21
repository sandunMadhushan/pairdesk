// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's side of the relay: TLS to the relay when it speaks it, the
// plain protocol otherwise.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/pairing/relay_route.dart';

final _id = 'ab' * 16;

/// Answers `PDR1 CONNECT <id>` with `OK`, then echoes what it receives.
void _serve(Stream<Socket> sockets, List<String> seen) {
  sockets.listen((s) {
    final buf = StringBuffer();
    var answered = false;
    s.listen(
      (data) {
        if (answered) return s.add(data);
        buf.write(latin1.decode(data));
        final text = buf.toString();
        final nl = text.indexOf('\n');
        if (nl < 0) return;
        answered = true;
        seen.add(text.substring(0, nl));
        s.add(utf8.encode('OK\n'));
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }, onError: (Object _) {});
}

Future<void> _roundTrip(int port) async {
  final c = await Socket.connect(InternetAddress.loopbackIPv4, port);
  c.add(utf8.encode('hello'));
  final got = await c.first.timeout(const Duration(seconds: 5));
  expect(utf8.decode(got), 'hello');
  c.destroy();
}

void main() {
  setUp(forgetPlainRelays);

  test('parses and prints relay routes', () {
    final r = RelayRoute.tryParse('relay:relay.example.org:443/$_id')!;
    expect((r.host, r.port, r.id), ('relay.example.org', 443, _id));
    expect(r.toString(), 'relay:relay.example.org:443/$_id');
    expect(RelayRoute.tryParse('relay:host:99999/$_id'), isNull);
    expect(RelayRoute.tryParse('relay:host:443/short'), isNull);
  });

  test('falls back to the plain protocol, and remembers that', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    var connections = 0;
    _serve(
      server.map((s) {
        connections++;
        return s;
      }),
      seen,
    );
    // "localhost" is a name, so TLS is tried first; this relay is plain.
    final route = RelayRoute('localhost', server.port, _id);
    const tls = Duration(milliseconds: 300);

    await _roundTrip(await openRelayTunnel(route, timeout: const Duration(seconds: 5), tlsTimeout: tls));
    // (The plain server also "reads" the TLS hello as a garbage line.)
    expect(seen.last, 'PDR1 CONNECT $_id');
    expect(connections, 2, reason: 'one failed TLS attempt, then plain');

    await _roundTrip(await openRelayTunnel(route, timeout: const Duration(seconds: 5), tlsTimeout: tls));
    expect(connections, 3, reason: 'plain remembered: no second TLS attempt');
    await server.close();
  });

  test('an IP address goes straight to the plain protocol', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    var connections = 0;
    _serve(
      server.map((s) {
        connections++;
        return s;
      }),
      seen,
    );
    final route = RelayRoute('127.0.0.1', server.port, _id);
    await _roundTrip(await openRelayTunnel(route, timeout: const Duration(seconds: 5)));
    expect(connections, 1);
    await server.close();
  });

  test('refusals from the relay are explained', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      s.listen((_) {
        s.add(utf8.encode('ERR offline\n'));
      }, onError: (Object _) {});
    });
    final route = RelayRoute('127.0.0.1', server.port, _id);
    await expectLater(
      openRelayTunnel(route, timeout: const Duration(seconds: 5)),
      throwsA(isA<RelayRefused>().having((e) => e.message, 'message', contains('isn\'t connected'))),
    );
    await server.close();
  });

  test('the check tells a down relay from an offline computer', () async {
    final online = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _serve(online, []);
    final offline = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    offline.listen((s) {
      s.listen((_) => s.add(utf8.encode('ERR offline\n')), onError: (Object _) {});
    });
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();

    expect((await checkRelay(RelayRoute('127.0.0.1', online.port, _id))).state, RelayState.computerOnline);
    expect((await checkRelay(RelayRoute('127.0.0.1', offline.port, _id))).state, RelayState.computerOffline);
    expect((await checkRelay(RelayRoute('127.0.0.1', closedPort, _id))).state, RelayState.relayDown);
    await online.close();
    await offline.close();
  });

  test('speaks TLS to a relay that does', () async {
    final dir = await Directory.systemTemp.createTemp('pd-relay-tls');
    addTearDown(() => dir.delete(recursive: true));
    final key = '${dir.path}/key.pem';
    final cert = '${dir.path}/cert.pem';
    final made = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, //
      '-days', '2', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
    ]);
    if (made.exitCode != 0) {
      markTestSkipped('openssl not available');
      return;
    }
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key),
    );
    final seen = <String>[];
    var connections = 0;
    _serve(
      server.map((s) {
        connections++;
        return s;
      }),
      seen,
    );
    final trust = SecurityContext(withTrustedRoots: false)..setTrustedCertificates(cert);
    final route = RelayRoute('localhost', server.port, _id);
    await _roundTrip(await openRelayTunnel(route, timeout: const Duration(seconds: 5), tlsContext: trust));
    expect(seen, ['PDR1 CONNECT $_id']);
    expect(connections, 1, reason: 'TLS worked first time, no plain attempt');
    await server.close();
  });
}
