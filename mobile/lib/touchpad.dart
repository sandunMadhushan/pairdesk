// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_connection.dart';
import 'touchpad_gestures.dart';

/// Full-area touchpad that drives the laptop cursor.
class Touchpad extends StatefulWidget {
  const Touchpad({super.key, required this.connection, this.speed = 1.0, this.naturalScroll = true});

  final AgentConnection connection;

  /// Multiplies cursor speed (1.0 = default).
  final double speed;

  /// True: content follows the fingers.
  final bool naturalScroll;

  @override
  State<Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<Touchpad> {
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

  int _fingers = 0;

  void _sync() {
    if (_fingers != _gestures.activePointers) {
      setState(() => _fingers = _gestures.activePointers);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _gestures.sensitivity = 1.6 * widget.speed;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _gestures.pointerDown(e.pointer, e.localPosition, e.timeStamp);
        _sync();
      },
      onPointerMove: (e) => _gestures.pointerMove(e.pointer, e.localPosition, e.timeStamp),
      onPointerUp: (e) {
        _gestures.pointerUp(e.pointer, e.localPosition, e.timeStamp);
        _sync();
      },
      onPointerCancel: (e) {
        _gestures.pointerCancel(e.pointer);
        _sync();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _fingers > 0 ? scheme.surfaceContainerHighest : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Center(
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Move with one finger · tap to click\n'
                'Two fingers: scroll · two-finger tap: right-click',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (_) => _press(),
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _down ? scheme.primary : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          widget.label,
          style: TextStyle(fontWeight: FontWeight.w600, color: _down ? scheme.onPrimary : scheme.onSurface),
        ),
      ),
    );
  }
}
