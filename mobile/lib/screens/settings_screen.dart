// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screen/video.dart';

import '../settings/app_lock.dart';
import '../update_check.dart';
import 'remote_help_screen.dart';
import '../settings/app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.updates,
    this.authenticate = deviceAuthenticate,
    this.canAuthenticate = deviceCanAuthenticate,
  });

  final AppSettings settings;

  /// New releases on GitHub. Null on F-Droid builds, which F-Droid updates.
  final UpdateChecker? updates;
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
            header('Connection'),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('Connect from anywhere'),
              subtitle: const Text('Use PairDesk away from home with Tailscale'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteHelpScreen())),
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
            const SmoothVideoTile(),
            header('About'),
            if (updates != null) _CheckForUpdates(updates: updates!),
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

/// "Check for updates" in About: asks GitHub now, rather than waiting for
/// the once-a-day check. What it finds shows on the Home screen.
class _CheckForUpdates extends StatefulWidget {
  const _CheckForUpdates({required this.updates});

  final UpdateChecker updates;

  @override
  State<_CheckForUpdates> createState() => _CheckForUpdatesState();
}

class _CheckForUpdatesState extends State<_CheckForUpdates> {
  bool _busy = false;
  String? _answer;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _answer = null;
    });
    String answer;
    try {
      final found = await widget.updates.checkNow();
      answer = found == null
          ? 'This is the newest version.'
          : 'PairDesk ${found.version} is available \u2014 see the Home screen.';
    } catch (_) {
      answer = 'Couldn\'t reach GitHub. Check the phone\'s connection.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _answer = answer;
    });
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.system_update_outlined),
    title: const Text('Check for updates'),
    subtitle: Text(_answer ?? 'PairDesk also checks by itself once a day'),
    trailing: _busy
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : null,
    onTap: _busy ? null : _check,
  );
}

/// Screen view as video (H.264) or pictures. Video turns itself off when
/// this phone can't show it; this switch turns it back on.
class SmoothVideoTile extends StatefulWidget {
  const SmoothVideoTile({super.key});

  @override
  State<SmoothVideoTile> createState() => _SmoothVideoTileState();
}

class _SmoothVideoTileState extends State<SmoothVideoTile> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _on = !(p.getBool(VideoSupport.brokenKey) ?? false));
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.slow_motion_video_outlined),
      title: const Text('Smooth screen view'),
      subtitle: const Text(
        'Video instead of pictures: smoother and uses less data. Turns itself off if this phone can\'t show it',
      ),
      value: _on ?? true,
      onChanged: _on == null
          ? null
          : (on) async {
              setState(() => _on = on);
              on ? await VideoSupport.reset() : await VideoSupport.markBroken();
            },
    );
  }
}
