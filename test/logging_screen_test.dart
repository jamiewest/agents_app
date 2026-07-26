// Widget tests for the Logs & diagnostics section: the Events body renders
// records, filters, and capture controls; the section shell switches between
// the Events and Prompts tabs.

import 'package:agents_app/data/prompt_log.dart';
import 'package:agents_app/ui/screens/logging_screen.dart';
import 'package:agents_app/ui/widgets/draggable_separator.dart';
import 'package:agents_app/ui/widgets/prompt_inspector_panel.dart';
import 'package:agents_app/ui/widgets/settings_section_shell.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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

    testWidgets('the side panel starts at the chats sidebar width and '
        'resizes by dragging the separator', (tester) async {
      final services = _loggingServices();
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_loggingApp(services));
      await tester.pumpAndSettle();

      // The separator sits at the panel's trailing edge, so its offset is
      // the rendered panel width.
      expect(
        _panelWidth(tester),
        SettingsSectionShell.defaultNavWidth,
      );

      await tester.drag(find.byType(DraggableSeparator), const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(
        _panelWidth(tester),
        SettingsSectionShell.defaultNavWidth + 60,
      );

      // Past the maximum the panel stops growing.
      await tester.drag(find.byType(DraggableSeparator), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(_panelWidth(tester), SettingsSectionShell.maxNavWidth);
    });

    testWidgets('the panel falls back to its floor when the window cannot '
        'afford the stored width', (tester) async {
      final services = _loggingServices();
      // 600 is the side-nav threshold: too narrow to give the panel its
      // 300pt default and the content its 360pt minimum.
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_loggingApp(services));
      await tester.pumpAndSettle();

      expect(_panelWidth(tester), SettingsSectionShell.minNavWidth);
      // The upper-case heading is the widest thing in the panel; it must
      // ellipsize rather than overflow at the floor.
      expect(find.text('LOGS & DIAGNOSTICS'), findsOneWidget);
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
      expect(find.text('LOGS & DIAGNOSTICS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// The rendered width of the section shell's side panel, read from where the
/// resize handle sits.
double _panelWidth(WidgetTester tester) =>
    tester.getTopLeft(find.byType(DraggableSeparator)).dx;

/// A minimal router with just the Logs section shell — the same branch
/// structure the app router uses, without the full app around it.
Widget _loggingApp(ServiceProvider services) => MaterialApp.router(
  routerConfig: GoRouter(
    initialLocation: '/settings/logging',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => SettingsSectionShell(
          title: 'Logs & diagnostics',
          icon: LucideIcons.receiptText300,
          destinations: loggingDestinations,
          shell: shell,
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
    ],
  ),
);
