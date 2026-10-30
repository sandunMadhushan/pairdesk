// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/audio/audio_controller.dart';
import 'package:pairdesk/audio/audio_packet.dart';
import 'package:pairdesk/audio/native_audio.dart';
import 'package:pairdesk/audio/sound_sheet.dart';
import 'package:pairdesk/audio/ulaw.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAudioConnection extends AgentConnection {
  FakeAudioConnection({this.allow = const Allowed(audio: true), this.feature = true});
  final Allowed allow;
  final bool feature;
  final packets = StreamController<AudioPacket>.broadcast();
  final stopped = StreamController<String>.broadcast();
  final calls = <String>[];
  final voice = <Uint8List>[];

  @override
  Set<String> get features => {if (feature) 'audio'};
  @override
  Allowed get allowed => allow;
  @override
  Stream<AudioPacket> get audioPackets => packets.stream;
  @override
  Stream<String> get audioStopped => stopped.stream;

  @override
  Future<AudioInfo> startAudio({required bool sound, required bool mic, required List<String> codecs}) async {
    calls.add('start sound=$sound mic=$mic ${codecs.join(',')}');
    if (mic && !allow.mic) throw RequestException('not_allowed', 'This is turned off in PairDesk settings.');
    return AudioInfo(
      codec: codecs.first,
      rate: 48000,
      channels: 2,
      frameMs: 20,
      preSkip: 312,
      sound: sound,
      mic: mic,
    );
  }

  @override
  void stopAudio() => calls.add('stop');
  @override
  void sendVoice(Uint8List ulaw) => voice.add(ulaw);
}

class FakeBackend implements AudioBackend {
  FakeBackend({this.opus = true, this.micAllowed = true});
  bool opus;
  bool micAllowed;
  final calls = <String>[];
  final played = <Uint8List>[];

  @override
  void Function(String message)? onPlayerError;
  @override
  void Function(Uint8List ulaw)? onMic;
  @override
  void Function(String message)? onMicError;

  @override
  Future<bool> opusSupported() async => opus;
  @override
  Future<void> startPlayer(AudioInfo info) async => calls.add('player ${info.codec} ${info.preSkip}');
  @override
  void play(Uint8List payload) => played.add(payload);
  @override
  Future<void> stopPlayer() async => calls.add('player stop');
  @override
  Future<void> setCallMode(bool on) async => calls.add('call $on');
  @override
  Future<bool> startMic() async {
    calls.add('mic start');
    return micAllowed;
  }

  @override
  Future<void> stopMic() async => calls.add('mic stop');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('packets parse, voice is framed', () {
    final data = Uint8List.fromList([0x50, 0x44, 0x41, 0x31, 0, 0, 1, 2, 9, 8, 7]);
    final p = AudioPacket.parse(data);
    expect(p.seq, 258);
    expect(p.payload, [9, 8, 7]);
    expect(AudioPacket.matches(Uint8List.fromList([0x50, 0x44, 0x46, 0x31, 0, 0, 0, 0])), isFalse);
    expect(voiceMessage(Uint8List.fromList([1, 2])), [0x50, 0x44, 0x4d, 0x31, 1, 2]);
    // µ-law matches G.711 (and the computer's decoder).
    expect(ulawEncode(Int16List.fromList([0, 32767, -32768, 1000])), [0xff, 0x80, 0x00, 0xce]);
  });

  test('listening plays the computer\'s packets; silence too', () async {
    final conn = FakeAudioConnection();
    final backend = FakeBackend();
    final audio = AudioController(conn, backend: backend);
    await audio.setSound(true);
    expect(conn.calls, ['start sound=true mic=false opus,pcm']);
    expect(backend.calls, ['player opus 312']);
    conn.packets.add(AudioPacket(0, Uint8List.fromList([1, 2, 3])));
    conn.packets.add(AudioPacket(1, Uint8List(0)));
    await Future<void>.delayed(Duration.zero);
    expect(backend.played, hasLength(2));
    await audio.setSound(false);
    expect(conn.calls.last, 'stop');
    expect(backend.calls.last, 'player stop');
    audio.dispose();
  });

  test('a phone whose Opus decoder fails switches to PCM for good', () async {
    final conn = FakeAudioConnection();
    final backend = FakeBackend();
    final audio = AudioController(conn, backend: backend);
    await audio.setSound(true);
    backend.onPlayerError!('decoder broke');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(conn.calls.last, 'start sound=true mic=false pcm');
    expect(backend.calls.last, 'player pcm 312');
    expect(audio.sound, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AudioController.opusBrokenKey), isTrue);
    audio.dispose();
  });

  test('the microphone is refused when the computer doesn\'t allow it', () async {
    final conn = FakeAudioConnection();
    final audio = AudioController(conn, backend: FakeBackend());
    await audio.setMic(true);
    expect(audio.mic, isFalse);
    expect(audio.error, contains('turned off'));
    audio.dispose();
  });

  test('talking is a call: the voice goes out while the computer is still heard', () async {
    final conn = FakeAudioConnection(allow: const Allowed(audio: true, mic: true));
    final backend = FakeBackend();
    final audio = AudioController(conn, backend: backend);
    await audio.startTalking();
    expect(audio.talking, isTrue);
    await audio.setSound(true);
    await audio.setMic(true);
    expect(backend.calls, ['call true', 'mic start', 'player opus 312', 'player opus 312']);
    // The computer's microphone keeps playing while talking.
    conn.packets.add(AudioPacket(0, Uint8List.fromList([1, 2, 3])));
    await Future<void>.delayed(Duration.zero);
    expect(backend.played, hasLength(1));
    backend.onMic!(Uint8List(320));
    expect(conn.voice, hasLength(1));
    audio.stopTalking();
    backend.onMic!(Uint8List(320)); // late: not sent
    expect(conn.voice, hasLength(1));
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls.sublist(backend.calls.length - 2), ['mic stop', 'call false']);
    audio.dispose();
  });

  test('no microphone permission: explained, not talking', () async {
    final backend = FakeBackend(micAllowed: false);
    final audio = AudioController(FakeAudioConnection(), backend: backend);
    await audio.startTalking();
    expect(audio.talking, isFalse);
    expect(audio.error, contains('microphone'));
    expect(backend.calls.last, 'call false');
    audio.dispose();
  });

  test('the computer stopping sound turns it off on the phone', () async {
    final conn = FakeAudioConnection();
    final audio = AudioController(conn, backend: FakeBackend());
    await audio.setSound(true);
    conn.stopped.add('This was turned off in PairDesk settings on the computer.');
    await Future<void>.delayed(Duration.zero);
    expect(audio.sound, isFalse);
    expect(audio.error, contains('turned off'));
    audio.dispose();
  });

  test('sound pauses in the background and picks up again', () async {
    final conn = FakeAudioConnection();
    final audio = AudioController(conn, backend: FakeBackend());
    await audio.setSound(true);
    audio.pause();
    expect(conn.calls.last, 'stop');
    await audio.resume();
    expect(conn.calls.last, startsWith('start sound=true'));
    expect(audio.sound, isTrue);
    audio.dispose();
  });

  testWidgets('the Sound panel', (tester) async {
    final conn = FakeAudioConnection();
    final backend = FakeBackend();
    final audio = AudioController(conn, backend: backend);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SoundSheet(audio: audio)),
      ),
    );
    expect(find.text('Computer sound'), findsOneWidget);
    expect(find.textContaining('Off on the computer'), findsOneWidget);
    await tester.tap(find.text('Computer sound'));
    await tester.pumpAndSettle();
    expect(audio.sound, isTrue);

    // Hold to talk.
    final gesture = await tester.startGesture(tester.getCenter(find.bySemanticsLabel('Hold to talk')));
    await tester.pump();
    expect(audio.talking, isTrue);
    expect(find.text('Talking…'), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(audio.talking, isFalse);
    audio.dispose();
  });

  testWidgets('the Sound panel when the computer is too old', (tester) async {
    final audio = AudioController(FakeAudioConnection(feature: false), backend: FakeBackend());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SoundSheet(audio: audio)),
      ),
    );
    expect(find.textContaining('Update PairDesk on the computer'), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Computer sound'));
    expect(sw.onChanged, isNull);
    audio.dispose();
  });
}
