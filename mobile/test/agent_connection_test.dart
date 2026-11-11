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

  /// Null = an agent from before Phase 2 (no optional features).
  List<String>? features = ['combo', 'power', 'apps'];
  Map<String, bool> allow = {'power': true, 'session': false, 'apps': true};

  /// Addresses announced in welcome (Phase 3).
  List<String>? addrs;

  /// The agent's release (sent since 0.5.1).
  String? version;
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
              jsonEncode({
                't': 'welcome',
                'name': 'test-laptop',
                'os': 'windows',
                'v': 2,
                'paired': pairing,
                'features': ?features,
                'allow': allow,
                'addrs': ?addrs,
                'version': ?version,
              }),
            );
            return;
          case 'ping':
            ws.add(jsonEncode({'t': 'pong'}));
            return;
          case 'power':
            final ok =
                allow[msg['a'] == 'shut_down' || msg['a'] == 'restart' || msg['a'] == 'sign_out'
                    ? 'session'
                    : 'power']!;
            ws.add(
              jsonEncode({
                't': 'ack',
                'id': msg['id'],
                'ok': ok,
                if (!ok) 'code': 'not_allowed',
                if (!ok) 'msg': 'This is turned off in PairDesk settings on the computer.',
              }),
            );
            return;
          case 'screen_start':
            ws.add(
              jsonEncode({
                't': 'screen',
                'id': msg['id'],
                'monitors': [
                  {'index': 0, 'name': 'Display 1 (main)', 'width': 1920, 'height': 1080, 'primary': true},
                  {'index': 1, 'name': 'Display 2', 'width': 1280, 'height': 1024, 'primary': false},
                ],
                'monitor': msg['monitor'] ?? 0,
                'width': 1280,
                'height': 720,
              }),
            );
            // A cursor-only frame: "PDS1", seq 1, 1280x720, cursor (640, 360), no rects.
            final f = ByteData(18)
              ..setUint32(0, 0x31534450, Endian.little)
              ..setUint32(4, 1, Endian.little)
              ..setUint16(8, 1280, Endian.little)
              ..setUint16(10, 720, Endian.little)
              ..setInt16(12, 640, Endian.little)
              ..setInt16(14, 360, Endian.little)
              ..setUint16(16, 0, Endian.little);
            ws.add(f.buffer.asUint8List());
            return;
          case 'apps':
            ws.add(
              jsonEncode({
                't': 'apps',
                'id': msg['id'],
                'shortcuts': [
                  {'id': 's1', 'name': 'Mail', 'kind': 'url'},
                ],
                'apps': [
                  {'id': 'a1', 'name': 'Calculator', 'kind': 'app'},
                  {'bad': 'entry'},
                ],
              }),
            );
            return;
          case 'launch':
            final known = msg['app'] == 'a1' || msg['app'] == 's1';
            ws.add(
              jsonEncode({
                't': 'ack',
                'id': msg['id'],
                'ok': known,
                if (!known) 'code': 'not_found',
                if (!known) 'msg': 'That app isn\'t on the computer any more.',
              }),
            );
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

  test('reconnects by itself when the computer goes quiet', () async {
    final conn = AgentConnection(
      pingInterval: const Duration(milliseconds: 50),
      deadAfter: const Duration(milliseconds: 200),
    );
    final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
    await conn.disconnect();
    await conn.connect(laptop, me, phoneName: 'p');
    expect(conn.status, ConnectionStatus.connected);
    final first = agent.socket!;
    // The computer's socket stops answering, then the phone comes back.
    agent.subscription!.pause();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(conn.status, ConnectionStatus.connected);
    expect(identical(agent.socket, first), isFalse);
    expect(conn.lastError, isNull);
    await conn.disconnect();
  });

  test('closing it yourself does not reconnect', () async {
    final conn = AgentConnection(pingInterval: const Duration(milliseconds: 50));
    final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
    await conn.disconnect();
    await conn.connect(laptop, me, phoneName: 'p');
    await conn.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(conn.status, ConnectionStatus.disconnected);
  });

  group('phase 2 requests', () {
    late AgentConnection conn;
    setUp(() async {
      conn = AgentConnection(pingInterval: const Duration(hours: 1));
      await conn.pair(infoFor(agent), me, phoneName: 'p');
    });
    tearDown(() => conn.disconnect());

    test('reads features and permissions from welcome', () {
      expect(conn.features, {'combo', 'power', 'apps'});
      expect(conn.allowed.power, isTrue);
      expect(conn.allowed.session, isFalse);
      expect(conn.allowed.action(PowerAction.lock), isTrue);
      expect(conn.allowed.action(PowerAction.restart), isFalse);
    });

    test('sends shortcuts as combo messages', () async {
      agent.received.clear();
      conn.combo([Modifier.ctrl, Modifier.shift], key: AgentKey.escape);
      conn.combo([Modifier.ctrl], char: 'c');
      conn.combo([Modifier.meta]);
      await settle();
      expect(agent.received, [
        {
          't': 'combo',
          'mods': ['ctrl', 'shift'],
          'k': 'escape',
        },
        {
          't': 'combo',
          'mods': ['ctrl'],
          'c': 'c',
        },
        {
          't': 'combo',
          'mods': ['meta'],
        },
      ]);
    });

    test('power actions report refusals', () async {
      await conn.power(PowerAction.lock);
      await expectLater(
        conn.power(PowerAction.shutDown),
        throwsA(isA<RequestException>().having((e) => e.code, 'code', 'not_allowed')),
      );
      final sent = agent.received.where((m) => m['t'] == 'power').toList();
      expect(sent.map((m) => m['a']), ['lock', 'shut_down']);
      expect(sent[0]['id'], isNot(sent[1]['id']), reason: 'each request has its own id');
    });

    test('lists and launches apps', () async {
      final list = await conn.fetchApps();
      expect(list.shortcuts.single.name, 'Mail');
      expect(list.apps.map((a) => a.name), ['Calculator'], reason: 'malformed entries are skipped');
      await conn.launch('a1');
      await expectLater(
        conn.launch('gone'),
        throwsA(isA<RequestException>().having((e) => e.code, 'code', 'not_found')),
      );
    });
  });

  test('older computers without Phase 2 features are reported clearly', () async {
    agent.features = null;
    final conn = AgentConnection(pingInterval: const Duration(hours: 1));
    final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
    expect(conn.features, isEmpty);
    expect(conn.agentVersion, isNull);
    await expectLater(
      conn.power(PowerAction.lock),
      throwsA(
        isA<RequestException>()
            .having((e) => e.code, 'code', 'unsupported')
            .having((e) => e.message, 'message', contains('Stop PairDesk'))
            .having((e) => e.message, 'message', contains('next to the clock')),
      ),
    );
    await conn.disconnect();

    // A newer agent says which release it is.
    agent.version = '0.5.1';
    await conn.connect(laptop, me, phoneName: 'p');
    expect(conn.agentVersion, '0.5.1');
    expect(conn.outdatedComputerMessage(), contains('PairDesk 0.5.1'));
    await conn.disconnect();
  });

  test('notices from the computer reach the app', () async {
    final conn = AgentConnection(pingInterval: const Duration(hours: 1));
    await conn.pair(infoFor(agent), me, phoneName: 'p');
    final got = conn.notices.first;
    agent.socket!.add(jsonEncode({'t': 'notice', 'msg': 'Approve PairDesk on the computer.'}));
    expect(await got.timeout(const Duration(seconds: 2)), 'Approve PairDesk on the computer.');
    await conn.disconnect();
  });

  test('pending requests fail when the connection drops', () async {
    agent.allow = {'power': true, 'session': true, 'apps': true};
    final conn = AgentConnection(pingInterval: const Duration(hours: 1));
    await conn.pair(infoFor(agent), me, phoneName: 'p');
    agent.subscription!.pause(); // never answers
    final pending = expectLater(
      conn.fetchApps(),
      throwsA(isA<RequestException>().having((e) => e.code, 'code', 'disconnected')),
    );
    await settle();
    await conn.disconnect();
    await pending;
  });

  group('phase 3: reaching the computer from anywhere', () {
    test('recognises Tailscale addresses and names', () {
      expect(isTailscaleHost('100.101.102.103'), isTrue);
      expect(isTailscaleHost('100.64.0.1'), isTrue);
      expect(isTailscaleHost('100.128.0.1'), isFalse);
      expect(isTailscaleHost('192.168.1.5'), isFalse);
      expect(isTailscaleHost('sandun-pc.tail1234.ts.net'), isTrue);
      expect(isUsableHost('sandun-pc.tail1234.ts.net'), isTrue);
      expect(isUsableHost('evil.example.com'), isFalse);
      expect(isUsableHost('127.0.0.1'), isFalse);
      expect(isUsableHost('::1'), isFalse);
    });

    test('a hanging address does not hold up a working one', () async {
      // Accepts TCP but never answers TLS, like a stale address on another network.
      final blackhole = await ServerSocket.bind('127.0.0.3', agent.port);
      final held = <Socket>[];
      blackhole.listen(held.add);
      final conn = AgentConnection(
        connectTimeout: const Duration(seconds: 6),
        pingInterval: const Duration(hours: 1),
      );
      final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
      await conn.disconnect();
      laptop.addresses = ['127.0.0.3', '127.0.0.1'];

      final watch = Stopwatch()..start();
      await conn.connect(laptop, me, phoneName: 'p');
      watch.stop();
      expect(conn.address, '127.0.0.1');
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'did not wait 6 s for the dead address',
      );
      expect(laptop.addresses.first, '127.0.0.1');
      await conn.disconnect();
      for (final s in held) {
        s.destroy();
      }
      await blackhole.close();
    });

    test('cancel stops a slow connection attempt straight away', () async {
      final blackhole = await ServerSocket.bind('127.0.0.3', agent.port);
      blackhole.listen((_) {});
      final conn = AgentConnection(connectTimeout: const Duration(seconds: 10));
      final laptop = Laptop(
        fingerprint: Uint8List.fromList(agentFingerprint),
        name: 'test-laptop',
        port: agent.port,
        addresses: ['127.0.0.3'],
      );
      final watch = Stopwatch()..start();
      final attempt = expectLater(
        conn.connect(laptop, me, phoneName: 'p'),
        throwsA(isA<AgentException>().having((e) => e.kind, 'kind', FailureKind.cancelled)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await conn.cancel();
      await attempt;
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await blackhole.close();
    });

    test('learns the computer\'s other addresses, such as Tailscale', () async {
      agent.addrs = [
        '192.168.1.50',
        '100.101.102.103',
        'pc.tail1234.ts.net',
        '127.0.0.1',
        'evil.example.com',
        '::1',
      ];
      final conn = AgentConnection(pingInterval: const Duration(milliseconds: 100));
      final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
      expect(laptop.addresses, ['127.0.0.1', '192.168.1.50', '100.101.102.103', 'pc.tail1234.ts.net']);
      expect(laptop.reachableAnywhere, isTrue);
      expect(conn.viaTailscale, isFalse);

      // Survives a save and reload.
      expect(Laptop.fromJson(laptop.toJson())!.reachableAnywhere, isTrue);

      // Latency is measured from ping to pong.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(conn.latency, isNotNull);
      expect(conn.latency!, lessThan(const Duration(seconds: 1)));
      await conn.disconnect();
      expect(conn.latency, isNull);
    });

    test('learns a Tailscale address that appears while connected', () async {
      agent.addrs = ['192.168.1.50'];
      final conn = AgentConnection(pingInterval: const Duration(milliseconds: 100));
      final laptop = await conn.pair(infoFor(agent), me, phoneName: 'p');
      expect(laptop.reachableAnywhere, isFalse);

      final saved = expectLater(conn.addressUpdates.first, completes);
      // Tailscale comes up on the computer after the phone connected.
      agent.socket!.add(
        jsonEncode({
          't': 'addrs',
          'addrs': ['192.168.1.50', '100.101.102.103', 'pc.tail1234.ts.net', 'evil.example.com'],
        }),
      );
      await saved;

      expect(laptop.addresses, contains('100.101.102.103'));
      expect(laptop.addresses, contains('pc.tail1234.ts.net'));
      expect(laptop.addresses, isNot(contains('evil.example.com')));
      expect(laptop.reachableAnywhere, isTrue);
      await conn.disconnect();
    });

    test('keeps at most eight addresses, newest first', () {
      final l = Laptop(
        fingerprint: Uint8List(32),
        name: 'x',
        port: 1,
        addresses: [for (var i = 0; i < 8; i++) '10.0.0.$i'],
      );
      l.learnAddresses(working: '10.0.0.5', fromComputer: ['100.64.0.1', '10.0.0.9']);
      expect(l.addresses.length, Laptop.maxAddresses);
      expect(l.addresses.take(3), ['10.0.0.5', '100.64.0.1', '10.0.0.9']);
      // A relay route is always kept, last, and the computer's newest wins.
      l.learnAddresses(working: '10.0.0.5', fromComputer: ['relay:r.example.org:443/${'a' * 32}']);
      l.learnAddresses(
        working: '10.0.0.1',
        fromComputer: ['10.0.0.2', 'relay:r.example.org:443/${'b' * 32}'],
      );
      expect(l.addresses.length, Laptop.maxAddresses);
      expect(l.addresses.last, 'relay:r.example.org:443/${'b' * 32}');
      expect(l.addresses.where((a) => a.startsWith('relay:')), hasLength(1));
      expect(l.reachableAnywhere, isTrue);
    });
  });

  test('screen view: start, frames, acks and pointing', () async {
    agent.features = ['combo', 'power', 'apps', 'screen'];
    final conn = AgentConnection(pingInterval: const Duration(hours: 1));
    await conn.pair(infoFor(agent), me, phoneName: 'p');
    final firstFrame = conn.screenFrames.first;
    final info = await conn.startScreen(quality: 'low');
    expect((info.width, info.height), (1280, 720));
    expect(info.monitors.map((m) => m.name), ['Display 1 (main)', 'Display 2']);
    final frame = await firstFrame.timeout(const Duration(seconds: 2));
    expect(frame.seq, 1);
    expect((frame.cursorX, frame.cursorY), (640, 360));

    agent.received.clear();
    conn.ackScreen(1);
    conn.moveTo(0.25, 0.75);
    conn.stopScreen();
    await settle();
    expect(agent.received, [
      {'t': 'screen_ack', 'seq': 1},
      {'t': 'move_to', 'x': 0.25, 'y': 0.75},
      {'t': 'screen_stop'},
    ]);
    expect(agent.received.first.containsKey('id'), isFalse);
    await conn.disconnect();
  });
}
