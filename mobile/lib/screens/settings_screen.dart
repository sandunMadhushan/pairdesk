// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../settings/app_lock.dart';
import '../settings/app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.authenticate = deviceAuthenticate,
    this.canAuthenticate = deviceCanAuthenticate,
  });

  final AppSettings settings;
  final Authenticator authenticate;
  final Future<bool> Function() canAuthenticate;

  Future<void> _toggleLock(BuildContext context, bool on) async {
    if (!on) {
      // Turning it off needs the same proof as unlocking.
      if (await authenticate('Turn off app lock')) await settings.setAppLock(false);
      return;
    }
    if (!await canAuthenticate()) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Set a screen lock first'),
          content: const Text(
            'App lock uses your phone\'s fingerprint, face or screen lock. '
            'Set one up in Android settings, then try again.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return;
    }
    if (await authenticate('Turn on app lock')) await settings.setAppLock(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(t, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            header('Security'),
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('App lock'),
              subtitle: const Text('Ask for fingerprint, face or screen lock to open PairDesk'),
              value: settings.appLock,
              onChanged: (on) => _toggleLock(context, on),
            ),
            if (settings.appLock)
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Lock again'),
                trailing: DropdownButton<LockAfter>(
                  value: settings.lockAfter,
                  underline: const SizedBox.shrink(),
                  onChanged: (v) => settings.setLockAfter(v!),
                  items: [for (final v in LockAfter.values) DropdownMenuItem(value: v, child: Text(v.label))],
                ),
              ),
            header('Touchpad'),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('Pointer speed'),
              subtitle: Slider(
                value: settings.pointerSpeed,
                min: AppSettings.minSpeed,
                max: AppSettings.maxSpeed,
                divisions: 8,
                label: '${settings.pointerSpeed.toStringAsFixed(2)}×',
                onChanged: settings.setPointerSpeed,
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.swap_vert),
              title: const Text('Natural scrolling'),
              subtitle: const Text('Content moves with your fingers, like on a phone'),
              value: settings.naturalScroll,
              onChanged: settings.setNaturalScroll,
            ),
            header('About'),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (_, snap) => ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('PairDesk'),
                subtitle: Text(
                  '${snap.hasData ? 'Version ${snap.data!.version} · ' : ''}Free software, GPL-3.0-or-later\n'
                  'github.com/sandunMadhushan/pairdesk',
                ),
                isThreeLine: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
