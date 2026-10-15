// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../agent_connection.dart';
import '../settings/app_settings.dart';
import '../touchpad.dart';
import 'tabs/apps_tab.dart';
import 'tabs/buttons_tab.dart';
import 'tabs/power_tab.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key, required this.connection, required this.laptopKey, this.settings});

  final AgentConnection connection;

  /// Identifies the computer (favourite apps are kept per computer).
  final String laptopKey;
  final AppSettings? settings;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  bool _showKeyboard = false;
  bool _closing = false;
  int _tab = 0;

  AgentConnection get _conn => widget.connection;

  @override
  void initState() {
    super.initState();
    _conn.addListener(_onConnectionChanged);
  }

  @override
  void dispose() {
    _conn.removeListener(_onConnectionChanged);
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _onConnectionChanged() {
    if (_conn.status == ConnectionStatus.disconnected && !_closing && mounted) {
      _closing = true;
      Navigator.of(context).pop();
    }
  }

  void _sendText() {
    final s = _text.text;
    if (s.isEmpty) return;
    _conn.typeText(s);
    _text.clear();
    _textFocus.requestFocus();
  }

  void _toggleKeyboard() {
    setState(() => _showKeyboard = !_showKeyboard);
    if (_showKeyboard) {
      _textFocus.requestFocus();
    } else {
      _textFocus.unfocus();
    }
  }

  Widget _touchpadTab() {
    final settings = widget.settings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        children: [
          _MediaRow(connection: _conn),
          const SizedBox(height: 8),
          Expanded(
            child: settings == null
                ? Touchpad(connection: _conn)
                : ListenableBuilder(
                    listenable: settings,
                    builder: (_, _) => Touchpad(
                      connection: _conn,
                      speed: settings.pointerSpeed,
                      naturalScroll: settings.naturalScroll,
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: HoldButton(connection: _conn, button: MouseBtn.left, label: 'Left'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: HoldButton(connection: _conn, button: MouseBtn.right, label: 'Right'),
              ),
            ],
          ),
          if (_showKeyboard) ...[
            const SizedBox(height: 10),
            _KeyRow(connection: _conn),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              focusNode: _textFocus,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendText(),
              decoration: InputDecoration(
                hintText: 'Type, then send to the computer',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _sendText),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _closing = true;
          _conn.disconnect();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: ListenableBuilder(
            listenable: _conn,
            builder: (context, _) {
              final ms = _conn.latency?.inMilliseconds;
              final route = _conn.viaTailscale ? 'Tailscale' : 'Wi-Fi';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_conn.agentName ?? 'Computer', overflow: TextOverflow.ellipsis),
                  Text(
                    ms == null ? 'Connected via $route' : 'Connected via $route · $ms ms',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
          actions: [
            if (_tab == 0)
              IconButton(
                tooltip: _showKeyboard ? 'Hide keyboard' : 'Keyboard',
                icon: Icon(_showKeyboard ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined),
                onPressed: _toggleKeyboard,
              ),
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.link_off),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _tab,
            children: [
              _touchpadTab(),
              ButtonsTab(connection: _conn),
              // Built on first visit, so the app list loads only when wanted.
              _tab == 2 || _visitedApps
                  ? AppsTab(connection: _conn, laptopKey: widget.laptopKey)
                  : const SizedBox.shrink(),
              PowerTab(connection: _conn),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            if (i != 0 && _showKeyboard) _toggleKeyboard();
            setState(() {
              _tab = i;
              if (i == 2) _visitedApps = true;
            });
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.touch_app_outlined),
              selectedIcon: Icon(Icons.touch_app),
              label: 'Touchpad',
            ),
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'Buttons',
            ),
            NavigationDestination(
              icon: Icon(Icons.apps_outlined),
              selectedIcon: Icon(Icons.apps),
              label: 'Apps',
            ),
            NavigationDestination(
              icon: Icon(Icons.power_settings_new_outlined),
              selectedIcon: Icon(Icons.power_settings_new),
              label: 'Power',
            ),
          ],
        ),
      ),
    );
  }

  bool _visitedApps = false;
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.connection});

  final AgentConnection connection;

  static const _keys = <(String, AgentKey)>[
    ('Enter', AgentKey.enter),
    ('⌫', AgentKey.backspace),
    ('Esc', AgentKey.escape),
    ('Tab', AgentKey.tab),
    ('←', AgentKey.left),
    ('↑', AgentKey.up),
    ('↓', AgentKey.down),
    ('→', AgentKey.right),
    ('Del', AgentKey.delete),
    ('Home', AgentKey.home),
    ('End', AgentKey.end),
    ('PgUp', AgentKey.pageUp),
    ('PgDn', AgentKey.pageDown),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _keys.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (label, key) = _keys[i];
          return OutlinedButton(
            onPressed: () => connection.key(key),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
            child: Text(label),
          );
        },
      ),
    );
  }
}

class _MediaRow extends StatelessWidget {
  const _MediaRow({required this.connection});

  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String tip, AgentKey key) =>
        IconButton(tooltip: tip, icon: Icon(icon), onPressed: () => connection.key(key));
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        btn(Icons.volume_down, 'Volume down', AgentKey.volumeDown),
        btn(Icons.volume_off, 'Mute', AgentKey.mute),
        btn(Icons.volume_up, 'Volume up', AgentKey.volumeUp),
        btn(Icons.skip_previous, 'Previous', AgentKey.prev),
        btn(Icons.play_arrow, 'Play / pause', AgentKey.playPause),
        btn(Icons.skip_next, 'Next', AgentKey.next),
      ],
    );
  }
}
