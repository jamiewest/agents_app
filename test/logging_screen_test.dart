// Widget tests for the Logs & diagnostics section: the Events body renders
// records, filters, and capture controls; the section shell switches between
// the Events and Prompts tabs.

import 'package:agents_app/app/app_shell.dart';
import 'package:agents_app/ui/screens/logging_screen.dart';
import 'package:agents_app/ui/widgets/draggable_separator.dart';
import 'package:agents_app/ui/widgets/prompt_inspector_panel.dart';
import 'package:agents_app/ui/widgets/settings_section_shell.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

ServiceProvider _loggingServices() {
  final services = ServiceCollection()
    ..addLogging()
    ..addAppLogging()
    ..addSingleton<PromptLog>((_) => PromptLog());
  return services.buildServiceProvider();
}

Future<void> _pumpEvents(WidgetTester tester, ServiceProvider services) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LoggingEventsBody(services: services)),
      ),
    );

void main() {
  group('LoggingEventsBody', () {
    testWidgets('shows captured records and capture controls', (tester) async {
      final services = _loggingServices();
      services
          .getRequiredService<LoggerFactory>()
          .createLogger('Widget.Test')
          .logInformation('hello from the log');

      await _pumpEvents(tester, services);

      expect(find.text('Capture levels'), findsOneWidget);
      expect(find.textContaining('hello from the log'), findsOneWidget);
      expect(find.textContaining('Widget.Test'), findsOneWidget);
    });

    testWidgets('search filters the visible records', (tester) async {
      final services = _loggingServices();
      final logger = services.getRequiredService<LoggerFactory>().createLogger(
        'Widget.Test',
      );
      logger.logInformation('alpha event');
      logger.logInformation('beta event');
      await _pumpEvents(tester, services);

      await tester.enterText(find.byType(TextField), 'alpha');
      await tester.pump();

      expect(find.textContaining('alpha event'), findsOneWidget);
      expect(find.textContaining('beta event'), findsNothing);
    });

    testWidgets('clear empties the list', (tester) async {
      final services = _loggingServices();
      services
          .getRequiredService<LoggerFactory>()
          .createLogger('Widget.Test')
          .logWarning('stale record');
      await _pumpEvents(tester, services);

      await tester.tap(find.byTooltip('Clear log'));
      await tester.pump();

      expect(find.textContaining('stale record'), findsNothing);
      expect(find.text('No log records match.'), findsOneWidget);
    });

    testWidgets('records below the capture level are not stored', (
      tester,
    ) async {
      final services = _loggingServices();
      services
          .getRequiredService<LoggerFactory>()
          .createLogger('Widget.Test')
          .logDebug('too detailed');

      await _pumpEvents(tester, services);

      expect(find.textContaining('too detailed'), findsNothing);
    });
  });

  group('Logs & diagnostics section shell', () {
    testWidgets('the nav persists while switching Events and Prompts', (
      tester,
    ) async {
      final services = _loggingServices();
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_loggingApp(services));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsSectionShell), findsOneWidget);
      expect(find.text('Capture levels'), findsOneWidget);

      await tester.tap(find.text('Prompts'));
      await tester.pumpAndSettle();

      // Same shell, content swapped to the prompt inspector.
      expect(find.byType(SettingsSectionShell), findsOneWidget);
      expect(find.byType(PromptInspectorPanel), findsOneWidget);

      await tester.tap(find.text('Events'));
      await tester.pumpAndSettle();
      expect(find.text('Capture levels'), findsOneWidget);
    });

    testWidgets('the section wears the Settings header, not a panel', (
      tester,
    ) async {
      final services = _loggingServices();
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_loggingApp(services));
      await tester.pumpAndSettle();

      // The resizable side panel is gone: a section looks like the Settings
      // page it was opened from at every width.
      expect(find.byType(DraggableSeparator), findsNothing);
      expect(find.text('Logs & diagnostics'), findsOneWidget);
      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the compact layout keeps the segmented nav above the '
        'content', (tester) async {
      final services = _loggingServices();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_loggingApp(services));
      await tester.pumpAndSettle();

      expect(find.byType(DraggableSeparator), findsNothing);
      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(find.text('Logs & diagnostics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the header leads with the back control, not the drawer '
        'button', (tester) async {
      final services = _loggingServices();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // How the section actually mounts on compact: inside the app shell,
      // which offers a drawer. A sub-page still leads with back — the
      // drawer is one tap further up, on the Settings page itself.
      var opened = 0;
      await tester.pumpWidget(
        _loggingApp(services, onOpenDrawer: () => opened++),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SettingsBackButton), findsOneWidget);
      expect(find.byTooltip('Menu'), findsNothing);
      expect(find.text('Logs & diagnostics'), findsOneWidget);
      expect(opened, 0);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A minimal router with just the Logs section shell — the same branch
/// structure the app router uses, without the full app around it.
///
/// Pass [onOpenDrawer] to stand in for the app shell's drawer, which is what
/// the section sees on compact widths in the real app.
Widget _loggingApp(ServiceProvider services, {VoidCallback? onOpenDrawer}) =>
    MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/settings/logging',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) => AppShellScope(
              openDrawer: onOpenDrawer,
              child: SettingsSectionShell(
                title: 'Logs & diagnostics',
                destinations: loggingDestinations,
                shell: shell,
                backLocation: '/settings',
              ),
            ),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/settings/logging',
                    builder: (context, state) =>
                        LoggingEventsBody(services: services),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/settings/logging/prompts',
                    builder: (context, state) =>
                        LoggingPromptsBody(services: services),
                  ),
                ],
              ),
            ],
          ),
          // Stands in for the settings home the back button returns to.
          GoRoute(
            path: '/settings',
            builder: (context, state) =>
                const Scaffold(body: Text('Settings home')),
          ),
        ],
      ),
    );
