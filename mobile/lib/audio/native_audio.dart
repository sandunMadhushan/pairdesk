// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'audio_packet.dart';

/// The phone's sound hardware (Android: AudioChannel.kt).
abstract class AudioBackend {
  Future<bool> opusSupported();
  Future<void> startPlayer(AudioInfo info);
  void play(Uint8List payload);
  Future<void> stopPlayer();

  /// While the person talks: a phone call's audio path, so the phone's
  /// echo cancelling works and both sides can talk at once.
  Future<void> setCallMode(bool on);

  /// False if the person didn't allow the microphone.
  Future<bool> startMic();
  Future<void> stopMic();

  void Function(String message)? onPlayerError;
  void Function(Uint8List ulaw)? onMic;
  void Function(String message)? onMicError;
}

class PlatformAudioBackend implements AudioBackend {
  PlatformAudioBackend() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'playerError':
          onPlayerError?.call('${call.arguments}');
        case 'mic':
          final data = call.arguments;
          if (data is Uint8List) onMic?.call(data);
        case 'micError':
          onMicError?.call('${call.arguments}');
      }
    });
  }

  static const _channel = MethodChannel('pairdesk/audio');

  @override
  void Function(String message)? onPlayerError;
  @override
  void Function(Uint8List ulaw)? onMic;
  @override
  void Function(String message)? onMicError;

  @override
  Future<bool> opusSupported() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('opusSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startPlayer(AudioInfo info) => _channel.invokeMethod('startPlayer', {
    'codec': info.codec,
    'rate': info.rate,
    'channels': info.channels,
    'preSkip': info.preSkip,
  });

  @override
  void play(Uint8List payload) {
    _channel.invokeMethod('play', {'data': payload}).catchError((_) => null);
  }

  @override
  Future<void> stopPlayer() async {
    try {
      await _channel.invokeMethod('stopPlayer');
    } catch (_) {}
  }

  @override
  Future<void> setCallMode(bool on) async {
    try {
      await _channel.invokeMethod('setCallMode', {'on': on});
    } catch (_) {}
  }

  @override
  Future<bool> startMic() async => await _channel.invokeMethod<bool>('startMic') ?? false;

  @override
  Future<void> stopMic() async {
    try {
      await _channel.invokeMethod('stopMic');
    } catch (_) {}
  }
}
