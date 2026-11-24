// SPDX-License-Identifier: GPL-3.0-or-later
// Present: big Next and Previous, a talk timer, blank, laser and stop.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent_connection.dart';
import '../present/present_controller.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

const _channel = MethodChannel('pairdesk/present');

class PresentScreen extends StatefulWidget {
  const PresentScreen({super.key, required this.connection});
  final AgentConnection connection;

  static Future<void> open(BuildContext context, AgentConnection connection) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PresentScreen(connection: connection), fullscreenDialog: true),
    );
  }

  @override
  State<PresentScreen> createState() => _PresentScreenState();
}

class _PresentScreenState extends State<PresentScreen> {
  late final PresentController _p = PresentController(
    press: widget.connection.key,
    combo: widget.connection.combo,
  );

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Keeps the screen on and lets the volume keys turn slides.
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'volume') return;
      call.arguments == 'up' ? _go(_p.previous) : _go(_p.next);
    });
    _channel.invokeMethod<void>('setActive', true).catchError((_) {});
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _channel.invokeMethod<void>('setActive', false).catchError((_) {});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _p.dispose();
    super.dispose();
  }

  void _go(VoidCallback action) {
    HapticFeedback.lightImpact();
    action();
  }

  Future<void> _pickTarget() async {
    final minutes = await showPdSheet<int>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PdTitle(
              'Talk length',
              subtitle: 'The timer counts down to this and turns red when you run over.',
              size: 22,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in const [0, 5, 10, 15, 20, 30, 45, 60])
                  SecondaryButton(
                    label: m == 0 ? 'No limit' : '$m min',
                    height: 44,
                    onPressed: () => Navigator.pop(ctx, m),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (minutes != null) _p.setTarget(Duration(minutes: minutes));
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _p,
          builder: (context, _) => LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > box.maxHeight;
              final nav = _navButtons(c, wide);
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: Column(
                  children: [
                    _top(c),
                    const SizedBox(height: 12),
                    if (_p.laser) ...[
                      SizedBox(
                        height: wide ? 90 : 150,
                        child: _LaserPad(connection: widget.connection),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Expanded(child: nav),
                    const SizedBox(height: 12),
                    _bar(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _top(PdColors c) {
    final rem = _p.remaining;
    final over = rem != null && rem.isNegative;
    final shown = rem == null ? formatClock(_p.elapsed) : '${over ? '+' : ''}${formatClock(rem)}';
    return Row(
      children: [
        RoundButton(
          icon: Icons.close_rounded,
          tooltip: 'Leave presenter mode',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () => _p.timerRunning ? _p.pauseTimer() : _p.startTimer(),
            onLongPress: _p.resetTimer,
            child: Column(
              children: [
                Text(
                  shown,
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: over ? Colors.redAccent : c.ink,
                  ),
                ),
                Text(
                  _p.timerRunning ? 'Tap to pause · hold to reset' : 'Tap to start · hold to reset',
                  style: TextStyle(fontSize: 12, color: c.sub),
                ),
              ],
            ),
          ),
        ),
        RoundButton(icon: Icons.timer_outlined, tooltip: 'Talk length', onPressed: _pickTarget),
      ],
    );
  }

  Widget _navButtons(PdColors c, bool wide) {
    final prev = _BigButton(
      icon: Icons.arrow_back_rounded,
      label: 'Back',
      color: c.s2,
      foreground: c.ink,
      onTap: () => _go(_p.previous),
    );
    final next = _BigButton(
      icon: Icons.arrow_forward_rounded,
      label: 'Next',
      color: c.accent,
      foreground: PdColors.onAccent,
      onTap: () => _go(_p.next),
    );
    return wide
        ? Row(
            children: [
              Expanded(child: prev),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: next),
            ],
          )
        : Column(
            children: [
              Expanded(child: prev),
              const SizedBox(height: 12),
              Expanded(flex: 2, child: next),
            ],
          );
  }

  Widget _bar() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        SecondaryButton(
          label: 'Start',
          icon: Icons.slideshow_rounded,
          height: 44,
          onPressed: () => _go(_p.start),
        ),
        SecondaryButton(label: 'From here', height: 44, onPressed: () => _go(_p.startHere)),
        SecondaryButton(
          label: 'Blank',
          icon: Icons.visibility_off_rounded,
          height: 44,
          background: _p.blanked ? PdColors.of(context).inv : null,
          foreground: _p.blanked ? PdColors.of(context).bg : null,
          onPressed: () => _go(_p.toggleBlank),
        ),
        SecondaryButton(
          label: 'Laser',
          icon: Icons.highlight_rounded,
          height: 44,
          background: _p.laser ? PdColors.of(context).inv : null,
          foreground: _p.laser ? PdColors.of(context).bg : null,
          onPressed: () => _go(_p.toggleLaser),
        ),
        SecondaryButton(
          label: 'End show',
          icon: Icons.stop_rounded,
          height: 44,
          onPressed: () => _go(_p.stop),
        ),
      ],
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.foreground,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(36)),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: foreground),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small pad that moves the computer's pointer, for the laser.
class _LaserPad extends StatelessWidget {
  const _LaserPad({required this.connection});
  final AgentConnection connection;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => connection.move((d.delta.dx * 2.2).round(), (d.delta.dy * 2.2).round()),
      child: Container(
        decoration: BoxDecoration(color: c.s1, borderRadius: BorderRadius.circular(28)),
        alignment: Alignment.center,
        child: Text('Drag here to move the pointer', style: TextStyle(color: c.sub)),
      ),
    );
  }
}
