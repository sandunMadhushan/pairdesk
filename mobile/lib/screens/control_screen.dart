// SPDX-License-Identifier: GPL-3.0-or-later
// Connected to a computer. Top: ✕ disconnect, the computer's name and how
// it's connected, ⏻ power. Bottom: Touchpad · Screen · Shortcuts · Files ·
// Sound. A lime "Type" button opens the keyboard on Touchpad and Screen.

import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_connection.dart';
import '../audio/audio_controller.dart';
import '../audio/native_audio.dart';
import '../files/share_inbox.dart';
import '../files/transfers.dart';
import '../pairing/relay_route.dart';
import '../settings/app_settings.dart';
import '../touchpad.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'exchange_sheet.dart';
import 'tabs/files_tab.dart';
import 'tabs/power_tab.dart';
import 'tabs/screen_tab.dart';
import 'tabs/shortcuts_tab.dart';
import 'tabs/sound_tab.dart';

class ControlScreen extends StatefulWidget {
  const ControlScreen({
    super.key,
    required this.connection,
    required this.laptopKey,
    this.settings,
    this.inbox,
    this.audioBackend,
    this.helping = false,
  });

  /// The phone's sound hardware (tests use a stand-in).
  final AudioBackend? audioBackend;

  final AgentConnection connection;

  /// What other apps shared (default: the app-wide inbox).
  final ShareInbox? inbox;

  /// Identifies the computer (favourite apps are kept per computer).
  final String laptopKey;
  final AppSettings? settings;

  /// Temporary access from a "Get help" link: a banner says so.
  final bool helping;

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  bool _showKeyboard = false;
  bool _closing = false;
  int _tab = 0;
  final Set<int> _visited = {0};
  bool _fullscreen = false;

  AgentConnection get _conn => widget.connection;
  StreamSubscription<String>? _notices;
  StreamSubscription<Transfer>? _received;
  late final Exchange _exchange = Exchange(_conn, _say);
  late final AudioController _audio = AudioController(_conn, backend: widget.audioBackend);
  ShareInbox get _inbox => widget.inbox ?? ShareInbox.instance;

  static const _kTouchpad = 0, _kScreen = 1, _kFiles = 3, _kSound = 4;
  bool get _keyboardTab => _tab == _kTouchpad || _tab == _kScreen;

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
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(12, 0, 12, _fullscreen || _showKeyboard ? 12 : 96),
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
      _conn.resumed();
      _audio.resume();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _audio.pause();
    }
  }

  void _onAudioChanged() {
    if (mounted) setState(() {});
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
    if (!mounted) return;
    if (_conn.status == ConnectionStatus.disconnected && !_closing) {
      _closing = true;
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
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

  void _openPower() => showPdSheet<void>(context, (_) => PowerSheet(connection: _conn));

  void _select(int i) {
    if (_showKeyboard && i != _kTouchpad && i != _kScreen) _toggleKeyboard();
    setState(() {
      _tab = i;
      _visited.add(i);
    });
  }

  String _route() {
    final a = _conn.address;
    if (a != null && RelayRoute.looksLike(a)) return 'Relay';
    if (_conn.viaTailscale) return 'Tailscale';
    return 'Wi-Fi';
  }

  Widget _header() {
    final c = PdColors.of(context);
    final reconnecting = _conn.status == ConnectionStatus.connecting;
    final ms = _conn.latency?.inMilliseconds;
    final status = reconnecting ? 'Reconnecting…' : (ms == null ? _route() : '${_route()} · $ms ms');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          RoundButton(
            icon: Icons.close_rounded,
            tooltip: 'Disconnect',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              children: [
                Text(
                  _conn.agentName ?? 'Computer',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: PdMotion.fade,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(color: c.s1, borderRadius: BorderRadius.circular(999)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PulseDot(color: reconnecting ? c.sub : c.accent),
                      const SizedBox(width: 6),
                      Text(status, style: TextStyle(fontSize: 13, color: c.sub)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          RoundButton(icon: Icons.power_settings_new_rounded, tooltip: 'Power', onPressed: _openPower),
        ],
      ),
    );
  }

  Widget _banners() {
    final c = PdColors.of(context);
    final reconnecting = _conn.status == ConnectionStatus.connecting;
    final transfers = _conn.transfers.items.where((t) => !t.finished).toList();
    return Column(
      children: [
        AnimatedSize(
          duration: PdMotion.move,
          curve: PdMotion.curve,
          child: reconnecting
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(color: c.inv, borderRadius: BorderRadius.circular(22)),
                    child: Row(
                      children: [
                        PdSpinner(
                          size: 22,
                          color: c.dark ? PdColors.onAccent : PdColors.lime,
                          track: c.subInv,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Connection dropped',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.onInv),
                              ),
                              Text(
                                'Getting it back by itself. Stay here.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: c.dark ? const Color(0xFF55565B) : c.subInv,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        if (widget.helping)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(22),
                boxShadow: c.glow,
              ),
              child: Row(
                children: [
                  const Icon(Icons.support_agent_rounded, color: PdColors.onAccent),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'You\'re helping · temporary access, up to 2 hours',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: PdColors.onAccent),
                    ),
                  ),
                  SecondaryButton(
                    label: 'Leave',
                    height: 40,
                    background: PdColors.onAccent,
                    foreground: Colors.white,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ),
        if (transfers.isNotEmpty && _tab != _kFiles)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: () {
                  final size = transfers.fold<int>(0, (a, t) => a + t.size);
                  final done = transfers.fold<int>(0, (a, t) => a + t.done);
                  return size == 0 ? null : done / size;
                }(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _touchpadTab() {
    final settings = widget.settings;
    final typeButton = _showKeyboard ? null : _TypeButton(onPressed: _toggleKeyboard);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        children: [
          Expanded(
            child: settings == null
                ? Touchpad(connection: _conn, corner: typeButton)
                : ListenableBuilder(
                    listenable: settings,
                    builder: (_, _) => Touchpad(
                      connection: _conn,
                      speed: settings.pointerSpeed,
                      naturalScroll: settings.naturalScroll,
                      corner: typeButton,
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: HoldButton(connection: _conn, button: MouseBtn.left, label: 'Left click'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: HoldButton(connection: _conn, button: MouseBtn.right, label: 'Right click'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _keyboardPanel() {
    final c = PdColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: c.s1,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Keyboard', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                SecondaryButton(label: 'Hide', height: 38, onPressed: _toggleKeyboard),
              ],
            ),
            const SizedBox(height: 10),
            KeyRow(connection: _conn),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _textFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendText(),
                    decoration: const InputDecoration(hintText: 'Type, then send to the computer'),
                  ),
                ),
                const SizedBox(width: 8),
                RoundButton(
                  icon: Icons.send_rounded,
                  tooltip: 'Send to computer',
                  onPressed: _sendText,
                  background: c.accent,
                  foreground: PdColors.onAccent,
                  size: 54,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _items = [
    PillNavItem(icon: Icons.touch_app_rounded, label: 'Touchpad'),
    PillNavItem(icon: Icons.desktop_windows_rounded, label: 'Screen'),
    PillNavItem(icon: Icons.grid_view_rounded, label: 'Shortcuts'),
    PillNavItem(icon: Icons.swap_vert_rounded, label: 'Files', tooltip: 'Clipboard and files'),
    PillNavItem(icon: Icons.headphones_rounded, label: 'Sound', tooltip: 'Sound and media'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final talking = _audio.talking;
    final hearing = _audio.sound || _audio.mic;
    final busyFiles = _conn.transfers.items.any((t) => !t.finished);
    final items = [
      for (final (i, it) in _items.indexed)
        PillNavItem(
          icon: it.icon,
          label: it.label,
          tooltip: it.tooltip,
          badge: (i == _kSound && (talking || hearing)) || (i == _kFiles && busyFiles),
        ),
    ];
    final showNav = !_fullscreen && !(_showKeyboard && _keyboardTab);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _closing = true;
          _conn.disconnect();
        }
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : c.bg,
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            // Bottom too: after full screen Android lets the window draw
            // under the navigation bar, and the controls must stay above it.
            SafeArea(
              top: !_fullscreen,
              child: Column(
                children: [
                  if (!_fullscreen) _header(),
                  if (!_fullscreen) _banners(),
                  Expanded(
                    child: FadeIndexedStack(
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
                                onKeyboard: _toggleKeyboard,
                              )
                            : const SizedBox.shrink(),
                        ShortcutsTab(connection: _conn, laptopKey: widget.laptopKey),
                        FilesTab(exchange: _exchange),
                        SoundTab(audio: _audio, connection: _conn),
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: PdMotion.move,
                    curve: PdMotion.curve,
                    alignment: Alignment.topCenter,
                    child: _showKeyboard && _keyboardTab
                        ? _keyboardPanel()
                        : const SizedBox(width: double.infinity),
                  ),
                  if (showNav) const SizedBox(height: 96),
                ],
              ),
            ),
            if (showNav)
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: SafeArea(
                  top: false,
                  child: PillNav(items: items, selected: _tab, onSelected: _select),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TypeButton extends StatelessWidget {
  const _TypeButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Keyboard',
      child: Pressable(
        onTap: onPressed,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: PdColors.lime,
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [BoxShadow(color: Color(0x2E000000), blurRadius: 24, offset: Offset(0, 10))],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.keyboard_rounded, color: PdColors.onAccent),
              SizedBox(width: 8),
              Text(
                'Type',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: PdColors.onAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Enter, Esc, arrows and the other keys a phone keyboard lacks.
class KeyRow extends StatelessWidget {
  const KeyRow({super.key, required this.connection});

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
    final c = PdColors.of(context);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _keys.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (label, key) = _keys[i];
          return Pressable(
            onTap: () => connection.key(key),
            child: Container(
              constraints: const BoxConstraints(minWidth: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.s2, borderRadius: BorderRadius.circular(14)),
              child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          );
        },
      ),
    );
  }
}
