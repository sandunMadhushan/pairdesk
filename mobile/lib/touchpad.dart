// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_connection.dart';
import 'touchpad_gestures.dart';
import 'ui/theme.dart';

/// Full-area touchpad that drives the laptop cursor.
class Touchpad extends StatefulWidget {
  const Touchpad({
    super.key,
    required this.connection,
    this.speed = 1.0,
    this.naturalScroll = true,
    this.corner,
  });

  final AgentConnection connection;

  /// Multiplies cursor speed (1.0 = default).
  final double speed;

  /// True: content follows the fingers.
  final bool naturalScroll;

  /// Shown in the top-right corner (the "Type" button).
  final Widget? corner;

  @override
  State<Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<Touchpad> with SingleTickerProviderStateMixin {
  late final TouchpadGestures _gestures = TouchpadGestures(
    onMove: widget.connection.move,
    onScroll: (dx, dy) => widget.naturalScroll
        ? widget.connection.scroll(dx: dx, dy: dy)
        : widget.connection.scroll(dx: -dx, dy: -dy),
    onClick: (b) {
      HapticFeedback.lightImpact();
      widget.connection.click(b);
    },
  );

  /// Where fingers are now, to draw them.
  final _touches = <int, Offset>{};

  /// The ring that spreads out where you last lifted a finger.
  late final AnimationController _ripple = AnimationController(vsync: this, duration: PdMotion.move);
  Offset? _rippleAt;

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
    _gestures.pointerDown(e.pointer, e.localPosition, e.timeStamp);
    setState(() => _touches[e.pointer] = e.localPosition);
  }

  void _move(PointerMoveEvent e) {
    _gestures.pointerMove(e.pointer, e.localPosition, e.timeStamp);
    setState(() => _touches[e.pointer] = e.localPosition);
  }

  void _up(PointerUpEvent e) {
    _gestures.pointerUp(e.pointer, e.localPosition, e.timeStamp);
    setState(() {
      _touches.remove(e.pointer);
      _rippleAt = e.localPosition;
    });
    if (!PdMotion.reduced(context)) _ripple.forward(from: 0);
  }

  void _cancel(PointerCancelEvent e) {
    _gestures.pointerCancel(e.pointer);
    setState(() => _touches.remove(e.pointer));
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    _gestures.sensitivity = 1.6 * widget.speed;
    final scrolling = _touches.length >= 2;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: ColoredBox(
          color: c.s1,
          child: AnimatedBuilder(
            animation: _ripple,
            builder: (context, _) => CustomPaint(
              painter: _PadPainter(
                colors: c,
                touches: _touches.values.toList(),
                ripple: _ripple.isAnimating ? _ripple.value : null,
                rippleAt: _rippleAt,
                scrolling: scrolling,
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 16,
                    top: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: c.s2, borderRadius: BorderRadius.circular(999)),
                      child: const Text(
                        'Touchpad',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  if (widget.corner != null) Positioned(right: 12, top: 12, child: widget.corner!),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 18,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: PdMotion.fade,
                        opacity: _touches.isEmpty ? 1 : 0,
                        child: Text(
                          'Tap to click · two fingers scroll · two-finger tap: right-click',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: c.sub),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter({
    required this.colors,
    required this.touches,
    required this.ripple,
    required this.rippleAt,
    required this.scrolling,
  });

  final PdColors colors;
  final List<Offset> touches;
  final double? ripple;
  final Offset? rippleAt;
  final bool scrolling;

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = colors.dots;
    for (var y = 11.0; y < size.height; y += 22) {
      for (var x = 11.0; x < size.width; x += 22) {
        canvas.drawCircle(Offset(x, y), 1.4, dot);
      }
    }
    // The scroll strip on the right lights up while two fingers scroll.
    final strip = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - 16, 76, 6, (size.height - 132).clamp(0, double.infinity)),
      const Radius.circular(6),
    );
    canvas.drawRRect(strip, Paint()..color = scrolling ? colors.accent : colors.s2);
    final r = ripple, at = rippleAt;
    if (r != null && at != null) {
      canvas.drawCircle(
        at,
        24 + 40 * r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = colors.accent.withValues(alpha: (1 - r) * 0.9),
      );
    }
    for (final t in touches) {
      canvas.drawCircle(t, 26, Paint()..color = colors.accent.withValues(alpha: 0.85));
      canvas.drawCircle(
        t,
        34,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = colors.accent.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

/// A mouse button that stays pressed while your finger is on it, so you can
/// drag with another finger on the touchpad.
class HoldButton extends StatefulWidget {
  const HoldButton({super.key, required this.connection, required this.button, required this.label});

  final AgentConnection connection;
  final MouseBtn button;
  final String label;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  bool _down = false;

  void _press() {
    if (_down) return;
    HapticFeedback.selectionClick();
    setState(() => _down = true);
    widget.connection.buttonDown(widget.button);
  }

  void _release() {
    if (!_down) return;
    setState(() => _down = false);
    widget.connection.buttonUp(widget.button);
  }

  @override
  void dispose() {
    if (_down) widget.connection.buttonUp(widget.button);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Listener(
      onPointerDown: (_) => _press(),
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: PdMotion.press,
        child: AnimatedContainer(
          duration: PdMotion.press,
          height: 60,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: _down ? c.inv : c.s1, borderRadius: BorderRadius.circular(24)),
          child: Text(
            widget.label,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _down ? c.onInv : c.ink),
          ),
        ),
      ),
    );
  }
}
