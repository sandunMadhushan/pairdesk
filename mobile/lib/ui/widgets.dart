// SPDX-License-Identifier: GPL-3.0-or-later
// Building blocks for PairDesk's look: cards, round buttons, the floating
// pill navigation, sheets and press feedback.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Dips to 94 % while pressed and springs back (the design's "Press").
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.94});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _set(false);
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: PdMotion.press,
        curve: PdMotion.curve,
        child: widget.child,
      ),
    );
  }
}

/// A rounded white (or dark) card.
class PdCard extends StatelessWidget {
  const PdCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.color,
    this.radius = 26,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: color ?? c.s1, borderRadius: BorderRadius.circular(radius)),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A round icon button, 46 px by default.
class RoundButton extends StatelessWidget {
  const RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.background,
    this.foreground,
    this.size = 46,
    this.iconSize = 21,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? background;
  final Color? foreground;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Pressable(
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: background ?? c.s1, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: iconSize,
              color: onPressed == null ? c.sub.withValues(alpha: 0.5) : foreground ?? c.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// The lime pill: the one main action on a screen.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.height = 56});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final on = onPressed != null;
    return Semantics(
      button: true,
      enabled: on,
      child: Pressable(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: PdMotion.fade,
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: on ? c.accent : c.s2,
            borderRadius: BorderRadius.circular(999),
            boxShadow: on ? c.glow : const [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 21, color: on ? PdColors.onAccent : c.sub),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: on ? PdColors.onAccent : c.sub,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet grey pill.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 56,
    this.background,
    this.foreground,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final fg = onPressed == null ? c.sub : foreground ?? c.ink;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: Pressable(
        onTap: onPressed,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(color: background ?? c.s2, borderRadius: BorderRadius.circular(999)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row in a card: icon circle, title, subtitle, something at the end.
class PdRow extends StatelessWidget {
  const PdRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconBackground,
    this.iconColor,
    this.minHeight = 64,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconBackground;
  final Color? iconColor;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: iconBackground ?? c.s2, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: iconColor ?? c.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(subtitle!, style: TextStyle(fontSize: 13, color: c.sub, height: 1.3)),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(16), child: row),
    );
  }
}

/// A thin line between rows, indented past the icon.
class PdDivider extends StatelessWidget {
  const PdDivider({super.key, this.indent = 52});
  final double indent;

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: EdgeInsets.only(left: indent),
    color: PdColors.of(context).line,
  );
}

/// Pick one of a few options; the chosen one is an ink pill.
class PdSegmented<T> extends StatelessWidget {
  const PdSegmented({super.key, required this.options, required this.selected, required this.onChanged});

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: c.s2, borderRadius: BorderRadius.circular(999)),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / options.length;
          final index = options.indexWhere((o) => o.$1 == selected);
          return SizedBox(
            height: 42,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: PdMotion.move,
                  curve: PdMotion.spring,
                  left: w * (index < 0 ? 0 : index),
                  width: w,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: index < 0 ? Colors.transparent : c.inv,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final (value, label) in options)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: value == selected,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onChanged == null
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    onChanged!(value);
                                  },
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: PdMotion.fade,
                                style: TextStyle(
                                  fontFamily: 'Urbanist',
                                  fontSize: 15,
                                  fontWeight: value == selected ? FontWeight.w600 : FontWeight.w500,
                                  color: value == selected ? c.onInv : c.ink,
                                ),
                                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One destination in a [PillNav].
class PillNavItem {
  const PillNavItem({required this.icon, required this.label, this.badge = false, this.tooltip});
  final IconData icon;
  final String label;

  /// Shown on long press; defaults to [label].
  final String? tooltip;

  /// A small lime dot: something is happening there.
  final bool badge;
}

/// The floating bottom bar: the active item is a pill that slides to the
/// new tab with a soft spring and shows its label; the others show icon
/// and a small label (so Files and Sound are easy to find).
class PillNav extends StatelessWidget {
  const PillNav({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.compactLabels = true,
  });

  final List<PillNavItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Show small labels under the inactive icons.
  final bool compactLabels;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final reduced = PdMotion.reduced(context);
    return Container(
      height: 66,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: c.nav,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x38000000), blurRadius: 30, offset: Offset(0, 14))],
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          // The active item takes more room than the others.
          final n = items.length;
          final activeW = (box.maxWidth * (n > 3 ? 0.34 : 0.42)).clamp(96.0, 170.0);
          final otherW = (box.maxWidth - activeW) / (n - 1);
          double leftOf(int i) => i <= selected ? i * otherW : activeW + (i - 1) * otherW;
          final duration = reduced ? Duration.zero : PdMotion.move;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: duration,
                curve: PdMotion.spring,
                left: leftOf(selected),
                width: activeW,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: c.navOn, borderRadius: BorderRadius.circular(999)),
                ),
              ),
              for (var i = 0; i < n; i++)
                AnimatedPositioned(
                  duration: duration,
                  curve: PdMotion.spring,
                  left: leftOf(i),
                  width: i == selected ? activeW : otherW,
                  top: 0,
                  bottom: 0,
                  child: _NavButton(
                    item: items[i],
                    active: i == selected,
                    compactLabel: compactLabels,
                    onTap: () {
                      if (i != selected) HapticFeedback.selectionClick();
                      onSelected(i);
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.active,
    required this.compactLabel,
    required this.onTap,
  });

  final PillNavItem item;
  final bool active;
  final bool compactLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    final fg = active ? PdColors.onAccent : c.navFg;
    final icon = Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(item.icon, size: active ? 21 : 20, color: fg),
        if (item.badge)
          Positioned(
            right: -3,
            top: -2,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
            ),
          ),
      ],
    );
    return Tooltip(
      message: item.tooltip ?? item.label,
      child: Semantics(
        button: true,
        selected: active,
        label: item.label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedSwitcher(
            duration: PdMotion.fade,
            child: active
                ? Row(
                    key: const ValueKey(true),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      icon,
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg),
                        ),
                      ),
                    ],
                  )
                : Column(
                    key: const ValueKey(false),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      icon,
                      if (compactLabel) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Opens a rounded sheet that rises from the bottom over a dimmed page.
Future<T?> showPdSheet<T>(BuildContext context, WidgetBuilder builder, {bool scrollable = true}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: scrollable,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: builder(ctx),
      ),
    ),
  );
}

/// Title and optional line under it, for sheets and pages.
class PdTitle extends StatelessWidget {
  const PdTitle(this.title, {super.key, this.subtitle, this.size = 26});
  final String title;
  final String? subtitle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = PdColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.15),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(subtitle!, style: TextStyle(fontSize: 15, color: c.sub, height: 1.4)),
          ),
      ],
    );
  }
}

/// A dot that slowly breathes; for "connected" and "live".
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.size = 7, this.animate = true});
  final Color color;
  final double size;
  final bool animate;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.animate && PdMotion.loops(context)) {
      _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 1.0, end: 0.35).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

/// A spinner in the house style.
class PdSpinner extends StatelessWidget {
  const PdSpinner({super.key, this.size = 20, this.color, this.track});
  final double size;
  final Color? color;
  final Color? track;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(
      strokeWidth: 3,
      color: color ?? PdColors.lime,
      backgroundColor: track ?? Colors.transparent,
      strokeCap: StrokeCap.round,
    ),
  );
}

/// New content fades in and rises 8 px (the design's page change).
class FadeRise extends StatelessWidget {
  const FadeRise({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    if (PdMotion.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: PdMotion.fade + delay,
      curve: Interval(
        delay.inMilliseconds / (PdMotion.fade + delay).inMilliseconds,
        1,
        curve: PdMotion.curve,
      ),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// Switches between children with a fade-through (old out quickly, new in
/// and rising), keeping every child alive like an IndexedStack.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: PdMotion.fade, value: 1);

  @override
  void didUpdateWidget(FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && !PdMotion.reduced(context)) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: PdMotion.curve);
    return AnimatedBuilder(
      animation: a,
      builder: (context, child) => Opacity(
        opacity: a.value,
        child: Transform.translate(offset: Offset(0, 8 * (1 - a.value)), child: child),
      ),
      child: IndexedStack(index: widget.index, sizing: StackFit.expand, children: widget.children),
    );
  }
}
