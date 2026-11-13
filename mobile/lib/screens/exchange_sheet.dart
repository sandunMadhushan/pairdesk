// SPDX-License-Identifier: GPL-3.0-or-later
// Clipboard and file actions between the phone and the computer, used by
// the Files tab and by "Share → PairDesk".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent_connection.dart';
import '../files/native_files.dart';
import '../files/transfers.dart';

/// Shows a message on the control screen's scaffold.
typedef Say = void Function(String text, {SnackBarAction? action});

String formatSize(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = n / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

/// Clipboard actions, shared by the sheet and "Share → PairDesk".
class Exchange {
  Exchange(this.conn, this.say, {this.nativeFiles});
  final AgentConnection conn;
  final Say say;

  /// Default: the Android side.
  final NativeFiles? nativeFiles;
  NativeFiles get files => nativeFiles ?? NativeFiles.instance;

  String _preview(String t) {
    final one = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 40 ? '${one.substring(0, 40)}…' : one;
  }

  Future<void> copyFromComputer() async {
    try {
      final text = await conn.clipboardGet();
      if (text.isEmpty) {
        say('The computer\'s clipboard has no text.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      say('Copied from the computer: "${_preview(text)}"');
    } on RequestException catch (e) {
      say(e.message);
    }
  }

  Future<void> sendText(String text, {bool paste = false}) async {
    if (text.isEmpty) {
      say('Nothing to send: the phone\'s clipboard is empty.');
      return;
    }
    try {
      await conn.clipboardSet(text, paste: paste);
      say(paste ? 'Pasted on the computer.' : 'On the computer\'s clipboard. Paste it there with Ctrl+V.');
    } on RequestException catch (e) {
      say(e.message);
    }
  }

  Future<void> sendPhoneClipboard({bool paste = false}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    await sendText(data?.text ?? '', paste: paste);
  }

  /// Sends files (copies in the cache, deleted afterwards).
  Future<void> sendFiles(List<PickedFile> picked) async {
    if (picked.isEmpty) return;
    var ok = 0;
    String? lastError;
    for (final p in picked) {
      final f = File(p.path);
      try {
        await conn.sendFile(f, name: p.name);
        ok++;
      } on RequestException catch (e) {
        lastError = '${p.name}: ${e.message}';
      } finally {
        try {
          await f.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
    final where = conn.agentOs == 'windows' ? 'Downloads\\PairDesk' : 'Downloads/PairDesk';
    if (lastError != null) {
      say(ok == 0 ? lastError : '$ok of ${picked.length} files sent. $lastError');
    } else {
      say(ok == 1 ? 'Sent. It\'s in $where on the computer.' : '$ok files sent to $where on the computer.');
    }
  }

  Future<void> pickAndSend() async {
    try {
      await sendFiles(await files.pickFiles());
    } catch (e) {
      say('Couldn\'t open the file picker: $e');
    }
  }

  Future<void> open(Transfer t) async {
    final uri = t.openUri;
    if (uri == null || !await files.open(uri, t.name)) {
      say('No app on this phone opens that file. It\'s in ${t.savedWhere ?? 'Download/PairDesk'}.');
    }
  }
}
