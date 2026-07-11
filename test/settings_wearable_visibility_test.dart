// Platform gating for the wearable surface. Runs on the VM (native
// expectations) and under `flutter test --platform chrome` (web
// expectations) — the assertions follow kIsWeb.

import 'package:agents_app/data/theme_settings.dart';
import 'package:agents_app/ui/screens/settings_home_screen.dart';
import 'package:agents_app/ui/screens/wearable_unavailable_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the settings wearable entry follows platform support', (
    tester,
  ) async {
    final services =
        (ServiceCollection()
              ..addSingleton<ThemeSettings>(
                (_) => ThemeSettings(InMemoryKeyValueStore()),
              ))
            .buildServiceProvider();

    await tester.pumpWidget(
      MaterialApp(home: SettingsHomeScreen(services: services)),
    );
    await tester.pumpAndSettle();

    // BLE does not exist in the browser, so web builds hide the entry
    // entirely; native builds keep it.
    expect(
      find.text('Wearable device'),
      kIsWeb ? findsNothing : findsOneWidget,
    );
  });

  testWidgets('the wearable fallback screen explains itself', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WearableUnavailableScreen()),
    );

    expect(find.text('Unavailable in the browser'), findsOneWidget);
    expect(find.textContaining('Bluetooth'), findsOneWidget);
  });
}
