// SPDX-License-Identifier: GPL-3.0-or-later
// A reliable, ordered byte stream over UDP ("PDU1"), for direct
// connections between the phone and a computer. The computer has the same
// code in Rust (agent/src/direct/conn.rs); the two must stay in step, and
// that file describes the packets.
//
// TLS runs inside it exactly as over TCP, with the certificate pinned, so
// this layer only has to deliver bytes in order. It does no input or output
// of its own: the caller feeds it packets and the time, and sends what it
// hands back.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

const kPunch = 1;
const kPunchAck = 2;
const kData = 3;
const kAck = 4;
const kFin = 5;
const kPing = 6;
const kReset = 7;

const maxPayload = 1200;
const _recvWindow = 2048;
const _sendBuffer = 2048;
const _initialCwnd = 16.0;
const _minCwnd = 2.0;
const _maxCwnd = 2048.0;
const _initialRto = Duration(milliseconds: 600);
const _minRto = Duration(milliseconds: 200);
const _maxRto = Duration(seconds: 4);
const idleTimeout = Duration(seconds: 20);
const _keepalive = Duration(seconds: 4);
const _burst = 10.0;
const _reorder = 3;

Uint8List packetHeader(int kind, Uint8List token, [int extra = 0]) {
  final p = Uint8List(9 + extra);
  p[0] = kind;
  p.setRange(1, 9, token);
  return p;
}

/// The packet's kind, if it carries this token.
int? kindOf(List<int> packet, Uint8List token) {
  if (packet.length < 9) return null;
  for (var i = 0; i < 8; i++) {
    if (packet[1 + i] != token[i]) return null;
  }
  return packet[0];
}

int _be32(List<int> b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void _put32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

class _Segment {
  _Segment(this.seq, this.data, {this.fin = false});
  final int seq;
  final Uint8List data;
  final bool fin;
  DateTime? sent;
  bool retransmitted = false;
  bool acked = false;
  bool lost = false;
}

enum ConnState { open, closed, failed }

Duration _min(Duration a, Duration b) => a < b ? a : b;
Duration _max(Duration a, Duration b) => a > b ? a : b;
DateTime _minT(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

class DirectConn {
  DirectConn(this.token, DateTime now) : _refilled = now, _lastSent = now, _lastHeard = now;

  final Uint8List token;
  ConnState _state = ConnState.open;
  ConnState get state => _state;

  // Sending.
  final _queue = ListQueue<_Segment>();
  int _nextSeq = 0;
  bool _closing = false;
  bool _finAcked = false;
  double _cwnd = _initialCwnd;
  double _ssthresh = _maxCwnd;
  Duration? _srtt;
  Duration _rttvar = Duration.zero;
  Duration _rto = _initialRto;
  int _recovery = 0;
  DateTime? _rackSent;
  int _peerWindow = _recvWindow;
  double _tokens = _burst;
  DateTime _refilled;
  DateTime _lastSent;

  // Receiving.
  int _rcvNext = 0;
  final _early = SplayTreeMap<int, (Uint8List, bool)>();
  final _ready = BytesBuilder(copy: false);
  int _readyPackets = 0;
  bool _peerFinished = false;
  bool _ackDue = false;
  DateTime _lastHeard;

  int get sendSpace =>
      (_closing || _state != ConnState.open) ? 0 : math.max(0, _sendBuffer - _queue.length) * maxPayload;

  /// Queues as much of [data] as fits; returns how much.
  int write(List<int> data) {
    final room = math.min(sendSpace, data.length);
    for (var o = 0; o < room; o += maxPayload) {
      final end = math.min(room, o + maxPayload);
      _queue.add(_Segment(_nextSeq++, Uint8List.fromList(data.sublist(o, end))));
    }
    return room;
  }

  void close() {
    if (_closing || _state != ConnState.open) return;
    _closing = true;
    _queue.add(_Segment(_nextSeq++, Uint8List(0), fin: true));
  }

  Uint8List reset() {
    _state = ConnState.failed;
    return packetHeader(kReset, token);
  }

  bool get hasReady => _ready.length > 0;

  /// Everything received in order and not read yet.
  Uint8List read() {
    final out = _ready.takeBytes();
    _readyPackets = 0;
    if (out.isNotEmpty) _ackDue = true;
    return out;
  }

  bool get peerFinished => _peerFinished && _ready.length == 0;

  int get _window => math.max(0, _recvWindow - _early.length - _readyPackets);

  bool onPacket(List<int> packet, DateTime now) {
    final kind = kindOf(packet, token);
    if (kind == null) return false;
    final bodyLen = packet.length - 9;
    switch (kind) {
      case kData || kFin when bodyLen >= 4:
        final seq = _be32(packet, 9);
        final dataLen = bodyLen - 4;
        if (kind == kData && (dataLen == 0 || dataLen > maxPayload)) return false;
        _lastHeard = now;
        _ackDue = true;
        if (seq >= _rcvNext && seq - _rcvNext < _recvWindow) {
          _early.putIfAbsent(seq, () => (Uint8List.fromList(packet.sublist(13)), kind == kFin));
          while (true) {
            final e = _early.remove(_rcvNext);
            if (e == null) break;
            _rcvNext++;
            if (e.$2) {
              _peerFinished = true;
              _early.clear();
              break;
            }
            _ready.add(e.$1);
          }
          _readyPackets = (_ready.length + maxPayload - 1) ~/ maxPayload;
        }
      case kAck when bodyLen >= 14:
        _lastHeard = now;
        final next = _be32(packet, 9);
        _peerWindow = (packet[13] << 8) | packet[14];
        final hi = _be32(packet, 15), lo = _be32(packet, 19);
        _onAck(next, hi, lo, now);
      case kPing:
        _lastHeard = now;
        _ackDue = true;
      case kReset:
        _state = ConnState.failed;
      default:
        return false;
    }
    _checkClosed();
    return true;
  }

  static bool _sackBit(int hi, int lo, int i) => i < 32 ? (lo >> i) & 1 == 1 : (hi >> (i - 32)) & 1 == 1;

  void _onAck(int next, int hi, int lo, DateTime now) {
    Duration? sample;
    var newly = 0;
    int? highest;
    for (final seg in _queue) {
      final covered =
          seg.seq < next ||
          (seg.seq > next && seg.seq - next - 1 < 64 && _sackBit(hi, lo, seg.seq - next - 1));
      if (covered && !seg.acked) {
        seg.acked = true;
        newly++;
        if (seg.fin) _finAcked = true;
        if (seg.sent != null && !seg.retransmitted) sample = now.difference(seg.sent!);
        final sent = seg.sent;
        if (sent != null && (_rackSent == null || sent.isAfter(_rackSent!))) _rackSent = sent;
      }
      if (seg.acked) highest = seg.seq;
    }
    while (_queue.isNotEmpty && _queue.first.acked) {
      _queue.removeFirst();
    }
    if (sample != null) _updateRtt(sample.isNegative ? Duration.zero : sample);
    for (var i = 0; i < newly; i++) {
      _cwnd += _cwnd < _ssthresh ? 1.0 : 1.0 / _cwnd;
    }
    _cwnd = math.min(_cwnd, _maxCwnd);
    final rack = _rackSent;
    if (highest != null && rack != null) {
      var loss = false;
      for (final seg in _queue) {
        if (!seg.acked &&
            !seg.lost &&
            seg.sent != null &&
            seg.sent!.isBefore(rack) &&
            seg.seq + _reorder <= highest) {
          seg.lost = true;
          if (seg.seq >= _recovery) loss = true;
        }
      }
      if (loss) {
        _ssthresh = math.max(_cwnd / 2, _minCwnd);
        _cwnd = _ssthresh;
        _recovery = _nextSeq;
      }
    }
  }

  void _updateRtt(Duration rtt) {
    final srtt = _srtt;
    if (srtt == null) {
      _srtt = rtt;
      _rttvar = rtt ~/ 2;
    } else {
      final diff = (srtt - rtt).abs();
      _rttvar = (_rttvar * 3 + diff) ~/ 4;
      _srtt = (srtt * 7 + rtt) ~/ 8;
    }
    final rto = _srtt! + _max(_rttvar * 4, const Duration(milliseconds: 10));
    _rto = _min(_max(rto, _minRto), _maxRto);
  }

  void _checkClosed() {
    if (_state == ConnState.open && _closing && _finAcked && _peerFinished && _ready.length == 0) {
      _state = ConnState.closed;
    }
  }

  int get _inflight => _queue.where((s) => s.sent != null && !s.acked && !s.lost).length;

  void _refill(DateTime now) {
    final srtt = _max(_srtt ?? const Duration(milliseconds: 100), const Duration(milliseconds: 5));
    final rate = _cwnd * 1.25 / (srtt.inMicroseconds / 1e6);
    final elapsed = math.max(0, now.difference(_refilled).inMicroseconds) / 1e6;
    _tokens = math.min(_tokens + rate * elapsed, math.max(_burst, _cwnd / 4));
    _refilled = now;
  }

  Uint8List _dataPacket(_Segment s) {
    final p = packetHeader(s.fin ? kFin : kData, token, 4 + s.data.length);
    _put32(p, 9, s.seq);
    p.setRange(13, 13 + s.data.length, s.data);
    return p;
  }

  Uint8List _ackPacket() {
    var hi = 0, lo = 0;
    for (final seq in _early.keys) {
      final off = seq - _rcvNext;
      if (off >= 1 && off <= 64) {
        final i = off - 1;
        if (i < 32) {
          lo |= 1 << i;
        } else {
          hi |= 1 << (i - 32);
        }
      }
    }
    final p = packetHeader(kAck, token, 14);
    _put32(p, 9, _rcvNext);
    final w = math.min(_window, 0xffff);
    p[13] = w >> 8;
    p[14] = w & 0xff;
    _put32(p, 15, hi);
    _put32(p, 19, lo);
    return p;
  }

  /// The next packet to send now, if any. Call until it returns null.
  Uint8List? pollTransmit(DateTime now) {
    if (_state == ConnState.failed) return null;
    if (_ackDue) {
      _ackDue = false;
      _lastSent = now;
      return _ackPacket();
    }
    if (_state != ConnState.open) return null;
    _refill(now);
    if (_tokens >= 1) {
      final limit = math.min(_cwnd.toInt(), math.max(1, _peerWindow));
      _Segment? pick;
      if (_inflight < limit) {
        for (final s in _queue) {
          if (s.lost && !s.acked) {
            pick = s;
            break;
          }
        }
        if (pick == null) {
          for (final s in _queue) {
            if (s.sent == null) {
              pick = s;
              break;
            }
          }
        }
      }
      if (pick != null) {
        if (pick.sent != null) pick.retransmitted = true;
        pick.lost = false;
        pick.sent = now;
        _tokens -= 1;
        _lastSent = now;
        return _dataPacket(pick);
      }
    }
    if (now.difference(_lastSent) >= _keepalive) {
      _lastSent = now;
      return packetHeader(kPing, token);
    }
    return null;
  }

  void onTimeout(DateTime now) {
    if (_state != ConnState.open) return;
    if (now.difference(_lastHeard) >= idleTimeout) {
      _state = ConnState.failed;
      return;
    }
    _Segment? oldest;
    for (final seg in _queue) {
      if (!seg.acked && !seg.lost && seg.sent != null) {
        oldest = seg;
        break;
      }
    }
    if (oldest != null && now.difference(oldest.sent!) >= _rto) {
      // Everything still out is presumed lost (a whole burst often is) and
      // sent again as the window allows.
      for (final seg in _queue) {
        if (!seg.acked && seg.sent != null) seg.lost = true;
      }
      _ssthresh = math.max(_cwnd / 2, _minCwnd);
      _cwnd = _minCwnd;
      _rto = _min(_rto * 2, _maxRto);
      _recovery = _nextSeq;
    }
  }

  DateTime nextTimeout(DateTime now) {
    var at = _minT(_lastHeard.add(idleTimeout), _lastSent.add(_keepalive));
    for (final s in _queue) {
      if (!s.acked && !s.lost && s.sent != null) at = _minT(at, s.sent!.add(_rto));
    }
    final limit = math.min(_cwnd.toInt(), math.max(1, _peerWindow));
    final waiting = _queue.any((s) => s.lost || s.sent == null);
    if (waiting && _tokens < 1 && _inflight < limit) at = _minT(at, now.add(const Duration(milliseconds: 2)));
    return at.isBefore(now) ? now : at;
  }
}
