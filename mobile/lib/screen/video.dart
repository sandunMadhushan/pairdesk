// SPDX-License-Identifier: GPL-3.0-or-later
// Screen view as H.264 video, decoded by the phone's hardware decoder
// (Android MediaCodec, see MainActivity.kt) straight onto a Flutter texture.
//
// The app offers H.264 only when the phone has a decoder and video hasn't
// failed on this phone before; otherwise the computer sends JPEG pictures
// as it always did. Any decoder error switches this phone back to JPEG.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Splits one H.264 access unit (Annex B, start codes) into its parameter
/// sets (SPS, PPS: the decoder's "codec config") and the rest. A key frame
/// from the computer carries both.
({Uint8List? config, Uint8List frame}) splitParameterSets(Uint8List au) {
  // Start offsets of each NAL unit (after its 00 00 01 / 00 00 00 01).
  final starts = <int>[];
  final codeStarts = <int>[];
  for (var i = 0; i + 2 < au.length; i++) {
    if (au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1) {
      final codeStart = i > 0 && au[i - 1] == 0 ? i - 1 : i;
      codeStarts.add(codeStart);
      starts.add(i + 3);
      i += 2;
    }
  }
  if (starts.isEmpty) return (config: null, frame: au);
  var configEnd = 0;
  for (var n = 0; n < starts.length; n++) {
    if (starts[n] >= au.length) break;
    final type = au[starts[n]] & 0x1f;
    if (type == 7 || type == 8) {
      configEnd = n + 1 < starts.length ? codeStarts[n + 1] : au.length;
    } else {
      break;
    }
  }
  if (configEnd == 0) return (config: null, frame: au);
  return (
    config: Uint8List.sublistView(au, codeStarts.first, configEnd),
    frame: Uint8List.sublistView(au, configEnd),
  );
}

/// A hardware video decoder that draws onto a Flutter texture.
abstract class VideoDecoder {
  /// Starts decoding pictures of [width]×[height]. Returns the texture id,
  /// or null if this phone can't.
  Future<int?> start(int width, int height);

  /// Queues one access unit.
  Future<void> decode(Uint8List data, {required bool keyframe});

  Future<void> stop();

  /// Reports a decoder failure after [start] (from the platform).
  set onError(void Function(String message)? handler);

  /// The picture's surface went away (the app was hidden); a new [start]
  /// brings it back.
  set onLost(void Function()? handler);
}

class PlatformVideoDecoder implements VideoDecoder {
  PlatformVideoDecoder({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(_name) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'error':
          _onError?.call(call.arguments as String? ?? 'video decoder failed');
        case 'lost':
          _onLost?.call();
      }
    });
  }

  static const _name = 'pairdesk/video';
  final MethodChannel _channel;
  void Function(String)? _onError;
  void Function()? _onLost;
  int _pts = 0;

  @override
  set onError(void Function(String message)? handler) => _onError = handler;

  @override
  set onLost(void Function()? handler) => _onLost = handler;

  @override
  Future<int?> start(int width, int height) async {
    _pts = 0;
    try {
      return await _channel.invokeMethod<int>('start', {'width': width, 'height': height});
    } on PlatformException catch (e) {
      debugPrint('video decoder: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> decode(Uint8List data, {required bool keyframe}) async {
    final parts = keyframe ? splitParameterSets(data) : (config: null, frame: data);
    _pts += 33333;
    await _channel.invokeMethod<void>('decode', {
      'config': parts.config,
      'frame': parts.frame,
      'key': keyframe,
      'pts': _pts,
    });
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Not on Android.
    }
  }
}

/// Whether to ask the computer for video on this phone.
class VideoSupport {
  static const brokenKey = 'screen.videoBroken';

  /// Set while video plays. Still set when the app starts means the app
  /// was killed during video (a crash in the phone's decoder): use JPEG
  /// from then on.
  static const tryingKey = 'screen.videoTrying';
  static bool? _hasDecoder;
  static bool _checkedCrash = false;

  /// True if the phone has an H.264 decoder and video hasn't failed here.
  static Future<bool> available({MethodChannel channel = const MethodChannel('pairdesk/video')}) async {
    if (!(androidForTest ?? Platform.isAndroid)) return false;
    final prefs = await SharedPreferences.getInstance();
    if (!_checkedCrash) {
      _checkedCrash = true;
      if (prefs.getBool(tryingKey) ?? false) {
        await prefs.remove(tryingKey);
        await prefs.setBool(brokenKey, true);
      }
    }
    if (prefs.getBool(brokenKey) ?? false) return false;
    try {
      _hasDecoder ??= await channel.invokeMethod<bool>('supported') ?? false;
    } catch (_) {
      _hasDecoder = false;
    }
    return _hasDecoder!;
  }

  /// Video didn't work on this phone: use JPEG from now on.
  static Future<void> markBroken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(brokenKey, true);
  }

  /// Settings → "Try smooth video again".
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(brokenKey);
    await prefs.remove(tryingKey);
  }

  /// Video is about to play ([playing] true) or has stopped cleanly.
  static Future<void> playing(bool playing) async {
    final prefs = await SharedPreferences.getInstance();
    playing ? await prefs.setBool(tryingKey, true) : await prefs.remove(tryingKey);
  }

  @visibleForTesting
  static bool? androidForTest;

  @visibleForTesting
  static void resetForTest() {
    _hasDecoder = null;
    _checkedCrash = false;
  }
}
