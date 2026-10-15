// SPDX-License-Identifier: GPL-3.0-or-later
// Connection from the phone to the PairDesk desktop agent.
//
// Phase 0: plain WebSocket on the local network, no pairing or encryption.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const int protocolVersion = 1;
const int defaultAgentPort = 47800;

enum ConnectionStatus { disconnected, connecting, connected }

/// Mouse buttons understood by the agent.
enum MouseBtn { left, right, middle }

/// Named keys understood by the agent (see docs/PROTOCOL.md).
enum AgentKey {
  enter('enter'),
  backspace('backspace'),
  escape('escape'),
  tab('tab'),
  space('space'),
  delete('delete'),
  up('up'),
  down('down'),
  left('left'),
  right('right'),
  home('home'),
  end('end'),
  pageUp('page_up'),
  pageDown('page_down'),
  volumeUp('volume_up'),
  volumeDown('volume_down'),
  mute('mute'),
  playPause('play_pause'),
  next('next'),
  prev('prev');

  const AgentKey(this.wire);
  final String wire;
}

class AgentConnection extends ChangeNotifier {
  AgentConnection({
    this.connectTimeout = const Duration(seconds: 5),
    this.pingInterval = const Duration(seconds: 3),
    this.deadAfter = const Duration(seconds: 10),
  });

  final Duration connectTimeout;
  final Duration pingInterval;
  final Duration deadAfter;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  DateTime _lastHeard = DateTime.now();

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  String? _agentName;
  String? get agentName => _agentName;

  String? _agentOs;
  String? get agentOs => _agentOs;

  String? _lastError;
  String? get lastError => _lastError;

  /// Connects to `host:port` and waits for the agent's hello.
  /// Returns normally on success; throws a readable message on failure.
  Future<void> connect(String host, int port) async {
    await disconnect(notify: false);
    _status = ConnectionStatus.connecting;
    _lastError = null;
    notifyListeners();

    final uri = Uri(scheme: 'ws', host: host, port: port);
    final hello = Completer<void>();
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready.timeout(connectTimeout);

      _sub = channel.stream.listen(
        (data) {
          _lastHeard = DateTime.now();
          if (data is! String) return;
          final Object? msg;
          try {
            msg = jsonDecode(data);
          } on FormatException {
            return;
          }
          if (msg is! Map<String, dynamic>) return;
          switch (msg['t']) {
            case 'hello':
              _agentName = msg['name'] as String?;
              _agentOs = msg['os'] as String?;
              if (!hello.isCompleted) hello.complete();
            case 'error':
              debugPrint('agent error: ${msg['msg']}');
          }
        },
        onError: (Object e) => _lost('Connection error: $e'),
        onDone: () => _lost('The laptop closed the connection.'),
        cancelOnError: true,
      );

      _send({'t': 'hello', 'name': 'PairDesk phone', 'v': protocolVersion});
      await hello.future.timeout(connectTimeout);
    } on TimeoutException {
      await disconnect(notify: false);
      _fail('No answer from $host:$port. Is the agent running and on the same Wi-Fi?');
      throw _lastError!;
    } catch (e) {
      await disconnect(notify: false);
      _fail('Could not connect to $host:$port ($e).');
      throw _lastError!;
    }

    _status = ConnectionStatus.connected;
    _lastHeard = DateTime.now();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (DateTime.now().difference(_lastHeard) > deadAfter) {
        _lost('The laptop stopped answering.');
        return;
      }
      _send({'t': 'ping'});
    });
    notifyListeners();
  }

  Future<void> disconnect({bool notify = true}) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _sub?.cancel();
    _sub = null;
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await ch.sink.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    _status = ConnectionStatus.disconnected;
    if (notify) notifyListeners();
  }

  void _fail(String message) {
    _lastError = message;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  void _lost(String message) {
    if (_status == ConnectionStatus.disconnected) return;
    disconnect(notify: false);
    _fail(message);
  }

  void _send(Map<String, Object?> msg) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(msg));
    } catch (e) {
      _lost('Send failed: $e');
    }
  }

  // ---- Commands -------------------------------------------------------

  void move(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    _send({'t': 'move', 'dx': dx, 'dy': dy});
  }

  void click(MouseBtn b) => _send({'t': 'click', 'b': b.name});
  void buttonDown(MouseBtn b) => _send({'t': 'down', 'b': b.name});
  void buttonUp(MouseBtn b) => _send({'t': 'up', 'b': b.name});

  void scroll({int dx = 0, int dy = 0}) {
    if (dx == 0 && dy == 0) return;
    _send({'t': 'scroll', 'dx': dx, 'dy': dy});
  }

  void typeText(String s) {
    if (s.isEmpty) return;
    _send({'t': 'text', 's': s});
  }

  void key(AgentKey k) => _send({'t': 'key', 'k': k.wire});

  @override
  void dispose() {
    disconnect(notify: false);
    super.dispose();
  }
}
