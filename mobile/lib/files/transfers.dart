// SPDX-License-Identifier: GPL-3.0-or-later
// Files between the phone and the computer, over the phone's connection.
// Same rules both ways (docs/PROTOCOL.md):
//   file_offer → file_accept → binary chunks → file_end (SHA-256) → file_done
// The receiver reports file_progress every MiB and when it has everything;
// the sender keeps at most 4 MiB unacknowledged and sends file_end only
// once every byte is acknowledged.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../pairing/codec.dart' show hex;

const _magic = [0x50, 0x44, 0x46, 0x31]; // "PDF1"
const chunkSize = 128 * 1024;
const window = 4 * 1024 * 1024;
const progressEvery = 1024 * 1024;

/// File ids the computer picks start here; the phone uses lower ones.
const agentFids = 1 << 31;

Uint8List chunkMessage(int fid, int offset, List<int> data) {
  final b = Uint8List(16 + data.length);
  b.setRange(0, 4, _magic);
  final d = ByteData.sublistView(b);
  d.setUint32(4, fid, Endian.little);
  d.setUint64(8, offset, Endian.little);
  b.setRange(16, b.length, data);
  return b;
}

bool isFileChunk(Uint8List m) =>
    m.length >= 16 && m[0] == _magic[0] && m[1] == _magic[1] && m[2] == _magic[2] && m[3] == _magic[3];

enum TransferState { waiting, active, done, failed }

class Transfer {
  Transfer({required this.fid, required this.incoming, required this.name, required this.size});
  final int fid;

  /// From the computer to this phone.
  final bool incoming;
  String name;
  final int size;
  int done = 0;
  TransferState state = TransferState.waiting;

  /// Why it failed.
  String? message;

  /// Received: where it was saved (shown to people) and how to open it.
  String? savedWhere;
  String? openUri;

  bool get finished => state == TransferState.done || state == TransferState.failed;
  double get fraction => size == 0 ? 1 : done / size;
}

/// A received file, saved where people can find it.
class SavedFile {
  const SavedFile({required this.where, this.uri});

  /// Human-readable place, e.g. "Download/PairDesk/report.pdf".
  final String where;

  /// For opening it; null if it can't be opened from the app.
  final String? uri;
}

/// What the transfers need from the connection.
abstract class TransferLink {
  void sendJson(Map<String, Object?> msg);
  void sendBinary(Uint8List data);
}

class TransferException implements Exception {
  TransferException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Outgoing {
  _Outgoing() {
    // A cancel can come before anyone waits; that mustn't count as unhandled.
    accepted.future.ignore();
    finished.future.ignore();
  }
  final accepted = Completer<void>();
  final finished = Completer<Map<String, dynamic>>();
  int acked = 0;
  Completer<void>? progressed;
  String? cancelled;

  void wake() {
    final p = progressed;
    progressed = null;
    if (p != null && !p.isCompleted) p.complete();
  }

  Future<void> nextProgress() {
    if (cancelled != null) throw TransferException(cancelled!);
    return (progressed ??= Completer<void>()).future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TransferException('The computer stopped receiving.'),
    );
  }
}

class _Incoming {
  _Incoming(this.transfer, this.temp, this.raf, this.hash);
  final Transfer transfer;
  final File temp;
  final RandomAccessFile raf;
  final HashSink hash;
  int received = 0;
  int reported = 0;

  /// Writes happen one after another, in arrival order.
  Future<void> queue = Future.value();
  String? error;
}

class FileTransfers extends ChangeNotifier {
  FileTransfers(this.link, {required this.save, this.tempDir});

  final TransferLink link;

  /// Moves a finished temp file to its place for people (Downloads).
  final Future<SavedFile> Function(File temp, String name) save;

  /// Where incoming files wait until they're complete (default: the app's
  /// cache).
  final Directory? tempDir;

  final List<Transfer> _items = [];
  final Map<int, _Outgoing> _out = {};
  final Map<int, _Incoming> _in = {};
  int _nextFid = 1;
  final _received = StreamController<Transfer>.broadcast();

  /// Newest first.
  List<Transfer> get items => List.unmodifiable(_items.reversed);
  bool get busy => _items.any((t) => !t.finished);

  /// Each file the computer sent, once it is saved.
  Stream<Transfer> get received => _received.stream;

  void _add(Transfer t) {
    _items.add(t);
    while (_items.length > 30) {
      final i = _items.indexWhere((x) => x.finished);
      if (i < 0) break;
      _items.removeAt(i);
    }
    notifyListeners();
  }

  void _fail(Transfer t, String msg) {
    if (t.finished) return;
    t.state = TransferState.failed;
    t.message = msg;
    notifyListeners();
  }

  // ---- sending --------------------------------------------------------

  /// Sends [file] to the computer; completes with the name it was saved
  /// under. Progress shows in [items].
  Future<Transfer> send(File file, {String? name}) async {
    final size = await file.length();
    final fid = _nextFid++;
    final t = Transfer(fid: fid, incoming: false, name: name ?? file.uri.pathSegments.last, size: size);
    _add(t);
    final out = _Outgoing();
    _out[fid] = out;
    RandomAccessFile? raf;
    try {
      link.sendJson({'t': 'file_offer', 'fid': fid, 'name': t.name, 'size': size});
      await out.accepted.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TransferException('The computer didn\'t answer.'),
      );
      t.state = TransferState.active;
      notifyListeners();
      raf = await file.open();
      final hash = Sha256().newHashSink();
      var sent = 0;
      while (sent < size) {
        while (sent - out.acked >= window) {
          await out.nextProgress();
        }
        final data = await raf.read(math.min(chunkSize, size - sent));
        if (data.isEmpty) throw TransferException('The file got shorter while sending.');
        if (out.cancelled != null) throw TransferException(out.cancelled!);
        hash.add(data);
        link.sendBinary(chunkMessage(fid, sent, data));
        sent += data.length;
      }
      while (out.acked < size) {
        await out.nextProgress();
      }
      hash.close();
      link.sendJson({'t': 'file_end', 'fid': fid, 'sha256': hex((await hash.hash()).bytes)});
      final done = await out.finished.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TransferException('The computer didn\'t confirm the file.'),
      );
      if (done['ok'] != true) {
        throw TransferException(done['msg'] as String? ?? 'The computer couldn\'t save it.');
      }
      t.name = done['name'] as String? ?? t.name;
      t.done = size;
      t.state = TransferState.done;
      notifyListeners();
      return t;
    } on TransferException catch (e) {
      _fail(t, e.message);
      link.sendJson({'t': 'file_cancel', 'fid': fid});
      rethrow;
    } catch (e) {
      _fail(t, 'Couldn\'t send: $e');
      link.sendJson({'t': 'file_cancel', 'fid': fid});
      throw TransferException('Couldn\'t send: $e');
    } finally {
      await raf?.close();
      _out.remove(fid);
    }
  }

  /// Stops a transfer in either direction.
  void cancel(int fid) {
    link.sendJson({'t': 'file_cancel', 'fid': fid});
    _cancelLocal(fid, 'Cancelled.');
  }

  void _cancelLocal(int fid, String msg) {
    final out = _out[fid];
    if (out != null) {
      out.cancelled = msg;
      if (!out.accepted.isCompleted) out.accepted.completeError(TransferException(msg));
      if (!out.finished.isCompleted) out.finished.completeError(TransferException(msg));
      out.wake();
    }
    final inc = _in.remove(fid);
    if (inc != null) {
      inc.error = msg;
      _fail(inc.transfer, msg);
      inc.queue = inc.queue.whenComplete(() => _discard(inc));
    }
  }

  Future<void> _discard(_Incoming inc) async {
    try {
      await inc.raf.close();
    } catch (_) {}
    try {
      await inc.temp.delete();
    } catch (_) {}
  }

  // ---- receiving ------------------------------------------------------

  Future<void> _offer(int fid, String name, int size) async {
    final t = Transfer(fid: fid, incoming: true, name: name, size: size);
    _add(t);
    try {
      final dir = Directory('${(tempDir ?? Directory.systemTemp).path}/pairdesk-in');
      await dir.create(recursive: true);
      final temp = File('${dir.path}/$fid.part');
      final raf = await temp.open(mode: FileMode.write);
      _in[fid] = _Incoming(t, temp, raf, Sha256().newHashSink());
      t.state = TransferState.active;
      notifyListeners();
      link.sendJson({'t': 'file_accept', 'fid': fid});
    } catch (e) {
      _fail(t, 'Couldn\'t save it: $e');
      link.sendJson({'t': 'file_cancel', 'fid': fid, 'msg': 'The phone couldn\'t save it: $e'});
    }
  }

  void _chunk(int fid, int offset, Uint8List data) {
    final inc = _in[fid];
    if (inc == null || inc.error != null) return;
    if (offset != inc.received || inc.received + data.length > inc.transfer.size) {
      link.sendJson({'t': 'file_cancel', 'fid': fid, 'msg': 'Parts of the file arrived out of order.'});
      _cancelLocal(fid, 'Parts of the file arrived out of order.');
      return;
    }
    inc.received += data.length;
    inc.hash.add(data);
    final received = inc.received;
    final report = received - inc.reported >= progressEvery || received == inc.transfer.size;
    if (report) inc.reported = received;
    inc.queue = inc.queue.then((_) async {
      if (inc.error != null) return;
      try {
        await inc.raf.writeFrom(data);
      } catch (e) {
        inc.error = 'Couldn\'t save it: $e';
        link.sendJson({'t': 'file_cancel', 'fid': fid, 'msg': 'The phone couldn\'t save it: $e'});
        _cancelLocal(fid, inc.error!);
        return;
      }
      inc.transfer.done = received;
      if (report) {
        // Reported after the bytes are on disk, so "everything" means it.
        link.sendJson({'t': 'file_progress', 'fid': fid, 'received': received});
        notifyListeners();
      }
    });
  }

  Future<void> _end(int fid, String sha256) async {
    final inc = _in[fid];
    if (inc == null) return;
    await inc.queue;
    _in.remove(fid);
    final t = inc.transfer;
    if (inc.error != null) return;
    try {
      await inc.raf.close();
      inc.hash.close();
      final digest = hex((await inc.hash.hash()).bytes);
      if (inc.received != t.size) throw TransferException('The file arrived incomplete.');
      if (digest != sha256.toLowerCase()) {
        throw TransferException('The file was damaged on the way (checksum mismatch).');
      }
      final saved = await save(inc.temp, t.name);
      t.savedWhere = saved.where;
      t.openUri = saved.uri;
      t.done = t.size;
      t.state = TransferState.done;
      link.sendJson({'t': 'file_done', 'fid': fid, 'ok': true});
      notifyListeners();
      _received.add(t);
    } catch (e) {
      final msg = e is TransferException ? e.message : 'Couldn\'t save it: $e';
      _fail(t, msg);
      link.sendJson({'t': 'file_done', 'fid': fid, 'ok': false, 'msg': msg});
      await _discard(inc);
    }
  }

  // ---- from the connection ---------------------------------------------

  /// Handles a `file_*` message; returns false for anything else.
  bool handleMessage(Map<String, dynamic> m) {
    final fid = m['fid'];
    if (fid is! int) return false;
    switch (m['t']) {
      case 'file_offer':
        final size = m['size'];
        if (fid < agentFids || size is! int || size < 0) {
          link.sendJson({'t': 'file_cancel', 'fid': fid, 'msg': 'Bad file offer.'});
        } else {
          _offer(fid, (m['name'] as String?) ?? 'file', size);
        }
      case 'file_accept':
        final out = _out[fid];
        if (out != null && !out.accepted.isCompleted) out.accepted.complete();
      case 'file_progress':
        final out = _out[fid];
        final n = m['received'];
        if (out != null && n is int) {
          out.acked = math.max(out.acked, n);
          final t = _items.where((x) => x.fid == fid && !x.incoming).lastOrNull;
          if (t != null) t.done = math.min(out.acked, t.size);
          out.wake();
          notifyListeners();
        }
      case 'file_end':
        _end(fid, (m['sha256'] as String?) ?? '');
      case 'file_done':
        final out = _out[fid];
        if (out != null && !out.finished.isCompleted) out.finished.complete(m);
      case 'file_cancel':
        _cancelLocal(fid, (m['msg'] as String?) ?? 'Cancelled on the computer.');
      default:
        return false;
    }
    return true;
  }

  void handleChunk(Uint8List m) {
    if (!isFileChunk(m)) return;
    final d = ByteData.sublistView(m);
    _chunk(d.getUint32(4, Endian.little), d.getUint64(8, Endian.little), Uint8List.sublistView(m, 16));
  }

  /// The connection dropped: everything in flight fails.
  void connectionLost() {
    for (final fid in [..._out.keys, ..._in.keys]) {
      _cancelLocal(fid, 'Disconnected from the computer.');
    }
  }

  @override
  void dispose() {
    connectionLost();
    _received.close();
    super.dispose();
  }
}
