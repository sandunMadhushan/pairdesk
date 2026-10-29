// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_model.dart';
import 'files/share_inbox.dart';
import 'screens/home_screen.dart';
import 'settings/app_lock.dart';
import 'update_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = await AppModel.load();
  ShareInbox.instance.start();
  final updates = await _updateChecker();
  runApp(PairDeskApp(model: model, updates: updates));
  updates?.checkIfDue();
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
  const PairDeskApp({super.key, required this.model, this.updates});

  final AppModel model;
  final UpdateChecker? updates;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2457D6);
    return MaterialApp(
      title: 'PairDesk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      builder: (context, child) {
        final settings = model.settings;
        if (settings == null || child == null) return child ?? const SizedBox.shrink();
        return AppLockGate(settings: settings, child: child);
      },
      home: HomeScreen(model: model, updates: updates),
    );
  }
}
