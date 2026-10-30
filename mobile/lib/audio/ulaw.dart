// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// G.711 µ-law: 16-bit samples → bytes (the phone's voice for the
/// computer). The phone app encodes in Kotlin; this is the same, for tests.
Uint8List ulawEncode(Int16List pcm) {
  final out = Uint8List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    var s = pcm[i];
    var sign = 0;
    if (s < 0) {
      s = -s;
      sign = 0x80;
    }
    s = (s > 32635 ? 32635 : s) + 0x84;
    var exponent = 7;
    for (var mask = 0x4000; (s & mask) == 0 && exponent > 0; mask >>= 1) {
      exponent--;
    }
    final mantissa = (s >> (exponent + 3)) & 0x0f;
    out[i] = ~(sign | (exponent << 4) | mantissa) & 0xff;
  }
  return out;
}
