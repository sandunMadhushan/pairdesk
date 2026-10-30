// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_connection.dart';
import '../audio/audio_controller.dart';
import '../audio/native_audio.dart';
import '../audio/sound_sheet.dart';
import '../files/share_inbox.dart';
import '../files/transfers.dart';
import 'exchange_sheet.dart';
import '../settings/app_settings.dart';
import '../touchpad.dart';
import 'tabs/apps_tab.dart';
import 'tabs/buttons_tab.dart';
import 'tabs/power_tab.dart';
import 'tabs/screen_tab.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({
    super.key,
    required this.connection,
    required this.laptopKey,
    this.settings,
    this.inbox,
    this.audioBackend,
  });

  /// The phone's sound hardware (tests use a stand-in).
  final AudioBackend? audioBackend;

  final AgentConnection connection;

  /// What other apps shared (default: the app-wide inbox).
  final ShareInbox? inbox;

  /// Identifies the computer (favourite apps are kept per computer).
  final String laptopKey;
  final AppSettings? settings;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  bool _showKeyboard = false;
  bool _closing = false;
  int _tab = 0;

  AgentConnection get _conn => widget.connection;
  StreamSubscription<String>? _notices;
  StreamSubscription<Transfer>? _received;
  late final Exchange _exchange = Exchange(_conn, _say);
  late final AudioController _audio = AudioController(_conn, backend: widget.audioBackend);
  ShareInbox get _inbox => widget.inbox ?? ShareInbox.instance;

  void _say(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: Duration(seconds: action == null ? 5 : 8),
          showCloseIcon: action == null,
          action: action,
        ),
      );
  }

  @override
  void initState() {
    super.initState();
    _conn.addListener(_onConnectionChanged);
    _notices = _conn.notices.listen((msg) => _say(msg));
    _received = _conn.transfers.received.listen((t) {
      _say(
        'Received ${t.name}',
        action: t.openUri == null ? null : SnackBarAction(label: 'Open', onPressed: () => _exchange.open(t)),
      );
    });
    _inbox.addListener(_takeShared);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeShared());
    WidgetsBinding.instance.addObserver(this);
    _audio.addListener(_onAudioChanged);
  }

  // Sound stops while PairDesk isn't on screen, and picks up again after.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _audio.resume();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _audio.pause();
    }
  }

  void _onAudioChanged() {
    if (mounted) setState(() {});
  }

  void _openSound() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SoundSheet(audio: _audio),
    );
  }

  /// "Share → PairDesk" from another app: files go to the computer, text
  /// to its clipboard.
  void _takeShared() {
    if (!mounted || _conn.status != ConnectionStatus.connected) return;
    final items = _inbox.take();
    if (items == null) return;
    if (items.files.isNotEmpty) {
      _exchange.sendFiles(items.files);
    } else if (items.text != null) {
      _exchange.sendText(items.text!);
    }
  }

  void _openExchange() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ExchangeSheet(exchange: _exchange),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _audio.removeListener(_onAudioChanged);
    _audio.dispose();
    _inbox.removeListener(_takeShared);
    _received?.cancel();
    _notices?.cancel();
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
        ],
      ),
    );
  }

  Widget _keyboardPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
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
      ),
    );
  }

  static const _kTouchpad = 0, _kScreen = 1, _kApps = 3;
  bool get _keyboardTab => _tab == _kTouchpad || _tab == _kScreen;

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
        appBar: _fullscreen
            ? null
            : AppBar(
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
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: ListenableBuilder(
                    listenable: _conn.transfers,
                    builder: (context, _) {
                      final active = _conn.transfers.items.where((t) => !t.finished).toList();
                      if (active.isEmpty) return const SizedBox(height: 2);
                      final size = active.fold<int>(0, (a, t) => a + t.size);
                      final done = active.fold<int>(0, (a, t) => a + t.done);
                      return LinearProgressIndicator(minHeight: 2, value: size == 0 ? null : done / size);
                    },
                  ),
                ),
                actions: [
                  if (_audio.talking)
                    IconButton(
                      tooltip: 'Stop talking',
                      color: Theme.of(context).colorScheme.error,
                      icon: const Icon(Icons.mic),
                      onPressed: _audio.stopTalking,
                    ),
                  IconButton(
                    tooltip: 'Sound',
                    isSelected: _audio.sound || _audio.mic,
                    icon: const Icon(Icons.headphones_outlined),
                    selectedIcon: const Icon(Icons.headphones),
                    onPressed: _openSound,
                  ),
                  IconButton(
                    tooltip: 'Clipboard and files',
                    icon: const Icon(Icons.swap_vert),
                    onPressed: _openExchange,
                  ),
                  if (_keyboardTab)
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
          top: !_fullscreen,
          child: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    _touchpadTab(),
                    // Built on first visit; streams only while visible.
                    _visited.contains(_kScreen)
                        ? ScreenTab(
                            connection: _conn,
                            settings: widget.settings,
                            active: _tab == _kScreen,
                            fullscreen: _fullscreen,
                            onFullscreen: (on) => setState(() => _fullscreen = on),
                          )
                        : const SizedBox.shrink(),
                    ButtonsTab(connection: _conn),
                    // Built on first visit, so the app list loads only when wanted.
                    _visited.contains(_kApps)
                        ? AppsTab(connection: _conn, laptopKey: widget.laptopKey)
                        : const SizedBox.shrink(),
                    PowerTab(connection: _conn),
                  ],
                ),
              ),
              if (_showKeyboard && _keyboardTab) _keyboardPanel(),
            ],
          ),
        ),
        bottomNavigationBar: _fullscreen
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) {
                  if (_showKeyboard && i != _kTouchpad && i != _kScreen) _toggleKeyboard();
                  setState(() {
                    _tab = i;
                    _visited.add(i);
                  });
                },
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.touch_app_outlined),
                    selectedIcon: Icon(Icons.touch_app),
                    label: 'Touchpad',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.desktop_windows_outlined),
                    selectedIcon: Icon(Icons.desktop_windows),
                    label: 'Screen',
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

  final Set<int> _visited = {0};
  bool _fullscreen = false;
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
