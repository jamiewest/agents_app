// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Seed colors offered to the user, mirroring Flutter's Material 3
/// color-scheme sample.
enum AppThemeSeed {
  baseline('M3 Baseline', Color(0xff6750a4)),
  indigo('Indigo', Colors.indigo),
  blue('Blue', Colors.blue),
  teal('Teal', Colors.teal),
  green('Green', Colors.green),
  yellow('Yellow', Colors.yellow),
  orange('Orange', Colors.orange),
  deepOrange('Deep Orange', Colors.deepOrange),
  pink('Pink', Colors.pink);

  const AppThemeSeed(this.label, this.color);

  /// Human-readable name shown in the Settings picker.
  final String label;

  /// The seed both color schemes derive from.
  final Color color;
}

/// Semantic status colors that Material 3 doesn't provide (there is no
/// "success/online" role in [ColorScheme]).
///
/// Read via `Theme.of(context).extension<StatusColors>()!`. Registered for
/// both brightnesses by [buildAppTheme], so the values are always present.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  /// Creates a [StatusColors].
  const StatusColors({required this.online, required this.offline});

  /// Dot/indicator color for a reachable peer or healthy connection.
  final Color online;

  /// Dot/indicator color for an unreachable peer or idle connection.
  final Color offline;

  /// Values tuned for light surfaces.
  static const StatusColors light = StatusColors(
    online: Color(0xFF2E7D32),
    offline: Color(0xFFBDBDBD),
  );

  /// Values tuned for dark surfaces.
  static const StatusColors dark = StatusColors(
    online: Color(0xFF81C784),
    offline: Color(0xFF5C5C66),
  );

  @override
  StatusColors copyWith({Color? online, Color? offline}) => StatusColors(
    online: online ?? this.online,
    offline: offline ?? this.offline,
  );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      online: Color.lerp(online, other.online, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
    );
  }
}

/// The app's back-navigation glyph: a chevron inside a soft tonal circle.
///
/// Installed app-wide through [ThemeData.actionIconTheme] so every implied
/// [BackButton] picks it up. The contained-chevron look keeps back buttons
/// visually distinct from the hamburger menu button that compact layouts
/// show in the same leading position.
class AppBackIcon extends StatelessWidget {
  /// Creates an [AppBackIcon].
  const AppBackIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.chevronLeft300,
        size: 16,
        color: scheme.onSurface,
      ),
    );
  }
}

/// Shared corner radii so cards, fields, and inline containers stay on one
/// geometric scale (Material 3 expressive: large for cards, medium for
/// nested elements).
abstract final class AppShape {
  /// Cards and other top-level surfaces.
  static const double card = 16;

  /// Elements nested inside a card: banners, code blocks, fields.
  static const double inner = 12;

  /// Small inline elements such as buttons and chips.
  static const double small = 8;
}

/// Shared spacing scale for gaps, padding, and margins, so screens lay out
/// on one rhythm instead of ad-hoc magic numbers.
abstract final class AppSpacing {
  /// 4 — hairline gaps between tightly-coupled elements.
  static const double xs = 4;

  /// 8 — default gap between related controls.
  static const double sm = 8;

  /// 12 — gap between an icon and its label, or grouped rows.
  static const double md = 12;

  /// 16 — standard page gutter and gap between distinct elements.
  static const double lg = 16;

  /// 20 — padding inside cards and section containers.
  static const double xl = 20;

  /// 24 — gap between major sections.
  static const double xxl = 24;

  /// 32 — generous separation around hero/empty-state content.
  static const double xxxl = 32;
}

/// Builds the app-wide Material 3 theme for one [brightness], seeded from
/// the user-selected [seedColor].
///
/// All component styling shared across screens belongs here — widgets
/// should only read from the theme, not restate colors/shapes locally.
ThemeData buildAppTheme({
  required Color seedColor,
  required Brightness brightness,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final textTheme = _scaleTextTheme(
    GoogleFonts.outfitTextTheme(
      brightness == Brightness.dark
          ? ThemeData.dark().textTheme
          : ThemeData.light().textTheme,
    ),
  );

  return ThemeData(
    colorScheme: scheme,
    // Match the chat screen's background (LlmChatViewStyle uses
    // scheme.surface) across every screen and their app bars, so the app
    // reads as one seamless surface.
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    // Restyled back affordance (see [AppBackIcon]): compact layouts put a
    // hamburger menu button in the same leading slot on root pages, so back
    // buttons need their own distinct look.
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (context) => const AppBackIcon(),
    ),
    // Canonical card surface: a translucent layered surface with a soft
    // outline on the [AppShape.card] radius.
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.card),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      iconColor: scheme.onSurfaceVariant,
      selectedTileColor: scheme.secondaryContainer,
      selectedColor: scheme.onSecondaryContainer,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
      color: scheme.surfaceContainerHigh,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.small),
      ),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    // Accent-tinted navigation: the selected destination gets a soft
    // primary-tinted indicator and a primary icon/label, while the rest
    // stay muted (onSurfaceVariant).
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelMedium!.copyWith(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.normal,
        ),
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[
      brightness == Brightness.dark ? StatusColors.dark : StatusColors.light,
    ],
  );
}

/// Nudges every role in [baseTheme] one point larger, matching the type
/// scale the design is calibrated against.
TextTheme _scaleTextTheme(TextTheme baseTheme) {
  TextStyle? bump(TextStyle? style, double base) =>
      style?.copyWith(fontSize: (style.fontSize ?? base) + 1);

  return baseTheme.copyWith(
    displayLarge: bump(baseTheme.displayLarge, 57),
    displayMedium: bump(baseTheme.displayMedium, 45),
    displaySmall: bump(baseTheme.displaySmall, 36),
    headlineLarge: bump(baseTheme.headlineLarge, 32),
    headlineMedium: bump(baseTheme.headlineMedium, 28),
    headlineSmall: bump(baseTheme.headlineSmall, 24),
    titleLarge: bump(baseTheme.titleLarge, 22),
    titleMedium: bump(baseTheme.titleMedium, 16),
    titleSmall: bump(baseTheme.titleSmall, 14),
    bodyLarge: bump(baseTheme.bodyLarge, 16),
    bodyMedium: bump(baseTheme.bodyMedium, 14),
    bodySmall: bump(baseTheme.bodySmall, 12),
    labelLarge: bump(baseTheme.labelLarge, 14),
    labelMedium: bump(baseTheme.labelMedium, 12),
    labelSmall: bump(baseTheme.labelSmall, 11),
  );
}
