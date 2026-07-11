import 'package:agents_app/ui/providers/providers.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage notifications', () {
    test('append notifies once per chunk and grows the text', () {
      final message = ChatMessage.llm();
      var notified = 0;
      message.addListener(() => notified++);

      message.append('Hel');
      message.append('lo');

      expect(message.text, 'Hello');
      expect(notified, 2);
    });

    test('toolActivity notifies on change and skips same-value writes', () {
      final message = ChatMessage.llm();
      var notified = 0;
      message.addListener(() => notified++);

      message.toolActivity = 'search';
      message.toolActivity = 'search';
      message.toolActivity = null;

      expect(notified, 2);
    });

    test('isGenerating notifies on change and skips same-value writes', () {
      final message = ChatMessage.llm();
      var notified = 0;
      message.addListener(() => notified++);

      message.isGenerating = true;
      message.isGenerating = true;
      message.isGenerating = false;

      expect(notified, 2);
    });

    test('usage setter and addUsage both notify', () {
      final message = ChatMessage.llm();
      var notified = 0;
      message.addListener(() => notified++);

      message.usage = ai.UsageDetails(inputTokenCount: 10);
      expect(notified, 1);

      message.addUsage(ai.UsageDetails(inputTokenCount: 5, outputTokenCount: 2));
      expect(notified, 2);
      expect(message.usage!.inputTokenCount, 15);
      expect(message.usage!.outputTokenCount, 2);
    });

    test('addUsage accumulates from empty and notifies each time', () {
      final message = ChatMessage.llm();
      var notified = 0;
      message.addListener(() => notified++);

      message.addUsage(ai.UsageDetails(outputTokenCount: 3));
      message.addUsage(ai.UsageDetails(outputTokenCount: 4));

      expect(notified, 2);
      expect(message.usage!.outputTokenCount, 7);
    });

    test('turn timing fields stay plain (no notification)', () {
      final message = ChatMessage.llm();
      var notified = 0;
      message.addListener(() => notified++);

      message.turnStartedAt = DateTime.utc(2026, 7, 10);
      message.turnDuration = const Duration(seconds: 3);

      expect(notified, 0);
    });

    test('JSON round-trip is unchanged', () {
      final message = ChatMessage.user('hello there', const []);
      final restored = ChatMessage.fromJson(message.toJson());

      expect(restored.text, 'hello there');
      expect(restored.origin, message.origin);
      expect(restored.toJson(), message.toJson());
    });
  });
}
