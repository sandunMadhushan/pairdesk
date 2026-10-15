// SPDX-License-Identifier: GPL-3.0-or-later
// Runs AgentConnection against a fake agent on localhost and checks the exact
// JSON it sends, so the phone and docs/PROTOCOL.md stay in step.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';

class FakeAgent {
  late HttpServer _server;
  final received = <Map<String, dynamic>>[];
  WebSocket? socket;
  bool answerHello = true;

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      socket = ws;
      ws.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(msg);
        if (msg['t'] == 'hello' && answerHello) {
          ws.add(jsonEncode({'t': 'hello', 'name': 'test-laptop', 'os': 'windows', 'v': 1}));
        } else if (msg['t'] == 'ping') {
          ws.add(jsonEncode({'t': 'pong'}));
        }
      });
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late FakeAgent agent;

  setUp(() async {
    agent = FakeAgent();
    await agent.start();
  });

  tearDown(() => agent.stop());

  test('connects, learns the agent name and sends protocol messages', () async {
    final conn = AgentConnection();
    await conn.connect('127.0.0.1', agent.port);
    expect(conn.status, ConnectionStatus.connected);
    expect(conn.agentName, 'test-laptop');

    conn.move(4, -2);
    conn.move(0, 0); // ignored
    conn.click(MouseBtn.right);
    conn.buttonDown(MouseBtn.left);
    conn.buttonUp(MouseBtn.left);
    conn.scroll(dy: 3);
    conn.typeText('hello');
    conn.typeText(''); // ignored
    conn.key(AgentKey.pageDown);
    await settle();

    expect(agent.received, [
      {'t': 'hello', 'name': 'PairDesk phone', 'v': 1},
      {'t': 'move', 'dx': 4, 'dy': -2},
      {'t': 'click', 'b': 'right'},
      {'t': 'down', 'b': 'left'},
      {'t': 'up', 'b': 'left'},
      {'t': 'scroll', 'dx': 0, 'dy': 3},
      {'t': 'text', 's': 'hello'},
      {'t': 'key', 'k': 'page_down'},
    ]);
    await conn.disconnect();
    expect(conn.status, ConnectionStatus.disconnected);
  });

  test('fails with a readable message when nothing is listening', () async {
    final port = agent.port;
    await agent.stop();
    final conn = AgentConnection(connectTimeout: const Duration(seconds: 2));
    await expectLater(conn.connect('127.0.0.1', port), throwsA(isA<String>()));
    expect(conn.status, ConnectionStatus.disconnected);
    expect(conn.lastError, contains('127.0.0.1:$port'));
  });

  test('fails when the other side never says hello', () async {
    agent.answerHello = false;
    final conn = AgentConnection(connectTimeout: const Duration(milliseconds: 500));
    await expectLater(conn.connect('127.0.0.1', agent.port), throwsA(isA<String>()));
    expect(conn.lastError, contains('No answer'));
  });

  test('notices when the laptop goes away', () async {
    final conn = AgentConnection();
    await conn.connect('127.0.0.1', agent.port);
    final dropped = Completer<void>();
    conn.addListener(() {
      if (conn.status == ConnectionStatus.disconnected && !dropped.isCompleted) dropped.complete();
    });
    await agent.socket!.close();
    await dropped.future.timeout(const Duration(seconds: 2));
    expect(conn.lastError, isNotNull);
  });
}
