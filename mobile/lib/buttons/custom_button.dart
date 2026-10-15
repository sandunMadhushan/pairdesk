// SPDX-License-Identifier: GPL-3.0-or-later
// Custom buttons: one tap sends a shortcut, types text, opens an app or
// runs a power action on the computer.

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../agent_connection.dart';

sealed class ButtonAction {
  const ButtonAction();

  Map<String, Object?> toJson();

  static ButtonAction? fromJson(Object? j) {
    if (j is! Map) return null;
    switch (j['type']) {
      case 'combo':
        final mods = [
          for (final m in (j['mods'] as List? ?? const [])) ...Modifier.values.where((v) => v.name == m),
        ];
        final key = AgentKey.values.where((k) => k.wire == j['k']).firstOrNull;
        final char = j['c'] is String && (j['c'] as String).length == 1 ? j['c'] as String : null;
        if (key == null && char == null && mods.isEmpty) return null;
        return ComboAction(mods, key: key, char: char);
      case 'text':
        final s = j['s'];
        return s is String && s.isNotEmpty ? TextAction(s) : null;
      case 'app':
        final id = j['id'], name = j['name'];
        return id is String && name is String ? AppAction(id, name) : null;
      case 'power':
        final a = PowerAction.values.where((p) => p.wire == j['a']).firstOrNull;
        return a == null ? null : PowerButtonAction(a);
    }
    return null;
  }
}

class ComboAction extends ButtonAction {
  const ComboAction(this.mods, {this.key, this.char});
  final List<Modifier> mods;
  final AgentKey? key;

  /// One character, sent lower-case.
  final String? char;

  @override
  Map<String, Object?> toJson() => {
    'type': 'combo',
    'mods': [for (final m in mods) m.name],
    'k': ?key?.wire,
    'c': ?char,
  };

  /// "Ctrl + Shift + T", with the Windows/Super key named for the computer.
  String describe({String? os}) {
    final parts = [for (final m in mods) modifierLabel(m, os: os)];
    if (key != null) parts.add(keyLabel(key!));
    if (char != null) parts.add(char!.toUpperCase());
    return parts.join(' + ');
  }
}

class TextAction extends ButtonAction {
  const TextAction(this.text);
  final String text;
  @override
  Map<String, Object?> toJson() => {'type': 'text', 's': text};
}

class AppAction extends ButtonAction {
  const AppAction(this.appId, this.appName);
  final String appId;
  final String appName;
  @override
  Map<String, Object?> toJson() => {'type': 'app', 'id': appId, 'name': appName};
}

class PowerButtonAction extends ButtonAction {
  const PowerButtonAction(this.action);
  final PowerAction action;
  @override
  Map<String, Object?> toJson() => {'type': 'power', 'a': action.wire};
}

class CustomButton {
  CustomButton({required this.id, required this.label, required this.action});
  final String id;
  final String label;
  final ButtonAction action;

  Map<String, Object?> toJson() => {'id': id, 'label': label, 'action': action.toJson()};

  static CustomButton? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['label'] is! String) return null;
    final action = ButtonAction.fromJson(j['action']);
    if (action == null) return null;
    return CustomButton(id: j['id'] as String, label: j['label'] as String, action: action);
  }

  static String newId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}

String modifierLabel(Modifier m, {String? os}) => switch (m) {
  Modifier.ctrl => 'Ctrl',
  Modifier.alt => 'Alt',
  Modifier.shift => 'Shift',
  Modifier.meta => os == 'windows' ? 'Win' : 'Super',
};

String keyLabel(AgentKey k) => switch (k) {
  AgentKey.enter => 'Enter',
  AgentKey.backspace => 'Backspace',
  AgentKey.escape => 'Esc',
  AgentKey.tab => 'Tab',
  AgentKey.space => 'Space',
  AgentKey.delete => 'Delete',
  AgentKey.up => '↑',
  AgentKey.down => '↓',
  AgentKey.left => '←',
  AgentKey.right => '→',
  AgentKey.home => 'Home',
  AgentKey.end => 'End',
  AgentKey.pageUp => 'Page Up',
  AgentKey.pageDown => 'Page Down',
  AgentKey.volumeUp => 'Volume up',
  AgentKey.volumeDown => 'Volume down',
  AgentKey.mute => 'Mute',
  AgentKey.playPause => 'Play/Pause',
  AgentKey.next => 'Next track',
  AgentKey.prev => 'Previous track',
  AgentKey.insert => 'Insert',
  AgentKey.printScreen => 'Print Screen',
  _ => k.wire.toUpperCase(), // F1…F12
};

String powerLabel(PowerAction a) => switch (a) {
  PowerAction.lock => 'Lock',
  PowerAction.sleep => 'Sleep',
  PowerAction.screenOff => 'Screen off',
  PowerAction.signOut => 'Sign out',
  PowerAction.restart => 'Restart',
  PowerAction.shutDown => 'Shut down',
};

/// Buttons a new install starts with. Shortcuts that differ between
/// systems use the Windows form; Linux desktops mostly share them.
List<CustomButton> defaultButtons({String? os}) {
  CustomButton b(String id, String label, ButtonAction a) => CustomButton(id: id, label: label, action: a);
  const ctrl = [Modifier.ctrl];
  return [
    b('d-copy', 'Copy', const ComboAction(ctrl, char: 'c')),
    b('d-paste', 'Paste', const ComboAction(ctrl, char: 'v')),
    b('d-cut', 'Cut', const ComboAction(ctrl, char: 'x')),
    b('d-undo', 'Undo', const ComboAction(ctrl, char: 'z')),
    b('d-all', 'Select all', const ComboAction(ctrl, char: 'a')),
    b('d-find', 'Find', const ComboAction(ctrl, char: 'f')),
    b('d-switch', 'Switch app', const ComboAction([Modifier.alt], key: AgentKey.tab)),
    b('d-close', 'Close window', const ComboAction([Modifier.alt], key: AgentKey.f4)),
    b('d-desktop', 'Show desktop', const ComboAction([Modifier.meta], char: 'd')),
    b('d-newtab', 'New tab', const ComboAction(ctrl, char: 't')),
    b('d-closetab', 'Close tab', const ComboAction(ctrl, char: 'w')),
    b('d-full', 'Full screen', const ComboAction([], key: AgentKey.f11)),
    if (os != 'linux') ...[
      b(
        'd-taskmgr',
        'Task Manager',
        const ComboAction([Modifier.ctrl, Modifier.shift], key: AgentKey.escape),
      ),
      b('d-snip', 'Screenshot', const ComboAction([Modifier.meta, Modifier.shift], char: 's')),
      b('d-explorer', 'File Explorer', const ComboAction([Modifier.meta], char: 'e')),
    ] else
      b('d-snip', 'Screenshot', const ComboAction([], key: AgentKey.printScreen)),
  ];
}

class ButtonStore {
  static const _key = 'pairdesk.buttons.v1';

  /// Saved buttons, or null if the user never changed the defaults.
  Future<List<CustomButton>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return [for (final j in jsonDecode(raw) as List) ?CustomButton.fromJson(j)];
    } catch (_) {
      return null;
    }
  }

  Future<void> save(List<CustomButton> buttons) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final b in buttons) b.toJson()]));
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// Favourite apps, per computer.
class FavouriteStore {
  static String _key(String laptopKey) => 'pairdesk.favs.v1.$laptopKey';

  Future<List<String>> load(String laptopKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key(laptopKey)) ?? const [];
  }

  Future<void> save(String laptopKey, List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key(laptopKey), ids);
  }
}

/// Sends a button's action. Throws [RequestException] for refused
/// power or app actions.
Future<void> runButton(AgentConnection conn, ButtonAction action) async {
  switch (action) {
    case ComboAction(:final mods, :final key, :final char):
      conn.combo(mods, key: key, char: char);
    case TextAction(:final text):
      conn.typeText(text);
    case AppAction(:final appId):
      await conn.launch(appId);
    case PowerButtonAction(action: final a):
      await conn.power(a);
  }
}
