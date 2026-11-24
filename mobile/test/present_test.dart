// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/present/present_controller.dart';

void main() {
  group('formatClock', () {
    test('minutes and seconds', () {
      expect(formatClock(const Duration(minutes: 4, seconds: 5)), '4:05');
      expect(formatClock(Duration.zero), '0:00');
    });
    test('hours appear past an hour', () {
      expect(formatClock(const Duration(hours: 1, minutes: 2, seconds: 9)), '1:02:09');
    });
    test('the sign is left to the caller', () {
      expect(formatClock(const Duration(seconds: -75)), '1:15');
    });
  });

  group('PresentTimer', () {
    final t0 = DateTime(2026, 11, 24, 9);
    test('counts only while running', () {
      final t = PresentTimer();
      t.start(t0);
      expect(t.elapsed(t0.add(const Duration(seconds: 30))), const Duration(seconds: 30));
      t.pause(t0.add(const Duration(seconds: 30)));
      expect(t.elapsed(t0.add(const Duration(minutes: 5))), const Duration(seconds: 30));
      t.start(t0.add(const Duration(minutes: 5)));
      expect(t.elapsed(t0.add(const Duration(minutes: 5, seconds: 10))), const Duration(seconds: 40));
    });
    test('starting twice keeps the first start', () {
      final t = PresentTimer()..start(t0);
      t.start(t0.add(const Duration(seconds: 20)));
      expect(t.elapsed(t0.add(const Duration(seconds: 30))), const Duration(seconds: 30));
    });
    test('counts down to a target and goes negative when over', () {
      final t = PresentTimer(target: const Duration(minutes: 10))..start(t0);
      expect(t.remaining(t0.add(const Duration(minutes: 4))), const Duration(minutes: 6));
      expect(t.remaining(t0.add(const Duration(minutes: 11))), const Duration(minutes: -1));
    });
    test('no target means no remaining time', () {
      expect(PresentTimer().remaining(t0), isNull);
    });
    test('reset stops and clears', () {
      final t = PresentTimer()..start(t0);
      t.reset();
      expect(t.running, isFalse);
      expect(t.elapsed(t0.add(const Duration(minutes: 1))), Duration.zero);
    });
  });

  group('PresentController keys', () {
    late List<String> sent;
    late PresentController c;
    setUp(() {
      sent = [];
      c = PresentController(
        press: (k) => sent.add(k.wire),
        combo: (mods, {key, char}) =>
            sent.add('${mods.map((m) => m.name).join('+')}|${key?.wire ?? ''}|${char ?? ''}'),
      );
    });
    tearDown(() => c.dispose());

    test('next and previous are the arrow keys', () {
      c.next();
      c.previous();
      expect(sent, ['right', 'left']);
    });
    test('start is F5, from here is Shift+F5, stop is Escape', () {
      c.start();
      c.pauseTimer();
      c.startHere();
      c.stop();
      expect(sent, ['f5', 'shift|f5|', 'escape']);
    });
    test('starting a show starts the timer', () {
      c.start();
      expect(c.timerRunning, isTrue);
      c.pauseTimer();
    });
    test('blank sends B and tracks the state', () {
      c.toggleBlank();
      expect(c.blanked, isTrue);
      c.toggleBlank();
      expect(c.blanked, isFalse);
      expect(sent, ['||b', '||b']);
    });
    test('laser sends Ctrl+L and stop turns it off', () {
      c.toggleLaser();
      expect(c.laser, isTrue);
      c.stop();
      expect(c.laser, isFalse);
      expect(sent.first, 'ctrl||l');
    });
  });
}
