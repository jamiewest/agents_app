import 'dart:async';

import 'package:agents_app/ui/llm_exception.dart';
import 'package:agents_app/ui/views/llm_chat_view/llm_response.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LlmResponse', () {
    test('repeated cancel reports exactly one cancellation', () async {
      final controller = StreamController<String>();
      final done = <LlmException?>[];
      final response = LlmResponse(
        stream: controller.stream,
        onUpdate: (_) {},
        onDone: done.add,
      );

      response.cancel();
      response.cancel();
      response.cancel();

      expect(done, hasLength(1));
      expect(done.single, isA<LlmCancelException>());
      await controller.close();
    });

    test('cancel after natural completion is a no-op', () async {
      final controller = StreamController<String>();
      final done = <LlmException?>[];
      final updates = <String>[];
      final response = LlmResponse(
        stream: controller.stream,
        onUpdate: updates.add,
        onDone: done.add,
      );

      controller.add('hello');
      await controller.close();
      await Future<void>.delayed(Duration.zero);
      expect(updates, ['hello']);
      expect(done, [null]);

      // Before the idempotency fix this re-fired onDone with a cancel
      // (spurious snackbar + CANCEL text) or tripped an assert.
      response.cancel();
      expect(done, [null]);
    });

    test('a stream error reports the failure once, even if cancelled after',
        () async {
      final controller = StreamController<String>();
      final done = <LlmException?>[];
      final response = LlmResponse(
        stream: controller.stream,
        onUpdate: (_) {},
        onDone: done.add,
      );

      controller.addError(StateError('boom'));
      await Future<void>.delayed(Duration.zero);
      response.cancel();

      expect(done, hasLength(1));
      expect(done.single, isA<LlmFailureException>());
      await controller.close();
    });

    test('detach cancels upstream without reporting a result', () async {
      var upstreamCancelled = false;
      final controller = StreamController<String>(
        onCancel: () => upstreamCancelled = true,
      );
      final done = <LlmException?>[];
      final response = LlmResponse(
        stream: controller.stream,
        onUpdate: (_) {},
        onDone: done.add,
      );

      response.detach();
      await Future<void>.delayed(Duration.zero);

      expect(upstreamCancelled, isTrue);
      expect(done, isEmpty);

      // A late cancel after detach stays silent too.
      response.cancel();
      expect(done, isEmpty);
    });
  });
}
