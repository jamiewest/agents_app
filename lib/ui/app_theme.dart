// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The single seed color both themes derive from.
///
/// A calm cyan-blue: distinctive without fighting the chat content, and it
/// produces balanced tonal palettes in both brightnesses.
const Color seedColor = Color(0xFF00658F);

/// Builds the app theme for [brightness].
///
/// One construction path for light and dark keeps the two modes in
/// lockstep: every component style below is expressed through the scheme's
/// roles, never hard-coded colors.
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final base = ThemeData(brightness: brightness);
  final textTheme = GoogleFonts.outfitTextTheme(base.textTheme).copyWith(
    titleLarge: GoogleFonts.outfitTextTheme(
      base.textTheme,
    ).titleLarge?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: GoogleFonts.outfitTextTheme(
      base.textTheme,
    ).labelLarge?.copyWith(fontWeight: FontWeight.w600),
    bodyMedium: GoogleFonts.outfitTextTheme(
      base.textTheme,
    ).bodyMedium?.copyWith(height: 1.4),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      scrolledUnderElevation: 2,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      labelType: NavigationRailLabelType.all,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      iconColor: scheme.onSurfaceVariant,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: scheme.surfaceContainerHigh,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    tabBarTheme: const TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.label,
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
  );
}

/// Scales type with the window so text keeps comfortable proportions on
/// larger layouts, composed on top of the user's own accessibility scale.
TextScaler responsiveTextScaler({
  required double width,
  required TextScaler userScaler,
}) {
  final layoutFactor = width >= 1200
      ? 1.08
      : width >= 700
      ? 1.04
      : 1.0;
  final userFactor = userScaler.scale(100) / 100;
  return TextScaler.linear(userFactor * layoutFactor);
}
