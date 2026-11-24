// SPDX-License-Identifier: GPL-3.0-or-later
// Shortcuts: your one-tap buttons, and the computer's apps beside them.

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../present_screen.dart';
import 'apps_tab.dart';
import 'buttons_tab.dart';

class ShortcutsTab extends StatefulWidget {
  const ShortcutsTab({super.key, required this.connection, required this.laptopKey});
  final AgentConnection connection;
  final String laptopKey;

  @override
  State<ShortcutsTab> createState() => _ShortcutsTabState();
}

class _ShortcutsTabState extends State<ShortcutsTab> {
  int _part = 0;

  /// The app list loads only once Apps is first opened.
  bool _appsOpened = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: PdSegmented<int>(
            options: const [(0, 'Shortcuts'), (1, 'Apps')],
            selected: _part,
            onChanged: (v) => setState(() {
              _part = v;
              if (v == 1) _appsOpened = true;
            }),
          ),
        ),
        if (_part == 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _PresentCard(onTap: () => PresentScreen.open(context, widget.connection)),
          ),
        Expanded(
          child: FadeIndexedStack(
            index: _part,
            children: [
              ButtonsTab(connection: widget.connection),
              _appsOpened
                  ? AppsTab(connection: widget.connection, laptopKey: widget.laptopKey)
                  : const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The way into presenter mode.
class _PresentCard extends StatelessWidget {
  const _PresentCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Semantics(
      button: true,
      label: 'Present',
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: PdCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.slideshow_rounded, color: c.ink),
              const SizedBox(width: 14),
              const Expanded(
                child: Text('Present', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              Text('Slides, timer, laser', style: TextStyle(fontSize: 13, color: c.sub)),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, color: c.sub),
            ],
          ),
        ),
      ),
    );
  }
}
