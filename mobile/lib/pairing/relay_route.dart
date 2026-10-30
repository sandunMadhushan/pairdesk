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

/// Asks the relay for the computer and, once joined, returns a local port
/// whose first connection is forwarded to it.
Future<int> openRelayTunnel(RelayRoute route, {required Duration timeout}) async {
  final upstream = await Socket.connect(route.host, route.port, timeout: timeout);
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
