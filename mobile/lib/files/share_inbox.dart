// SPDX-License-Identifier: GPL-3.0-or-later
// Files and text other apps shared with PairDesk ("Share → PairDesk"),
// waiting until a computer is connected to take them.

import 'package:flutter/foundation.dart';

import 'native_files.dart';

class ShareInbox extends ChangeNotifier {
  ShareInbox({Future<SharedItems> Function()? take}) : _take = take ?? NativeFiles.instance.takeShared;

  static final instance = ShareInbox();

  final Future<SharedItems> Function() _take;
  SharedItems? _pending;
  bool _started = false;

  /// Waiting to be sent, if anything.
  SharedItems? get pending => _pending;

  /// Picks up what started the app, and anything shared while it runs.
  void start() {
    if (_started) return;
    _started = true;
    check();
    try {
      NativeFiles.instance.sharedArrived.listen((_) => check());
    } catch (_) {}
  }

  Future<void> check() async {
    try {
      final s = await _take();
      if (s.isEmpty) return;
      final old = _pending;
      _pending = old == null ? s : SharedItems(files: [...old.files, ...s.files], text: s.text ?? old.text);
      notifyListeners();
    } catch (_) {
      // No Android side (tests, other platforms): nothing shared.
    }
  }

  /// Takes everything waiting; null if nothing.
  SharedItems? take() {
    final p = _pending;
    if (p == null) return null;
    _pending = null;
    notifyListeners();
    return p;
  }

  /// For tests.
  @visibleForTesting
  void put(SharedItems items) {
    _pending = items;
    notifyListeners();
  }
}
