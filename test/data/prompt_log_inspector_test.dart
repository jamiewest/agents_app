import 'package:agents_app/data/prompt_log_inspector.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:llama_cpp_flutter/chat.dart' show PromptSnapshot;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PromptLogInspector', () {
    test('mirrors the wire snapshot and sampling tags into the log', () {
      final log = PromptLog();
      final inspector = PromptLogInspector(log);

      inspector.record(
        PromptSnapshot(
          text: '<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n',
          stopSequences: const <String>['<|im_end|>'],
          maxTokens: 256,
          temperature: 0.7,
          topK: 40,
          topP: 0.95,
          seed: 1,
          imageCount: 0,
          contextSize: 4096,
          capturedAt: DateTime(2026),
        ),
      );

      expect(log.entries, hasLength(1));
      final entry = log.entries.single;
      expect(entry.title, 'local llama');
      expect(entry.body, contains('<|im_start|>user'));
      expect(entry.tags, contains('temp 0.7'));
      expect(entry.tags, contains('4096 ctx'));
      expect(entry.tags, contains('stop <|im_end|>'));
      // The base inspector still exposes the latest snapshot.
      expect(inspector.latest?.text, contains('hi'));
    });
  });
}
