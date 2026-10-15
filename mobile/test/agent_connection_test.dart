// SPDX-License-Identifier: GPL-3.0-or-later
// Runs AgentConnection against a fake agent with real TLS on localhost:
// certificate pinning, the pair/hello → challenge → auth handshake, and
// the exact JSON the phone sends.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/pairing/codec.dart';
import 'package:pairdesk/pairing/discovery.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/laptop.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

const fixtures = 'test/fixtures';

List<int> pemToDer(String pem) =>
    base64.decode(pem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join());

final agentFingerprint = sha256
    .convert(pemToDer(File('$fixtures/test-agent-cert.pem').readAsStringSync()))
    .bytes;

/// A pretend computer that behaves like the Rust agent.
class FakeAgent {
  FakeAgent({this.cert = 'test-agent', this.token = 'TOKEN-1234567890ab'});

  final String cert;
  final String token;
  late HttpServer _server;
  final received = <Map<String, dynamic>>[];
  final paired = <String>{};
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;

  int get port => _server.port;

  Future<void> start() async {
    final ctx = SecurityContext()
      ..useCertificateChain('$fixtures/$cert-cert.pem')
      ..usePrivateKey('$fixtures/$cert-key.pem');
    _server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      socket = ws;
      List<int>? nonce;
      String? claimedId;
      var pairing = false;
      subscription = ws.listen((data) async {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(msg);
        void error(String code) {
          ws.add(jsonEncode({'t': 'error', 'code': code, 'msg': code}));
          ws.close();
        }

        switch (msg['t']) {
          case 'hello':
            if (!paired.contains(msg['id'])) return error('not_paired');
            claimedId = msg['id'] as String;
          case 'pair':
            if (msg['token'] != token) return error('bad_token');
            claimedId = msg['id'] as String;
            pairing = true;
          case 'auth':
            final ok = await Ed25519().verify(
              [
                ...utf8.encode('pairdesk-auth-v2'),
                0,
                ...agentFingerprint,
                ...nonce!,
                ...b64Decode(claimedId!)!,
              ],
              signature: Signature(
                b64Decode(msg['sig'] as String)!,
                publicKey: SimplePublicKey(b64Decode(claimedId!)!, type: KeyPairType.ed25519),
              ),
            );
            if (!ok) return error('bad_signature');
            if (pairing) paired.add(claimedId!);
            ws.add(
              jsonEncode({'t': 'welcome', 'name': 'test-laptop', 'os': 'windows', 'v': 2, 'paired': pairing}),
            );
            return;
          case 'ping':
            ws.add(jsonEncode({'t': 'pong'}));
            return;
          default:
            return;
        }
        nonce = List.generate(32, (i) => i * 7 % 256);
        ws.add(jsonEncode({'t': 'challenge', 'nonce': b64Encode(nonce!), 'v': 2}));
      });
    });
  }

  Future<void> stop() => _server.close(force: true);
}

class FakeFinder implements LaptopFinder {
  FakeFinder(this.result);
  final List<String> result;
  String? askedFor;
  @override
  Future<List<String>> find(String shortId, {Duration timeout = Duration.zero}) async {
    askedFor = shortId;
    return result;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

PairingInfo infoFor(FakeAgent agent, {List<int>? fingerprint, String? token}) => PairingInfo(
  name: 'test-laptop',
  fingerprint: Uint8List.fromList(fingerprint ?? agentFingerprint),
  token: token ?? agent.token,
  port: agent.port,
  addresses: ['127.0.0.1'],
);

void main() {
  late FakeAgent agent;
  late PhoneIdentity me;

  setUp(() async {
    agent = FakeAgent();
    await agent.start();
    me = await PhoneIdentity.fromSeed(List.filled(32, 3));
  });

  tearDown(() => agent.stop());

  test('pairs, then reconnects with a signature and sends input', () async {
    final conn = AgentConnection(pingInterval: const Duration(hours: 1));
    final laptop = await conn.pair(infoFor(agent), me, phoneName: 'Pixel 7');
    expect(conn.status, ConnectionStatus.connected);
    expect(agent.received.first, {'t': 'pair', 'v': 2, 'token': agent.token, 'id': me.id, 'name': 'Pixel 7'});
    expect(laptop.addresses.first, '127.0.0.1');
    expect(laptop.os, 'windows');
    await conn.disconnect();

    agent.received.clear();
    await conn.connect(laptop, me, phoneName: 'Pixel 7');
    expect(conn.status, ConnectionStatus.connected);
    expect(agent.received.first['t'], 'hello');
    expect(agent.received.first['id'], me.id);
    expect(agent.received[1]['t'], 'auth');

    conn.move(3, -2);
    conn.click(MouseBtn.right);
    conn.key(AgentKey.pageDown);
    await settle();
    expect(agent.received.sublist(2), [
      {'t': 'move', 'dx': 3, 'dy': -2},
      {'t': 'click', 'b': 'right'},
      {'t': 'key', 'k': 'page_down'},
    ]);
    await conn.disconnect();
  });

  test('refuses a computer with a different certificate', () async {
    final other = FakeAgent(cert: 'other');
    await other.start();
    final conn = AgentConnection();
    final err = await conn
        .pair(infoFor(other), me, phoneName: 'p')
        .then<AgentException?>((_) => null, onError: (Object e) => e as AgentException);
    expect(err?.kind, FailureKind.wrongComputer);
    expect(other.received, isEmpty, reason: 'nothing may be sent to an unverified computer');
    await other.stop();
  });

  test('reports a used or wrong pairing code', () async {
    final conn = AgentConnection();
    await expectLater(
      conn.pair(infoFor(agent, token: 'WRONG-0123456789ab'), me, phoneName: 'p'),
      throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.badToken)),
    );
    expect(conn.status, ConnectionStatus.disconnected);
  });

  test('reports when the computer no longer knows this phone', () async {
    final conn = AgentConnection();
    final laptop = Laptop(
      fingerprint: Uint8List.fromList(agentFingerprint),
      name: 'test-laptop',
      port: agent.port,
      addresses: ['127.0.0.1'],
    );
    await expectLater(
      conn.connect(laptop, me, phoneName: 'p'),
      throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.notPaired)),
    );
  });

  test('finds the computer at a new address through discovery', () async {
    final conn = AgentConnection(
      finder: FakeFinder(['127.0.0.1']),
      connectTimeout: const Duration(seconds: 1),
      pingInterval: const Duration(hours: 1),
    );
    final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
    await conn.disconnect();

    // The old address no longer answers (nothing listens on 127.0.0.2).
    laptop.addresses = ['127.0.0.2'];
    final finder = conn.finder as FakeFinder;
    await conn.connect(laptop, me, phoneName: 'p');
    expect(conn.status, ConnectionStatus.connected);
    expect(finder.askedFor, laptop.shortId);
    expect(laptop.addresses, ['127.0.0.1', '127.0.0.2']);
    await conn.disconnect();
  });

  test('unreachable computer gives a clear failure', () async {
    final laptop = Laptop(
      fingerprint: Uint8List.fromList(agentFingerprint),
      name: 'test-laptop',
      port: agent.port,
      addresses: ['127.0.0.2'],
    );
    final conn = AgentConnection(connectTimeout: const Duration(seconds: 1));
    await expectLater(
      conn.connect(laptop, me, phoneName: 'p'),
      throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.unreachable)),
    );
  });

  test('disconnects with not_paired when the computer removes the phone', () async {
    final conn = AgentConnection(pingInterval: const Duration(hours: 1));
    await conn.pair(infoFor(agent), me, phoneName: 'p');
    agent.socket!.add(jsonEncode({'t': 'error', 'code': 'not_paired', 'msg': 'removed'}));
    await settle();
    expect(conn.status, ConnectionStatus.disconnected);
    expect(conn.lastError?.kind, FailureKind.notPaired);
  });

  test('detects a silent computer', () async {
    final conn = AgentConnection(
      pingInterval: const Duration(milliseconds: 50),
      deadAfter: const Duration(milliseconds: 200),
    );
    await conn.pair(infoFor(agent), me, phoneName: 'p');
    // The computer stops reading, so pings go unanswered.
    agent.subscription!.pause();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(conn.status, ConnectionStatus.disconnected);
  });
}
