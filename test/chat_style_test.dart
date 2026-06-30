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
}

TextTheme _textTheme(String fontFamily) => TextTheme(
  displaySmall: TextStyle(fontFamily: fontFamily),
  headlineSmall: TextStyle(fontFamily: fontFamily),
  titleLarge: TextStyle(fontFamily: fontFamily),
  bodyLarge: TextStyle(fontFamily: fontFamily),
  bodyMedium: TextStyle(fontFamily: fontFamily),
  bodySmall: TextStyle(fontFamily: fontFamily),
);
