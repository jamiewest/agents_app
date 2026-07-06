// Widget tests for the Logs & diagnostics screen: records render, display
// filters narrow the list, and capture levels adjust at runtime.

import 'package:agents_app/data/prompt_log.dart';
import 'package:agents_app/ui/screens/logging_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceProvider _buildServices() {
  final services = ServiceCollection()
    ..addLogging()
    ..addAppLogging()
    ..addSingleton<PromptLog>((_) => PromptLog());
  return services.buildServiceProvider();
}

Future<void> _pumpScreen(WidgetTester tester, ServiceProvider services) async {
  await tester.pumpWidget(MaterialApp(home: LoggingScreen(services: services)));
}

void main() {
  testWidgets('shows captured records and capture controls', (tester) async {
    // Arrange
    final services = _buildServices();
    services
        .getRequiredService<LoggerFactory>()
        .createLogger('Widget.Test')
        .logInformation('hello from the log');

    // Act
    await _pumpScreen(tester, services);

    // Assert
    expect(find.text('Capture levels'), findsOneWidget);
    expect(find.textContaining('hello from the log'), findsOneWidget);
    expect(find.textContaining('Widget.Test'), findsOneWidget);
  });

  testWidgets('search filters the visible records', (tester) async {
    // Arrange
    final services = _buildServices();
    final logger = services.getRequiredService<LoggerFactory>().createLogger(
      'Widget.Test',
    );
    logger.logInformation('alpha event');
    logger.logInformation('beta event');
    await _pumpScreen(tester, services);

    // Act
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();

    // Assert
    expect(find.textContaining('alpha event'), findsOneWidget);
    expect(find.textContaining('beta event'), findsNothing);
  });

  testWidgets('clear empties the list', (tester) async {
    // Arrange
    final services = _buildServices();
    services
        .getRequiredService<LoggerFactory>()
        .createLogger('Widget.Test')
        .logWarning('stale record');
    await _pumpScreen(tester, services);

    // Act
    await tester.tap(find.byTooltip('Clear log'));
    await tester.pump();

    // Assert
    expect(find.textContaining('stale record'), findsNothing);
    expect(find.text('No log records match.'), findsOneWidget);
  });

  testWidgets('records below the capture level are not stored', (tester) async {
    // Arrange: default capture level is information.
    final services = _buildServices();
    services
        .getRequiredService<LoggerFactory>()
        .createLogger('Widget.Test')
        .logDebug('too detailed');

    // Act
    await _pumpScreen(tester, services);

    // Assert
    expect(find.textContaining('too detailed'), findsNothing);
  });

  testWidgets('Prompts tab embeds the prompt inspector', (tester) async {
    // Arrange
    final services = _buildServices();
    await _pumpScreen(tester, services);

    // Act
    await tester.tap(find.text('Prompts'));
    await tester.pumpAndSettle();

    // Assert
    expect(find.text('No prompts captured yet'), findsOneWidget);
  });
}
