// SPDX-License-Identifier: GPL-3.0-or-later
// Turns raw finger events into touchpad actions. Pure Dart (no widgets) so
// the behaviour can be unit-tested.
//
//   1 finger move   -> move cursor (with mild acceleration)
//   1 finger tap    -> left click
//   2 finger move   -> scroll (content follows fingers, like a laptop pad)
//   2 finger tap    -> right click
//   3 finger tap    -> middle click
//
// Optional, for the screen view:
//   tap, then touch again and move -> drag (left button held)   [tapToDrag]
//   2 fingers spreading or closing -> zoom                       [onPinch]

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'agent_connection.dart' show MouseBtn;

class TouchpadGestures {
  TouchpadGestures({
    required this.onMove,
    required this.onClick,
    required this.onScroll,
    this.sensitivity = 1.6,
    this.scrollStepPx = 18,
    this.tapMaxDuration = const Duration(milliseconds: 220),
    this.tapMaxTravelPx = 10,
    this.onButton,
    this.onPinch,
    this.doubleTapWindow = const Duration(milliseconds: 250),
    Timer Function(Duration, void Function())? timer,
  }) : _timer = timer ?? Timer.new;

  final void Function(int dx, int dy) onMove;
  final void Function(MouseBtn button) onClick;
  final void Function(int dx, int dy) onScroll;

  /// Press (`true`) or release a button. When set, tap-and-drag works:
  /// a tap followed quickly by a touch that moves drags with the left
  /// button held. The first tap's click then waits [doubleTapWindow]
  /// to see whether a drag follows.
  final void Function(MouseBtn button, bool down)? onButton;

  /// Two fingers spreading (> 1) or closing (< 1), around [focal].
  /// When set, a two-finger gesture is either a pinch or a scroll,
  /// decided by which shows first.
  final void Function(double scale, Offset focal)? onPinch;

  final Duration doubleTapWindow;
  final Timer Function(Duration, void Function()) _timer;

  /// Base cursor speed multiplier.
  double sensitivity;

  /// Finger travel (logical px) for one scroll line.
  final double scrollStepPx;
  final Duration tapMaxDuration;
  final double tapMaxTravelPx;

  final Map<int, Offset> _pointers = {};
  Duration _gestureStart = Duration.zero;
  int _maxPointers = 0;
  double _travel = 0;

  // Fractional remainders, so slow movements are not lost to rounding.
  double _moveRemX = 0, _moveRemY = 0;
  double _scrollAccX = 0, _scrollAccY = 0;

  // Tap-and-drag: a click waiting to see whether a drag follows.
  Timer? _pendingClick;
  Duration _lastTapUp = Duration.zero;
  bool _secondTouch = false;
  bool _dragging = false;

  // Two fingers: undecided, scrolling or pinching.
  _TwoFinger _two = _TwoFinger.undecided;
  double _pinchStart = 0, _pinchLast = 0;

  int get activePointers => _pointers.length;

  /// True while a tap-and-drag holds the left button.
  bool get dragging => _dragging;

  void pointerDown(int id, Offset pos, Duration time) {
    if (_pointers.isEmpty) {
      _gestureStart = time;
      _maxPointers = 0;
      _travel = 0;
      _moveRemX = _moveRemY = 0;
      _scrollAccX = _scrollAccY = 0;
      _two = _TwoFinger.undecided;
      final pending = _pendingClick;
      _secondTouch = pending != null && time - _lastTapUp <= doubleTapWindow;
      if (pending != null && !_secondTouch) _flushClick();
      pending?.cancel();
      _pendingClick = null;
    }
    _pointers[id] = pos;
    _maxPointers = math.max(_maxPointers, _pointers.length);
    if (_pointers.length == 2) {
      if (_secondTouch) {
        // Not a drag after all: the earlier tap was just a click.
        _secondTouch = false;
        onClick(MouseBtn.left);
      }
      _endDrag();
      _pinchStart = _pinchLast = _spread();
    }
  }

  void pointerMove(int id, Offset pos, Duration time) {
    final last = _pointers[id];
    if (last == null) return;
    _pointers[id] = pos;
    final delta = pos - last;
    _travel += delta.distance;

    if (_pointers.length == 1 && _maxPointers == 1) {
      if (_secondTouch && !_dragging && _travel > tapMaxTravelPx) {
        _dragging = true;
        onButton?.call(MouseBtn.left, true);
      }
      _moveCursor(delta);
    } else if (_pointers.length == 2 && onPinch != null && _two != _TwoFinger.scroll) {
      final spread = _spread();
      if (_two == _TwoFinger.undecided && _pinchStart > 0 && (spread / _pinchStart - 1).abs() > 0.15) {
        _two = _TwoFinger.pinch;
        _pinchLast = _pinchStart;
      }
      if (_two == _TwoFinger.pinch) {
        if (_pinchLast > 0 && spread > 0) onPinch!(spread / _pinchLast, _focal());
        _pinchLast = spread;
      } else {
        _scrollBy(delta);
      }
    } else if (_pointers.length >= 2 && _two != _TwoFinger.pinch) {
      _scrollBy(delta);
    }
    // A finger left over after a two-finger gesture does nothing until all
    // fingers lift, so the cursor doesn't jump at the end of a scroll.
  }

  void pointerUp(int id, Offset pos, Duration time) {
    if (_pointers.remove(id) == null) return;
    if (_pointers.isNotEmpty) return;

    final isTap = (time - _gestureStart) <= tapMaxDuration && _travel <= tapMaxTravelPx;
    if (_dragging) {
      _endDrag();
      _secondTouch = false;
      return;
    }
    if (_secondTouch) {
      // Tap, tap: a double click. Tap, then a still press: one click.
      _secondTouch = false;
      onClick(MouseBtn.left);
      if (isTap) onClick(MouseBtn.left);
      return;
    }
    if (!isTap) return;
    switch (_maxPointers) {
      case 1:
        if (onButton == null) {
          onClick(MouseBtn.left);
        } else {
          _lastTapUp = time;
          _pendingClick = _timer(doubleTapWindow, _flushClick);
        }
      case 2:
        onClick(MouseBtn.right);
      case >= 3:
        onClick(MouseBtn.middle);
    }
  }

  void pointerCancel(int id) {
    _pointers.remove(id);
    if (_pointers.isEmpty) {
      _travel = double.infinity; // never a tap
      _endDrag();
      _secondTouch = false;
    }
  }

  /// Releases anything held (call when the view goes away).
  void reset() {
    _pendingClick?.cancel();
    _pendingClick = null;
    _pointers.clear();
    _endDrag();
    _secondTouch = false;
  }

  void _flushClick() {
    _pendingClick = null;
    onClick(MouseBtn.left);
  }

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    onButton?.call(MouseBtn.left, false);
  }

  double _spread() {
    if (_pointers.length < 2) return 0;
    final p = _pointers.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  Offset _focal() {
    final p = _pointers.values.take(2).toList();
    return (p[0] + p[1]) / 2;
  }

  void _scrollBy(Offset delta) {
    // Every finger reports its own move; average them by the finger count.
    _scrollAccX += delta.dx / _pointers.length;
    _scrollAccY += delta.dy / _pointers.length;
    if (_emitScroll()) _two = _TwoFinger.scroll;
  }

  void _moveCursor(Offset delta) {
    final speed = delta.distance;
    // Faster swipes travel further: 1x when slow, up to 3x when fast.
    final accel = 1 + math.min(speed / 12, 2.0);
    _moveRemX += delta.dx * sensitivity * accel;
    _moveRemY += delta.dy * sensitivity * accel;
    final dx = _moveRemX.truncate();
    final dy = _moveRemY.truncate();
    _moveRemX -= dx;
    _moveRemY -= dy;
    if (dx != 0 || dy != 0) onMove(dx, dy);
  }

  bool _emitScroll() {
    // Fingers moving up (negative dy) scroll the page down.
    final linesY = (-_scrollAccY / scrollStepPx).truncate();
    final linesX = (-_scrollAccX / scrollStepPx).truncate();
    _scrollAccY += linesY * scrollStepPx;
    _scrollAccX += linesX * scrollStepPx;
    if (linesX == 0 && linesY == 0) return false;
    onScroll(linesX, linesY);
    return true;
  }
}

enum _TwoFinger { undecided, scroll, pinch }
