// SPDX-License-Identifier: GPL-3.0-or-later
// Lock, sleep, screen off, sign out, restart, shut down: the ⏻ sheet.

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../buttons/custom_button.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

IconData powerIcon(PowerAction a) => switch (a) {
  PowerAction.lock => Icons.lock_outline_rounded,
  PowerAction.sleep => Icons.bedtime_outlined,
  PowerAction.screenOff => Icons.desktop_access_disabled_outlined,
  PowerAction.signOut => Icons.logout,
  PowerAction.restart => Icons.restart_alt,
  PowerAction.shutDown => Icons.power_settings_new,
};

/// Asks first for actions that can lose work. Returns false if cancelled.
Future<bool> confirmPower(BuildContext context, PowerAction a, String computer) async {
  if (!a.endsSession) return true;
  final verb = powerLabel(a).toLowerCase();
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(powerIcon(a)),
      title: Text('${powerLabel(a)} $computer?'),
      content: Text(
        'Unsaved work in open apps may be lost. You can\'t undo this from the phone once it starts.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: PdColors.of(ctx).inv,
            foregroundColor: PdColors.of(ctx).onInv,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(verb[0].toUpperCase() + verb.substring(1)),
        ),
      ],
    ),
  );
  return yes == true;
}

/// Runs a power action with confirmation and feedback.
Future<void> doPower(BuildContext context, AgentConnection conn, PowerAction a) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!await confirmPower(context, a, conn.agentName ?? 'the computer')) return;
  try {
    await conn.power(a);
    if (a == PowerAction.lock || a == PowerAction.screenOff) {
      messenger.showSnackBar(SnackBar(content: Text('${powerLabel(a)}: done')));
    }
  } on RequestException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// The ⏻ sheet: lock, sleep and screen off as tiles; the actions that end
/// the session below them, each asking first.
class PowerSheet extends StatelessWidget {
  const PowerSheet({super.key, required this.connection});
  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final head = PdTitle(
      'Power',
      subtitle: [
        connection.agentName,
        switch (connection.agentOs) {
          'windows' => 'Windows',
          'linux' => 'Linux',
          'macos' => 'macOS',
          _ => null,
        },
      ].nonNulls.join(' · '),
    );
    if (!connection.features.contains('power')) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            head,
            const SizedBox(height: 12),
            Text(connection.outdatedComputerMessage(), style: TextStyle(fontSize: 15, color: c.sub)),
          ],
        ),
      );
    }
    final allowed = connection.allowed;
    Future<void> run(PowerAction a) async {
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      if (!await confirmPower(context, a, connection.agentName ?? 'the computer')) return;
      navigator.maybePop();
      try {
        await connection.power(a);
        if (a == PowerAction.lock || a == PowerAction.screenOff) {
          messenger.showSnackBar(SnackBar(content: Text('${powerLabel(a)}: done')));
        }
      } on RequestException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }

    Widget tile(PowerAction a, int i) {
      final ok = allowed.action(a);
      return FadeRise(
        delay: Duration(milliseconds: 40 * i),
        child: Semantics(
          button: true,
          enabled: ok,
          label: powerLabel(a),
          excludeSemantics: true,
          child: Pressable(
            onTap: ok ? () => run(a) : null,
            child: Container(
              height: 100,
              decoration: BoxDecoration(color: c.s2, borderRadius: BorderRadius.circular(24)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(powerIcon(a), size: 26, color: ok ? c.ink : c.sub.withValues(alpha: 0.5)),
                  const SizedBox(height: 10),
                  Text(
                    powerLabel(a),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: ok ? c.ink : c.sub.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget risky(PowerAction a, int i) {
      final ok = allowed.action(a);
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FadeRise(
          delay: Duration(milliseconds: 40 * i),
          child: Semantics(
            button: true,
            enabled: ok,
            label: powerLabel(a),
            excludeSemantics: true,
            child: Pressable(
              scale: 0.97,
              onTap: ok ? () => run(a) : null,
              child: Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: ok ? c.inv : c.s2, borderRadius: BorderRadius.circular(22)),
                child: Row(
                  children: [
                    Icon(powerIcon(a), color: ok ? c.onInv : c.sub),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        powerLabel(a),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: ok ? c.onInv : c.sub,
                        ),
                      ),
                    ),
                    Text(
                      ok ? 'Asks first' : 'Off',
                      style: TextStyle(
                        fontSize: 13,
                        color: ok ? (c.dark ? const Color(0xFF55565B) : c.subInv) : c.sub,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final safe = PowerAction.values.where((a) => !a.endsSession).toList();
    final ending = PowerAction.values.where((a) => a.endsSession).toList();
    final anyOff = PowerAction.values.any((a) => !allowed.action(a));
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          const SizedBox(height: 16),
          Row(
            children: [
              for (final (i, a) in safe.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: tile(a, i)),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Text('These can lose unsaved work', style: TextStyle(fontSize: 14, color: c.sub)),
          for (final (i, a) in ending.indexed) risky(a, i + safe.length),
          if (anyOff)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Actions marked "Off" are turned off in PairDesk settings on the computer.',
                style: TextStyle(fontSize: 13, color: c.sub),
              ),
            ),
        ],
      ),
    );
  }
}
