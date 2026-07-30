// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/theme_settings.dart';
import '../app_theme.dart';
import '../widgets/settings_page.dart';

/// The Appearance sub-page: light/dark mode and the seed colour both schemes
/// are derived from.
class AppearanceSettingsScreen extends StatelessWidget {
  /// Creates an [AppearanceSettingsScreen].
  const AppearanceSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final settings = services.getRequiredService<ThemeSettings>();
    return SettingsPage(
      title: 'Appearance',
      children: [
        const SettingsGroupLabel('Theme'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _ThemeModeSelector(settings: settings),
        ),
        const SettingsGroupLabel('Accent colour'),
        const SettingsGroupCaption(
          'Every other colour in the app is derived from this one.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _SeedSelector(settings: settings),
        ),
      ],
    );
  }
}

/// The system/light/dark switch.
class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.settings});

  final ThemeSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(
          value: ThemeMode.system,
          icon: Icon(LucideIcons.sunMoon300),
          label: Text('System'),
        ),
        ButtonSegment(
          value: ThemeMode.light,
          icon: Icon(LucideIcons.sun300),
          label: Text('Light'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: Icon(LucideIcons.moon300),
          label: Text('Dark'),
        ),
      ],
      selected: {settings.mode},
      onSelectionChanged: (selection) => settings.setMode(selection.single),
    ),
  );
}

/// The grid of seed colours.
class _SeedSelector extends StatelessWidget {
  const _SeedSelector({required this.settings});

  final ThemeSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final seed in AppThemeSeed.values)
          _SeedSwatch(
            seed: seed,
            selected: seed == settings.seed,
            onTap: () => settings.setSeed(seed),
          ),
      ],
    ),
  );
}

/// A tappable color dot for one [AppThemeSeed] choice.
class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final AppThemeSeed seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: seed.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: seed.color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  LucideIcons.check300,
                  size: 18,
                  color:
                      ThemeData.estimateBrightnessForColor(seed.color) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                )
              : null,
        ),
      ),
    );
  }
}
