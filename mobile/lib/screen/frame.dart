// SPDX-License-Identifier: GPL-3.0-or-later
// Screen frames from the computer (see docs/PROTOCOL.md, "Screen view").
//
//   "PDS1" | seq u32 | width u16 | height u16 | cursor_x i16 | cursor_y i16 | count u16
//   then count × (x u16 | y u16 | w u16 | h u16 | len u32 | JPEG bytes)
//
//   "PDV1" | seq u32 | width u16 | height u16 | cursor_x i16 | cursor_y i16 | flags u8 | len u32 | H.264
//   (flags bit 0: key frame; len 0: only the cursor moved)
//
// All little-endian. Cursor -1 means the pointer is on another monitor.

import 'dart:typed_data';

class FrameRect {
  const FrameRect(this.x, this.y, this.w, this.h, this.jpeg);
  final int x, y, w, h;
  final Uint8List jpeg;
}

class ScreenFrame {
  const ScreenFrame({
    required this.seq,
    required this.width,
    required this.height,
    required this.cursorX,
    required this.cursorY,
    required this.rects,
    required this.bytes,
    this.video,
    this.keyframe = false,
  });

  final int seq;
  final int width;
  final int height;

  /// Pointer position in frame pixels, or null when it's on another monitor.
  final int? cursorX;
  final int? cursorY;
  final List<FrameRect> rects;

  /// Size on the wire, for the data-rate display.
  final int bytes;

  /// H.264 frames: the access unit (null for JPEG frames; empty when only
  /// the cursor moved).
  final Uint8List? video;
  final bool keyframe;

  bool get isVideo => video != null;

  static ScreenFrame parse(Uint8List data) {
    if (data.length < 18) throw const FormatException('screen frame too short');
    // "PDS1": JPEG rectangles; "PDV1": H.264.
    if (data[0] != 0x50 || data[1] != 0x44 || data[3] != 0x31) {
      throw const FormatException('not a screen frame');
    }
    if (data[2] == 0x56) return _parseVideo(data);
    if (data[2] != 0x53) throw const FormatException('not a screen frame');
    final b = ByteData.sublistView(data);
    final seq = b.getUint32(4, Endian.little);
    final width = b.getUint16(8, Endian.little);
    final height = b.getUint16(10, Endian.little);
    final cx = b.getInt16(12, Endian.little);
    final cy = b.getInt16(14, Endian.little);
    final count = b.getUint16(16, Endian.little);
    var off = 18;
    final rects = <FrameRect>[];
    for (var i = 0; i < count; i++) {
      if (off + 12 > data.length) throw const FormatException('screen frame cut short');
      final x = b.getUint16(off, Endian.little);
      final y = b.getUint16(off + 2, Endian.little);
      final w = b.getUint16(off + 4, Endian.little);
      final h = b.getUint16(off + 6, Endian.little);
      final len = b.getUint32(off + 8, Endian.little);
      off += 12;
      if (off + len > data.length) throw const FormatException('screen frame cut short');
      if (x + w > width || y + h > height || w == 0 || h == 0) {
        throw const FormatException('screen rectangle outside the frame');
      }
      rects.add(FrameRect(x, y, w, h, Uint8List.sublistView(data, off, off + len)));
      off += len;
    }
    final onScreen = cx >= 0 && cy >= 0;
    return ScreenFrame(
      seq: seq,
      width: width,
      height: height,
      cursorX: onScreen ? cx : null,
      cursorY: onScreen ? cy : null,
      rects: rects,
      bytes: data.length,
    );
  }
}

ScreenFrame _parseVideo(Uint8List data) {
  if (data.length < 21) throw const FormatException('video frame too short');
  final b = ByteData.sublistView(data);
  final len = b.getUint32(17, Endian.little);
  if (21 + len != data.length) throw const FormatException('video frame cut short');
  final cx = b.getInt16(12, Endian.little);
  final cy = b.getInt16(14, Endian.little);
  final onScreen = cx >= 0 && cy >= 0;
  return ScreenFrame(
    seq: b.getUint32(4, Endian.little),
    width: b.getUint16(8, Endian.little),
    height: b.getUint16(10, Endian.little),
    cursorX: onScreen ? cx : null,
    cursorY: onScreen ? cy : null,
    rects: const [],
    bytes: data.length,
    video: Uint8List.sublistView(data, 21),
    keyframe: data[16] & 1 == 1,
  );
}

class MonitorInfo {
  const MonitorInfo({
    required this.index,
    required this.name,
    required this.width,
    required this.height,
    required this.primary,
  });
  final int index;
  final String name;
  final int width, height;
  final bool primary;
}

class ScreenInfo {
  const ScreenInfo({
    required this.monitors,
    required this.monitor,
    required this.width,
    required this.height,
    this.codec = 'jpeg',
  });
  final List<MonitorInfo> monitors;
  final int monitor;
  final int width, height;

  /// `jpeg` or `h264` (computers before 0.9 always send JPEG).
  final String codec;

  static ScreenInfo fromJson(Map<String, dynamic> j) => ScreenInfo(
    monitors: [
      for (final m in (j['monitors'] as List? ?? const []))
        if (m is Map)
          MonitorInfo(
            index: m['index'] as int? ?? 0,
            name: m['name'] as String? ?? 'Display',
            width: m['width'] as int? ?? 0,
            height: m['height'] as int? ?? 0,
            primary: m['primary'] == true,
          ),
    ],
    monitor: j['monitor'] as int? ?? 0,
    width: j['width'] as int? ?? 0,
    height: j['height'] as int? ?? 0,
    codec: j['codec'] as String? ?? 'jpeg',
  );
}
