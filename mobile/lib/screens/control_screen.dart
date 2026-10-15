// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../agent_connection.dart';
import '../touchpad.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key, required this.connection});

  final AgentConnection connection;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  bool _showKeyboard = false;
  bool _closing = false;

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
          title: Text(_conn.agentName ?? 'Laptop', overflow: TextOverflow.ellipsis),
          actions: [
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              children: [
                _MediaRow(connection: _conn),
                const SizedBox(height: 8),
                Expanded(child: Touchpad(connection: _conn)),
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
                      hintText: 'Type, then send to the laptop',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _sendText),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
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
