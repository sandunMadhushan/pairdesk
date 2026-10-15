// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/screen/compositor.dart';
import 'package:pairdesk/screen/frame.dart';
import 'package:pairdesk/screens/tabs/screen_tab.dart';

/// Builds a frame exactly as the agent does (see agent/src/screen/encode.rs).
Uint8List buildFrame(int seq, int w, int h, (int, int)? cursor, List<(int, int, int, int, Uint8List)> rects) {
  final b = BytesBuilder();
  final head = ByteData(18);
  head.setUint8(0, 0x50);
  head.setUint8(1, 0x44);
  head.setUint8(2, 0x53);
  head.setUint8(3, 0x31);
  head.setUint32(4, seq, Endian.little);
  head.setUint16(8, w, Endian.little);
  head.setUint16(10, h, Endian.little);
  head.setInt16(12, cursor?.$1 ?? -1, Endian.little);
  head.setInt16(14, cursor?.$2 ?? -1, Endian.little);
  head.setUint16(16, rects.length, Endian.little);
  b.add(head.buffer.asUint8List());
  for (final (x, y, rw, rh, img) in rects) {
    final r = ByteData(12)
      ..setUint16(0, x, Endian.little)
      ..setUint16(2, y, Endian.little)
      ..setUint16(4, rw, Endian.little)
      ..setUint16(6, rh, Endian.little)
      ..setUint32(8, img.length, Endian.little);
    b.add(r.buffer.asUint8List());
    b.add(img);
  }
  return b.toBytes();
}

/// A solid-colour PNG (the compositor decodes any image format).
Future<Uint8List> solidPng(int w, int h, Color c) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = c);
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return png!.buffer.asUint8List();
}

Future<Color> pixel(ui.Image img, int x, int y) async {
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final i = (y * img.width + x) * 4;
  return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
}

class FakeScreenConnection extends AgentConnection {
  FakeScreenConnection({this.refuse});
  final String? refuse;
  final frames = StreamController<ScreenFrame>.broadcast();
  final stopped = StreamController<String>.broadcast();
  final calls = <String>[];

  @override
  Set<String> get features => {'screen'};
  @override
  Stream<ScreenFrame> get screenFrames => frames.stream;
  @override
  Stream<String> get screenStopped => stopped.stream;
  @override
  Future<ScreenInfo> startScreen({int? monitor, String quality = 'medium'}) async {
    calls.add('start $quality');
    if (refuse != null) throw RequestException('not_allowed', refuse!);
    return const ScreenInfo(
      monitors: [MonitorInfo(index: 0, name: 'Display 1 (main)', width: 1280, height: 800, primary: true)],
      monitor: 0,
      width: 64,
      height: 40,
    );
  }

  @override
  void ackScreen(int seq) => calls.add('ack $seq');
  @override
  void stopScreen() => calls.add('stop');
  @override
  void moveTo(double x, double y) => calls.add('move_to ${x.toStringAsFixed(2)} ${y.toStringAsFixed(2)}');
  @override
  void click(MouseBtn b) => calls.add('click ${b.name}');
  @override
  void move(int dx, int dy) => calls.add('move');
  @override
  void scroll({int dx = 0, int dy = 0}) => calls.add('scroll $dx $dy');
  @override
  void buttonDown(MouseBtn b) => calls.add('down ${b.name}');
  @override
  void buttonUp(MouseBtn b) => calls.add('up ${b.name}');
}

void main() {
  group('frame parsing', () {
    test('reads header, cursor and rectangles', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]);
      final f = ScreenFrame.parse(buildFrame(7, 1280, 720, (10, 20), [(64, 0, 64, 64, jpeg)]));
      expect(f.seq, 7);
      expect((f.width, f.height), (1280, 720));
      expect((f.cursorX, f.cursorY), (10, 20));
      expect(f.rects.single.x, 64);
      expect(f.rects.single.jpeg, jpeg);
      final none = ScreenFrame.parse(buildFrame(8, 10, 10, null, []));
      expect(none.cursorX, isNull);
      expect(none.rects, isEmpty);
    });

    test('rejects damaged frames', () {
      final good = buildFrame(1, 100, 100, null, [(0, 0, 10, 10, Uint8List(20))]);
      expect(() => ScreenFrame.parse(Uint8List(5)), throwsFormatException);
      expect(() => ScreenFrame.parse(Uint8List.fromList([...good]..[0] = 0)), throwsFormatException);
      expect(() => ScreenFrame.parse(Uint8List.sublistView(good, 0, good.length - 1)), throwsFormatException);
      final outside = buildFrame(1, 100, 100, null, [(95, 0, 10, 10, Uint8List(4))]);
      expect(() => ScreenFrame.parse(outside), throwsFormatException);
    });
  });

  testWidgets('compositor paints changed rectangles over the last picture', (tester) async {
    await tester.runAsync(() async {
      final comp = ScreenCompositor();
      final red = await solidPng(64, 40, const Color(0xFFFF0000));
      final blue = await solidPng(32, 20, const Color(0xFF0000FF));
      expect(await comp.apply(ScreenFrame.parse(buildFrame(1, 64, 40, null, [(0, 0, 64, 40, red)]))), isTrue);
      expect(await comp.apply(ScreenFrame.parse(buildFrame(2, 64, 40, (1, 1), []))), isFalse, reason: 'cursor only');
      await comp.apply(ScreenFrame.parse(buildFrame(3, 64, 40, null, [(32, 20, 32, 20, blue)])));
      final img = comp.image!;
      expect((img.width, img.height), (64, 40));
      expect(await pixel(img, 5, 5), const Color(0xFFFF0000), reason: 'old part kept');
      expect(await pixel(img, 50, 30), const Color(0xFF0000FF), reason: 'new part painted');
      comp.dispose();
    });
  });

  group('screen tab', () {
    Future<FakeScreenConnection> showTab(WidgetTester tester, {String? refuse}) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final conn = FakeScreenConnection(refuse: refuse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScreenTab(connection: conn, active: true)),
        ),
      );
      await tester.pump();
      return conn;
    }

    testWidgets('shows frames, acks them, and taps click at that spot', (tester) async {
      final conn = await showTab(tester);
      expect(conn.calls, ['start medium']);
      expect(find.text('Getting the screen…'), findsOneWidget);

      final png = (await tester.runAsync(() => solidPng(64, 40, const Color(0xFF336699))))!;
      conn.frames.add(ScreenFrame.parse(buildFrame(1, 64, 40, (32, 20), [(0, 0, 64, 40, png)])));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(conn.calls, contains('ack 1'));
      expect(find.byType(CustomPaint), findsWidgets);

      // Tap-to-point mode: the pointer goes where you tap.
      expect(find.byKey(const ValueKey('touchpad-view')), findsOneWidget, reason: 'touchpad mode by default');
      await tester.tap(find.byIcon(Icons.mouse_outlined));
      await tester.pump();
      expect(find.byIcon(Icons.touch_app_outlined), findsOneWidget);

      // Tap the centre of the picture: pointer goes to the middle, then clicks.
      final box = tester.getRect(find.byType(AspectRatio));
      await tester.tapAt(box.center);
      await tester.pump(const Duration(milliseconds: 50));
      expect(conn.calls.sublist(conn.calls.length - 2), ['move_to 0.50 0.50', 'click left']);

      await tester.longPressAt(box.topLeft + const Offset(1, 1));
      await tester.pump();
      expect(conn.calls.last, 'click right');
      expect(conn.calls[conn.calls.length - 2], startsWith('move_to 0.0'));

      // Changing quality restarts the stream.
      await tester.tap(find.text('High'));
      await tester.pump();
      expect(conn.calls.last, 'start high');

      // Stopped on the computer.
      conn.stopped.add('Screen view was stopped on the computer.');
      await tester.pump();
      expect(find.text('Screen view was stopped on the computer.'), findsOneWidget);
    });

    testWidgets('touchpad mode: move, click, drag, scroll and zoom like the touchpad', (tester) async {
      final conn = await showTab(tester);
      final png = (await tester.runAsync(() => solidPng(64, 40, const Color(0xFF336699))))!;
      conn.frames.add(ScreenFrame.parse(buildFrame(1, 64, 40, (32, 20), [(0, 0, 64, 40, png)])));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      final view = find.byKey(const ValueKey('touchpad-view'));
      final centre = tester.getCenter(view);
      conn.calls.clear();

      // One finger anywhere moves the pointer; no jump to the finger.
      await tester.dragFrom(centre, const Offset(80, 40));
      await tester.pump(const Duration(milliseconds: 300));
      expect(conn.calls, isNotEmpty);
      expect(conn.calls.toSet(), {'move'});
      expect(conn.calls.any((c) => c.startsWith('move_to')), isFalse);

      // A tap clicks (after the double-tap window).
      conn.calls.clear();
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 300));
      expect(conn.calls, ['click left']);

      // Tap, then touch again and drag: the left button is held.
      conn.calls.clear();
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 80));
      final g = await tester.startGesture(centre);
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(10, 5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(conn.calls.first, 'down left');
      expect(conn.calls.last, 'up left');
      expect(conn.calls.where((c) => c == 'click left'), isEmpty);

      // Two fingers moving together scroll.
      conn.calls.clear();
      final a = await tester.startGesture(centre - const Offset(40, 0), pointer: 11);
      final b = await tester.startGesture(centre + const Offset(40, 0), pointer: 12);
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(0, -15));
        await b.moveBy(const Offset(0, -15));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(conn.calls.where((c) => c.startsWith('scroll')), isNotEmpty);
      expect(conn.calls.where((c) => c == 'move'), isEmpty);

      // Pinch zooms the picture on the phone; nothing goes to the computer.
      conn.calls.clear();
      final c = await tester.startGesture(centre - const Offset(30, 0), pointer: 21);
      final d = await tester.startGesture(centre + const Offset(30, 0), pointer: 22);
      for (var i = 0; i < 6; i++) {
        await c.moveBy(const Offset(-15, 0));
        await d.moveBy(const Offset(15, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await c.up();
      await d.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(conn.calls, isEmpty, reason: 'a pinch neither scrolls nor moves the pointer');
    });

    testWidgets('explains when screen view is turned off', (tester) async {
      await showTab(tester, refuse: 'This is turned off in PairDesk settings on the computer.');
      await tester.pump();
      expect(find.text('This is turned off in PairDesk settings on the computer.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('stops streaming when the tab is hidden', (tester) async {
      final conn = await showTab(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScreenTab(connection: conn, active: false)),
        ),
      );
      expect(conn.calls.last, 'stop');
    });
  });
}
