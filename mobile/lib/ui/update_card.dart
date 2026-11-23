// SPDX-License-Identifier: GPL-3.0-or-later
// The "Version X is ready" card: Home shows it, and so does Settings after
// "Check for updates" finds one, so the update can start where it was found.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update_check.dart';
import '../update_install.dart';
import 'theme.dart';
import 'widgets.dart';

class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key, required this.update, required this.installer, required this.onDismiss});

  final AvailableUpdate update;
  final UpdateInstaller installer;
  final VoidCallback onDismiss;

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  Future<void> _update() async {
    final installer = widget.installer;
    if (!await installer.canInstall()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Let PairDesk install updates'),
          content: const Text(
            'Android asks for this once. On the next screen turn on "Allow from this source" '
            'for PairDesk, then come back and press Update.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (go == true) await installer.requestPermission();
      return;
    }
    await installer.install(widget.update);
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final update = widget.update;
    final installer = widget.installer;
    final failed = installer.stage == UpdateStage.failed;
    final (title, detail) = switch (installer.stage) {
      UpdateStage.downloading => ('Downloading ${update.version}', null),
      UpdateStage.installing => ('Getting it ready…', null),
      UpdateStage.waiting => (
        'Finish in Android',
        'Android is asking you to confirm. PairDesk restarts once it is installed.',
      ),
      UpdateStage.failed => ('Update failed', installer.error),
      UpdateStage.idle => ('Version ${update.version} is ready', 'Downloads and installs over this one'),
    };
    Widget small(String label, VoidCallback onTap, {bool strong = false}) => Pressable(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: strong ? c.inv : c.s2, borderRadius: BorderRadius.circular(999)),
        child: Text(
          label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: strong ? c.onInv : c.ink),
        ),
      ),
    );
    return PdCard(
      padding: const EdgeInsets.all(12),
      radius: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: c.inv, shape: BoxShape.circle),
                child: Icon(
                  failed ? Icons.error_outline_rounded : Icons.system_update_alt_rounded,
                  size: 20,
                  color: c.dark ? PdColors.onAccent : PdColors.lime,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    if (detail != null) Text(detail, style: TextStyle(fontSize: 13, color: c.sub)),
                  ],
                ),
              ),
              if (installer.stage == UpdateStage.idle) small('Update', _update, strong: true),
            ],
          ),
          if (installer.stage == UpdateStage.downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(54, 10, 4, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(value: installer.progress, minHeight: 6),
              ),
            ),
          if (installer.stage != UpdateStage.downloading && installer.stage != UpdateStage.installing)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: switch (installer.stage) {
                  UpdateStage.waiting => [small('Close', installer.reset)],
                  UpdateStage.failed => [
                    small('Close', installer.reset),
                    small('Open GitHub', () => launchUrl(update.notes, mode: LaunchMode.externalApplication)),
                    small('Try again', _update, strong: true),
                  ],
                  _ => [
                    small('Not now', widget.onDismiss),
                    small('What\'s new', () => launchUrl(update.notes, mode: LaunchMode.externalApplication)),
                  ],
                },
              ),
            ),
        ],
      ),
    );
  }
}
