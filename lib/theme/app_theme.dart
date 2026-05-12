import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_tokens.dart';

export 'app_tokens.dart';

// ─── AtmosTheme ───────────────────────────────────────────────────────────────
// All color references go through Theme.of(context).colorScheme.*
// The static fields below are kept ONLY for legacy widgets being migrated;
// new code must use colorScheme directly.

class AtmosTheme {
  AtmosTheme._();

  // ── Legacy aliases (used during migration — remove as screens are updated) ──
  // These now read from the CURRENT seed so they stay in sync.
  static Color get primary         => _latestScheme?.primary         ?? const Color(0xFF6C5CE7);
  static Color get surface         => _latestScheme?.surface         ?? const Color(0xFF0F0F1E);
  static Color get background      => _latestScheme?.surface         ?? const Color(0xFF080810);
  static Color get surfaceElevated => _latestScheme?.surfaceContainerLow ?? const Color(0xFF16162A);
  static Color get textPrimary     => _latestScheme?.onSurface       ?? const Color(0xFFF8F8FC);
  static Color get textSecondary   => _latestScheme?.onSurfaceVariant ?? const Color(0xFFB0B0C8);
  static Color get textMuted       => _latestScheme?.outline         ?? const Color(0xFF6B6B8A);
  static Color get card            => _latestScheme?.surfaceContainer ?? const Color(0xFF1A1A2E);
  static Color get accent          => _latestScheme?.secondary       ?? const Color(0xFFE040FB);
  static Color get gold            => const Color(0xFFFFD700);

  // Internal: updated by build() so legacy code stays correct.
  static ColorScheme? _latestScheme;

  // ── Build ThemeData from seed color ────────────────────────────────────────
  static ThemeData build(Color seed) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    _latestScheme = scheme;

    // Configure system UI chrome to match the dark M3 surface
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: scheme.surface,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    final textTheme = GoogleFonts.outfitTextTheme().copyWith(
      displayLarge:  GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w700, letterSpacing: -1.5),
      displayMedium: GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w600, letterSpacing: -0.5),
      headlineLarge: GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w600),
      headlineMedium:GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w600),
      headlineSmall: GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w500),
      titleLarge:    GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w500),
      titleMedium:   GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w500),
      titleSmall:    GoogleFonts.outfit(color: scheme.onSurface, fontWeight: FontWeight.w500),
      bodyLarge:     GoogleFonts.outfit(color: scheme.onSurfaceVariant, height: 1.6),
      bodyMedium:    GoogleFonts.outfit(color: scheme.onSurfaceVariant),
      bodySmall:     GoogleFonts.outfit(color: scheme.outline),
      labelLarge:    GoogleFonts.outfit(color: scheme.onSurface,        fontWeight: FontWeight.w600, letterSpacing: 0.5),
      labelMedium:   GoogleFonts.outfit(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500),
      labelSmall:    GoogleFonts.outfit(color: scheme.outline,          fontWeight: FontWeight.w500, letterSpacing: 0.5),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme,

      // Scaffold & AppBar
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 3,
        surfaceTintColor: scheme.surfaceTint,
        titleTextStyle: GoogleFonts.outfit(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 20,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),

      // Cards
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        margin: EdgeInsets.zero,
      ),

      // Navigation rail (tablet / TV)
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: GoogleFonts.outfit(color: scheme.primary, fontWeight: FontWeight.w600),
        indicatorColor: scheme.secondaryContainer,
      ),

      // Navigation bar (phone bottom bar)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
        )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => GoogleFonts.outfit(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        )),
      ),

      // Chips (filter chips)
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.secondaryContainer,
        labelStyle: GoogleFonts.outfit(color: scheme.onSurface),
        side: BorderSide(color: scheme.outlineVariant),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      ),

      // Inputs
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        hintStyle: GoogleFonts.outfit(color: scheme.outline),
        border: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + AppSpacing.xs,
        ),
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm + AppSpacing.xs),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          textStyle: GoogleFonts.outfit(fontWeight: FontWeight.w600, letterSpacing: 0.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          textStyle: GoogleFonts.outfit(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: scheme.outline),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
          textStyle: GoogleFonts.outfit(fontWeight: FontWeight.w500),
        ),
      ),

      // Bottom sheets
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.topXl),
        showDragHandle: true,
      ),

      // Dialogs
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
        titleTextStyle: GoogleFonts.outfit(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),

      // Dividers
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),

      // Progress indicators
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),

      // Scrollbar
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(scheme.outlineVariant),
        radius: const Radius.circular(AppRadius.xs),
      ),

      // List tiles
      listTileTheme: ListTileThemeData(
        tileColor: Colors.transparent,
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        subtitleTextStyle: GoogleFonts.outfit(color: scheme.outline, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
      ),

      // Switches
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.outline),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? scheme.primary : scheme.surfaceContainerHighest),
      ),

      // Snack bars
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: GoogleFonts.outfit(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
      ),

      // Tooltips
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: AppRadius.smAll,
        ),
        textStyle: GoogleFonts.outfit(color: scheme.onInverseSurface, fontSize: 12),
      ),

      // Interactions
      splashColor: scheme.primary.withAlpha(26),
      highlightColor: scheme.primary.withAlpha(20),
      focusColor: scheme.primary.withAlpha(38),
      splashFactory: InkSparkle.splashFactory,

      // M3 Expressive page transitions
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(
            allowEnterRouteSnapshotting: false,
          ),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  // ── Gradient helpers (seed-aware) ──────────────────────────────────────────
  static LinearGradient primaryGradient(ColorScheme scheme) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [scheme.primary, scheme.secondary],
  );

  static LinearGradient heroGradient(ColorScheme scheme) => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, scheme.surface.withAlpha(128), scheme.surface],
    stops: const [0.0, 0.5, 1.0],
  );
}
