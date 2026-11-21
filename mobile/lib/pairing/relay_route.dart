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
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

/// Asks the relay for the computer and, once joined, returns a local port
/// whose first connection is forwarded to it.
Future<int> openRelayTunnel(
  RelayRoute route, {
  required Duration timeout,
  Duration tlsTimeout = const Duration(seconds: 5),
  @visibleForTesting SecurityContext? tlsContext,
}) async {
  final upstream = await _connectRelay(route, timeout, tlsTimeout, tlsContext);
  upstream.setOption(SocketOption.tcpNoDelay, true);
  final reply = Completer<String>();
  final header = BytesBuilder();
  final early = <Uint8List>[];
  Socket? local;
  var answered = false;

  upstream.listen(
    (data) {
      if (answered) {
        final l = local;
        l == null ? early.add(data) : l.add(data);
        return;
      }
      header.add(data);
      final bytes = header.toBytes();
      final nl = bytes.indexOf(10);
      if (nl < 0) {
        if (bytes.length > 256 && !reply.isCompleted) reply.completeError(RelayRefused('bad answer'));
        return;
      }
      answered = true;
      if (nl + 1 < bytes.length) early.add(Uint8List.sublistView(bytes, nl + 1));
      if (!reply.isCompleted) reply.complete(utf8.decode(bytes.sublist(0, nl), allowMalformed: true).trim());
    },
    onError: (Object e) {
      if (!reply.isCompleted) reply.completeError(e);
      local?.destroy();
    },
    onDone: () {
      if (!reply.isCompleted) reply.completeError(RelayRefused('the relay closed the connection'));
      local?.destroy();
    },
    cancelOnError: true,
  );
  upstream.add(utf8.encode('PDR1 CONNECT ${route.id}\n'));

  final String line;
  try {
    line = await reply.future.timeout(timeout);
  } catch (e) {
    upstream.destroy();
    rethrow;
  }
  if (line != 'OK') {
    upstream.destroy();
    throw RelayRefused(switch (line) {
      'ERR offline' => 'The computer isn\'t connected to the relay. Is PairDesk running on it?',
      'ERR no answer' => 'The computer didn\'t answer through the relay.',
      _ => 'The relay said: $line',
    });
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final giveUp = Timer(timeout, () {
    server.close();
    if (local == null) upstream.destroy();
  });
  server.first.then((s) {
    giveUp.cancel();
    server.close();
    s.setOption(SocketOption.tcpNoDelay, true);
    local = s;
    for (final d in early) {
      s.add(d);
    }
    early.clear();
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
