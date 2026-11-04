// SPDX-License-Identifier: GPL-3.0-or-later
// Installing an update without leaving PairDesk.
//
// The app downloads the APK the signed manifest points at, checks it
// against the SHA-256 in that manifest, and hands the file to Android
// (UpdateChannel.kt). Android asks the owner to confirm and installs it
// over this copy. Nothing is installed if the download doesn't match
// what the manifest says, and Android itself refuses an APK signed with
// a different key.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'update_check.dart';

enum UpdateStage { idle, downloading, installing, waiting, failed }

/// Keeps the digest `sha256.startChunkedConversion` hands over at the end.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class UpdateInstaller extends ChangeNotifier {
  UpdateInstaller({
    MethodChannel? channel,
    Future<Directory> Function()? cacheDir,
    Future<HttpClientResponse> Function(Uri url)? open,
  }) : _channel = channel ?? const MethodChannel('pairdesk/update'),
       _cacheDir = cacheDir ?? (() async => Directory.systemTemp.createTemp('pairdesk-update')),
       _open = open ?? _httpOpen {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'installed':
          _stage = UpdateStage.idle;
          _error = null;
          notifyListeners();
        case 'failed':
          _fail(call.arguments as String? ?? 'The update wasn\'t installed.');
      }
    });
  }

  final MethodChannel _channel;
  final Future<Directory> Function() _cacheDir;
  final Future<HttpClientResponse> Function(Uri url) _open;

  UpdateStage _stage = UpdateStage.idle;
  UpdateStage get stage => _stage;

  /// 0 to 1 while downloading, or null when the size isn't known.
  double? _progress;
  double? get progress => _progress;

  String? _error;
  String? get error => _error;

  bool get busy => _stage == UpdateStage.downloading || _stage == UpdateStage.installing;

  /// True when Android lets PairDesk install an app.
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Android's "Install unknown apps" page for PairDesk.
  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on PlatformException catch (e) {
      _fail(e.message ?? 'Couldn\'t open Android\'s settings.');
    }
  }

  /// Downloads [update] and asks Android to install it. The owner still
  /// confirms on Android's own screen.
  Future<void> install(AvailableUpdate update) async {
    if (busy) return;
    _stage = UpdateStage.downloading;
    _progress = null;
    _error = null;
    notifyListeners();
    File? file;
    try {
      file = await _download(update);
      _stage = UpdateStage.installing;
      notifyListeners();
      await _channel.invokeMethod<void>('install', {'path': file.path});
      // Android's confirmation screen is up; the result arrives on the
      // channel, and a successful install replaces this app anyway.
      _stage = UpdateStage.waiting;
      notifyListeners();
    } on PlatformException catch (e) {
      await _delete(file);
      _fail(e.message ?? 'Couldn\'t start the update.');
    } catch (e) {
      await _delete(file);
      _fail(_explain(e));
    }
  }

  Future<File> _download(AvailableUpdate update) async {
    final dir = await _cacheDir();
    final file = File('${dir.path}/pairdesk-${update.version}.apk');
    final res = await _open(update.download);
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: update.download);
    }
    final total = update.size > 0 ? update.size : res.contentLength;
    final sink = file.openWrite();
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    var got = 0;
    try {
      await for (final chunk in res) {
        got += chunk.length;
        if (total > 0 && got > total) throw const FormatException('the download is bigger than expected');
        sink.add(chunk);
        hash.add(chunk);
        if (total > 0) {
          _progress = got / total;
          notifyListeners();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    hash.close();
    if (update.size > 0 && got != update.size) {
      await _delete(file);
      throw const FormatException('the download is the wrong size');
    }
    if (update.sha256.isNotEmpty && '${digest.value}' != update.sha256.toLowerCase()) {
      await _delete(file);
      throw const FormatException('the download doesn\'t match what PairDesk signed');
    }
    return file;
  }

  Future<void> _delete(File? file) async {
    if (file == null) return;
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  String _explain(Object e) => switch (e) {
    FormatException(:final message) => 'The update was not installed: $message.',
    SocketException _ => 'Couldn\'t reach GitHub. Check the phone\'s connection.',
    HttpException _ => 'GitHub didn\'t send the update. Try again later.',
    _ => 'The update failed: $e',
  };

  void _fail(String message) {
    _stage = UpdateStage.failed;
    _progress = null;
    _error = message;
    notifyListeners();
  }

  /// Back to the "an update is available" card after a failure.
  void reset() {
    if (busy) return;
    _stage = UpdateStage.idle;
    _progress = null;
    _error = null;
    notifyListeners();
  }

  static Future<HttpClientResponse> _httpOpen(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    final req = await client.getUrl(url);
    return req.close().timeout(const Duration(minutes: 10));
  }
}
