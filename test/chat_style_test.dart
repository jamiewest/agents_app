import 'package:agents_app/ui/strings/strings.dart';
import 'package:agents_app/ui/styles/styles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chat defaults inherit the host text theme', (tester) async {
    late LlmChatViewStyle resolved;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(textTheme: _textTheme('ExampleSans')),
        home: Builder(
          builder: (context) {
            resolved = LlmChatViewStyle.resolveFor(context, null);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(resolved.userMessageStyle!.textStyle!.fontFamily, 'ExampleSans');
    expect(resolved.chatInputStyle!.textStyle!.fontFamily, 'ExampleSans');
    expect(resolved.chatInputStyle!.hintStyle!.fontFamily, 'ExampleSans');
    expect(resolved.suggestionStyle!.textStyle!.fontFamily, 'ExampleSans');
    expect(
      resolved.fileAttachmentStyle!.filenameStyle!.fontFamily,
      'ExampleSans',
    );
    expect(
      resolved.fileAttachmentStyle!.filetypeStyle!.fontFamily,
      'ExampleSans',
    );
    expect(
      resolved.attachFileButtonStyle!.textStyle!.fontFamily,
      'ExampleSans',
    );

    final markdown = resolved.llmMessageStyle!.markdownStyle!;
    expect(markdown.p!.fontFamily, 'ExampleSans');
    expect(markdown.h1!.fontFamily, 'ExampleSans');
  });

  testWidgets('code styles use a monospace fallback', (tester) async {
    late LlmChatViewStyle resolved;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(textTheme: _textTheme('ExampleSans')),
        home: Builder(
          builder: (context) {
            resolved = LlmChatViewStyle.resolveFor(context, null);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(
      resolved.llmMessageStyle!.markdownStyle!.code!.fontFamily,
      'monospace',
    );
  });

  testWidgets('explicit text style overrides win over theme defaults', (
    tester,
  ) async {
    late LlmChatViewStyle resolved;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(textTheme: _textTheme('ExampleSans')),
        home: Builder(
          builder: (context) {
            resolved = LlmChatViewStyle.resolveFor(
              context,
              LlmChatViewStyle(
                userMessageStyle: const UserMessageStyle(
                  textStyle: TextStyle(fontFamily: 'OverrideSans'),
                ),
                llmMessageStyle: LlmMessageStyle(
                  markdownStyle: MarkdownStyleSheet(
                    code: TextStyle(fontFamily: 'OverrideMono'),
                  ),
                ),
              ),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(resolved.userMessageStyle!.textStyle!.fontFamily, 'OverrideSans');
    expect(
      resolved.llmMessageStyle!.markdownStyle!.code!.fontFamily,
      'OverrideMono',
    );
    expect(resolved.chatInputStyle!.textStyle!.fontFamily, 'ExampleSans');
  });

  group('material 3 color roles', () {
    for (final brightness in Brightness.values) {
      testWidgets('chat defaults map to scheme roles ($brightness)', (
        tester,
      ) async {
        final (resolved, scheme) = await _resolveUnder(tester, brightness);

        final userBubble =
            resolved.userMessageStyle!.decoration! as BoxDecoration;
        expect(userBubble.color, scheme.secondaryContainer);
        expect(
          resolved.userMessageStyle!.textStyle!.color,
          scheme.onSecondaryContainer,
        );

        final inputPill = resolved.chatInputStyle!.decoration! as BoxDecoration;
        expect(inputPill.color, scheme.surfaceContainerHigh);

        expect(resolved.progressIndicatorColor, scheme.onSurfaceVariant);

        final markdown = resolved.llmMessageStyle!.markdownStyle!;
        final codeBlock = markdown.codeblockDecoration! as BoxDecoration;
        expect(codeBlock.color, scheme.surfaceContainerHighest);
        expect(markdown.a!.color, scheme.primary);

        expect(resolved.submitButtonStyle!.iconColor, scheme.onPrimary);
        final submitBg =
            resolved.submitButtonStyle!.iconDecoration! as BoxDecoration;
        expect(submitBg.color, scheme.primary);
      });
    }

    testWidgets('user bubble has M3 asymmetric corners', (tester) async {
      final (resolved, _) = await _resolveUnder(tester, Brightness.light);

      final bubble = resolved.userMessageStyle!.decoration! as BoxDecoration;
      final radius = bubble.borderRadius! as BorderRadius;
      expect(radius.topRight, const Radius.circular(4));
      expect(radius.topLeft, const Radius.circular(20));
      expect(radius.bottomLeft, const Radius.circular(20));
      expect(radius.bottomRight, const Radius.circular(20));
    });

    testWidgets('light and dark resolve to different chat colors', (
      tester,
    ) async {
      final (light, _) = await _resolveUnder(tester, Brightness.light);
      final (dark, _) = await _resolveUnder(tester, Brightness.dark);

      Color bubble(LlmChatViewStyle style) =>
          (style.userMessageStyle!.decoration! as BoxDecoration).color!;
      Color input(LlmChatViewStyle style) =>
          (style.chatInputStyle!.decoration! as BoxDecoration).color!;

      expect(bubble(light), isNot(bubble(dark)));
      expect(input(light), isNot(input(dark)));
      expect(light.backgroundColor, isNot(dark.backgroundColor));
    });

    testWidgets('custom strings keep theme-derived button colors', (
      tester,
    ) async {
      final (resolved, scheme) = await _resolveUnder(
        tester,
        Brightness.dark,
        style: const LlmChatViewStyle(
          strings: LlmChatViewStrings(submitMessage: 'Send it'),
        ),
      );

      expect(resolved.submitButtonStyle!.text, 'Send it');
      expect(resolved.submitButtonStyle!.iconColor, scheme.onPrimary);
      final submitBg =
          resolved.submitButtonStyle!.iconDecoration! as BoxDecoration;
      expect(submitBg.color, scheme.primary);
    });
  });
}

Future<(LlmChatViewStyle, ColorScheme)> _resolveUnder(
  WidgetTester tester,
  Brightness brightness, {
  LlmChatViewStyle? style,
}) async {
  late LlmChatViewStyle resolved;
  late ColorScheme scheme;

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00658F),
          brightness: brightness,
        ),
      ),
      home: Builder(
        builder: (context) {
          scheme = Theme.of(context).colorScheme;
          resolved = LlmChatViewStyle.resolveFor(context, style);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  // MaterialApp animates theme changes across pumps; settle so the
  // builder captures the final theme, not a mid-lerp frame.
  await tester.pumpAndSettle();

  return (resolved, scheme);
}

TextTheme _textTheme(String fontFamily) => TextTheme(
  displaySmall: TextStyle(fontFamily: fontFamily),
  headlineSmall: TextStyle(fontFamily: fontFamily),
  titleLarge: TextStyle(fontFamily: fontFamily),
  bodyLarge: TextStyle(fontFamily: fontFamily),
  bodyMedium: TextStyle(fontFamily: fontFamily),
  bodySmall: TextStyle(fontFamily: fontFamily),
);
