// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import 'app_model.dart';
import 'files/share_inbox.dart';
import 'screens/home_screen.dart';
import 'settings/app_lock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = await AppModel.load();
  ShareInbox.instance.start();
  runApp(PairDeskApp(model: model));
}

class PairDeskApp extends StatelessWidget {
  const PairDeskApp({super.key, required this.model});

  final AppModel model;

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
      home: HomeScreen(model: model),
    );
  }
}
