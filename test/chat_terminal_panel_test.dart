import 'package:agents_flutter/agents_flutter.dart';
import 'package:agents/agents.dart' show ShellResult;
import 'package:agents_app/ui/widgets/chat_terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  Widget host(ChatTerminalSession session, {Brightness? brightness}) =>
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff6750a4),
            brightness: brightness ?? Brightness.light,
          ),
        ),
        home: Scaffold(body: ChatTerminalPanel(session: session)),
      );

  const okResult = ShellResult(
    stdout: 'hi',
    stderr: '',
    exitCode: 0,
    duration: Duration(milliseconds: 5),
  );

  testWidgets('stays hidden until the first command echoes', (tester) async {
    final session = TerminalActivity().listen('conv-a');
    await tester.pumpWidget(host(session));

    expect(find.text('Terminal'), findsNothing);
    expect(find.byType(TerminalView), findsNothing);

    session.beginCommand('echo hi');
    await tester.pump();

    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets('header shows the running command, then the count', (
    tester,
  ) async {
    final session = TerminalActivity().listen('conv-a');
    session.beginCommand('echo hi');
    await tester.pumpWidget(host(session));

    expect(find.text('echo hi'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    session.completeCommand(okResult);
    await tester.pump();

    expect(find.text('1 command'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('collapses to the header strip and expands back', (tester) async {
    final session = TerminalActivity().listen('conv-a');
    session
      ..beginCommand('echo hi')
      ..completeCommand(okResult);
    await tester.pumpWidget(host(session));
    expect(find.byType(TerminalView), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse terminal'));
    await tester.pump();
    expect(find.byType(TerminalView), findsNothing);
    expect(find.text('Terminal'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand terminal'));
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets('clear hides the panel again', (tester) async {
    final session = TerminalActivity().listen('conv-a');
    session
      ..beginCommand('echo hi')
      ..completeCommand(okResult);
    await tester.pumpWidget(host(session));

    await tester.tap(find.byTooltip('Clear terminal'));
    await tester.pump();

    expect(find.text('Terminal'), findsNothing);
    expect(find.byType(TerminalView), findsNothing);
  });

  test('terminal theme derives from the Material color scheme', () {
    for (final brightness in Brightness.values) {
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xff6750a4),
        brightness: brightness,
      );
      final theme = chatTerminalThemeFor(scheme);
      expect(theme.background, scheme.surfaceContainerLowest);
      expect(theme.foreground, scheme.onSurface);
      expect(theme.cursor, scheme.primary);
    }
  });
}
