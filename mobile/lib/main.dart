// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_model.dart';
import 'files/share_inbox.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'settings/app_lock.dart';
import 'update_check.dart';
import 'update_install.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ShareInbox.instance.start();
  runApp(const PairDeskLoader());
}

/// Shows the splash while the saved computers and settings load, then fades
/// into the app. The splash stays at least long enough to be seen.
class PairDeskLoader extends StatefulWidget {
  const PairDeskLoader({super.key});

  @override
  State<PairDeskLoader> createState() => _PairDeskLoaderState();
}

class _PairDeskLoaderState extends State<PairDeskLoader> {
  AppModel? _model;
  UpdateChecker? _updates;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shown = Future<void>.delayed(const Duration(milliseconds: 1500));
    final model = await AppModel.load();
    final updates = await _updateChecker();
    await shown;
    if (!mounted) return;
    setState(() {
      _model = model;
      _updates = updates;
    });
    updates?.checkIfDue();
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    return PairDeskApp(
      model: model,
      updates: _updates,
      installer: _updates == null ? null : UpdateInstaller(cacheDir: _updateCache),
    );
  }
}

/// Where a downloaded APK waits until Android installs it: the app's own
/// temporary space, which Android clears by itself if the install never
/// happens. Only PairDesk can read it.
Future<Directory> _updateCache() async {
  final dir = Directory('${Directory.systemTemp.path}/pairdesk-updates');
  if (!dir.existsSync()) await dir.create(recursive: true);
  // One update at a time: drop anything an earlier try left behind.
  for (final old in dir.listSync()) {
    try {
      await old.delete(recursive: true);
    } catch (_) {}
  }
  return dir;
}

/// GitHub builds look for new releases; F-Droid builds leave that to F-Droid.
Future<UpdateChecker?> _updateChecker() async {
  if (updatesFrom != 'github' || !Platform.isAndroid) return null;
  try {
    final info = await PackageInfo.fromPlatform();
    final android = await DeviceInfoPlugin().androidInfo;
    return UpdateChecker(currentVersion: info.version, abis: android.supportedAbis);
  } catch (_) {
    return null;
  }
}

class PairDeskApp extends StatelessWidget {
  const PairDeskApp({super.key, required this.model, this.updates, this.installer});

  /// Null while it loads: the splash shows.
  final AppModel? model;
  final UpdateChecker? updates;

  /// Downloads and installs an update; made only when [updates] is.
  final UpdateInstaller? installer;

  @override
  Widget build(BuildContext context) {
    final model = this.model;
    return MaterialApp(
      title: 'PairDesk',
      debugShowCheckedModeBanner: false,
      theme: pdTheme(Brightness.light),
      darkTheme: pdTheme(Brightness.dark),
      builder: (context, child) {
        final settings = model?.settings;
        if (settings == null || child == null) return child ?? const SizedBox.shrink();
        return AppLockGate(settings: settings, child: child);
      },
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeOutCubic,
        child: model == null
            ? const SplashScreen(key: ValueKey('splash'))
            : HomeScreen(key: const ValueKey('home'), model: model, updates: updates, installer: installer),
      ),
    );
  }
}
