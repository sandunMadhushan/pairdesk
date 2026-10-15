// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart' show MouseBtn;
import 'package:pairdesk/touchpad_gestures.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  late List<(int, int)> moves;
  late List<MouseBtn> clicks;
  late List<(int, int)> scrolls;
  late TouchpadGestures g;

  setUp(() {
    moves = [];
    clicks = [];
    scrolls = [];
    g = TouchpadGestures(
      onMove: (dx, dy) => moves.add((dx, dy)),
      onClick: clicks.add,
      onScroll: (dx, dy) => scrolls.add((dx, dy)),
      sensitivity: 1.0,
    );
  });

  test('quick one-finger tap is a left click', () {
    g.pointerDown(1, const Offset(100, 100), ms(0));
    g.pointerUp(1, const Offset(101, 100), ms(90));
    expect(clicks, [MouseBtn.left]);
    expect(moves, isEmpty);
  });

  test('two-finger tap is a right click, three-finger tap is middle', () {
    g.pointerDown(1, const Offset(100, 100), ms(0));
    g.pointerDown(2, const Offset(150, 100), ms(10));
    g.pointerUp(1, const Offset(100, 100), ms(80));
    g.pointerUp(2, const Offset(150, 100), ms(90));

    g.pointerDown(1, const Offset(100, 100), ms(1000));
    g.pointerDown(2, const Offset(150, 100), ms(1005));
    g.pointerDown(3, const Offset(200, 100), ms(1010));
    for (final id in [1, 2, 3]) {
      g.pointerUp(id, const Offset(0, 0) + Offset(50.0 * id + 50, 100), ms(1100));
    }
    expect(clicks, [MouseBtn.right, MouseBtn.middle]);
  });

  test('a long press is not a click', () {
    g.pointerDown(1, const Offset(100, 100), ms(0));
    g.pointerUp(1, const Offset(100, 100), ms(600));
    expect(clicks, isEmpty);
  });

  test('one-finger drag moves the cursor and is not a click', () {
    g.pointerDown(1, const Offset(100, 100), ms(0));
    for (var i = 1; i <= 10; i++) {
      g.pointerMove(1, Offset(100.0 + i * 2, 100.0 - i), ms(i * 8));
    }
    g.pointerUp(1, const Offset(120, 90), ms(100));
    final total = moves.fold<(int, int)>((0, 0), (a, m) => (a.$1 + m.$1, a.$2 + m.$2));
    expect(total.$1, greaterThanOrEqualTo(20)); // at least 1x the finger travel
    expect(total.$2, lessThanOrEqualTo(-10));
    expect(clicks, isEmpty);
  });

  test('slow sub-pixel movement is not lost', () {
    g.pointerDown(1, const Offset(0, 0), ms(0));
    for (var i = 1; i <= 10; i++) {
      g.pointerMove(1, Offset(i * 0.4, 0), ms(i * 16));
    }
    final dx = moves.fold<int>(0, (a, m) => a + m.$1);
    expect(dx, inInclusiveRange(4, 5)); // 4px of travel, tiny acceleration
  });

  test('two fingers moving up scroll down, without moving the cursor', () {
    g.pointerDown(1, const Offset(100, 300), ms(0));
    g.pointerDown(2, const Offset(160, 300), ms(5));
    for (var i = 1; i <= 10; i++) {
      g.pointerMove(1, Offset(100, 300.0 - i * 10), ms(i * 10));
      g.pointerMove(2, Offset(160, 300.0 - i * 10), ms(i * 10 + 1));
    }
    g.pointerUp(1, const Offset(100, 200), ms(200));
    g.pointerUp(2, const Offset(160, 200), ms(205));
    final lines = scrolls.fold<int>(0, (a, s) => a + s.$2);
    expect(lines, 5); // 100px of travel / 18px per line
    expect(moves, isEmpty);
    expect(clicks, isEmpty);
  });

  test('finger left over after a scroll does not jump the cursor', () {
    g.pointerDown(1, const Offset(100, 300), ms(0));
    g.pointerDown(2, const Offset(160, 300), ms(5));
    g.pointerUp(2, const Offset(160, 300), ms(300));
    g.pointerMove(1, const Offset(180, 260), ms(310));
    expect(moves, isEmpty);
  });

  group('screen view extras', () {
    late List<(MouseBtn, bool)> buttons;
    late List<double> pinches;
    late List<_FakeTimer> timers;

    setUp(() {
      buttons = [];
      pinches = [];
      timers = [];
      g = TouchpadGestures(
        onMove: (dx, dy) => moves.add((dx, dy)),
        onClick: clicks.add,
        onScroll: (dx, dy) => scrolls.add((dx, dy)),
        onButton: (b, down) => buttons.add((b, down)),
        onPinch: (scale, _) => pinches.add(scale),
        sensitivity: 1.0,
        timer: (d, f) {
          final t = _FakeTimer(f);
          timers.add(t);
          return t;
        },
      );
    });

    void tap(int at) {
      g.pointerDown(1, const Offset(100, 100), ms(at));
      g.pointerUp(1, const Offset(100, 100), ms(at + 60));
    }

    test('a single tap clicks once the double-tap window passes', () {
      tap(0);
      expect(clicks, isEmpty);
      timers.single.fire();
      expect(clicks, [MouseBtn.left]);
      expect(buttons, isEmpty);
    });

    test('tap, then touch and move, drags with the left button held', () {
      tap(0);
      g.pointerDown(1, const Offset(100, 100), ms(150));
      g.pointerMove(1, const Offset(130, 100), ms(200));
      g.pointerMove(1, const Offset(160, 120), ms(250));
      expect(buttons, [(MouseBtn.left, true)]);
      expect(g.dragging, isTrue);
      g.pointerUp(1, const Offset(160, 120), ms(300));
      expect(buttons, [(MouseBtn.left, true), (MouseBtn.left, false)]);
      expect(clicks, isEmpty, reason: 'the tap became the drag');
      expect(moves, isNotEmpty);
      expect(timers.single.isActive, isFalse);
    });

    test('two quick taps are a double click', () {
      tap(0);
      tap(150);
      expect(clicks, [MouseBtn.left, MouseBtn.left]);
      expect(buttons, isEmpty);
    });

    test('a touch after the window is a new gesture; the old click went out', () {
      tap(0);
      timers.single.fire();
      g.pointerDown(1, const Offset(100, 100), ms(600));
      g.pointerMove(1, const Offset(150, 100), ms(650));
      g.pointerUp(1, const Offset(150, 100), ms(700));
      expect(clicks, [MouseBtn.left]);
      expect(buttons, isEmpty, reason: 'just moved the pointer');
    });

    test('spreading two fingers zooms instead of scrolling', () {
      g.pointerDown(1, const Offset(100, 300), ms(0));
      g.pointerDown(2, const Offset(200, 300), ms(5));
      for (var i = 1; i <= 5; i++) {
        g.pointerMove(1, Offset(100 - i * 10.0, 300), ms(10 + i * 20));
        g.pointerMove(2, Offset(200 + i * 10.0, 300), ms(15 + i * 20));
      }
      g.pointerUp(1, const Offset(50, 300), ms(200));
      g.pointerUp(2, const Offset(250, 300), ms(205));
      expect(scrolls, isEmpty);
      final total = pinches.fold(1.0, (a, b) => a * b);
      expect(total, closeTo(2.0, 0.01), reason: 'fingers went from 100 to 200 px apart');
      expect(clicks, isEmpty);
    });

    test('two fingers moving together still scroll', () {
      g.pointerDown(1, const Offset(100, 300), ms(0));
      g.pointerDown(2, const Offset(200, 300), ms(5));
      for (var i = 1; i <= 6; i++) {
        g.pointerMove(1, Offset(100, 300 - i * 15.0), ms(10 + i * 20));
        g.pointerMove(2, Offset(200, 300 - i * 15.0), ms(15 + i * 20));
      }
      expect(pinches, isEmpty);
      expect(scrolls, isNotEmpty);
    });

    test('reset releases a held drag', () {
      tap(0);
      g.pointerDown(1, const Offset(100, 100), ms(150));
      g.pointerMove(1, const Offset(140, 100), ms(200));
      g.reset();
      expect(buttons, [(MouseBtn.left, true), (MouseBtn.left, false)]);
    });
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this._f);
  final void Function() _f;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _f();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
