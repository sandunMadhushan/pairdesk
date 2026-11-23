// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screen/video.dart';

import '../settings/app_lock.dart';
import '../sponsor.dart';
import '../ui/update_card.dart';
import '../update_check.dart';
import '../update_install.dart';

import 'package:url_launcher/url_launcher.dart';

import 'remote_help_screen.dart';
import '../settings/app_settings.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    this.updates,
    this.installer,
    this.authenticate = deviceAuthenticate,
    this.canAuthenticate = deviceCanAuthenticate,
    this.embedded = false,
  });

  final AppSettings settings;

  /// New releases on GitHub. Null on F-Droid builds, which F-Droid updates.
  final UpdateChecker? updates;

  /// Downloads and installs what [updates] finds, from here.
  final UpdateInstaller? installer;
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
                  subtitle: 'The relay or your router',
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
                    if (updates != null) ...[
                      _CheckForUpdates(updates: updates!, installer: installer),
                      const PdDivider(),
                    ],
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
                    if (showSponsor) ...[const PdDivider(), const _SupportRow()],
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
/// the once-a-day check. When it finds one, the same "Update" card as on the
/// Home screen appears right here.
class _CheckForUpdates extends StatefulWidget {
  const _CheckForUpdates({required this.updates, this.installer});

  final UpdateChecker updates;
  final UpdateInstaller? installer;

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
      answer = found == null ? 'This is the newest version.' : 'PairDesk ${found.version} is available.';
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
  Widget build(BuildContext context) {
    final installer = widget.installer;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.updates, ?installer]),
      builder: (context, _) {
        final update = widget.updates.available;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PdRow(
              icon: Icons.system_update_alt_rounded,
              title: 'Check for updates',
              subtitle: update != null
                  ? 'PairDesk ${update.version} is available.'
                  : _answer ?? 'PairDesk also checks by itself once a day',
              trailing: _busy ? PdSpinner(color: PdColors.of(context).ink) : null,
              onTap: _busy ? null : _check,
            ),
            if (update != null && installer != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: UpdateCard(update: update, installer: installer, onDismiss: widget.updates.dismiss),
              ),
          ],
        );
      },
    );
  }
}

/// "Support PairDesk": a sheet with the places to sponsor it.
class _SupportRow extends StatelessWidget {
  const _SupportRow();

  @override
  Widget build(BuildContext context) => PdRow(
    icon: Icons.favorite_rounded,
    title: 'Support PairDesk',
    subtitle: 'Free and open source. Sponsor its development',
    onTap: () => showPdSheet<void>(context, (_) => const _SupportSheet(), scrollable: false),
  );
}

class _SupportSheet extends StatelessWidget {
  const _SupportSheet();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PdTitle(
          'Support PairDesk',
          subtitle: 'PairDesk is free and has no ads. Sponsors keep it that way.',
        ),
        const SizedBox(height: 12),
        for (final link in sponsorLinks)
          PdRow(
            icon: Icons.favorite_border_rounded,
            title: link.name,
            subtitle: link.note,
            onTap: () => launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication),
          ),
      ],
    ),
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
