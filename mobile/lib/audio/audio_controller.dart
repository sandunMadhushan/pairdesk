// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent_connection.dart';
import 'native_audio.dart';

/// Sound between the phone and the computer it's connected to:
/// listening to the computer's sound and/or microphone, and talking
/// through its speakers.
class AudioController extends ChangeNotifier {
  AudioController(this.conn, {AudioBackend? backend}) : backend = backend ?? PlatformAudioBackend() {
    this.backend
      ..onPlayerError = _playerFailed
      ..onMic = _onMic
      ..onMicError = _micFailed;
    _packets = conn.audioPackets.listen(_onPacket);
    _stopped = conn.audioStopped.listen(_onStopped);
  }

  final AgentConnection conn;
  final AudioBackend backend;
  late final StreamSubscription<AudioPacket> _packets;
  late final StreamSubscription<String> _stopped;

  /// Opus failed on this phone before: use PCM.
  static const opusBrokenKey = 'audio.opusBroken';

  bool _sound = false;
  bool _mic = false;
  bool _talking = false;
  bool _handsFree = false;
  bool _busy = false;
  bool _paused = false;
  String? _error;
  AudioInfo? _info;
  bool _ready = false;
  bool _disposed = false;

  /// Hearing what the computer plays.
  bool get sound => _sound;

  /// Hearing the computer's microphone.
  bool get mic => _mic;

  /// The phone's microphone goes to the computer's speakers.
  bool get talking => _talking;

  /// Talking stays on without holding the button.
  bool get handsFree => _handsFree;

  bool get busy => _busy;
  String? get error => _error;

  /// The computer can do sound (PairDesk 0.10 or newer).
  bool get available => conn.features.contains('audio');
  bool get allowed => conn.allowed.audio;
  bool get micAllowed => conn.allowed.mic;

  /// Something is on: the top bar shows it.
  bool get active => _sound || _mic || _talking;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> setSound(bool on) => _listen(sound: on, mic: _mic);
  Future<void> setMic(bool on) => _listen(sound: _sound, mic: on);

  Future<void> _listen({required bool sound, required bool mic}) async {
    _sound = sound;
    _mic = mic;
    _error = null;
    _notify();
    await _restart();
  }

  Future<void> _restart() async {
    _ready = false;
    if (_paused) return;
    if (!_sound && !_mic) {
      if (_info != null) conn.stopAudio();
      _info = null;
      await backend.stopPlayer();
      _notify();
      return;
    }
    _busy = true;
    _notify();
    try {
      final prefs = await SharedPreferences.getInstance();
      final opus = !(prefs.getBool(opusBrokenKey) ?? false) && await backend.opusSupported();
      final info = await conn.startAudio(sound: _sound, mic: _mic, codecs: [if (opus) 'opus', 'pcm']);
      await backend.startPlayer(info);
      _info = info;
      _ready = true;
    } on RequestException catch (e) {
      _fail(e.message);
    } on AgentException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail('Can\'t play the computer\'s sound: $e');
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _fail(String message) {
    _error = message;
    _sound = _mic = false;
    if (_info != null) conn.stopAudio();
    _info = null;
    _ready = false;
    backend.stopPlayer();
  }

  void _onPacket(AudioPacket p) {
    if (_ready) backend.play(p.payload);
  }

  void _onStopped(String message) {
    _info = null;
    _ready = false;
    _sound = _mic = false;
    _error = message;
    backend.stopPlayer();
    _notify();
  }

  Future<void> _playerFailed(String message) async {
    debugPrint('audio player failed: $message');
    if (_info?.codec == 'opus') {
      // This phone's Opus decoder doesn't work: PCM from now on.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(opusBrokenKey, true);
      await _restart();
      return;
    }
    _fail('The phone couldn\'t play the sound ($message).');
    _notify();
  }

  // ---- Talking ----

  Future<void> startTalking() async {
    if (_talking || _paused) return;
    _error = null;
    _talking = true;
    _notify();
    // A call: echo cancelled on the phone (the computer cancels its side),
    // so you hear the computer while you talk.
    await backend.setCallMode(true);
    final ok = await backend.startMic().catchError((Object e) {
      _error = 'Can\'t use the microphone: $e';
      return false;
    });
    if (!ok) {
      _error ??= 'PairDesk needs the microphone to talk to the computer. Allow it in Android settings.';
      _talking = false;
      _handsFree = false;
      await backend.setCallMode(false);
      _notify();
    }
  }

  void stopTalking() {
    if (!_talking) return;
    _talking = false;
    _handsFree = false;
    backend.stopMic().then((_) => backend.setCallMode(false));
    _notify();
  }

  Future<void> setHandsFree(bool on) async {
    _handsFree = on;
    _notify();
    if (on) {
      await startTalking();
      if (!_talking) _handsFree = false;
    } else {
      stopTalking();
    }
  }

  void _onMic(Uint8List ulaw) {
    if (_talking) conn.sendVoice(ulaw);
  }

  void _micFailed(String message) {
    _error = 'The microphone stopped: $message';
    stopTalking();
  }

  // ---- The app goes to the background and back ----

  /// Stops sound while the app isn't visible.
  void pause() {
    if (_paused) return;
    stopTalking();
    _paused = true;
    if (_info != null) conn.stopAudio();
    _info = null;
    _ready = false;
    backend.stopPlayer();
  }

  /// Picks up listening where it was.
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    if (_sound || _mic) await _restart();
  }

  @override
  void dispose() {
    _disposed = true;
    _packets.cancel();
    _stopped.cancel();
    if (_talking) {
      backend.stopMic();
      backend.setCallMode(false);
    }
    if (_info != null) conn.stopAudio();
    backend.stopPlayer();
    super.dispose();
  }
}
