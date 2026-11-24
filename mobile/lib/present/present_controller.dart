// SPDX-License-Identifier: GPL-3.0-or-later
// Presenter mode: the keys a slideshow understands, and a talk timer.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent_connection.dart';

/// "4:05", or "1:02:09" past an hour. Negative durations are shown without
/// the sign (the caller says "over").
String formatClock(Duration d) {
  final s = d.inSeconds.abs();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// A stopwatch that takes the time from the caller (so tests don't wait),
/// with an optional target to count down to.
class PresentTimer {
  PresentTimer({this.target = Duration.zero});

  /// How long the talk should take; zero means just count up.
  Duration target;

  Duration _before = Duration.zero;
  DateTime? _since;

  bool get running => _since != null;

  Duration elapsed(DateTime now) => _before + (_since == null ? Duration.zero : now.difference(_since!));

  /// Time left, or negative once over. Null without a target.
  Duration? remaining(DateTime now) => target == Duration.zero ? null : target - elapsed(now);

  void start(DateTime now) => _since ??= now;

  void pause(DateTime now) {
    if (_since == null) return;
    _before += now.difference(_since!);
    _since = null;
  }

  void reset() {
    _before = Duration.zero;
    _since = null;
  }
}

/// How a slide show answers to keys. PowerPoint, LibreOffice Impress, PDF
/// viewers and browsers' full-screen slides share these.
class PresentController extends ChangeNotifier {
  PresentController({required this.press, required this.combo, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final void Function(AgentKey key) press;
  final void Function(List<Modifier> mods, {AgentKey? key, String? char}) combo;
  final DateTime Function() _now;

  final PresentTimer timer = PresentTimer();
  Timer? _tick;

  bool blanked = false;
  bool laser = false;

  void next() => press(AgentKey.right);
  void previous() => press(AgentKey.left);
  void first() => press(AgentKey.home);
  void last() => press(AgentKey.end);

  /// From the first slide (F5).
  void start() {
    press(AgentKey.f5);
    startTimer();
  }

  /// From the current slide (Shift+F5).
  void startHere() {
    combo([Modifier.shift], key: AgentKey.f5);
    startTimer();
  }

  void stop() {
    press(AgentKey.escape);
    blanked = false;
    laser = false;
    notifyListeners();
  }

  /// Black screen (B); the same key brings the slide back.
  void toggleBlank() {
    combo(const [], char: 'b');
    blanked = !blanked;
    notifyListeners();
  }

  /// PowerPoint's laser pointer (Ctrl+L). The pad on the Present screen
  /// moves the pointer; other programs just see a normal pointer.
  void toggleLaser() {
    combo([Modifier.ctrl], char: 'l');
    laser = !laser;
    notifyListeners();
  }

  // ---- Timer ----------------------------------------------------------

  Duration get elapsed => timer.elapsed(_now());
  Duration? get remaining => timer.remaining(_now());
  bool get timerRunning => timer.running;

  void startTimer() {
    timer.start(_now());
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
  }

  void pauseTimer() {
    timer.pause(_now());
    _stopTick();
    notifyListeners();
  }

  void resetTimer() {
    timer.reset();
    _stopTick();
    notifyListeners();
  }

  void setTarget(Duration d) {
    timer.target = d;
    notifyListeners();
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  void dispose() {
    _stopTick();
    super.dispose();
  }
}
