// SPDX-License-Identifier: GPL-3.0-or-later
// The first thing PairDesk shows: the logo pops in, a lime dot travels
// from the laptop to the phone, and the name rises in underneath.

import 'package:flutter/material.dart';

import '../ui/theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final AnimationController _dot = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (PdMotion.reduced(context)) {
      _intro.value = 1;
    } else if (!_intro.isAnimating && _intro.value == 0) {
      _intro.forward();
      Future.delayed(const Duration(milliseconds: 450), () {
        if (mounted && PdMotion.loops(context)) _dot.repeat();
      });
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _dot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final pop = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0, 0.6, curve: Curves.easeOutBack),
    );
    final word = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.4, 0.85, curve: PdMotion.curve),
    );
    final tag = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.55, 1, curve: PdMotion.curve),
    );
    Widget rise(Animation<double> a, Widget child) => AnimatedBuilder(
      animation: a,
      builder: (_, child) => Opacity(
        opacity: a.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 16 * (1 - a.value)), child: child),
      ),
      child: child,
    );
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ScaleTransition(
                  scale: Tween(begin: 0.55, end: 1.0).animate(pop),
                  child: FadeTransition(
                    opacity: CurvedAnimation(parent: _intro, curve: const Interval(0, 0.3)),
                    child: _LinkMark(dot: _dot, colors: c),
                  ),
                ),
                const SizedBox(height: 30),
                rise(
                  word,
                  const Text(
                    'PairDesk',
                    style: TextStyle(fontSize: 42, fontWeight: FontWeight.w700, letterSpacing: -1),
                  ),
                ),
                const SizedBox(height: 6),
                rise(
                  tag,
                  Text('Your phone, for your computer', style: TextStyle(fontSize: 17, color: c.sub)),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 56,
            child: FadeTransition(
              opacity: tag,
              child: Text(
                'Free software · no account',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: c.sub),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ink tile with a laptop, a phone, and the lime dot travelling between.
class _LinkMark extends StatelessWidget {
  const _LinkMark({required this.dot, required this.colors});
  final Animation<double> dot;
  final PdColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      width: 220,
      height: 120,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: BoxDecoration(color: c.inv, borderRadius: BorderRadius.circular(36)),
      child: Row(
        children: [
          Icon(Icons.laptop_rounded, size: 48, color: c.dark ? PdColors.onAccent : PdColors.lime),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                height: 12,
                child: LayoutBuilder(
                  builder: (context, box) => AnimatedBuilder(
                    animation: dot,
                    builder: (_, _) {
                      final t = dot.isAnimating ? Curves.easeInOut.transform(dot.value) : 0.5;
                      final fade = dot.value < 0.12
                          ? dot.value / 0.12
                          : dot.value > 0.88
                          ? (1 - dot.value) / 0.12
                          : 1.0;
                      return Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          CustomPaint(size: Size(box.maxWidth, 2), painter: _Dashes(c.subInv)),
                          Positioned(
                            left: t * (box.maxWidth - 10),
                            child: Opacity(
                              opacity: dot.isAnimating ? fade.clamp(0.0, 1.0) : 1,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: c.dark ? PdColors.onAccent : PdColors.lime,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Icon(Icons.smartphone_rounded, size: 40, color: c.dark ? PdColors.onAccent : PdColors.lime),
        ],
      ),
    );
  }
}

class _Dashes extends CustomPainter {
  _Dashes(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var x = 0.0; x < size.width; x += 9) {
      canvas.drawLine(Offset(x, size.height / 2), Offset((x + 4).clamp(0, size.width), size.height / 2), p);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color;
}
