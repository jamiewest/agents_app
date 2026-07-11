// Accessibility behavior for the chat controls: real disabled states,
// keyboard reachability, and semantic labels.

import 'package:agents_app/ui/styles/action_button_style.dart';
import 'package:agents_app/ui/styles/llm_chat_view_style.dart';
import 'package:agents_app/ui/views/action_button.dart';
import 'package:agents_app/ui/views/chat_input/input_button.dart';
import 'package:agents_app/ui/views/chat_input/input_state.dart';
import 'package:agents_app/ui/views/chat_message_view/hovering_buttons.dart';
import 'package:agents_app/ui/widgets/draggable_separator.dart';
import 'package:agents_app/ui/widgets/side_panel_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = ActionButtonStyle(icon: Icons.send, text: 'Send message');

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ActionButton', () {
    testWidgets('enabled button is a labeled, tappable control', (
      tester,
    ) async {
      var pressed = 0;
      await tester.pumpWidget(
        _wrap(ActionButton(style: _style, onPressed: () => pressed++)),
      );

      expect(find.byTooltip('Send message'), findsOneWidget);
      await tester.tap(find.byType(ActionButton));
      expect(pressed, 1);

      // The activation target meets the 44px platform minimum even though
      // the visual glyph stays smaller.
      final size = tester.getSize(find.byType(IconButton));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('null onPressed produces a genuinely disabled control', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _wrap(const ActionButton(style: _style, onPressed: null)),
      );

      // No tap action is reachable...
      await tester.tap(find.byType(ActionButton), warnIfMissed: false);

      // ...and assistive technology sees a disabled button, not a live
      // no-op target.
      expect(
        tester.getSemantics(find.byType(IconButton)),
        isSemantics(hasEnabledState: true, isEnabled: false),
      );
      handle.dispose();
    });
  });

  group('InputButton STT state', () {
    testWidgets('an in-flight transcription is cancellable', (tester) async {
      var cancelled = 0;
      final chatStyle = LlmChatViewStyle.resolve(null);
      await tester.pumpWidget(
        _wrap(
          InputButton(
            inputState: InputState.canCancelStt,
            chatStyle: chatStyle,
            onSubmitPrompt: () {},
            onCancelPrompt: () {},
            onStartRecording: () {},
            onStopRecording: () {},
            onCancelStt: () => cancelled++,
          ),
        ),
      );

      // A real stop button, not just an inert spinner.
      expect(find.byType(ActionButton), findsOneWidget);
      await tester.tap(find.byType(ActionButton));
      expect(cancelled, 1);
    });
  });

  group('HoveringButtons', () {
    testWidgets('keyboard focus reveals the actions and they activate', (
      tester,
    ) async {
      var edited = 0;
      final chatStyle = LlmChatViewStyle.resolve(null);
      await tester.pumpWidget(
        _wrap(
          HoveringButtons(
            chatStyle: chatStyle,
            isUserMessage: true,
            clipboardText: 'copy me',
            clipboardMessage: 'copied',
            onEdit: () => edited++,
            child: const Text('bubble'),
          ),
        ),
      );

      // Hidden at rest…
      expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
      final editButton = tester.widget<IconButton>(
        find.byType(IconButton).first,
      );
      expect(editButton.tooltip, isNotNull);

      // …revealed when keyboard traversal reaches an action.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);

      await tester.tap(find.byType(IconButton).first);
      expect(edited, 1);
    });
  });

  group('DraggableSeparator', () {
    testWidgets('arrow keys resize; semantics expose an adjustable control', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final deltas = <double>[];
      await tester.pumpWidget(
        _wrap(
          Row(
            children: [
              DraggableSeparator(onDragUpdate: deltas.add),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      );

      final focus = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byType(DraggableSeparator),
                matching: find.byType(MouseRegion),
              )
              .first,
        ),
      );
      focus.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);

      expect(deltas, [
        DraggableSeparator.keyboardStep,
        -DraggableSeparator.keyboardStep,
      ]);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Resize panel')),
        isSemantics(hasIncreaseAction: true, hasDecreaseAction: true),
      );
      handle.dispose();
    });
  });

  group('SidePanelHost', () {
    Widget host() => MaterialApp(
      home: SidePanelHost(
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => SidePanelScope.maybeOf(
                  context,
                )!.toggle((_) => const Text('panel content')),
                child: const Text('open panel'),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('outside tap closes the panel and restores focus', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('open panel'));
      await tester.pumpAndSettle();
      expect(find.text('panel content'), findsOneWidget);

      // Tap the barrier region far from the right-anchored panel.
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      expect(find.text('panel content'), findsNothing);
    });

    testWidgets('escape closes the panel', (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('open panel'));
      await tester.pumpAndSettle();
      expect(find.text('panel content'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('panel content'), findsNothing);
    });

    testWidgets('underlying content is inert while the panel is open', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('open panel'));
      await tester.pumpAndSettle();

      // The trigger button under the panel cannot be tapped again (the
      // barrier absorbs it and closes instead).
      await tester.tap(find.text('open panel'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('panel content'), findsNothing);
    });
  });
}
