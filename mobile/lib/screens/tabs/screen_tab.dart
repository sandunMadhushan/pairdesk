// SPDX-License-Identifier: GPL-3.0-or-later
// Live view of the computer's screen. Two ways to move the pointer:
//  - touchpad (default): drag one finger to move it, tap to click, tap and
//    drag to drag, two fingers to scroll or right-click, pinch to zoom; the
//    zoomed view follows the pointer;
//  - tap: the pointer goes where you tap; press and hold to right-click.
// Streams only while this tab is visible.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent_connection.dart';
import '../../screen/compositor.dart';
import '../../screen/frame.dart';
import '../../screen/video.dart';
import '../../screen/viewport.dart';
import '../../settings/app_settings.dart';
import '../../touchpad_gestures.dart';

class ScreenTab extends StatefulWidget {
  const ScreenTab({
    super.key,
    required this.connection,
    required this.active,
    this.settings,
    this.fullscreen = false,
    this.onFullscreen,
    this.videoDecoder,
    this.videoAvailable,
  });

  final AgentConnection connection;

  /// Streams only while true (the tab is visible).
  final bool active;

  /// Pointer speed, scroll direction and the chosen pointer mode.
  final AppSettings? settings;
  final bool fullscreen;
  final ValueChanged<bool>? onFullscreen;

  /// Tests replace the phone's video decoder and its availability check.
  final VideoDecoder Function()? videoDecoder;
  final Future<bool> Function()? videoAvailable;

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
  late bool _touchpad = widget.settings?.screenTouchpad ?? true;
  final _viewport = ScreenViewport();
  Size? _viewSize;

  // Video mode (H.264 on a texture).
  VideoDecoder? _video;
  int? _texture;
  bool _videoShown = false;

  /// Video failed during this view: JPEG until the tab is rebuilt.
  bool _noVideo = false;
  late final TouchpadGestures _gestures = TouchpadGestures(
    onMove: (dx, dy) {
      _hideHint();
      _conn.move(dx, dy);
    },
    onClick: (b) {
      _hideHint();
      HapticFeedback.lightImpact();
      _conn.click(b);
    },
    onScroll: (dx, dy) => (widget.settings?.naturalScroll ?? true)
        ? _conn.scroll(dx: dx, dy: dy)
        : _conn.scroll(dx: -dx, dy: -dy),
    onButton: (b, down) {
      _hideHint();
      if (down) {
        HapticFeedback.selectionClick();
        _conn.buttonDown(b);
      } else {
        _conn.buttonUp(b);
      }
    },
    onPinch: (scale, focal) {
      final view = _viewSize, picture = _picture;
      if (view == null || picture == null) return;
      setState(() => _viewport.zoomBy(scale, focal, view, picture));
    },
  );

  AgentConnection get _conn => widget.connection;

  bool get _videoMode => _texture != null;

  /// Size of the computer's picture, once there is one to show.
  Size? get _picture {
    if (_videoMode) {
      final info = _info;
      return _videoShown && info != null ? Size(info.width.toDouble(), info.height.toDouble()) : null;
    }
    final image = _compositor.image;
    return image == null ? null : Size(image.width.toDouble(), image.height.toDouble());
  }

  void _hideHint() {
    if (_showHint) setState(() => _showHint = false);
  }

  void _setTouchpad(bool on) {
    _gestures.reset();
    setState(() {
      _touchpad = on;
      _showHint = true;
      _viewport.reset();
    });
    widget.settings?.setScreenTouchpad(on);
  }

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
    _gestures.reset();
    if (_streaming) _conn.stopScreen();
    if (widget.fullscreen) _setSystemFullscreen(false);
    _compositor.dispose();
    _video?.stop();
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
      final wantVideo = !_noVideo && await (widget.videoAvailable ?? VideoSupport.available)();
      final info = await _conn.startScreen(
        monitor: _monitor,
        quality: _quality,
        codecs: wantVideo ? const ['h264'] : const [],
      );
      await _stopVideo();
      if (info.codec == 'h264') {
        final decoder = (widget.videoDecoder ?? PlatformVideoDecoder.new)();
        await VideoSupport.playing(true);
        decoder.onError = _videoFailed;
        decoder.onLost = _videoLost;
        final texture = await decoder.start(info.width, info.height);
        if (texture == null) {
          await decoder.stop();
          throw const _VideoUnavailable();
        }
        _video = decoder;
        _texture = texture;
      }
      if (!mounted) return;
      setState(() {
        _info = info;
        _monitor = info.monitor;
        _streaming = true;
      });
    } on _VideoUnavailable {
      _starting = false;
      await _videoFailed('this phone can\'t decode the video');
      return;
    } on RequestException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
    // The tab may have been left while starting.
    if (mounted && (!widget.active || !_foreground)) {
      _stop();
    } else {
      _drain();
    }
  }

  Future<void> _stopVideo() async {
    final v = _video;
    _video = null;
    _texture = null;
    _videoShown = false;
    await v?.stop();
    if (v != null) await VideoSupport.playing(false);
  }

  /// The picture surface went away (the app was hidden): start again when
  /// the tab is visible.
  Future<void> _videoLost() async {
    await _stopVideo();
    _queue.clear();
    if (mounted && widget.active && _foreground) _start();
  }

  /// The phone couldn't show the video: switch to JPEG pictures, now and
  /// from now on.
  Future<void> _videoFailed(String message) async {
    debugPrint('screen video failed: $message; using JPEG');
    if (_noVideo) return;
    _noVideo = true;
    await VideoSupport.markBroken();
    await _stopVideo();
    if (mounted && widget.active && _foreground) {
      _starting = false;
      _start();
    }
  }

  void _stop() {
    _gestures.reset();
    if (_video != null) VideoSupport.playing(false);
    if (!_streaming && !_starting) return;
    _conn.stopScreen();
    _queue.clear();
    if (mounted) setState(() => _streaming = false);
  }

  void _onFrame(ScreenFrame f) {
    // Frames may come in while the decoder is still starting: keep them.
    if (!_streaming && !_starting) return;
    _queue.add(f);
    if (_streaming) _drain();
  }

  /// Frames build on each other, so they're applied in order, one at a time.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        final f = _queue.removeAt(0);
        final video = _video;
        if (f.isVideo != (video != null)) {
          // Left over from the previous stream.
          _conn.ackScreen(f.seq);
          continue;
        }
        try {
          if (video != null) {
            final data = f.video!;
            if (data.isNotEmpty) {
              await video.decode(data, keyframe: f.keyframe);
              _videoShown = true;
            }
          } else {
            await _compositor.apply(f);
          }
        } catch (e) {
          debugPrint('screen frame failed: $e');
          if (video != null) {
            _videoFailed('$e');
            return;
          }
          _conn.refreshScreen();
        }
        _frames++;
        _bytes += f.bytes;
        _conn.ackScreen(f.seq);
        if (!mounted) return;
        setState(() {
          _cursorX = f.cursorX;
          _cursorY = f.cursorY;
          final view = _viewSize, picture = _picture, cx = f.cursorX, cy = f.cursorY;
          if (_touchpad && view != null && picture != null && cx != null && cy != null) {
            _viewport.follow(Offset(cx.toDouble(), cy.toDouble()), view, picture);
          }
        });
      }
    } finally {
      _draining = false;
    }
  }

  void _restart({int? monitor, String? quality}) {
    if (monitor != null && monitor != _monitor) _viewport.reset();
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
    _hideHint();
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
          IconButton(
            tooltip: _touchpad
                ? 'Pointer: touchpad (tap to switch to tap-to-point)'
                : 'Pointer: tap to point (tap to switch to touchpad)',
            icon: Icon(_touchpad ? Icons.mouse_outlined : Icons.touch_app_outlined),
            onPressed: () => _setTouchpad(!_touchpad),
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
    final picture = _picture;
    final image = _videoMode ? null : _compositor.image;
    final texture = _texture;
    final error = _error;

    Widget content;
    if (picture == null) {
      content = Center(
        child: error != null
            ? _Message(text: error, onRetry: _start)
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Getting the screen…')],
              ),
      );
    } else if (_touchpad) {
      _gestures.sensitivity = 1.6 * (widget.settings?.pointerSpeed ?? 1.0);
      content = LayoutBuilder(
        builder: (context, box) {
          final view = box.biggest;
          _viewSize = view;
          final t = _viewport.transform(view, picture);
          final painter = _ScreenPainter(image, picture, _cursorX, _cursorY, transform: t);
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _gestures.pointerDown(e.pointer, e.localPosition, e.timeStamp),
            onPointerMove: (e) => _gestures.pointerMove(e.pointer, e.localPosition, e.timeStamp),
            onPointerUp: (e) => _gestures.pointerUp(e.pointer, e.localPosition, e.timeStamp),
            onPointerCancel: (e) => _gestures.pointerCancel(e.pointer),
            child: texture == null
                ? CustomPaint(key: const ValueKey('touchpad-view'), size: view, painter: painter)
                : Stack(
                    key: const ValueKey('touchpad-view'),
                    children: [
                      Positioned.fromRect(
                        rect: t.pictureRect(picture),
                        child: Texture(textureId: texture, filterQuality: FilterQuality.medium),
                      ),
                      CustomPaint(size: view, painter: painter),
                    ],
                  ),
          );
        },
      );
    } else {
      content = InteractiveViewer(
        maxScale: 6,
        child: Center(
          child: AspectRatio(
            aspectRatio: picture.width / picture.height,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = box.biggest;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _pointAt(d.localPosition, size, MouseBtn.left),
                  onLongPressStart: (d) => _pointAt(d.localPosition, size, MouseBtn.right),
                  child: Stack(
                    children: [
                      if (texture != null)
                        Positioned.fill(
                          child: Texture(textureId: texture, filterQuality: FilterQuality.medium),
                        ),
                      CustomPaint(size: size, painter: _ScreenPainter(image, picture, _cursorX, _cursorY)),
                    ],
                  ),
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
                if (picture != null && error != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: _Message(text: error, onRetry: _start),
                      ),
                    ),
                  ),
                if (picture != null && _showHint && _streaming)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: _Hint(
                      text: _touchpad
                          ? 'Move with one finger · tap to click · tap, then drag to drag\n'
                                'Two fingers: scroll · two-finger tap: right-click · pinch to zoom'
                          : 'Tap to click there · press and hold to right-click · pinch to zoom',
                    ),
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
  _ScreenPainter(this.image, this.picture, this.cursorX, this.cursorY, {this.transform});

  /// The JPEG picture; null in video mode, where a texture shows the
  /// picture underneath and only the pointer is painted.
  final ui.Image? image;
  final Size picture;
  final int? cursorX, cursorY;

  /// Touchpad view: where the picture goes. Otherwise it fills [size].
  final ViewTransform? transform;

  @override
  void paint(Canvas canvas, Size size) {
    final t = transform ?? ViewTransform(size.width / picture.width, Offset.zero);
    final image = this.image;
    if (image != null) {
      canvas.drawImageRect(
        image,
        Offset.zero & picture,
        transform == null ? Offset.zero & size : t.pictureRect(picture),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    final cx = cursorX, cy = cursorY;
    if (cx == null || cy == null) return;
    // The computer's pointer, drawn as an arrow; a bit larger in the
    // touchpad view, where it's what you steer by.
    final p = transform == null
        ? Offset(cx * size.width / picture.width, cy * size.height / picture.height)
        : t.toView(Offset(cx.toDouble(), cy.toDouble()));
    final s = transform == null ? 1.0 : 1.3;
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
      old.image != image ||
      old.picture != picture ||
      old.cursorX != cursorX ||
      old.cursorY != cursorY ||
      old.transform?.scale != transform?.scale ||
      old.transform?.offset != transform?.offset;
}

class _VideoUnavailable implements Exception {
  const _VideoUnavailable();
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
