// SPDX-License-Identifier: GPL-3.0-or-later
// Two-way sound against the real agent. Run through tools/e2e-audio.sh.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/agent_connection.dart';
import 'package:pairdesk/audio/ulaw.dart';
import 'package:pairdesk/pairing/identity.dart';
import 'package:pairdesk/pairing/pairing_link.dart';

void main() {
  final env = Platform.environment;
  final link = env['PAIRDESK_E2E_LINK'];
  final settings = env['PAIRDESK_E2E_SETTINGS'];
  final dir = env['PAIRDESK_E2E_AUDIO'];
  // Wine can't record what the computer plays (real Windows can).
  final loopback = env['PAIRDESK_E2E_LOOPBACK'] != '0';
  final skip = link == null || settings == null || dir == null ? 'run through tools/e2e-audio.sh' : null;

  Future<void> post(String path, Object body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$settings$path'));
      req.headers.set('X-PairDesk', '1');
      req.write(jsonEncode(body));
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 200);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> get(String path) async {
    final client = HttpClient();
    try {
      final res = await (await client.getUrl(Uri.parse('$settings$path'))).close();
      return jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> waitFile(String name) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!File('$dir/$name').existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('$name never appeared');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
    'two-way sound',
    () async {
      final info = parsePairingLink(link!);
      info.addresses.insert(0, '127.0.0.1');
      final me = await PhoneIdentity.fromSeed(List.filled(32, 7));
      final conn = AgentConnection(pingInterval: const Duration(seconds: 1));
      final laptop = await conn.pair(info, me, phoneName: 'Audio phone');
      expect(conn.features, contains('audio'));
      expect(conn.allowed.audio, isTrue);
      expect(conn.allowed.mic, isFalse, reason: 'the microphone is off until the owner allows it');

      // The computer's microphone is refused while not allowed.
      await expectLater(
        conn.startAudio(sound: false, mic: true, codecs: ['opus', 'pcm']),
        throwsA(isA<RequestException>().having((e) => e.code, 'code', 'not_allowed')),
      );

      // ---- Computer sound → phone ----
      final packets = <AudioPacket>[];
      final sub = conn.audioPackets.listen(packets.add);
      if (loopback) {
        final audio = await conn.startAudio(sound: true, mic: false, codecs: ['opus', 'pcm']);
        expect(audio.codec, 'opus');
        expect((audio.rate, audio.channels, audio.frameMs), (48000, 2, 20));
        expect(audio.preSkip, greaterThan(0));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(packets.length, greaterThan(15), reason: 'about 50 packets a second');
        expect(packets.every((p) => p.payload.isEmpty), isTrue, reason: 'nothing plays yet: silence');
        File('$dir/play').createSync();
        await waitFile('played');
        final sounding = packets.where((p) => p.payload.length > 40).length;
        debugPrint('e2e audio: ${packets.length} packets, $sounding with sound');
        expect(sounding, greaterThan(40), reason: 'a 2 s tone is about 100 packets');
        // Sequence numbers count up without gaps (nothing was dropped locally).
        for (var i = 1; i < packets.length; i++) {
          expect(packets[i].seq, packets[i - 1].seq + 1);
        }
      }
      // ---- Phone voice → computer ----
      File('$dir/record').createSync();
      await waitFile('recording');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final start = DateTime.now();
      var n = 0;
      for (var frame = 0; frame < 75; frame++) {
        // 20 ms of a 1 kHz tone, 16 kHz mono µ-law, in real time.
        final pcm = Int16List(320);
        for (var i = 0; i < 320; i++) {
          pcm[i] = (12000 * math.sin(2 * math.pi * 1000 * n++ / 16000)).round();
        }
        conn.sendVoice(ulawEncode(pcm));
        final due = start.add(Duration(milliseconds: 20 * (frame + 1)));
        final wait = due.difference(DateTime.now());
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      File('$dir/stop-recording').createSync();
      await waitFile('recorded');

      // ---- Stopping ----
      if (loopback) {
        conn.stopAudio();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final before = packets.length;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(packets.length, before, reason: 'no packets after audio_stop');
      }
      // ---- Talking while listening: no echo of your own voice ----
      // The phone's voice plays on the computer and comes back in the
      // recorded computer sound; the computer's echo canceller removes it.
      // The voice is speech-like noise (a pure tone can't be told apart
      // from itself a moment later, real voices can).
      if (loopback) {
        final heard = <AudioPacket>[];
        final sub2 = conn.audioPackets.listen(heard.add);
        await conn.startAudio(sound: true, mic: false, codecs: ['pcm']);
        final talkStart = DateTime.now();
        var seed = 12345;
        var m = 0;
        double sentSum = 0;
        var sentCount = 0;
        int? lastSecondFrom;
        for (var frame = 0; frame < 250; frame++) {
          final pcm = Int16List(320);
          for (var i = 0; i < 320; i++) {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff;
            final noise = ((seed >> 8) & 0xffff) / 32768.0 - 1.0;
            final syllables = math.pow(0.5 + 0.5 * math.sin(2 * math.pi * 4 * m++ / 16000), 2);
            pcm[i] = (noise * syllables * 9000).round();
            if (frame >= 200) {
              sentSum += (pcm[i] / 32768) * (pcm[i] / 32768);
              sentCount++;
            }
          }
          if (frame == 200) lastSecondFrom = heard.length;
          conn.sendVoice(ulawEncode(pcm));
          final due = talkStart.add(Duration(milliseconds: 20 * (frame + 1)));
          final wait = due.difference(DateTime.now());
          if (wait > Duration.zero) await Future<void>.delayed(wait);
        }
        final tail = heard.sublist(lastSecondFrom!);
        double sum = 0;
        var count = 0;
        for (final p in tail) {
          final v = ByteData.sublistView(p.payload);
          for (var i = 0; i + 1 < p.payload.length; i += 2) {
            final x = v.getInt16(i, Endian.little) / 32768;
            sum += x * x;
          }
          count += 1920; // 20 ms of 48 kHz stereo, silence included
        }
        final sent = math.sqrt(sentSum / sentCount);
        final back = math.sqrt(sum / count);
        final db = 20 * math.log(back / sent) / math.ln10;
        debugPrint(
          'e2e audio: own voice coming back while talking: rms ${back.toStringAsFixed(4)} '
          '(sent ${sent.toStringAsFixed(4)}, ${db.toStringAsFixed(1)} dB)',
        );
        expect(db, lessThan(-20), reason: 'the phone hears itself: echo not cancelled');
        conn.stopAudio();
        await sub2.cancel();
      }

      // ---- The computer's microphone, once allowed ----
      await post('api/permissions', {'power': true, 'session': true, 'apps': true, 'mic': true});
      await conn.disconnect();
      await conn.connect(laptop, me, phoneName: 'Audio phone');
      expect(conn.allowed.mic, isTrue);
      final both = await conn.startAudio(sound: loopback, mic: true, codecs: ['opus']);
      expect((both.sound, both.mic), (loopback, true));
      final micPackets = await conn.audioPackets.take(10).toList().timeout(const Duration(seconds: 3));
      expect(micPackets, hasLength(10));
      // Listening to the microphone shows on the computer.
      final state = await get('api/state');
      final phone = (state['phones'] as List).single as Map;
      expect(phone['listening'], {'sound': loopback, 'mic': true});
      // Turning the microphone off on the computer stops it.
      final micStopped = conn.audioStopped.first;
      await post('api/permissions', {'power': true, 'session': true, 'apps': true, 'mic': false});
      expect(await micStopped.timeout(const Duration(seconds: 3)), contains('turned off'));

      // Turning sound off on the computer stops a phone that listens.
      if (loopback) {
        await conn.startAudio(sound: true, mic: false, codecs: ['pcm']);
        final stopped = conn.audioStopped.first;
        await post('api/permissions', {'power': true, 'session': true, 'apps': true, 'audio': false});
        expect(await stopped.timeout(const Duration(seconds: 3)), contains('turned off'));
      }
      await sub.cancel();
      await conn.disconnect();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
