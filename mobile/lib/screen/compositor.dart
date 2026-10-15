// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps the latest picture of the computer's screen: decodes the changed
// rectangles of each frame and paints them over the previous picture.

import 'dart:async';
import 'dart:ui' as ui;

import 'frame.dart';

class ScreenCompositor {
  ui.Image? _image;

  /// The current picture, or null before the first frame.
  ui.Image? get image => _image;

  /// Applies [frame]; returns true if the picture changed.
  Future<bool> apply(ScreenFrame frame) async {
    if (frame.rects.isEmpty) return false;
    final parts = await Future.wait(frame.rects.map(_decode));
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final previous = _image;
      if (previous != null && previous.width == frame.width && previous.height == frame.height) {
        canvas.drawImage(previous, ui.Offset.zero, ui.Paint());
      } else {
        // New size (first frame, or another monitor): start from black.
        canvas.drawRect(
          ui.Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
          ui.Paint()..color = const ui.Color(0xFF000000),
        );
      }
      for (var i = 0; i < parts.length; i++) {
        final r = frame.rects[i];
        final img = parts[i];
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          ui.Rect.fromLTWH(r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.none,
        );
      }
      final picture = recorder.endRecording();
      final next = await picture.toImage(frame.width, frame.height);
      picture.dispose();
      previous?.dispose();
      _image = next;
      return true;
    } finally {
      for (final p in parts) {
        p.dispose();
      }
    }
  }

  static Future<ui.Image> _decode(FrameRect r) async {
    final codec = await ui.instantiateImageCodec(r.jpeg);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}
