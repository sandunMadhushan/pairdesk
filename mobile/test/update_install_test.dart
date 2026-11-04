// SPDX-License-Identifier: GPL-3.0-or-later
// Downloading and installing an update: what the app checks before it
// hands an APK to Android.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pairdesk/update_check.dart';
import 'package:pairdesk/update_install.dart';

/// Enough of an HttpClientResponse to feed the downloader.
class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(this.body, {this.statusCode = 200});
  final List<int> body;
  @override
  final int statusCode;

  @override
  int get contentLength => body.length;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([body])
          .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final apk = Uint8List.fromList(List.generate(4096, (i) => i % 251));
  final good = sha256.convert(apk).toString();

  late Directory dir;
  late List<MethodCall> calls;
  late bool canInstall;
  late String? installError;

  const channel = MethodChannel('pairdesk/update');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pairdesk-update-test');
    calls = [];
    canInstall = true;
    installError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'canInstall':
          return canInstall;
        case 'install':
          if (installError != null) throw PlatformException(code: 'install', message: installError);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvailableUpdate update({String? sha, int? size}) => AvailableUpdate(
    version: '9.9.9',
    download: Uri.parse('https://example.com/pairdesk-9.9.9-android-arm64.apk'),
    notes: Uri.parse('https://example.com/notes'),
    sha256: sha ?? good,
    size: size ?? apk.length,
  );

  UpdateInstaller installer({List<int>? body, int status = 200}) => UpdateInstaller(
    channel: channel,
    cacheDir: () async => dir,
    open: (_) async => FakeResponse(body ?? apk, statusCode: status),
  );

  test('downloads, checks the hash and hands the file to Android', () async {
    final it = installer();
    final stages = <UpdateStage>[];
    it.addListener(() => stages.add(it.stage));
    await it.install(update());

    expect(it.error, isNull);
    expect(it.stage, UpdateStage.waiting);
    expect(stages, contains(UpdateStage.downloading));
    final install = calls.firstWhere((c) => c.method == 'install');
    final path = (install.arguments as Map)['path'] as String;
    expect(File(path).readAsBytesSync(), apk);
  });

  test('throws away a download that does not match the signed hash', () async {
    final it = installer();
    await it.install(update(sha: 'a' * 64));

    expect(it.stage, UpdateStage.failed);
    expect(it.error, contains('signed'));
    expect(calls.any((c) => c.method == 'install'), isFalse);
    expect(dir.listSync(), isEmpty, reason: 'the bad file is deleted');
  });

  test('throws away a download of the wrong size', () async {
    final it = installer(body: apk.sublist(0, 100));
    await it.install(update());

    expect(it.stage, UpdateStage.failed);
    expect(it.error, contains('size'));
    expect(calls.any((c) => c.method == 'install'), isFalse);
  });

  test('explains when GitHub does not send the file', () async {
    final it = installer(status: 404);
    await it.install(update());

    expect(it.stage, UpdateStage.failed);
    expect(it.error, contains('GitHub'));
  });

  test('asks Android for permission before it downloads anything', () async {
    canInstall = false;
    final it = installer();
    expect(await it.canInstall(), isFalse);
    await it.requestPermission();
    expect(calls.map((c) => c.method), contains('requestPermission'));
  });

  test('a failed install can be dismissed, and reports what Android said', () async {
    installError = 'Not enough space';
    final it = installer();
    await it.install(update());

    expect(it.stage, UpdateStage.failed);
    expect(it.error, 'Not enough space');
    it.reset();
    expect(it.stage, UpdateStage.idle);
    expect(it.error, isNull);
  });
}
