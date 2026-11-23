// SPDX-License-Identifier: GPL-3.0-or-later
// Direct connections: once the relay has joined the phone to the computer,
// the two try to open a path straight through their routers (UDP "hole
// punching"), so the screen doesn't pass through the relay. The computer's
// side, and the whole exchange, are described in agent/src/direct/mod.rs.
//
// The phone:
// 1. asks the relay (STUN) which address the internet sees for its UDP
//    socket, while the relay connection is being opened;
// 2. sends a signed offer line on the joined connection, before TLS;
// 3. on "PDD1 OK <addresses>", sends PUNCH packets to the computer's
//    addresses until one answers;
// 4. runs TLS over that path (DirectConn makes it a reliable stream), or,
//    if nothing answers in time, over the relay connection as before.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'direct_conn.dart';
import 'identity.dart';

const _stunCookie = 0x2112A442;
const _context = 'pairdesk-direct-v1';
const _maxCandidates = 8;
const _punchEvery = Duration(milliseconds: 100);

/// What the phone needs to offer a direct path to one computer.
class DirectOffer {
  DirectOffer({required this.identity, required this.fingerprint});
  final PhoneIdentity identity;
  final List<int> fingerprint;
}

/// Lets tests on one computer use 127.0.0.1 as a candidate.
@visibleForTesting
bool directIncludeLoopback = false;

/// When direct paths last failed, by relay route. After a failure the phone
/// goes straight to the relay for a while: the same networks would fail again.
final _failedAt = <String, DateTime>{};
const _failedSkip = Duration(minutes: 5);

bool directRecentlyFailed(String key) {
  final at = _failedAt[key];
  return at != null && DateTime.now().difference(at) < _failedSkip;
}

void directFailed(String key) => _failedAt[key] = DateTime.now();
void directWorked(String key) => _failedAt.remove(key);

@visibleForTesting
void forgetDirectFailures() => _failedAt.clear();

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

/// One UDP socket, read by whoever currently handles its packets.
class DirectSocket {
  DirectSocket._(this.socket) {
    _sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final d = socket.receive();
        if (d == null) break;
        onPacket?.call(d);
      }
    });
  }

  final RawDatagramSocket socket;
  late final StreamSubscription<RawSocketEvent> _sub;
  void Function(Datagram)? onPacket;

  static Future<DirectSocket> bind() async =>
      DirectSocket._(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  int get port => socket.port;

  void send(List<int> p, InternetAddress a, int port) {
    try {
      socket.send(p, a, port);
    } catch (_) {
      // A network that just went away; the stream retries or times out.
    }
  }

  void close() {
    _sub.cancel();
    socket.close();
  }
}

/// Asks a STUN server which address it sees [s] coming from.
Future<(InternetAddress, int)?> stun(DirectSocket s, InternetAddress server, int port) async {
  final rng = Random.secure();
  final txid = Uint8List.fromList(List.generate(12, (_) => rng.nextInt(256)));
  final req = Uint8List(20);
  req[1] = 1;
  req.buffer.asByteData().setUint32(4, _stunCookie);
  req.setRange(8, 20, txid);
  final done = Completer<(InternetAddress, int)?>();
  s.onPacket = (d) {
    if (d.address != server || d.port != port) return;
    final a = parseStunAnswer(d.data, txid);
    if (a != null && !done.isCompleted) done.complete(a);
  };
  try {
    for (var attempt = 1; attempt <= 3 && !done.isCompleted; attempt++) {
      s.send(req, server, port);
      await Future.any([done.future, Future<void>.delayed(Duration(milliseconds: 250 * attempt))]);
    }
    return done.isCompleted ? await done.future : null;
  } finally {
    s.onPacket = null;
  }
}

@visibleForTesting
(InternetAddress, int)? parseStunAnswer(Uint8List p, Uint8List txid) {
  if (p.length < 20 || p[0] != 1 || p[1] != 1) return null;
  final bd = p.buffer.asByteData(p.offsetInBytes, p.length);
  if (bd.getUint32(4) != _stunCookie) return null;
  for (var i = 0; i < 12; i++) {
    if (p[8 + i] != txid[i]) return null;
  }
  var i = 20;
  while (i + 4 <= p.length) {
    final kind = bd.getUint16(i), len = bd.getUint16(i + 2);
    if (i + 4 + len > p.length) return null;
    if (kind == 0x0020 && len >= 8 && p[i + 5] == 1) {
      final port = bd.getUint16(i + 6) ^ (_stunCookie >> 16);
      final ip = bd.getUint32(i + 8) ^ _stunCookie;
      final addr = InternetAddress.fromRawAddress(
        Uint8List.fromList([ip >> 24 & 0xff, ip >> 16 & 0xff, ip >> 8 & 0xff, ip & 0xff]),
      );
      return (addr, port);
    }
    i += 4 + ((len + 3) ~/ 4) * 4;
  }
  return null;
}

/// A socket ready to offer: where the computer can reach it.
class PreparedDirect {
  PreparedDirect(this.socket, this.candidates);
  final DirectSocket socket;
  final List<String> candidates;
}

/// Opens the UDP socket and finds its addresses (as the internet sees it,
/// through the relay's STUN, and on this network). Null if there's nothing
/// useful to offer.
Future<PreparedDirect?> prepareDirect(String relayHost, int relayPort) async {
  DirectSocket? s;
  try {
    s = await DirectSocket.bind();
    final cands = <String>[];
    final servers = await InternetAddress.lookup(
      relayHost,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 2));
    if (servers.isNotEmpty) {
      final mapped = await stun(s, servers.first, relayPort);
      if (mapped != null) cands.add('${mapped.$1.address}:${mapped.$2}');
    }
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        final c = '${a.address}:${s.port}';
        if (!cands.contains(c)) cands.add(c);
      }
    }
    if (directIncludeLoopback) cands.add('127.0.0.1:${s.port}');
    if (cands.isEmpty) {
      s.close();
      return null;
    }
    return PreparedDirect(s, cands.take(_maxCandidates).toList());
  } catch (_) {
    s?.close();
    return null;
  }
}

/// The offer line (with its newline).
Future<String> offerLine(DirectOffer offer, Uint8List token, List<String> candidates, {int? time}) async {
  final t = time ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final cands = candidates.isEmpty ? '-' : candidates.join(',');
  final tail = '$t ${_hex(token)} $cands';
  final msg = [...utf8.encode(_context), 0, ...offer.fingerprint, ...utf8.encode(tail)];
  final sig = await offer.identity.signRaw(msg);
  return 'PDD1 ${offer.identity.id} $tail ${_b64(sig)}\n';
}

/// Parses `ip:port,ip:port` (IPv4 only, at most eight).
List<(InternetAddress, int)> parseCandidates(String s) {
  if (s == '-') return const [];
  final out = <(InternetAddress, int)>[];
  for (final part in s.split(',')) {
    final colon = part.lastIndexOf(':');
    if (colon <= 0) continue;
    final ip = InternetAddress.tryParse(part.substring(0, colon));
    final port = int.tryParse(part.substring(colon + 1));
    if (ip == null || ip.type != InternetAddressType.IPv4 || port == null || port < 1 || port > 65535) {
      continue;
    }
    if (ip.isMulticast || ip.address == '0.0.0.0' || ip.address == '255.255.255.255') continue;
    if (ip.isLoopback && !directIncludeLoopback) continue;
    out.add((ip, port));
    if (out.length == _maxCandidates) break;
  }
  return out;
}

/// Punches towards [peers] until one answers; returns the address that did.
Future<(InternetAddress, int)?> punch(
  DirectSocket s,
  Uint8List token,
  List<(InternetAddress, int)> peers, {
  required Duration timeout,
}) async {
  final p = packetHeader(kPunch, token, 1);
  final ack = packetHeader(kPunchAck, token, 1);
  final done = Completer<(InternetAddress, int)?>();
  s.onPacket = (d) {
    final kind = kindOf(d.data, token);
    if (kind == kPunch) s.send(ack, d.address, d.port);
    if ((kind == kPunch || kind == kPunchAck) && !done.isCompleted) done.complete((d.address, d.port));
  };
  void send() {
    for (final (a, port) in peers) {
      s.send(p, a, port);
    }
  }

  send();
  final tick = Timer.periodic(_punchEvery, (_) => send());
  final giveUp = Timer(timeout, () {
    if (!done.isCompleted) done.complete(null);
  });
  try {
    return await done.future;
  } finally {
    tick.cancel();
    giveUp.cancel();
    s.onPacket = null;
  }
}

/// Runs a stream over the open path and returns a local port whose first
/// connection is carried over it (the same shape as the relay tunnel).
Future<int> forwardDirect(
  DirectSocket s,
  (InternetAddress, int) peer,
  Uint8List token, {
  required Duration timeout,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final giveUp = Timer(timeout, () {
    server.close();
    s.close();
  });
  server.first.then((local) {
    giveUp.cancel();
    server.close();
    local.setOption(SocketOption.tcpNoDelay, true);
    _DirectPump(s, peer, DirectConn(token, DateTime.now()), local).start();
  }, onError: (Object _) => s.close());
  return server.port;
}

/// Copies between the local socket and the direct path.
class _DirectPump {
  _DirectPump(this.udp, (InternetAddress, int) peer, this.conn, this.local)
    : _peerAddr = peer.$1,
      _peerPort = peer.$2;

  final DirectSocket udp;
  final DirectConn conn;
  final Socket local;
  InternetAddress _peerAddr;
  int _peerPort;
  late final StreamSubscription<Uint8List> _localSub;
  Uint8List? _pending;
  Timer? _timer;
  bool _localClosed = false;
  bool _finished = false;
  late final Uint8List _ack = packetHeader(kPunchAck, conn.token, 1);

  void start() {
    _localSub = local.listen(
      (data) {
        final n = conn.write(data);
        if (n < data.length) {
          _pending = Uint8List.sublistView(data, n);
          _localSub.pause();
        }
        _pump();
      },
      onError: (Object _) => _fail(),
      onDone: () {
        conn.close();
        _pump();
      },
      cancelOnError: true,
    );
    udp.onPacket = (d) {
      final kind = kindOf(d.data, conn.token);
      if (kind == null) return;
      if (kind == kPunch) {
        udp.send(_ack, d.address, d.port);
        return;
      }
      if (kind == kPunchAck) return;
      if (conn.onPacket(d.data, DateTime.now())) {
        // Follow the computer if its router moved it.
        _peerAddr = d.address;
        _peerPort = d.port;
      }
      _pump();
    };
    _pump();
  }

  void _pump() {
    if (_finished) return;
    final now = DateTime.now();
    final pending = _pending;
    if (pending != null) {
      final n = conn.write(pending);
      if (n == pending.length) {
        _pending = null;
        _localSub.resume();
      } else {
        _pending = Uint8List.sublistView(pending, n);
      }
    }
    if (conn.hasReady) {
      try {
        local.add(conn.read());
      } catch (_) {}
    }
    if (conn.peerFinished && !_localClosed) {
      _localClosed = true;
      local.close().catchError((Object _) {});
    }
    while (true) {
      final p = conn.pollTransmit(now);
      if (p == null) break;
      udp.send(p, _peerAddr, _peerPort);
    }
    if (conn.state != ConnState.open) return _end();
    _timer?.cancel();
    final wait = conn.nextTimeout(now).difference(now);
    _timer = Timer(wait, () {
      conn.onTimeout(DateTime.now());
      _pump();
    });
  }

  void _fail() {
    if (_finished) return;
    udp.send(conn.reset(), _peerAddr, _peerPort);
    _end();
  }

  void _end() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _localSub.cancel();
    if (conn.state == ConnState.failed) {
      local.destroy();
    } else if (!_localClosed) {
      local.close().catchError((Object _) {});
    }
    udp.close();
  }
}
