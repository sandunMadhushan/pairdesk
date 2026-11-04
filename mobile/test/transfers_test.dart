// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/files/transfers.dart';

/// Plays the computer's side, the way the agent does (agent/src/files.rs).
class FakeComputer implements TransferLink {
  late FileTransfers phone;
  final sent = <Map<String, Object?>>[];
  final received = BytesBuilder();
  int acked = 0;
  int? size;

  /// Report progress like the agent (every MiB and at the end)?
  bool reportProgress = true;
  String? corruptHash;
  String? refuse;

  void reply(Map<String, dynamic> m) => scheduleMicrotask(() => phone.handleMessage(m));

  @override
  void sendJson(Map<String, Object?> msg) {
    sent.add(msg);
    final fid = msg['fid'];
    switch (msg['t']) {
      case 'file_offer':
        size = msg['size'] as int;
        if (refuse != null) {
          reply({'t': 'file_cancel', 'fid': fid, 'msg': refuse});
        } else {
          reply({'t': 'file_accept', 'fid': fid});
        }
      case 'file_end':
        final ok = (corruptHash ?? msg['sha256']) == sha256.convert(received.toBytes()).toString();
        reply({
          't': 'file_done',
          'fid': fid,
          'ok': ok,
          if (ok) 'name': 'saved name.bin',
          if (!ok) 'msg': 'The file was damaged on the way (checksum mismatch).',
        });
    }
  }

  @override
  void sendBinary(Uint8List data) {
    expect(isFileChunk(data), isTrue);
    final d = ByteData.sublistView(data);
    expect(d.getUint64(8, Endian.little), received.length, reason: 'in order');
    received.add(Uint8List.sublistView(data, 16));
    if (!reportProgress) return;
    final n = received.length;
    if (n - acked >= progressEvery || n == size) {
      acked = n;
      reply({'t': 'file_progress', 'fid': d.getUint32(4, Endian.little), 'received': n});
    }
  }
}

void main() {
  late Directory tmp;
  late FakeComputer computer;
  late FileTransfers phone;
  late List<(String, String)> saved;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pairdesk-test');
    computer = FakeComputer();
    saved = [];
    phone = FileTransfers(
      computer,
      tempDir: tmp,
      save: (temp, name) async {
        final dest = File('${tmp.path}/saved-$name');
        await temp.rename(dest.path);
        saved.add((dest.path, name));
        return SavedFile(where: 'Download/PairDesk/$name', uri: 'content://test/$name');
      },
    );
    computer.phone = phone;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File makeFile(int size) {
    final f = File('${tmp.path}/out-$size.bin');
    f.writeAsBytesSync(List.generate(size, (i) => (i * 7) & 0xff));
    return f;
  }

  /// Waits until [done], or gives up after [limit]. Loaded machines (a
  /// build in the background, a busy CI runner) take their time, so these
  /// tests wait for the thing they are about to check instead of sleeping
  /// for a fixed number of milliseconds and hoping.
  Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(limit);
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('sends a file in order, within the window, with its checksum', () async {
    final f = makeFile(window + 3 * chunkSize + 5);
    final t = await phone.send(f);
    expect(t.state, TransferState.done);
    expect(t.name, 'saved name.bin', reason: 'the name the computer used');
    expect(computer.received.toBytes(), f.readAsBytesSync());
    expect(computer.sent.first, {
      't': 'file_offer',
      'fid': 1,
      'name': 'out-${f.lengthSync()}.bin',
      'size': f.lengthSync(),
    });
    expect(computer.sent.last['t'], 'file_end');
    expect(phone.items.single.fraction, 1);
  });

  test('waits for the computer before sending more than the window', () async {
    computer.reportProgress = false;
    final f = makeFile(window + chunkSize);
    final sending = phone.send(f);
    // Reading and sending 4 MiB takes as long as the machine takes, so wait
    // for the window to fill rather than guessing at a delay.
    await until(() => computer.received.length >= window);
    expect(computer.received.length, window, reason: 'stops at the window');
    expect(computer.sent.any((m) => m['t'] == 'file_end'), isFalse);
    // The computer catches up.
    computer.reportProgress = true;
    phone.handleMessage({'t': 'file_progress', 'fid': 1, 'received': window});
    await until(() => computer.received.length > window);
    phone.handleMessage({'t': 'file_progress', 'fid': 1, 'received': window + chunkSize});
    expect((await sending).state, TransferState.done);
  });

  test('a refusal or damage on the way is reported', () async {
    computer.refuse = 'This is turned off in PairDesk settings on the computer.';
    await expectLater(
      phone.send(makeFile(10)),
      throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('turned off'))),
    );
    computer.refuse = null;
    computer.corruptHash = '00';
    await expectLater(phone.send(makeFile(20)), throwsA(isA<TransferException>()));
    expect(phone.items.first.state, TransferState.failed);
    expect(phone.items.first.message, contains('checksum'));
  });

  test('a lost connection fails what is in flight', () async {
    computer.reportProgress = false;
    final sending = phone.send(makeFile(window * 2));
    await until(() => computer.received.isNotEmpty);
    phone.connectionLost();
    await expectLater(sending, throwsA(isA<TransferException>()));
    expect(phone.items.single.message, 'Disconnected from the computer.');
  });

  /// Feeds a file to the phone the way the agent sends one.
  Future<void> computerSends(int fid, String name, List<int> data, {String? sha}) async {
    phone.handleMessage({'t': 'file_offer', 'fid': fid, 'name': name, 'size': data.length});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(computer.sent.last, {'t': 'file_accept', 'fid': fid});
    for (var off = 0; off < data.length; off += chunkSize) {
      final end = off + chunkSize < data.length ? off + chunkSize : data.length;
      phone.handleChunk(chunkMessage(fid, off, data.sublist(off, end)));
    }
    // The agent waits for "everything received" before file_end.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!computer.sent.any(
      (m) => m['t'] == 'file_progress' && m['fid'] == fid && m['received'] == data.length,
    )) {
      if (DateTime.now().isAfter(deadline)) fail('no final progress: ${computer.sent}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    phone.handleMessage({'t': 'file_end', 'fid': fid, 'sha256': sha ?? sha256.convert(data).toString()});
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('receives a file from the computer and saves it', () async {
    final data = List.generate(3 * progressEvery ~/ 2, (i) => i & 0xff);
    final got = phone.received.first;
    await computerSends(agentFids + 1, 'report.pdf', data);
    final t = await got.timeout(const Duration(seconds: 2));
    expect(t.state, TransferState.done);
    expect(t.savedWhere, 'Download/PairDesk/report.pdf');
    expect(File(saved.single.$1).readAsBytesSync(), data);
    final progress = computer.sent.where((m) => m['t'] == 'file_progress').map((m) => m['received']);
    expect(progress, [progressEvery, data.length]);
    expect(computer.sent.last, {'t': 'file_done', 'fid': agentFids + 1, 'ok': true});
  });

  test('a damaged file from the computer is refused and deleted', () async {
    await computerSends(agentFids + 2, 'x.bin', [1, 2, 3], sha: '00');
    expect(computer.sent.last['ok'], false);
    expect(saved, isEmpty);
    expect(Directory('${tmp.path}/pairdesk-in').listSync(), isEmpty);
    // Offers with a phone-side id are refused.
    phone.handleMessage({'t': 'file_offer', 'fid': 5, 'name': 'y', 'size': 1});
    expect(computer.sent.last['t'], 'file_cancel');
  });
}
