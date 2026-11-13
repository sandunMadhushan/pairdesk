// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screen/video.dart';

import '../settings/app_lock.dart';
import '../update_check.dart';
import 'remote_help_screen.dart';
import '../settings/app_settings.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.updates,
    this.authenticate = deviceAuthenticate,
    this.canAuthenticate = deviceCanAuthenticate,
    this.embedded = false,
  });

  final AppSettings settings;

  /// New releases on GitHub. Null on F-Droid builds, which F-Droid updates.
  final UpdateChecker? updates;
  final Authenticator authenticate;
  final Future<bool> Function() canAuthenticate;

  /// Shown as a tab of the home screen (room left for its bottom bar).
  final bool embedded;

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
    final c = PdColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => ListView(
            padding: EdgeInsets.fromLTRB(16, 14, 16, embedded ? 120 : 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                child: Row(
                  children: [
                    if (!embedded && Navigator.of(context).canPop()) ...[
                      RoundButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                    ],
                    const Text(
                      'Settings',
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.6),
                    ),
                  ],
                ),
              ),
              PdCard(
                child: Column(
                  children: [
                    PdRow(
                      icon: Icons.fingerprint_rounded,
                      title: 'App lock',
                      subtitle: 'Fingerprint, face or screen lock to open PairDesk',
                      onTap: () => _toggleLock(context, !settings.appLock),
                      trailing: Switch(value: settings.appLock, onChanged: (on) => _toggleLock(context, on)),
                    ),
                    if (settings.appLock) ...[
                      const PdDivider(),
                      PdRow(
                        icon: Icons.lock_clock_outlined,
                        title: 'Lock again',
                        minHeight: 56,
                        subtitle: 'When PairDesk has been in the background',
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 52, bottom: 10),
                        child: SizedBox(
                          width: double.infinity,
                          child: DropdownButton<LockAfter>(
                            isExpanded: true,
                            value: settings.lockAfter,
                            underline: const SizedBox.shrink(),
                            borderRadius: BorderRadius.circular(18),
                            onChanged: (v) => settings.setLockAfter(v!),
                            items: [
                              for (final v in LockAfter.values)
                                DropdownMenuItem(value: v, child: Text(v.label)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              PdCard(
                child: PdRow(
                  icon: Icons.public_rounded,
                  title: 'Connect from anywhere',
                  subtitle: 'Relay, Tailscale or your router',
                  trailing: Icon(Icons.chevron_right_rounded, color: c.sub),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteHelpScreen())),
                ),
              ),
              const SizedBox(height: 12),
              PdCard(
                child: Column(
                  children: [
                    PdRow(
                      icon: Icons.speed_rounded,
                      title: 'Pointer speed',
                      trailing: Text(
                        '${settings.pointerSpeed.toStringAsFixed(2)}×',
                        style: TextStyle(fontSize: 15, color: c.sub),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 36, bottom: 6),
                      child: Slider(
                        value: settings.pointerSpeed,
                        min: AppSettings.minSpeed,
                        max: AppSettings.maxSpeed,
                        divisions: 8,
                        label: '${settings.pointerSpeed.toStringAsFixed(2)}×',
                        onChanged: settings.setPointerSpeed,
                      ),
                    ),
                    const PdDivider(),
                    PdRow(
                      icon: Icons.swap_vert_rounded,
                      title: 'Natural scrolling',
                      subtitle: 'Content moves with your fingers, like on a phone',
                      onTap: () => settings.setNaturalScroll(!settings.naturalScroll),
                      trailing: Switch(value: settings.naturalScroll, onChanged: settings.setNaturalScroll),
                    ),
                    const PdDivider(),
                    const SmoothVideoTile(),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              PdCard(
                child: Column(
                  children: [
                    if (updates != null) ...[_CheckForUpdates(updates: updates!), const PdDivider()],
                    FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (_, snap) => PdRow(
                        icon: Icons.info_outline_rounded,
                        title: 'PairDesk',
                        subtitle:
                            '${snap.hasData ? 'Version ${snap.data!.version} · ' : ''}Free software, GPL-3.0-or-later\n'
                            'github.com/sandunMadhushan/pairdesk',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
  Widget build(BuildContext context) => PdRow(
    icon: Icons.system_update_alt_rounded,
    title: 'Check for updates',
    subtitle: _answer ?? 'PairDesk also checks by itself once a day',
    trailing: _busy ? PdSpinner(color: PdColors.of(context).ink) : null,
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
    Future<void> set(bool on) async {
      setState(() => _on = on);
      on ? await VideoSupport.reset() : await VideoSupport.markBroken();
    }

    return PdRow(
      icon: Icons.slow_motion_video_rounded,
      title: 'Smooth screen view',
      subtitle:
          'Video instead of pictures: smoother, less data. Turns itself off if this phone can\'t show it',
      onTap: _on == null ? null : () => set(!_on!),
      trailing: Switch(value: _on ?? true, onChanged: _on == null ? null : set),
    );
  }
}
