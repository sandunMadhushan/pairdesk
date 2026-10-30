// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

/// What the computer sends while a phone listens (see `audio_start`).
class AudioInfo {
  const AudioInfo({
    required this.codec,
    required this.rate,
    required this.channels,
    required this.frameMs,
    required this.preSkip,
    required this.sound,
    required this.mic,
  });

  /// `opus` or `pcm` (16-bit little-endian).
  final String codec;
  final int rate;
  final int channels;
  final int frameMs;

  /// Opus samples the decoder drops at the start.
  final int preSkip;
  final bool sound;
  final bool mic;

  static AudioInfo fromJson(Map<String, dynamic> j) => AudioInfo(
    codec: j['codec'] as String? ?? 'pcm',
    rate: (j['rate'] as num?)?.toInt() ?? 48000,
    channels: (j['channels'] as num?)?.toInt() ?? 2,
    frameMs: (j['frame_ms'] as num?)?.toInt() ?? 20,
    preSkip: (j['pre_skip'] as num?)?.toInt() ?? 0,
    sound: j['sound'] == true,
    mic: j['mic'] == true,
  );
}

/// One "PDA1" message: 20 ms of the computer's sound. An empty payload is
/// silence.
class AudioPacket {
  const AudioPacket(this.seq, this.payload);
  final int seq;
  final Uint8List payload;

  static bool matches(Uint8List data) =>
      data.length >= 8 && data[0] == 0x50 && data[1] == 0x44 && data[2] == 0x41 && data[3] == 0x31;

  static AudioPacket parse(Uint8List data) {
    if (!matches(data)) throw const FormatException('not an audio packet');
    final seq = ByteData.sublistView(data, 4, 8).getUint32(0);
    return AudioPacket(seq, Uint8List.sublistView(data, 8));
  }
}

/// The phone's voice for the computer: "PDM1" + 16 kHz mono µ-law.
Uint8List voiceMessage(Uint8List ulaw) {
  final out = Uint8List(4 + ulaw.length);
  out.setAll(0, const [0x50, 0x44, 0x4d, 0x31]);
  out.setAll(4, ulaw);
  return out;
}
