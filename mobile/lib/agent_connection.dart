// SPDX-License-Identifier: GPL-3.0-or-later
// Connection from the phone to the PairDesk desktop agent.
//
// Every connection is TLS, and the phone accepts exactly one certificate:
// the one whose SHA-256 fingerprint it got from the pairing QR code. The
// phone then proves who it is by signing the computer's challenge with
// its private key. See docs/PROTOCOL.md.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'pairing/codec.dart';
import 'pairing/discovery.dart';
import 'pairing/identity.dart';
import 'pairing/laptop.dart';
import 'pairing/pairing_link.dart';

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
  prev('prev'),
  insert('insert'),
  printScreen('print_screen'),
  f1('f1'),
  f2('f2'),
  f3('f3'),
  f4('f4'),
  f5('f5'),
  f6('f6'),
  f7('f7'),
  f8('f8'),
  f9('f9'),
  f10('f10'),
  f11('f11'),
  f12('f12');

  const AgentKey(this.wire);
  final String wire;
}

/// Why connecting or pairing failed.
enum FailureKind {
  /// Nothing answered at any known address.
  unreachable,

  /// Something answered, but with a different certificate.
  wrongComputer,

  /// The computer no longer knows this phone.
  notPaired,

  /// The pairing code is used, replaced or expired.
  badToken,

  /// App and computer speak different protocol versions.
  version,

  /// The user cancelled.
  cancelled,

  /// Anything else (bad signature, unexpected answer).
  other,
}

class AgentException implements Exception {
  AgentException(this.kind, this.message);
  final FailureKind kind;
  final String message;
  @override
  String toString() => message;

  static AgentException fromServer(Map<String, dynamic> msg) {
    final text = msg['msg'] as String? ?? 'The computer refused the connection.';
    final kind = switch (msg['code']) {
      'not_paired' => FailureKind.notPaired,
      'bad_token' => FailureKind.badToken,
      'version' => FailureKind.version,
      _ => FailureKind.other,
    };
    return AgentException(kind, text);
  }
}

/// Opens a WebSocket over TLS that only accepts the pinned certificate.
/// Exposed for tests.
@visibleForTesting
Future<IOWebSocketChannel> openPinnedChannel(
  String host,
  int port,
  List<int> fingerprint, {
  required Duration timeout,
}) async {
  var mismatch = false;
  // No trusted roots at all: every certificate goes through the callback,
  // so a certificate signed by some public authority can't sneak past the pin.
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = timeout
    ..badCertificateCallback = (cert, _, _) {
      final ok = bytesEqual(sha256.convert(cert.der).bytes, fingerprint);
      if (!ok) mismatch = true;
      return ok;
    };
  final uri = Uri(scheme: 'wss', host: host, port: port, path: '/');
  try {
    final ws = await WebSocket.connect(uri.toString(), customClient: client).timeout(timeout);
    return IOWebSocketChannel(ws);
  } catch (e) {
    client.close(force: true);
    if (mismatch) {
      throw AgentException(FailureKind.wrongComputer, 'The device at $host is not the computer you paired.');
    }
    throw AgentException(FailureKind.unreachable, 'No answer from $host:$port.');
  }
}

/// Modifier keys for shortcuts.
enum Modifier { ctrl, alt, shift, meta }

/// Power and session actions.
enum PowerAction {
  lock('lock'),
  sleep('sleep'),
  screenOff('screen_off'),
  signOut('sign_out'),
  restart('restart'),
  shutDown('shut_down');

  const PowerAction(this.wire);
  final String wire;

  /// Sign out, restart and shut down can lose unsaved work.
  bool get endsSession => this == signOut || this == restart || this == shutDown;
}

/// What the computer's owner allows (from `welcome`).
class Allowed {
  const Allowed({this.power = false, this.session = false, this.apps = false});
  final bool power;
  final bool session;
  final bool apps;

  bool action(PowerAction a) => a.endsSession ? session : power;

  static Allowed fromJson(Object? j) => j is Map
      ? Allowed(power: j['power'] == true, session: j['session'] == true, apps: j['apps'] == true)
      : const Allowed();
}

/// An app or shortcut the computer can open.
class RemoteApp {
  const RemoteApp({required this.id, required this.name, required this.kind});
  final String id;
  final String name;

  /// `app`, `url`, `folder`, `file` or `program`.
  final String kind;

  static List<RemoteApp> listFrom(Object? j) => [
    if (j is List)
      for (final e in j)
        if (e is Map && e['id'] is String && e['name'] is String)
          RemoteApp(id: e['id'] as String, name: e['name'] as String, kind: e['kind'] as String? ?? 'app'),
  ];
}

class AppsList {
  const AppsList({required this.shortcuts, required this.apps});
  final List<RemoteApp> shortcuts;
  final List<RemoteApp> apps;
}

/// A refused or failed request.
class RequestException implements Exception {
  RequestException(this.code, this.message);

  /// `not_allowed`, `not_found`, `failed`, `timeout`, `unsupported` or `disconnected`.
  final String code;
  final String message;
  @override
  String toString() => message;
}

class AgentConnection extends ChangeNotifier {
  AgentConnection({
    this.finder,
    this.connectTimeout = const Duration(seconds: 3),
    this.replyTimeout = const Duration(seconds: 8),
    this.pingInterval = const Duration(seconds: 3),
    this.deadAfter = const Duration(seconds: 10),
  });

  /// Finds a computer whose address changed. Null disables discovery.
  final LaptopFinder? finder;
  final Duration connectTimeout;
  final Duration replyTimeout;
  final Duration pingInterval;
  final Duration deadAfter;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  DateTime _lastHeard = DateTime.now();
  Completer<Map<String, dynamic>>? _reply;
  bool _cancelRequested = false;

  /// Set when the connection drops during the handshake.
  AgentException? _handshakeLost;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  /// What the app is doing while connecting, for the progress text.
  String? _progress;
  String? get progress => _progress;

  String? _agentName;
  String? get agentName => _agentName;

  String? _agentOs;
  String? get agentOs => _agentOs;

  Set<String> _features = const {};

  /// Optional features the computer supports (`combo`, `power`, `apps`).
  Set<String> get features => _features;

  Allowed _allowed = const Allowed();
  Allowed get allowed => _allowed;

  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _requests = {};

  String? _address;
  String? get address => _address;

  /// Why the last connection ended, if it ended badly.
  AgentException? _lastError;
  AgentException? get lastError => _lastError;

  // ---- Pairing and connecting -----------------------------------------

  /// Pairs with the computer from a scanned QR code and stays connected.
  /// Returns the computer to save.
  Future<Laptop> pair(PairingInfo info, PhoneIdentity me, {required String phoneName}) async {
    final laptop = Laptop(
      fingerprint: info.fingerprint,
      name: info.name,
      port: info.port,
      addresses: info.addresses,
    );
    await _connectAny(
      laptop,
      me,
      first: {'t': 'pair', 'v': protocolVersion, 'token': info.token, 'id': me.id, 'name': phoneName},
      useDiscovery: false,
    );
    return laptop;
  }

  /// Connects to a paired computer. Tries the addresses that worked
  /// before, then looks for it on the network. Updates [laptop] with the
  /// address that worked and the computer's current name.
  Future<void> connect(Laptop laptop, PhoneIdentity me, {required String phoneName}) {
    return _connectAny(
      laptop,
      me,
      first: {'t': 'hello', 'v': protocolVersion, 'id': me.id, 'name': phoneName},
      useDiscovery: true,
    );
  }

  Future<void> _connectAny(
    Laptop laptop,
    PhoneIdentity me, {
    required Map<String, Object?> first,
    required bool useDiscovery,
  }) async {
    await disconnect(notify: false);
    _cancelRequested = false;
    _status = ConnectionStatus.connecting;
    _lastError = null;
    _setProgress('Connecting to ${laptop.name}…');

    AgentException? best;
    Future<bool> tryAll(List<String> addresses) async {
      for (final host in addresses) {
        if (_cancelRequested) {
          _fail(AgentException(FailureKind.cancelled, 'Cancelled.'));
        }
        try {
          await _open(host, laptop, me, first);
          return true;
        } on AgentException catch (e) {
          // A definite answer from the right computer ends the search.
          if (e.kind != FailureKind.unreachable && e.kind != FailureKind.wrongComputer) {
            await disconnect(notify: false);
            _fail(e);
          }
          if (best == null || e.kind == FailureKind.wrongComputer) best = e;
          await disconnect(notify: false);
        }
      }
      return false;
    }

    var ok = await tryAll(laptop.addresses);
    if (!ok && useDiscovery && finder != null) {
      _setProgress('Looking for ${laptop.name} on this Wi-Fi…');
      final found = await finder!.find(laptop.shortId);
      final fresh = found.where((a) => !laptop.addresses.contains(a)).toList();
      ok = await tryAll(fresh);
    }
    if (_cancelRequested) _fail(AgentException(FailureKind.cancelled, 'Cancelled.'));
    if (!ok) {
      _fail(best ?? AgentException(FailureKind.unreachable, 'No address known for ${laptop.name}.'));
    }

    laptop
      ..rememberAddress(_address!)
      ..name = _agentName ?? laptop.name
      ..os = _agentOs ?? laptop.os
      ..lastUsed = DateTime.now().millisecondsSinceEpoch;

    _status = ConnectionStatus.connected;
    _progress = null;
    _lastHeard = DateTime.now();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (DateTime.now().difference(_lastHeard) > deadAfter) {
        _lost(AgentException(FailureKind.unreachable, 'The computer stopped answering.'));
        return;
      }
      _send({'t': 'ping'});
    });
    notifyListeners();
  }

  /// One attempt at one address: TLS + pin, then hello/pair, challenge, auth.
  Future<void> _open(String host, Laptop laptop, PhoneIdentity me, Map<String, Object?> first) async {
    final channel = await openPinnedChannel(host, laptop.port, laptop.fingerprint, timeout: connectTimeout);
    _channel = channel;
    _handshakeLost = null;
    _sub = channel.stream.listen(
      _onData,
      onError: (Object e) => _lost(AgentException(FailureKind.unreachable, 'Connection error: $e')),
      onDone: () => _lost(AgentException(FailureKind.unreachable, 'The computer closed the connection.')),
      cancelOnError: true,
    );

    _send(first);
    final challenge = await _nextReply();
    if (challenge['t'] != 'challenge') throw _unexpected(challenge);
    final nonce = b64Decode(challenge['nonce'] as String? ?? '');
    if (nonce == null || nonce.length != 32) throw _unexpected(challenge);

    _send({'t': 'auth', 'sig': await me.signChallenge(laptop.fingerprint, nonce)});
    final welcome = await _nextReply();
    if (welcome['t'] != 'welcome') throw _unexpected(welcome);
    _agentName = welcome['name'] as String?;
    _agentOs = welcome['os'] as String?;
    _features = {
      if (welcome['features'] is List)
        for (final f in welcome['features'] as List)
          if (f is String) f,
    };
    _allowed = Allowed.fromJson(welcome['allow']);
    _address = host;
  }

  AgentException _unexpected(Map<String, dynamic> msg) => msg['t'] == 'error'
      ? AgentException.fromServer(msg)
      : AgentException(FailureKind.other, 'Unexpected answer from the computer.');

  Future<Map<String, dynamic>> _nextReply() {
    final lost = _handshakeLost;
    if (lost != null) return Future.error(lost);
    final c = Completer<Map<String, dynamic>>();
    _reply = c;
    return c.future.timeout(
      replyTimeout,
      onTimeout: () => throw AgentException(FailureKind.unreachable, 'The computer didn\'t answer.'),
    );
  }

  void _onData(dynamic data) {
    _lastHeard = DateTime.now();
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    final id = decoded['id'];
    if (id is int && (decoded['t'] == 'ack' || decoded['t'] == 'apps')) {
      _requests.remove(id)?.complete(decoded);
      return;
    }

    final waiting = _reply;
    if (waiting != null && !waiting.isCompleted) {
      _reply = null;
      waiting.complete(decoded);
      return;
    }
    if (decoded['t'] == 'error') {
      if (decoded['code'] == 'bad_message') {
        debugPrint('agent: ${decoded['msg']}');
      } else {
        _lost(AgentException.fromServer(decoded));
      }
    }
  }

  /// Stops a connection attempt in progress.
  Future<void> cancel() async {
    if (_status != ConnectionStatus.connecting) return;
    _cancelRequested = true;
    final reply = _reply;
    _reply = null;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(AgentException(FailureKind.cancelled, 'Cancelled.'));
    }
  }

  Future<void> disconnect({bool notify = true}) async {
    for (final r in _requests.values) {
      if (!r.isCompleted) {
        r.completeError(RequestException('disconnected', 'Disconnected from the computer.'));
      }
    }
    _requests.clear();
    _pingTimer?.cancel();
    _pingTimer = null;
    final reply = _reply;
    _reply = null;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(AgentException(FailureKind.unreachable, 'Disconnected.'));
    }
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
    _progress = null;
    if (notify) notifyListeners();
  }

  void _setProgress(String text) {
    _progress = text;
    notifyListeners();
  }

  Never _fail(AgentException e) {
    _lastError = e;
    _status = ConnectionStatus.disconnected;
    _progress = null;
    notifyListeners();
    throw e;
  }

  void _lost(AgentException e) {
    final reply = _reply;
    if (reply != null && !reply.isCompleted) {
      _reply = null;
      reply.completeError(e);
      return;
    }
    if (_status != ConnectionStatus.connected) {
      _handshakeLost ??= e;
      return;
    }
    disconnect(notify: false);
    _lastError = e;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  void _send(Map<String, Object?> msg) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(msg));
    } catch (e) {
      _lost(AgentException(FailureKind.unreachable, 'Send failed: $e'));
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

  /// Keyboard shortcut: hold [mods], press [key] or [char], release.
  void combo(List<Modifier> mods, {AgentKey? key, String? char}) {
    _send({
      't': 'combo',
      'mods': [for (final m in mods) m.name],
      'k': ?key?.wire,
      'c': ?char,
    });
  }

  // ---- Requests with answers ------------------------------------------

  Future<Map<String, dynamic>> _request(
    Map<String, Object?> msg, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_status != ConnectionStatus.connected) {
      throw RequestException('disconnected', 'Not connected to the computer.');
    }
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _requests[id] = c;
    _send({...msg, 'id': id});
    try {
      final reply = await c.future.timeout(timeout);
      if (reply['t'] == 'ack' && reply['ok'] != true) {
        throw RequestException(
          reply['code'] as String? ?? 'failed',
          reply['msg'] as String? ?? 'The computer couldn\'t do that.',
        );
      }
      return reply;
    } on TimeoutException {
      throw RequestException('timeout', 'The computer didn\'t answer in time.');
    } finally {
      _requests.remove(id);
    }
  }

  void _requireFeature(String feature) {
    if (!_features.contains(feature)) {
      throw RequestException('unsupported', 'Update PairDesk on the computer to use this.');
    }
  }

  /// Lock, sleep, restart… Completes when the computer accepts.
  Future<void> power(PowerAction action) async {
    _requireFeature('power');
    await _request({'t': 'power', 'a': action.wire});
  }

  /// Installed apps and the owner's shortcuts.
  Future<AppsList> fetchApps() async {
    _requireFeature('apps');
    final reply = await _request({'t': 'apps'}, timeout: const Duration(seconds: 30));
    return AppsList(
      shortcuts: RemoteApp.listFrom(reply['shortcuts']),
      apps: RemoteApp.listFrom(reply['apps']),
    );
  }

  /// Opens an app or shortcut by the ID from [fetchApps].
  Future<void> launch(String appId) async {
    _requireFeature('apps');
    await _request({'t': 'launch', 'app': appId});
  }

  @override
  void dispose() {
    disconnect(notify: false);
    super.dispose();
  }
}

/// Fingerprint helper for showing to people, e.g. "AB12:CD34:…".
String fingerprintDisplay(Uint8List fp) {
  final h = hex(fp).toUpperCase();
  return [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4)].join(':');
}
