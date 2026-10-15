// SPDX-License-Identifier: GPL-3.0-or-later
// Live view of the computer's screen. Tap to click there, press and hold
// to right-click, pinch to zoom. Streams only while this tab is visible.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent_connection.dart';
import '../../screen/compositor.dart';
import '../../screen/frame.dart';

class ScreenTab extends StatefulWidget {
  const ScreenTab({
    super.key,
    required this.connection,
    required this.active,
    this.fullscreen = false,
    this.onFullscreen,
  });

  final AgentConnection connection;

  /// Streams only while true (the tab is visible).
  final bool active;
  final bool fullscreen;
  final ValueChanged<bool>? onFullscreen;

  @override
  State<ScreenTab> createState() => _ScreenTabState();
}

class _ScreenTabState extends State<ScreenTab> with WidgetsBindingObserver {
  final _compositor = ScreenCompositor();
  final _queue = <ScreenFrame>[];
  StreamSubscription<ScreenFrame>? _framesSub;
  StreamSubscription<String>? _stoppedSub;
  Timer? _statsTimer;

  ScreenInfo? _info;
  String? _error;
  bool _starting = false;
  bool _streaming = false;
  bool _draining = false;
  bool _showHint = true;
  String _quality = 'medium';
  int? _monitor;
  int? _cursorX, _cursorY;
  int _frames = 0, _bytes = 0;
  String _stats = '';
  bool _foreground = true;

  AgentConnection get _conn => widget.connection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _framesSub = _conn.screenFrames.listen(_onFrame);
    _stoppedSub = _conn.screenStopped.listen((msg) {
      if (!mounted) return;
      setState(() {
        _streaming = false;
        _error = msg;
      });
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final kb = (_bytes / 1024).round();
      final text = _streaming ? '$_frames fps · $kb KB/s' : '';
      _frames = 0;
      _bytes = 0;
      if (text != _stats) setState(() => _stats = text);
    });
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(ScreenTab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _start();
    if (!widget.active && old.active) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (!fg) {
      _stop();
    } else if (widget.active) {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _framesSub?.cancel();
    _stoppedSub?.cancel();
    _statsTimer?.cancel();
    if (_streaming) _conn.stopScreen();
    if (widget.fullscreen) _setSystemFullscreen(false);
    _compositor.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || !_foreground) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    _queue.clear();
    try {
      final info = await _conn.startScreen(monitor: _monitor, quality: _quality);
      if (!mounted) return;
      setState(() {
        _info = info;
        _monitor = info.monitor;
        _streaming = true;
      });
    } on RequestException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
    // The tab may have been left while starting.
    if (mounted && (!widget.active || !_foreground)) _stop();
  }

  void _stop() {
    if (!_streaming && !_starting) return;
    _conn.stopScreen();
    _queue.clear();
    if (mounted) setState(() => _streaming = false);
  }

  void _onFrame(ScreenFrame f) {
    if (!_streaming) return;
    _queue.add(f);
    _drain();
  }

  /// Frames build on each other, so they're applied in order, one at a time.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        final f = _queue.removeAt(0);
        try {
          await _compositor.apply(f);
        } catch (e) {
          debugPrint('screen frame failed: $e');
          _conn.refreshScreen();
        }
        _frames++;
        _bytes += f.bytes;
        _conn.ackScreen(f.seq);
        if (!mounted) return;
        setState(() {
          _cursorX = f.cursorX;
          _cursorY = f.cursorY;
        });
      }
    } finally {
      _draining = false;
    }
  }

  void _restart({int? monitor, String? quality}) {
    _monitor = monitor ?? _monitor;
    _quality = quality ?? _quality;
    if (_streaming || _error != null) _start();
  }

  Future<void> _setSystemFullscreen(bool on) =>
      SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);

  void _toggleFullscreen() {
    final on = !widget.fullscreen;
    _setSystemFullscreen(on);
    widget.onFullscreen?.call(on);
  }

  void _pointAt(Offset local, Size size, MouseBtn button) {
    if (!_streaming) return;
    HapticFeedback.lightImpact();
    if (_showHint) setState(() => _showHint = false);
    _conn.moveTo((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
    _conn.click(button);
  }

  Widget _toolbar(ThemeData theme) {
    final monitors = _info?.monitors ?? const <MonitorInfo>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SegmentedButton<String>(
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'low', label: Text('Low')),
                    ButtonSegment(value: 'medium', label: Text('Medium')),
                    ButtonSegment(value: 'high', label: Text('High')),
                  ],
                  selected: {_quality},
                  onSelectionChanged: (s) => setState(() => _restart(quality: s.first)),
                ),
              ),
            ),
          ),
          if (monitors.length > 1)
            PopupMenuButton<int>(
              tooltip: 'Choose display',
              icon: const Icon(Icons.monitor_outlined),
              onSelected: (i) => _restart(monitor: i),
              itemBuilder: (_) => [
                for (final m in monitors)
                  CheckedPopupMenuItem(
                    value: m.index,
                    checked: m.index == _monitor,
                    child: Text('${m.name} · ${m.width}×${m.height}'),
                  ),
              ],
            ),
          IconButton(
            tooltip: 'Full screen',
            icon: const Icon(Icons.fullscreen),
            onPressed: _toggleFullscreen,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = _compositor.image;
    final error = _error;

    Widget content;
    if (image == null) {
      content = Center(
        child: error != null
            ? _Message(text: error, onRetry: _start)
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Getting the screen…')],
              ),
      );
    } else {
      content = InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: AspectRatio(
            aspectRatio: image.width / image.height,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = box.biggest;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _pointAt(d.localPosition, size, MouseBtn.left),
                  onLongPressStart: (d) => _pointAt(d.localPosition, size, MouseBtn.right),
                  child: CustomPaint(size: size, painter: _ScreenPainter(image, _cursorX, _cursorY)),
                );
              },
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (!widget.fullscreen) _toolbar(theme),
        Expanded(
          child: Container(
            color: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(child: content),
                if (image != null && error != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: _Message(text: error, onRetry: _start),
                      ),
                    ),
                  ),
                if (image != null && _showHint && _streaming)
                  const Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: _Hint(text: 'Tap to click · press and hold to right-click · pinch to zoom'),
                  ),
                if (_stats.isNotEmpty)
                  Positioned(left: 8, bottom: 8, child: _Hint(text: _stats, small: true)),
                if (widget.fullscreen)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: IconButton.filledTonal(
                      tooltip: 'Exit full screen',
                      icon: const Icon(Icons.fullscreen_exit),
                      onPressed: _toggleFullscreen,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScreenPainter extends CustomPainter {
  _ScreenPainter(this.image, this.cursorX, this.cursorY);
  final ui.Image image;
  final int? cursorX, cursorY;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final cx = cursorX, cy = cursorY;
    if (cx == null || cy == null) return;
    // The computer's pointer, drawn as an arrow.
    final p = Offset(cx * size.width / image.width, cy * size.height / image.height);
    const s = 1.0;
    final arrow = Path()
      ..moveTo(p.dx, p.dy)
      ..lineTo(p.dx, p.dy + 16 * s)
      ..lineTo(p.dx + 4.5 * s, p.dy + 12 * s)
      ..lineTo(p.dx + 7.5 * s, p.dy + 18.5 * s)
      ..lineTo(p.dx + 10 * s, p.dy + 17.5 * s)
      ..lineTo(p.dx + 7 * s, p.dy + 11 * s)
      ..lineTo(p.dx + 12 * s, p.dy + 11 * s)
      ..close();
    canvas.drawPath(arrow, Paint()..color = Colors.white);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_ScreenPainter old) =>
      old.image != image || old.cursorX != cursorX || old.cursorY != cursorY;
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, this.small = false});
  final String text;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: small ? 6 : 10, vertical: small ? 2 : 6),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: small ? 11 : 13),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.desktop_access_disabled_outlined, size: 40),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
