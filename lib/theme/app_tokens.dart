import 'package:flutter/material.dart';

// ─── Spacing Scale ─────────────────────────────────────────────────────────────
abstract final class AppSpacing {
  static const double xs  = 4;
  static const double sm  = 8;
  static const double md  = 16;
  static const double lg  = 24;
  static const double xl  = 32;
  static const double xxl = 48;
}

// ─── Border Radius Scale ──────────────────────────────────────────────────────
abstract final class AppRadius {
  static const double xs   = 4;
  static const double sm   = 8;
  static const double md   = 12;
  static const double lg   = 16;
  static const double xl   = 24;
  static const double xxl  = 32;
  static const double full = 999;

  static const BorderRadius xsAll  = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll  = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll  = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll  = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll  = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius xxlAll = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius topLg  = BorderRadius.vertical(top: Radius.circular(lg));
  static const BorderRadius topXl  = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius topXxl = BorderRadius.vertical(top: Radius.circular(xxl));
}

// ─── M3 Expressive Motion ─────────────────────────────────────────────────────
// Based on Material Design 3 motion tokens (spring-based easing)
abstract final class AppMotion {
  // Durations
  static const Duration extraFast   = Duration(milliseconds: 100);
  static const Duration fast        = Duration(milliseconds: 200);
  static const Duration standard    = Duration(milliseconds: 300);
  static const Duration emphasized  = Duration(milliseconds: 400);
  static const Duration slow        = Duration(milliseconds: 500);
  static const Duration extraSlow   = Duration(milliseconds: 700);

  // M3 Expressive easing curves (spring-like feel)
  static const Curve emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);
  static const Curve emphasizedCurve      = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve standardCurve        = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve linearCurve          = Curves.linear;

  // Stagger delay for list items
  static Duration stagger(int index, {int ms = 40}) =>
      Duration(milliseconds: index * ms);
}

// ─── Breakpoints ──────────────────────────────────────────────────────────────
abstract final class AppBreakpoints {
  static const double compact  = 600;
  static const double medium   = 840;
  static const double expanded = 1200;
}

// ─── Responsive helpers ───────────────────────────────────────────────────────
extension ResponsiveContext on BuildContext {
  double get screenWidth  => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  bool get isCompact  => screenWidth < AppBreakpoints.compact;
  bool get isMedium   => screenWidth >= AppBreakpoints.compact && screenWidth < AppBreakpoints.expanded;
  bool get isExpanded => screenWidth >= AppBreakpoints.expanded;

  T responsive<T>({required T compact, T? medium, T? expanded}) {
    if (isExpanded) return expanded ?? medium ?? compact;
    if (isMedium)   return medium ?? compact;
    return compact;
  }

  EdgeInsets get pagePadding => EdgeInsets.symmetric(
    horizontal: responsive(
      compact: AppSpacing.md,
      medium:  AppSpacing.xl,
      expanded: AppSpacing.xxl,
    ),
    vertical: AppSpacing.md,
  );

  int get mediaGridColumns => responsive(compact: 3, medium: 4, expanded: 6);
  bool get showNavRail => !isCompact;
}

// ─── Telegram Brand Color ─────────────────────────────────────────────────────
const Color kTelegramBlue = Color(0xFF2AABEE);

// ─── Preset seed colors for the theme picker ─────────────────────────────────
const List<({String label, Color seed})> kThemeSeeds = [
  (label: 'Violet',  seed: Color(0xFF6C5CE7)),
  (label: 'Cyan',    seed: Color(0xFF00B4D8)),
  (label: 'Rose',    seed: Color(0xFFE040FB)),
  (label: 'Amber',   seed: Color(0xFFFFB703)),
  (label: 'Emerald', seed: Color(0xFF00C896)),
  (label: 'Coral',   seed: Color(0xFFFF6B6B)),
  (label: 'Indigo',  seed: Color(0xFF4361EE)),
  (label: 'Teal',    seed: Color(0xFF00897B)),
];
