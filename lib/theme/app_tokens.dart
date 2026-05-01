import 'package:flutter/material.dart';

// ─── Spacing Scale ─────────────────────────────────────────────────────────────
// Use AppSpacing.* everywhere instead of hardcoded EdgeInsets numbers.
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
  static const double xs  = 4;
  static const double sm  = 8;
  static const double md  = 12;
  static const double lg  = 16;
  static const double xl  = 24;
  static const double full = 999;

  static const BorderRadius xsAll  = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smAll  = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll  = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll  = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll  = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius topLg  = BorderRadius.vertical(top: Radius.circular(lg));
  static const BorderRadius topXl  = BorderRadius.vertical(top: Radius.circular(xl));
}

// ─── Breakpoints ──────────────────────────────────────────────────────────────
// compact  < 600  → phone (portrait)
// medium   < 840  → phone (landscape), small tablet
// expanded < 1200 → tablet, TV (standard)
// large    ≥ 1200 → TV, large tablet
abstract final class AppBreakpoints {
  static const double compact  = 600;
  static const double medium   = 840;
  static const double expanded = 1200;
}

// ─── Responsive helpers ───────────────────────────────────────────────────────
extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  bool get isCompact  => screenWidth < AppBreakpoints.compact;
  bool get isMedium   => screenWidth >= AppBreakpoints.compact && screenWidth < AppBreakpoints.expanded;
  bool get isExpanded => screenWidth >= AppBreakpoints.expanded;

  /// Pick a value based on the current breakpoint.
  T responsive<T>({required T compact, T? medium, T? expanded}) {
    if (isExpanded) return expanded ?? medium ?? compact;
    if (isMedium)   return medium ?? compact;
    return compact;
  }

  /// Horizontal page padding — grows on wider screens.
  EdgeInsets get pagePadding => EdgeInsets.symmetric(
    horizontal: responsive(
      compact: AppSpacing.md,
      medium:  AppSpacing.xl,
      expanded: AppSpacing.xxl,
    ),
    vertical: AppSpacing.md,
  );

  /// Grid column count for media cards.
  int get mediaGridColumns => responsive(compact: 3, medium: 4, expanded: 6);

  /// Whether a side navigation rail should be shown.
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
