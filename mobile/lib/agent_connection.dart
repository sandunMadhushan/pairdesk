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

import 'audio/audio_packet.dart';
import 'files/native_files.dart';
import 'files/transfers.dart';
import 'pairing/codec.dart';
import 'pairing/discovery.dart';
import 'pairing/identity.dart';
import 'pairing/laptop.dart';
import 'pairing/pairing_link.dart';
import 'pairing/relay_route.dart';
import 'screen/frame.dart';

export 'audio/audio_packet.dart' show AudioInfo, AudioPacket;

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

/// Tailscale addresses (100.64.0.0/10) and MagicDNS names (*.ts.net).
bool isTailscaleHost(String host) => isTailscaleAddress(host);

/// A home-network address answers in milliseconds or not at all. Anything
/// else (Tailscale, a name pointing at a home connection, the relay) may
/// take a few seconds, so it gets the longer timeout.
bool _isLocal(String host) {
  if (isTailscaleAddress(host)) return false;
  return InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4;
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
  var target = host;
  var targetPort = port;
  if (RelayRoute.looksLike(host)) {
    final route = RelayRoute.tryParse(host);
    if (route == null) throw AgentException(FailureKind.unreachable, 'Bad relay address.');
    try {
      targetPort = await openRelayTunnel(route, timeout: timeout);
      target = '127.0.0.1';
    } on RelayRefused catch (e) {
      client.close(force: true);
      throw AgentException(FailureKind.unreachable, e.message);
    } catch (e) {
      client.close(force: true);
      throw AgentException(FailureKind.unreachable, 'No answer from the relay ${route.host}.');
    }
  }
  final uri = Uri(scheme: 'wss', host: target, port: targetPort, path: '/');
  try {
    final ws = await WebSocket.connect(uri.toString(), customClient: client).timeout(timeout);
    return IOWebSocketChannel(ws);
  } catch (e) {
    client.close(force: true);
    if (mismatch) {
      throw AgentException(FailureKind.wrongComputer, 'The device at $host is not the computer you paired.');
    }
    throw AgentException(
      FailureKind.unreachable,
      RelayRoute.looksLike(host) ? 'No answer through the relay.' : 'No answer from $host:$port.',
    );
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
  const Allowed({
    this.power = false,
    this.session = false,
    this.apps = false,
    this.screen = false,
    this.clipboard = false,
    this.files = false,
    this.audio = false,
    this.mic = false,
  });
  final bool power;
  final bool session;
  final bool apps;
  final bool screen;
  final bool clipboard;

  /// Sending files to the computer.
  final bool files;

  /// Hearing the computer's sound and talking through its speakers.
  final bool audio;

  /// Hearing the computer's microphone.
  final bool mic;

  bool action(PowerAction a) => a.endsSession ? session : power;

  static Allowed fromJson(Object? j) => j is Map
      ? Allowed(
          power: j['power'] == true,
          session: j['session'] == true,
          apps: j['apps'] == true,
          screen: j['screen'] == true,
          clipboard: j['clipboard'] == true,
          files: j['files'] == true,
          audio: j['audio'] == true,
          mic: j['mic'] == true,
        )
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
    this.remoteConnectTimeout = const Duration(seconds: 8),
    this.stagger = const Duration(milliseconds: 250),
    this.relayHeadStart = const Duration(milliseconds: 1500),
    this.replyTimeout = const Duration(seconds: 8),
    this.pingInterval = const Duration(seconds: 3),
    this.deadAfter = const Duration(seconds: 25),
    Future<SavedFile> Function(File temp, String name)? saveFile,
    Directory? tempDir,
  }) {
    transfers = FileTransfers(
      _Link(this),
      save: saveFile ?? (f, name) => NativeFiles.instance.saveToDownloads(f, name),
      tempDir: tempDir,
    );
  }

  /// Files going to and coming from the computer.
  late final FileTransfers transfers;

  /// Finds a computer whose address changed. Null disables discovery.
  final LaptopFinder? finder;

  /// Home-network addresses answer fast or not at all.
  final Duration connectTimeout;

  /// Tailscale may need a few seconds to reach a computer through a relay.
  final Duration remoteConnectTimeout;

  /// Gap between starting attempts at successive addresses.
  final Duration stagger;

  /// How long direct routes get before the relay is tried too.
  final Duration relayHeadStart;
  final Duration replyTimeout;
  final Duration pingInterval;
  final Duration deadAfter;

  /// How often the connection may rebuild itself after the computer goes
  /// quiet, before it gives up and tells the owner.
  static const maxReconnects = 3;

  /// Set by [connect]: what [_reconnect] needs to come back on its own.
  (Laptop, PhoneIdentity, String)? _session;
  int _reconnects = 0;
  DateTime _lastTick = DateTime.now();
  DateTime _connectedAt = DateTime.now();

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  DateTime _lastHeard = DateTime.now();
  Completer<Map<String, dynamic>>? _reply;
  bool _cancelRequested = false;
  Completer<(String, IOWebSocketChannel)?>? _race;

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

  String? _agentVersion;

  /// The computer's PairDesk release ("0.5.1"); null before 0.5.1.
  String? get agentVersion => _agentVersion;

  Set<String> _features = const {};

  /// Optional features the computer supports (`combo`, `power`, `apps`).
  Set<String> get features => _features;

  Allowed _allowed = const Allowed();
  Allowed get allowed => _allowed;

  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _requests = {};

  String? _address;
  String? get address => _address;

  /// True when this connection goes through Tailscale.
  bool get viaTailscale => _address != null && isTailscaleHost(_address!);

  List<String> _agentAddrs = const [];

  /// The computer this connection belongs to, so an `addrs` message can
  /// update its saved addresses while connected.
  Laptop? _connected;

  final _addressUpdates = StreamController<void>.broadcast();

  /// Fires when the computer's addresses changed and were saved on the
  /// [Laptop]; the app writes them to storage.
  Stream<void> get addressUpdates => _addressUpdates.stream;

  DateTime? _pingSentAt;
  Duration? _latency;

  /// Round-trip time of the last ping.
  Duration? get latency => _latency;

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
      helping: info.help,
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
  Future<void> connect(Laptop laptop, PhoneIdentity me, {required String phoneName}) async {
    _session = null;
    _reconnects = 0;
    await _connectAny(
      laptop,
      me,
      first: {'t': 'hello', 'v': protocolVersion, 'id': me.id, 'name': phoneName},
      useDiscovery: true,
    );
    _session = (laptop, me, phoneName);
  }

  /// The connection went quiet (a sleeping phone, a Wi-Fi hiccup, a
  /// moved route): connect again without sending the owner back to the
  /// list. Gives up after [maxReconnects] in a row.
  Future<void> _reconnect() async {
    final s = _session;
    if (s == null) return;
    _reconnects++;
    final (laptop, me, phoneName) = s;
    await disconnect(notify: false);
    _status = ConnectionStatus.connecting;
    _progress = 'Reconnecting to ${laptop.name}…';
    notifyListeners();
    try {
      await _connectAny(
        laptop,
        me,
        first: {'t': 'hello', 'v': protocolVersion, 'id': me.id, 'name': phoneName},
        useDiscovery: true,
      );
    } on AgentException {
      // _connectAny has recorded the error and marked us disconnected.
    }
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
    void note(AgentException e) {
      if (best == null || e.kind == FailureKind.wrongComputer) best = e;
    }

    var ok = await _tryHosts(laptop.addresses, laptop, me, first, note);
    if (!ok && useDiscovery && finder != null && !_cancelRequested) {
      _setProgress('Looking for ${laptop.name} on this Wi-Fi…');
      final found = await finder!.find(laptop.shortId);
      final fresh = found.where((a) => !laptop.addresses.contains(a)).toList();
      ok = await _tryHosts(fresh, laptop, me, first, note);
    }
    if (_cancelRequested) _fail(AgentException(FailureKind.cancelled, 'Cancelled.'));
    if (!ok) {
      _fail(best ?? AgentException(FailureKind.unreachable, 'No address known for ${laptop.name}.'));
    }

    _connected = laptop;
    laptop
      ..learnAddresses(working: _address!, fromComputer: _agentAddrs)
      ..name = _agentName ?? laptop.name
      ..os = _agentOs ?? laptop.os
      ..lastUsed = DateTime.now().millisecondsSinceEpoch;

    _status = ConnectionStatus.connected;
    _progress = null;
    _lastHeard = DateTime.now();
    _lastTick = _connectedAt = DateTime.now();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      final now = DateTime.now();
      // A timer that fires long after it was due means the phone itself was
      // frozen (screen off, app in the background), not that the computer
      // went quiet. Give the computer a fresh window to answer a ping.
      if (now.difference(_lastTick) > pingInterval * 4 + const Duration(seconds: 1)) {
        _lastHeard = now;
      }
      _lastTick = now;
      if (_reconnects > 0 && now.difference(_connectedAt) > const Duration(minutes: 2)) _reconnects = 0;
      if (now.difference(_lastHeard) > deadAfter) {
        _lost(AgentException(FailureKind.unreachable, 'The computer stopped answering.'));
        return;
      }
      _pingSentAt = DateTime.now();
      _send({'t': 'ping'});
    });
    notifyListeners();
  }

  /// Tries [hosts] until one completes the handshake. Connections start
  /// a moment apart and the first to answer wins, so a dead home address
  /// doesn't delay a working Tailscale one (and the other way round).
  Future<bool> _tryHosts(
    List<String> hosts,
    Laptop laptop,
    PhoneIdentity me,
    Map<String, Object?> first,
    void Function(AgentException) note,
  ) async {
    final remaining = List.of(hosts);
    while (remaining.isNotEmpty) {
      if (_cancelRequested) _fail(AgentException(FailureKind.cancelled, 'Cancelled.'));
      final winner = await _raceChannels(remaining, laptop, note);
      if (winner == null) return false;
      final (host, channel) = winner;
      remaining.remove(host);
      try {
        await _handshake(host, channel, laptop, me, first);
        return true;
      } on AgentException catch (e) {
        await disconnect(notify: false);
        // A definite answer from the right computer ends the search.
        if (e.kind != FailureKind.unreachable && e.kind != FailureKind.wrongComputer) _fail(e);
        note(e);
      }
    }
    return false;
  }

  /// Opens pinned connections to [hosts], [stagger] apart; returns the
  /// first that succeeds and closes any that finish later.
  Future<(String, IOWebSocketChannel)?> _raceChannels(
    List<String> hosts,
    Laptop laptop,
    void Function(AgentException) note,
  ) {
    if (hosts.isEmpty) return Future.value(null);
    final done = Completer<(String, IOWebSocketChannel)?>();
    _race = done;
    var pending = hosts.length;
    void finished() {
      pending--;
      if (pending == 0 && !done.isCompleted) done.complete(null);
    }

    for (var i = 0; i < hosts.length; i++) {
      final host = hosts[i];
      // The relay is the last resort: direct routes get a head start.
      final relay = RelayRoute.looksLike(host);
      final delay = relay && hosts.length > 1 ? _maxDuration(stagger * i, relayHeadStart) : stagger * i;
      Future<void>.delayed(delay, () async {
        if (done.isCompleted || _cancelRequested) return finished();
        try {
          // An address may carry its own port (a router forwarding a
          // different one); otherwise the computer's own port is used.
          final where = relay ? (host: host, port: null) : splitHostPort(host);
          final ch = await openPinnedChannel(
            where.host,
            where.port ?? laptop.port,
            laptop.fingerprint,
            timeout: relay || !_isLocal(where.host) ? remoteConnectTimeout : connectTimeout,
          );
          if (done.isCompleted || _cancelRequested) {
            unawaited(ch.sink.close().catchError((_) {}));
          } else {
            done.complete((host, ch));
          }
        } on AgentException catch (e) {
          note(e);
        } finally {
          finished();
        }
      });
    }
    return done.future;
  }

  /// hello/pair, challenge, auth on an open channel.
  Future<void> _handshake(
    String host,
    IOWebSocketChannel channel,
    Laptop laptop,
    PhoneIdentity me,
    Map<String, Object?> first,
  ) async {
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
    _agentVersion = welcome['version'] as String?;
    _features = {
      if (welcome['features'] is List)
        for (final f in welcome['features'] as List)
          if (f is String) f,
    };
    _allowed = Allowed.fromJson(welcome['allow']);
    _agentAddrs = [
      if (welcome['addrs'] is List)
        for (final a in welcome['addrs'] as List)
          if (a is String && isUsableHost(a)) a,
    ];
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
    if (data is List<int>) {
      _onBinary(data is Uint8List ? data : Uint8List.fromList(data));
      return;
    }
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    final id = decoded['id'];
    if (decoded['t'] == 'screen_stopped') {
      _screenEvents.add(decoded['msg'] as String? ?? 'Screen view stopped.');
      return;
    }
    if (decoded['t'] == 'audio_stopped') {
      _audioStopped.add(decoded['msg'] as String? ?? 'Sound stopped.');
      return;
    }
    final type = decoded['t'];
    if (type is String && type.startsWith('file_') && transfers.handleMessage(decoded)) return;
    // The computer's addresses changed (Tailscale came up, a new Wi-Fi
    // address, the relay started). Keep them, so the next connection from
    // another network has a route to try without pairing again.
    if (decoded['t'] == 'addrs') {
      final fresh = [
        if (decoded['addrs'] is List)
          for (final a in decoded['addrs'] as List)
            if (a is String && isUsableHost(a)) a,
      ];
      _agentAddrs = fresh;
      final laptop = _connected;
      if (laptop != null && fresh.isNotEmpty) {
        final before = laptop.addresses.join(',');
        laptop.learnAddresses(working: _address ?? laptop.addresses.first, fromComputer: fresh);
        if (laptop.addresses.join(',') != before) _addressUpdates.add(null);
      }
      return;
    }
    if (decoded['t'] == 'notice') {
      final msg = decoded['msg'];
      if (msg is String && msg.isNotEmpty) _notices.add(msg);
      return;
    }
    if (id is int &&
        (decoded['t'] == 'ack' ||
            decoded['t'] == 'apps' ||
            decoded['t'] == 'screen' ||
            decoded['t'] == 'audio' ||
            decoded['t'] == 'clip')) {
      _requests.remove(id)?.complete(decoded);
      return;
    }

    final waiting = _reply;
    if (waiting != null && !waiting.isCompleted) {
      _reply = null;
      waiting.complete(decoded);
      return;
    }
    if (decoded['t'] == 'pong' && _pingSentAt != null) {
      _latency = DateTime.now().difference(_pingSentAt!);
      _pingSentAt = null;
      notifyListeners();
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
    final race = _race;
    if (race != null && !race.isCompleted) race.complete(null);
    final reply = _reply;
    _reply = null;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(AgentException(FailureKind.cancelled, 'Cancelled.'));
    }
  }

  Future<void> disconnect({bool notify = true}) async {
    if (notify) _session = null; // the owner closed it: don't come back
    transfers.connectionLost();
    for (final r in _requests.values) {
      if (!r.isCompleted) {
        r.completeError(RequestException('disconnected', 'Disconnected from the computer.'));
      }
    }
    _requests.clear();
    _connected = null;
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
    _latency = null;
    _pingSentAt = null;
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
    if (e.kind == FailureKind.unreachable && _session != null && _reconnects < maxReconnects) {
      _reconnect();
      return;
    }
    disconnect(notify: false);
    _lastError = e;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  void _sendBinary(Uint8List data) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(data);
    } catch (e) {
      _lost(AgentException(FailureKind.unreachable, 'Send failed: $e'));
    }
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
      throw RequestException('unsupported', outdatedComputerMessage());
    }
  }

  /// What to tell the user when the computer's PairDesk is too old for
  /// something. Before 0.5.1 the computer didn't say its version; the usual
  /// cause then is an old copy still running after a new one was downloaded.
  String outdatedComputerMessage() {
    final v = _agentVersion;
    if (v != null) {
      return 'The computer has PairDesk $v, which can\'t do this. '
          'Install the latest PairDesk on the computer.';
    }
    final where = _agentOs == 'windows'
        ? 'right-click the PairDesk icon next to the clock (it may be under the ^ arrow)'
        : 'open the PairDesk icon in the top bar or system tray';
    return 'The computer is running an older PairDesk.\n\n'
        'If you just installed a new one there: $where, choose Stop PairDesk, '
        'then open the new PairDesk. Otherwise download it from pairdesk.madhushan.me.';
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
  // ---- Screen view ----------------------------------------------------

  final _frames = StreamController<ScreenFrame>.broadcast();
  final _screenEvents = StreamController<String>.broadcast();
  final _notices = StreamController<String>.broadcast();

  /// Messages from the computer for the person, e.g. "approve PairDesk on
  /// the computer" (Linux Wayland).
  Stream<String> get notices => _notices.stream;

  /// Frames from the computer while screen view runs.
  Stream<ScreenFrame> get screenFrames => _frames.stream;

  /// Screen view ended on the computer's side (the reason, for people).
  Stream<String> get screenStopped => _screenEvents.stream;

  void _onBinary(Uint8List data) {
    if (AudioPacket.matches(data)) {
      _audio.add(AudioPacket.parse(data));
      return;
    }
    if (isFileChunk(data)) {
      transfers.handleChunk(data);
      return;
    }
    try {
      _frames.add(ScreenFrame.parse(data));
    } on FormatException catch (e) {
      debugPrint('bad screen frame: $e');
      _send({'t': 'screen_refresh'});
    }
  }

  // ---- Clipboard and files --------------------------------------------

  /// Largest clipboard text exchanged (bytes of UTF-8), as on the computer.
  static const maxClipboardBytes = 200000;

  /// The computer's clipboard text ("" when it holds no text).
  Future<String> clipboardGet() async {
    _requireFeature('clipboard');
    final reply = await _request({'t': 'clip_get'});
    return reply['text'] as String? ?? '';
  }

  /// Puts [text] on the computer's clipboard; with [paste], also pastes it
  /// into the computer's active window.
  Future<void> clipboardSet(String text, {bool paste = false}) async {
    _requireFeature('clipboard');
    if (utf8.encode(text).length > maxClipboardBytes) {
      throw RequestException('too_big', 'That text is too long for the clipboard (200 KB at most).');
    }
    await _request({'t': 'clip_set', 'text': text, 'paste': paste});
  }

  /// Sends a file to the computer's Downloads/PairDesk folder.
  Future<Transfer> sendFile(File file, {String? name}) async {
    _requireFeature('files');
    if (_status != ConnectionStatus.connected) {
      throw RequestException('disconnected', 'Not connected to the computer.');
    }
    try {
      return await transfers.send(file, name: name);
    } on TransferException catch (e) {
      throw RequestException('failed', e.message);
    }
  }

  /// Starts screen view; frames then arrive on [screenFrames].
  /// [codecs]: video formats this phone can decode (`h264`); the computer
  /// picks one, or JPEG (see [ScreenInfo.codec]).
  Future<ScreenInfo> startScreen({
    int? monitor,
    String quality = 'medium',
    List<String> codecs = const [],
  }) async {
    _requireFeature('screen');
    final reply = await _request({
      't': 'screen_start',
      'monitor': ?monitor,
      'quality': quality,
      if (codecs.isNotEmpty && features.contains('video')) 'codecs': codecs,
    });
    return ScreenInfo.fromJson(reply);
  }

  /// Tells the computer frame [seq] is shown, so it sends the next one.
  void ackScreen(int seq) => _send({'t': 'screen_ack', 'seq': seq});

  /// Asks for the whole screen again.
  void refreshScreen() => _send({'t': 'screen_refresh'});

  void stopScreen() => _send({'t': 'screen_stop'});

  /// Moves the pointer to a point on the shown screen (0..1 from top-left).
  void moveTo(double x, double y) => _send({'t': 'move_to', 'x': x, 'y': y});

  // ---- Sound ----------------------------------------------------------

  final _audio = StreamController<AudioPacket>.broadcast();
  final _audioStopped = StreamController<String>.broadcast();

  /// The computer's sound while listening.
  Stream<AudioPacket> get audioPackets => _audio.stream;

  /// Listening ended on the computer's side (the reason, for people).
  Stream<String> get audioStopped => _audioStopped.stream;

  /// Starts (or changes) listening to the computer's [sound] and/or its
  /// [mic]. [codecs]: what this phone can decode, best first.
  Future<AudioInfo> startAudio({required bool sound, required bool mic, required List<String> codecs}) async {
    _requireFeature('audio');
    final reply = await _request({'t': 'audio_start', 'sound': sound, 'mic': mic, 'codecs': codecs});
    return AudioInfo.fromJson(reply);
  }

  void stopAudio() => _send({'t': 'audio_stop'});

  /// 20 ms of the phone's voice (16 kHz mono µ-law) for the speakers.
  void sendVoice(Uint8List ulaw) => _sendBinary(voiceMessage(ulaw));

  Future<void> launch(String appId) async {
    _requireFeature('apps');
    await _request({'t': 'launch', 'app': appId});
  }

  @override
  void dispose() {
    transfers.dispose();
    _frames.close();
    _screenEvents.close();
    _audio.close();
    _audioStopped.close();
    _notices.close();
    _addressUpdates.close();
    disconnect(notify: false);
    super.dispose();
  }
}

/// Fingerprint helper for showing to people, e.g. "AB12:CD34:…".
String fingerprintDisplay(Uint8List fp) {
  final h = hex(fp).toUpperCase();
  return [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4)].join(':');
}

class _Link implements TransferLink {
  _Link(this.c);
  final AgentConnection c;
  @override
  void sendJson(Map<String, Object?> msg) => c._send(msg);
  @override
  void sendBinary(Uint8List data) => c._sendBinary(data);
}

Duration _maxDuration(Duration a, Duration b) => a > b ? a : b;
