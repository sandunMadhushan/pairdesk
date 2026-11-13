// SPDX-License-Identifier: GPL-3.0-or-later
// PairDesk's look: soft grey and white with one lime accent; in the dark,
// near-black with the same lime and white. Urbanist throughout.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// The app's own colours, read with `PdColors.of(context)`.
@immutable
class PdColors extends ThemeExtension<PdColors> {
  const PdColors({
    required this.bg,
    required this.s1,
    required this.s2,
    required this.ink,
    required this.sub,
    required this.line,
    required this.accent,
    required this.nav,
    required this.navFg,
    required this.navOn,
    required this.inv,
    required this.onInv,
    required this.subInv,
    required this.scrim,
    required this.glow,
    required this.dots,
    required this.dark,
  });

  /// The page behind everything.
  final Color bg;

  /// Cards and sheets.
  final Color s1;

  /// Wells inside cards: icon circles, segmented controls, inputs.
  final Color s2;

  /// Text and strong marks.
  final Color ink;

  /// Secondary text.
  final Color sub;
  final Color line;

  /// Lime: the main action, the active tab, things that are on.
  final Color accent;

  /// The bottom bar.
  final Color nav;
  final Color navFg;

  /// The active item's pill in the bottom bar.
  final Color navOn;

  /// The one strongest element on a card: ink in light, white in dark.
  final Color inv;
  final Color onInv;
  final Color subInv;
  final Color scrim;

  /// Soft lime glow under the main action (dark mode only).
  final List<BoxShadow> glow;

  /// The touchpad's dot grid.
  final Color dots;
  final bool dark;

  /// Text on lime, in both modes.
  static const onAccent = Color(0xFF111111);
  static const lime = Color(0xFFD2F34C);

  static const light = PdColors(
    bg: Color(0xFFEEEEEA),
    s1: Color(0xFFFFFFFF),
    s2: Color(0xFFF3F3EF),
    ink: Color(0xFF111111),
    sub: Color(0xFF62655E),
    line: Color(0xFFE3E3DE),
    accent: lime,
    nav: Color(0xFF111111),
    navFg: Color(0xFFA3A59F),
    navOn: lime,
    inv: Color(0xFF111111),
    onInv: Color(0xFFFFFFFF),
    subInv: Color(0xFFB5B7B0),
    scrim: Color(0x6B111111),
    glow: [],
    dots: Color(0x21111111),
    dark: false,
  );

  static const darkColors = PdColors(
    bg: Color(0xFF0D0D0F),
    s1: Color(0xFF19191C),
    s2: Color(0xFF232327),
    ink: Color(0xFFF2F2EE),
    sub: Color(0xFF9C9DA3),
    line: Color(0xFF2A2A2F),
    accent: lime,
    nav: Color(0xFF19191C),
    navFg: Color(0xFF8B8C92),
    navOn: Color(0xFFF2F2EE),
    inv: Color(0xFFF2F2EE),
    onInv: Color(0xFF111111),
    subInv: Color(0xFF4A4B50),
    scrim: Color(0x9E000000),
    glow: [BoxShadow(color: Color(0x99D2F34C), blurRadius: 34, spreadRadius: -12, offset: Offset(0, 14))],
    dots: Color(0x1FF2F2EE),
    dark: true,
  );

  static PdColors of(BuildContext context) => Theme.of(context).extension<PdColors>() ?? light;

  @override
  PdColors copyWith() => this;

  @override
  PdColors lerp(PdColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

/// Motion timings shared by the whole app (see the design's motion plan).
abstract final class PdMotion {
  static const press = Duration(milliseconds: 150);
  static const fade = Duration(milliseconds: 250);
  static const move = Duration(milliseconds: 380);
  static const curve = Curves.easeOutCubic;

  /// A soft spring: settles without bouncing past.
  static const spring = Cubic(0.2, 0.9, 0.25, 1.05);

  /// Android's "Remove animations" is on.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Animations that repeat forever (breathing dots, sound bars, talking
  /// rings). Off with "Remove animations", and under `flutter test`, where
  /// they would keep the frame clock busy.
  static bool loops(BuildContext context) => !reduced(context) && !_underTest;
  static final _underTest = Platform.environment.containsKey('FLUTTER_TEST');
}

ThemeData pdTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? PdColors.darkColors : PdColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.ink,
    onPrimary: c.onInv,
    primaryContainer: c.accent,
    onPrimaryContainer: PdColors.onAccent,
    secondary: c.accent,
    onSecondary: PdColors.onAccent,
    secondaryContainer: c.s2,
    onSecondaryContainer: c.ink,
    tertiary: c.accent,
    onTertiary: PdColors.onAccent,
    error: brightness == Brightness.dark ? const Color(0xFFFF8A80) : const Color(0xFFB3261E),
    onError: brightness == Brightness.dark ? const Color(0xFF111111) : Colors.white,
    errorContainer: brightness == Brightness.dark ? const Color(0xFF3A1C1C) : const Color(0xFFFBE4E2),
    onErrorContainer: brightness == Brightness.dark ? const Color(0xFFFFDAD6) : const Color(0xFF5C1410),
    surface: c.bg,
    onSurface: c.ink,
    onSurfaceVariant: c.sub,
    surfaceContainerLowest: c.s1,
    surfaceContainerLow: c.s1,
    surfaceContainer: c.s1,
    surfaceContainerHigh: c.s1,
    surfaceContainerHighest: c.s2,
    outline: c.sub,
    outlineVariant: c.line,
    inverseSurface: c.inv,
    onInverseSurface: c.onInv,
    inversePrimary: c.accent,
    shadow: Colors.black,
    scrim: c.scrim,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Urbanist');
  final text = base.textTheme.apply(bodyColor: c.ink, displayColor: c.ink);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  return base.copyWith(
    extensions: [c],
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: InkSparkle.splashFactory,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontFamily: 'Urbanist'),
    ),
    cardTheme: CardThemeData(
      color: c.s1,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.s1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      titleTextStyle: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 22),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.s1,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: c.scrim,
      showDragHandle: true,
      dragHandleColor: c.line,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: PdColors.onAccent,
        minimumSize: const Size(64, 52),
        shape: pill,
        textStyle: const TextStyle(fontFamily: 'Urbanist', fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        backgroundColor: c.s2,
        side: BorderSide.none,
        minimumSize: const Size(64, 52),
        shape: pill,
        textStyle: const TextStyle(fontFamily: 'Urbanist', fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.ink,
        shape: pill,
        textStyle: const TextStyle(fontFamily: 'Urbanist', fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: c.ink)),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? const Color(0xFF111111) : c.sub,
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.s2),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : c.line,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.ink,
      inactiveTrackColor: c.s2,
      thumbColor: c.ink,
      overlayColor: c.accent.withValues(alpha: 0.3),
      valueIndicatorColor: c.inv,
      valueIndicatorTextStyle: TextStyle(color: c.onInv, fontFamily: 'Urbanist'),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.ink,
      linearTrackColor: c.s2,
      circularTrackColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.inv,
      contentTextStyle: TextStyle(color: c.onInv, fontFamily: 'Urbanist', fontSize: 15),
      actionTextColor: c.dark ? const Color(0xFF111111) : c.accent,
      closeIconColor: c.onInv,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.s2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: c.ink, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: TextStyle(color: c.sub),
    ),
    listTileTheme: ListTileThemeData(iconColor: c.ink, textColor: c.ink),
    popupMenuTheme: PopupMenuThemeData(
      color: c.s1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.inv : c.s2,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onInv : c.ink,
        ),
        side: const WidgetStatePropertyAll(BorderSide.none),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.s2,
      selectedColor: c.inv,
      labelStyle: TextStyle(color: c.ink, fontFamily: 'Urbanist', fontWeight: FontWeight.w600),
      secondaryLabelStyle: TextStyle(color: c.onInv, fontFamily: 'Urbanist', fontWeight: FontWeight.w600),
      checkmarkColor: c.onInv,
      side: BorderSide.none,
      shape: const StadiumBorder(),
    ),
    searchBarTheme: SearchBarThemeData(
      backgroundColor: WidgetStatePropertyAll(c.s1),
      elevation: const WidgetStatePropertyAll(0),
      shape: WidgetStatePropertyAll(pill),
    ),
    dividerTheme: DividerThemeData(color: c.line, space: 1, thickness: 1),
  );
}
