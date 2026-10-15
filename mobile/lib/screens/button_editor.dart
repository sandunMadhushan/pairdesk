// SPDX-License-Identifier: GPL-3.0-or-later
// Create or change a custom button.

import 'package:flutter/material.dart';

import '../agent_connection.dart';
import '../buttons/custom_button.dart';
import 'tabs/apps_tab.dart';

enum _Kind { keys, text, app, power }

/// Keys offered for shortcuts: letters, digits, then named keys.
final List<(String, String)> shortcutKeys = [
  for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++)
    ('c:${String.fromCharCode(c)}', String.fromCharCode(c).toUpperCase()),
  for (var d = 0; d <= 9; d++) ('c:$d', '$d'),
  for (final k in AgentKey.values) ('k:${k.wire}', keyLabel(k)),
];

class ButtonEditor extends StatefulWidget {
  const ButtonEditor({super.key, required this.connection, this.initial});

  final AgentConnection connection;
  final CustomButton? initial;

  @override
  State<ButtonEditor> createState() => _ButtonEditorState();
}

class _ButtonEditorState extends State<ButtonEditor> {
  final _label = TextEditingController();
  final _text = TextEditingController();
  _Kind _kind = _Kind.keys;
  final Set<Modifier> _mods = {};
  String? _key; // 'c:x' or 'k:name'
  RemoteApp? _app;
  PowerAction _power = PowerAction.lock;

  String? get _os => widget.connection.agentOs;

  @override
  void initState() {
    super.initState();
    final b = widget.initial;
    if (b == null) return;
    _label.text = b.label;
    switch (b.action) {
      case ComboAction(:final mods, :final key, :final char):
        _kind = _Kind.keys;
        _mods.addAll(mods);
        _key = key != null ? 'k:${key.wire}' : (char != null ? 'c:${char.toLowerCase()}' : null);
      case TextAction(:final text):
        _kind = _Kind.text;
        _text.text = text;
      case AppAction(:final appId, :final appName):
        _kind = _Kind.app;
        _app = RemoteApp(id: appId, name: appName, kind: 'app');
      case PowerButtonAction(:final action):
        _kind = _Kind.power;
        _power = action;
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _text.dispose();
    super.dispose();
  }

  ButtonAction? _action() {
    switch (_kind) {
      case _Kind.keys:
        if (_mods.isEmpty && _key == null) return null;
        final mods = Modifier.values.where(_mods.contains).toList();
        final key = _key;
        if (key == null) return ComboAction(mods);
        if (key.startsWith('c:')) return ComboAction(mods, char: key.substring(2));
        return ComboAction(mods, key: AgentKey.values.firstWhere((k) => 'k:${k.wire}' == key));
      case _Kind.text:
        return _text.text.isEmpty ? null : TextAction(_text.text);
      case _Kind.app:
        final app = _app;
        return app == null ? null : AppAction(app.id, app.name);
      case _Kind.power:
        return PowerButtonAction(_power);
    }
  }

  String _autoLabel(ButtonAction a) => switch (a) {
    ComboAction() => a.describe(os: _os),
    TextAction(:final text) => text.length > 16 ? '${text.substring(0, 16)}…' : text,
    AppAction(:final appName) => appName,
    PowerButtonAction(:final action) => powerLabel(action),
  };

  void _save() {
    final action = _action();
    if (action == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (_kind) {
            _Kind.keys => 'Choose a key or at least one modifier.',
            _Kind.text => 'Type the text to send.',
            _Kind.app => 'Choose an app.',
            _Kind.power => '',
          }),
        ),
      );
      return;
    }
    final label = _label.text.trim().isEmpty ? _autoLabel(action) : _label.text.trim();
    Navigator.of(context)
        .pop(CustomButton(id: widget.initial?.id ?? CustomButton.newId(), label: label, action: action));
  }

  Future<void> _pickApp() async {
    final app = await Navigator.of(context)
        .push<RemoteApp>(MaterialPageRoute(builder: (_) => AppPickerScreen(connection: widget.connection)));
    if (app != null) setState(() => _app = app);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = _action();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'New button' : 'Edit button'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _label,
            maxLength: 24,
            decoration: InputDecoration(
              labelText: 'Label',
              hintText: action == null ? 'e.g. Copy' : _autoLabel(action),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<_Kind>(
            segments: const [
              ButtonSegment(value: _Kind.keys, label: Text('Keys')),
              ButtonSegment(value: _Kind.text, label: Text('Text')),
              ButtonSegment(value: _Kind.app, label: Text('App')),
              ButtonSegment(value: _Kind.power, label: Text('Power')),
            ],
            selected: {_kind},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 20),
          ...switch (_kind) {
            _Kind.keys => [
              Text('Hold', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in Modifier.values)
                    FilterChip(
                      label: Text(modifierLabel(m, os: _os)),
                      selected: _mods.contains(m),
                      onSelected: (on) => setState(() => on ? _mods.add(m) : _mods.remove(m)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownMenu<String?>(
                key: ValueKey(_key),
                initialSelection: _key,
                label: const Text('Then press'),
                expandedInsets: EdgeInsets.zero,
                menuHeight: 320,
                enableFilter: true,
                requestFocusOnTap: true,
                onSelected: (v) => setState(() => _key = v),
                dropdownMenuEntries: [
                  const DropdownMenuEntry(value: null, label: 'Nothing (modifiers only)'),
                  for (final (value, label) in shortcutKeys) DropdownMenuEntry(value: value, label: label),
                ],
              ),
              if (action is ComboAction) ...[
                const SizedBox(height: 16),
                Text('Sends ${action.describe(os: _os)}', style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 8),
              Text(
                'Some system shortcuts, like Ctrl + Alt + Delete or ${modifierLabel(Modifier.meta, os: _os)} + L, '
                'can\'t be sent by any app. Use the Power tab to lock.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            _Kind.text => [
              TextField(
                controller: _text,
                minLines: 2,
                maxLines: 6,
                maxLength: 2000,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Text to type',
                  hintText: 'e.g. your email address',
                  border: OutlineInputBorder(),
                ),
              ),
              Text(
                'Saved on this phone in plain form. Don\'t store passwords here.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            _Kind.app => [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.apps),
                title: Text(_app?.name ?? 'No app chosen'),
                trailing: FilledButton.tonal(
                  onPressed: _pickApp,
                  child: Text(_app == null ? 'Choose' : 'Change'),
                ),
              ),
            ],
            _Kind.power => [
              for (final a in PowerAction.values)
                RadioListTile<PowerAction>(
                  contentPadding: EdgeInsets.zero,
                  value: a,
                  // ignore: deprecated_member_use
                  groupValue: _power,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setState(() => _power = v!),
                  title: Text(powerLabel(a)),
                  subtitle: a.endsSession ? const Text('Asks before it runs') : null,
                ),
            ],
          },
        ],
      ),
    );
  }
}
