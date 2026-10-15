// SPDX-License-Identifier: GPL-3.0-or-later
// Lock, sleep, screen off, sign out, restart, shut down.

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../buttons/custom_button.dart';

IconData powerIcon(PowerAction a) => switch (a) {
  PowerAction.lock => Icons.lock_outline,
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
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
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

class PowerTab extends StatelessWidget {
  const PowerTab({super.key, required this.connection});
  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!connection.features.contains('power')) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(connection.outdatedComputerMessage(), textAlign: TextAlign.center),
        ),
      );
    }
    final allowed = connection.allowed;
    Widget tile(PowerAction a) {
      final ok = allowed.action(a);
      final danger = a.endsSession;
      final color = danger ? theme.colorScheme.errorContainer : theme.colorScheme.secondaryContainer;
      final onColor = danger ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSecondaryContainer;
      return Material(
        color: ok ? color : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: ok ? () => doPower(context, connection, a) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(powerIcon(a), size: 36, color: ok ? onColor : theme.disabledColor),
                const SizedBox(height: 8),
                Text(
                  powerLabel(a),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(color: ok ? onColor : theme.disabledColor),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final anyOff = PowerAction.values.any((a) => !allowed.action(a));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 124,
          ),
          children: [for (final a in PowerAction.values) tile(a)],
        ),
        if (anyOff)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Greyed-out actions are turned off in PairDesk settings on the computer.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}
