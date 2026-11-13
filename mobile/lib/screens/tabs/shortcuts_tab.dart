// SPDX-License-Identifier: GPL-3.0-or-later
// Shortcuts: your one-tap buttons, and the computer's apps beside them.

import 'package:flutter/material.dart';

import '../../agent_connection.dart';
import '../../ui/widgets.dart';
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
