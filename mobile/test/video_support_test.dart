// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/screen/video.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pairdesk/video');

  setUp(() {
    VideoSupport.resetForTest();
    VideoSupport.androidForTest = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'supported',
    );
  });

  tearDown(() => VideoSupport.androidForTest = null);

  test('video is used when the phone has a decoder', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await VideoSupport.available(), isTrue);
  });

  test('the app was killed while video played: pictures from then on', () async {
    SharedPreferences.setMockInitialValues({VideoSupport.tryingKey: true});
    expect(await VideoSupport.available(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(VideoSupport.brokenKey), isTrue);
    expect(prefs.getBool(VideoSupport.tryingKey), isNull);
  });

  test('playing in this run is not mistaken for a crash', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await VideoSupport.available(), isTrue);
    await VideoSupport.playing(true);
    expect(await VideoSupport.available(), isTrue);
    await VideoSupport.playing(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(VideoSupport.tryingKey), isNull);
  });

  test('turning it on again in Settings clears both marks', () async {
    SharedPreferences.setMockInitialValues({VideoSupport.tryingKey: true});
    expect(await VideoSupport.available(), isFalse);
    await VideoSupport.reset();
    expect(await VideoSupport.available(), isTrue);
  });
}
