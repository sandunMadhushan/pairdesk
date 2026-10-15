// SPDX-License-Identifier: GPL-3.0-or-later
// How to use PairDesk away from home, with Tailscale.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class RemoteHelpScreen extends StatelessWidget {
  const RemoteHelpScreen({super.key});

  static final _playStore = Uri.parse('https://play.google.com/store/apps/details?id=com.tailscale.ipn');
  static final _fdroid = Uri.parse('https://f-droid.org/packages/com.tailscale.ipn/');
  static final _download = Uri.parse('https://tailscale.com/download');

  Future<void> _open(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t open $uri')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget step(int n, String title, String body, [List<Widget> actions = const []]) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 14, child: Text('$n')),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(body, style: theme.textTheme.bodyMedium),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Connect from anywhere')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'At home, PairDesk connects over your Wi-Fi. To reach your computer from anywhere else, '
            'PairDesk uses Tailscale: a free private network between your own devices. '
            'Your PairDesk connection stays encrypted and paired as before; Tailscale only carries it.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          step(
            1,
            'On the computer',
            'Install Tailscale and sign in. The PairDesk page on the computer shows "Tailscale is on" when it\'s ready.',
            [
              OutlinedButton(
                onPressed: () => _open(context, _download),
                child: const Text('tailscale.com/download'),
              ),
            ],
          ),
          step(2, 'On this phone', 'Install Tailscale and sign in with the same account.', [
            FilledButton.tonal(onPressed: () => _open(context, _playStore), child: const Text('Google Play')),
            OutlinedButton(onPressed: () => _open(context, _fdroid), child: const Text('F-Droid')),
          ]),
          step(
            3,
            'Connect once at home',
            'Open PairDesk while the phone and computer share Wi-Fi. The phone then learns the computer\'s '
                'Tailscale address and shows "Wi-Fi or Tailscale" under its name.',
          ),
          step(
            4,
            'Away from home',
            'Turn Tailscale on, on the phone, and open PairDesk. It picks the fastest route by itself. '
                'The title bar shows whether you\'re connected via Wi-Fi or Tailscale.',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'The computer must be on and awake. To stop it sleeping, turn on "Keep this computer awake" '
                'on its PairDesk page. Android allows one VPN at a time, so Tailscale replaces any other VPN '
                'while it\'s on.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
