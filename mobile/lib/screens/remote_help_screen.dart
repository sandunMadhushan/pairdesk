// SPDX-License-Identifier: GPL-3.0-or-later
// How to use PairDesk when the phone and the computer are on different
// networks: the relay (on by itself), Tailscale, or your own router.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';

class RemoteHelpScreen extends StatelessWidget {
  const RemoteHelpScreen({super.key});

  static final _playStore = Uri.parse('https://play.google.com/store/apps/details?id=com.tailscale.ipn');
  static final _fdroid = Uri.parse('https://f-droid.org/packages/com.tailscale.ipn/');
  static final _appStore = Uri.parse('https://apps.apple.com/app/tailscale/id1470499037');
  static final _download = Uri.parse('https://tailscale.com/download');

  Future<void> _open(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t open $uri')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    Widget option(int n, String title, String body, {String? badge, List<Widget> actions = const []}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: PdCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: badge != null ? c.accent : c.s2,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$n',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: badge != null ? PdColors.onAccent : c.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                    if (badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: c.inv, borderRadius: BorderRadius.circular(999)),
                        child: Text(
                          badge,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.onInv),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(body, style: TextStyle(fontSize: 15, color: c.sub, height: 1.45)),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ],
            ),
          ),
        );

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: RoundButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            const SizedBox(height: 14),
            const PdTitle(
              'Connect from anywhere',
              subtitle:
                  'When the phone and the computer are on different networks, PairDesk reaches it '
                  'one of these ways. Your connection stays encrypted end to end.',
              size: 30,
            ),
            const SizedBox(height: 18),
            option(
              1,
              'PairDesk relay',
              'Works by itself. Both meet at the relay, which only passes encrypted data along. '
                  'Nothing to set up: on the computer, Remote access → PairDesk relay should say "Online".',
              badge: 'On',
            ),
            option(
              2,
              'Tailscale',
              'A free private network between your own devices. Install it on the computer and on this '
                  'phone and sign in with the same account. PairDesk finds the address by itself.',
              actions: [
                if (Platform.isIOS)
                  SecondaryButton(label: 'App Store', height: 44, onPressed: () => _open(context, _appStore))
                else ...[
                  SecondaryButton(
                    label: 'Google Play',
                    height: 44,
                    onPressed: () => _open(context, _playStore),
                  ),
                  SecondaryButton(label: 'F-Droid', height: 44, onPressed: () => _open(context, _fdroid)),
                ],
                SecondaryButton(
                  label: 'For the computer',
                  height: 44,
                  onPressed: () => _open(context, _download),
                ),
              ],
            ),
            option(
              3,
              'Your router',
              'Forward port 47800 on your home router to the computer, then on this phone use ⋯ → '
                  'Add an address with your home address or a name that points to it.',
            ),
            PdCard(
              color: c.s2,
              padding: const EdgeInsets.all(16),
              child: Text(
                'The computer must be on and awake. To stop it sleeping, turn on "Keep this computer awake" '
                'on its PairDesk page.',
                style: TextStyle(fontSize: 14, color: c.sub, height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
