// SPDX-License-Identifier: GPL-3.0-or-later
// Reaching a computer through a PairDesk relay, when it can't be reached
// directly (another network, no Tailscale).
//
// The phone asks the relay for the computer by its relay id; once the
// relay has joined the two connections, the phone talks TLS to the
// computer exactly as on Wi-Fi, with the certificate pinned, so the relay
// only passes encrypted bytes along. A small forwarder on 127.0.0.1 lets
// the usual pinned WebSocket code run over the joined connection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'direct.dart';

/// `relay:host:port/id`, as kept in a computer's address list.
class RelayRoute {
  const RelayRoute(this.host, this.port, this.id);
  final String host;
  final int port;

  /// The computer's id on the relay (32 hex characters).
  final String id;

  static const prefix = 'relay:';

  static bool looksLike(String address) => address.startsWith(prefix);

  /// Parses `relay:host:port/id` (or `host:port/id`); null if malformed.
  static RelayRoute? tryParse(String text) {
    final s = text.startsWith(prefix) ? text.substring(prefix.length) : text;
    final slash = s.lastIndexOf('/');
    if (slash < 0) return null;
    final id = s.substring(slash + 1);
    final hostPort = s.substring(0, slash);
    final colon = hostPort.lastIndexOf(':');
    if (colon <= 0) return null;
    final host = hostPort.substring(0, colon);
    final port = int.tryParse(hostPort.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return null;
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return null;
    if (host.length > 253 || !RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(host)) return null;
    return RelayRoute(host, port, id);
  }

  @override
  String toString() => '$prefix$host:$port/$id';
}

/// The relay answered but couldn't join us to the computer.
class RelayRefused implements Exception {
  RelayRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Relays that didn't speak TLS, and when we last found that out. A relay
/// that does TLS is tried first (it hides what the phone is doing from the
/// network); an older plain one is remembered so later connections don't wait.
final _plainRelays = <String, DateTime>{};
const _tlsRetryAfter = Duration(minutes: 10);

@visibleForTesting
void forgetPlainRelays() => _plainRelays.clear();

/// TLS to the relay first (only for names, as a certificate can't match an
/// IP address), then the plain protocol as before.
Future<Socket> _connectRelay(
  RelayRoute route,
  Duration timeout,
  Duration tlsTimeout,
  SecurityContext? context,
) async {
  final key = '${route.host}:${route.port}';
  final isName = InternetAddress.tryParse(route.host) == null;
  final since = _plainRelays[key];
  final tryTls = isName && (since == null || DateTime.now().difference(since) > _tlsRetryAfter);
  if (tryTls) {
    try {
      return await SecureSocket.connect(
        route.host,
        route.port,
        timeout: timeout,
        context: context,
      ).timeout(tlsTimeout);
    } catch (_) {
      // Not a TLS relay, or one with a certificate we can't verify: use the
      // plain protocol. The computer's own certificate is still pinned.
      _plainRelays[key] = DateTime.now();
    }
  }
  return Socket.connect(route.host, route.port, timeout: timeout);
}

/// The relay connection: lines first (the relay's answer, and the
/// computer's answer to a direct offer), then raw bytes for the forwarder.
class _Upstream {
  _Upstream(this.socket) {
    socket.listen(
      _onData,
      onError: (Object e) => _closed(e),
      onDone: () => _closed(RelayRefused('the relay closed the connection')),
      cancelOnError: true,
    );
  }

  final Socket socket;
  final _buf = <int>[];
  Completer<String>? _line;
  bool _raw = false;
  Socket? local;
  final early = <Uint8List>[];
  Object? _error;

  void _onData(Uint8List d) {
    if (_raw) {
      final l = local;
      l == null ? early.add(d) : l.add(d);
      return;
    }
    _buf.addAll(d);
    _tryLine();
  }

  void _closed(Object e) {
    _error ??= e;
    final c = _line;
    if (c != null && !c.isCompleted) c.completeError(e);
    local?.destroy();
  }

  void _tryLine() {
    final c = _line;
    if (c == null || c.isCompleted) return;
    final nl = _buf.indexOf(10);
    if (nl < 0) {
      if (_buf.length > 1024) c.completeError(RelayRefused('bad answer'));
      return;
    }
    final line = utf8.decode(_buf.sublist(0, nl), allowMalformed: true).trim();
    _buf.removeRange(0, nl + 1);
    c.complete(line);
  }

  Future<String> nextLine(Duration timeout) {
    final e = _error;
    if (e != null) return Future.error(e);
    final c = _line = Completer<String>();
    _tryLine();
    return c.future.timeout(timeout);
  }

  /// From here on everything goes to the forwarder.
  void goRaw() {
    _raw = true;
    if (_buf.isNotEmpty) early.add(Uint8List.fromList(_buf));
    _buf.clear();
  }
}

/// Asks the relay for the computer and, once joined, returns a local port
/// whose first connection is forwarded to it.
///
/// With [direct], the phone first offers the computer a direct path
/// (direct.dart); if one opens, the port leads there instead and [onDirect]
/// is called. Either way the caller sees a local port to talk TLS through.
Future<int> openRelayTunnel(
  RelayRoute route, {
  required Duration timeout,
  Duration tlsTimeout = const Duration(seconds: 5),
  @visibleForTesting SecurityContext? tlsContext,
  DirectOffer? direct,
  Duration punchTimeout = const Duration(seconds: 2),
  void Function()? onDirect,
}) async {
  final key = route.toString();
  final useDirect = direct != null && !directRecentlyFailed(key);
  // Finding our own address runs while the relay connection opens.
  final prepared = useDirect ? prepareDirect(route.host, route.port) : null;
  final Socket socket;
  try {
    socket = await _connectRelay(route, timeout, tlsTimeout, tlsContext);
  } catch (e) {
    unawaited(prepared?.then((p) => p?.socket.close()));
    rethrow;
  }
  socket.setOption(SocketOption.tcpNoDelay, true);
  final up = _Upstream(socket);
  socket.add(utf8.encode('PDR1 CONNECT ${route.id}\n'));

  final String line;
  try {
    line = await up.nextLine(timeout);
  } catch (e) {
    socket.destroy();
    unawaited(prepared?.then((p) => p?.socket.close()));
    rethrow;
  }
  if (line != 'OK') {
    socket.destroy();
    unawaited(prepared?.then((p) => p?.socket.close()));
    throw RelayRefused(switch (line) {
      'ERR offline' => 'The computer isn\'t connected to the relay. Is PairDesk running on it?',
      'ERR no answer' => 'The computer didn\'t answer through the relay.',
      _ => 'The relay said: $line',
    });
  }

  if (prepared != null) {
    final p = await prepared.timeout(const Duration(seconds: 2), onTimeout: () => null);
    if (p != null) {
      final port = await _tryDirect(up, p, direct!, key, punchTimeout, timeout);
      if (port == _broken) {
        // The computer didn't understand the offer and the connection is
        // spoiled: once more, plainly.
        socket.destroy();
        return openRelayTunnel(route, timeout: timeout, tlsTimeout: tlsTimeout, tlsContext: tlsContext);
      }
      if (port != null) {
        onDirect?.call();
        return port;
      }
    }
  }
  return _forwardRelay(up, timeout);
}

/// [_tryDirect]'s answer when the relay connection can't be used any more.
const _broken = -1;

/// Offers a direct path on the joined relay connection; returns the
/// forwarder's port if one opened (the relay connection is then closed),
/// null to carry on over the relay, or [_broken].
Future<int?> _tryDirect(
  _Upstream up,
  PreparedDirect p,
  DirectOffer direct,
  String key,
  Duration punchTimeout,
  Duration timeout,
) async {
  final rng = Random.secure();
  final token = Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
  try {
    up.socket.add(utf8.encode(await offerLine(direct, token, p.candidates)));
    final String answer;
    try {
      answer = await up.nextLine(const Duration(seconds: 4));
    } catch (_) {
      // No answer to the offer: most likely an older PairDesk on the
      // computer. Don't offer again for a while, so the next try is plain.
      directFailed(key);
      p.socket.close();
      return _broken;
    }
    if (!answer.startsWith('PDD1 ')) {
      directFailed(key);
      p.socket.close();
      return _broken;
    }
    final peers = answer.startsWith('PDD1 OK ')
        ? parseCandidates(answer.substring(8))
        : const <(InternetAddress, int)>[];
    if (peers.isEmpty) {
      p.socket.close();
      return null;
    }
    final peer = await punch(p.socket, token, peers, timeout: punchTimeout);
    if (peer == null) {
      directFailed(key);
      p.socket.close();
      return null;
    }
    directWorked(key);
    up.socket.destroy();
    return await forwardDirect(p.socket, peer, token, timeout: timeout);
  } catch (_) {
    p.socket.close();
    return null;
  }
}

Future<int> _forwardRelay(_Upstream up, Duration timeout) async {
  up.goRaw();
  final upstream = up.socket;
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final giveUp = Timer(timeout, () {
    server.close();
    if (up.local == null) upstream.destroy();
  });
  server.first.then((s) {
    giveUp.cancel();
    server.close();
    s.setOption(SocketOption.tcpNoDelay, true);
    up.local = s;
    for (final d in up.early) {
      s.add(d);
    }
    up.early.clear();
    s.listen(
      upstream.add,
      onError: (Object _) => upstream.destroy(),
      onDone: () => upstream.destroy(),
      cancelOnError: true,
    );
  }, onError: (Object _) => upstream.destroy());
  return server.port;
}

/// What a check found out about one relay.
enum RelayState { computerOnline, computerOffline, relayDown, unexpected }

class RelayCheck {
  const RelayCheck(this.route, this.state, this.detail);
  final RelayRoute route;
  final RelayState state;

  /// Plain words for the person looking at it.
  final String detail;
}

/// Asks a relay whether the computer is connected to it, without opening a
/// session (the connection is dropped as soon as the relay has answered).
Future<RelayCheck> checkRelay(
  RelayRoute route, {
  Duration timeout = const Duration(seconds: 6),
  Duration tlsTimeout = const Duration(seconds: 3),
}) async {
  try {
    final port = await openRelayTunnel(route, timeout: timeout, tlsTimeout: tlsTimeout);
    // The relay joined us to the computer, which proves everything works up
    // to the computer. Nobody connects to the forwarder, so it times out.
    unawaited(Future<void>.delayed(Duration.zero, () => _poke(port)));
    return RelayCheck(
      route,
      RelayState.computerOnline,
      'The relay answers and the computer is connected to it.',
    );
  } on RelayRefused catch (e) {
    final offline = e.message.contains('isn\'t connected');
    return RelayCheck(
      route,
      offline ? RelayState.computerOffline : RelayState.unexpected,
      offline ? 'The relay answers, but the computer isn\'t connected to it.' : e.message,
    );
  } catch (_) {
    return RelayCheck(route, RelayState.relayDown, 'No answer from ${route.host}.');
  }
}

/// Closes the forwarder's port so the tunnel is torn down at once.
Future<void> _poke(int port) async {
  try {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
    s.destroy();
  } catch (_) {}
}
