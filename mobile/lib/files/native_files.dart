// SPDX-License-Identifier: GPL-3.0-or-later
// Android side of files (MainActivity.kt): picking files, saving received
// ones to Download/PairDesk, opening them, and what other apps shared.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'transfers.dart';

/// A file ready to send: a private copy in the app's cache.
class PickedFile {
  const PickedFile(this.path, this.name);
  final String path;
  final String name;
}

/// What another app shared with PairDesk.
class SharedItems {
  const SharedItems({this.files = const [], this.text, this.link});
  final List<PickedFile> files;
  final String? text;

  /// A PairDesk link that opened the app (pairing or "Get help").
  final String? link;
  bool get isEmpty => files.isEmpty && (text == null || text!.isEmpty) && link == null;
}

class NativeFiles {
  NativeFiles._();
  static final instance = NativeFiles._();
  static const _channel = MethodChannel('pairdesk/files');
  final _sharedArrived = StreamController<void>.broadcast();
  bool _listening = false;

  /// Something was shared with PairDesk while it was open; call [takeShared].
  Stream<void> get sharedArrived {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'shared') _sharedArrived.add(null);
      });
    }
    return _sharedArrived.stream;
  }

  static List<PickedFile> _files(Object? list) => [
    if (list is List)
      for (final f in list)
        if (f is Map && f['path'] is String)
          PickedFile(f['path'] as String, (f['name'] as String?) ?? 'file'),
  ];

  /// Lets the person choose files; empty if they cancel.
  Future<List<PickedFile>> pickFiles() async => _files(await _channel.invokeMethod<Object?>('pickFiles'));

  Future<SharedItems> takeShared() async {
    final m = await _channel.invokeMethod<Map<Object?, Object?>>('takeShared');
    if (m == null) return const SharedItems();
    return SharedItems(files: _files(m['files']), text: m['text'] as String?, link: m['link'] as String?);
  }

  /// Moves a received file into Download/PairDesk.
  Future<SavedFile> saveToDownloads(File temp, String name) async {
    final m = await _channel.invokeMethod<Map<Object?, Object?>>('saveToDownloads', {
      'path': temp.path,
      'name': name,
    });
    return SavedFile(where: (m?['where'] as String?) ?? name, uri: m?['uri'] as String?);
  }

  /// Opens a received file with the app that handles it; false if none.
  Future<bool> open(String uri, String name) async =>
      await _channel.invokeMethod<bool>('openFile', {'uri': uri, 'name': name}) ?? false;
}
