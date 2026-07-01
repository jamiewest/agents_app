import 'dart:async';

import 'package:agents_app/ui/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TokenSmoother', () {
    test('emits bursty chunks as paced graphemes', () async {
      final chunks = await Stream.fromIterable([
        'abc',
      ]).smoothed(tick: _tick, window: _wideWindow).toList();

      expect(chunks, ['a', 'b', 'c']);
    });

    test('keeps multi-codepoint grapheme clusters intact', () async {
      final chunks = await Stream.fromIterable([
        '👨‍👩‍👧‍👦!',
      ]).smoothed(tick: _tick, window: _wideWindow).toList();

      expect(chunks, ['👨‍👩‍👧‍👦', '!']);
    });

    test('emits atomic chunks whole', () async {
      final chunks = await Stream.fromIterable(['<marker>'])
          .smoothed(
            tick: _tick,
            window: _wideWindow,
            atomic: (chunk) => chunk.startsWith('<'),
          )
          .toList();

      expect(chunks, ['<marker>']);
    });

    test('waits for buffered text to drain before completing', () async {
      final controller = StreamController<String>();
      final done = Completer<void>();
      var isDone = false;
      final chunks = <String>[];
      controller.stream
          .smoothed(tick: _tick, window: _wideWindow)
          .listen(
            chunks.add,
            onDone: () {
              isDone = true;
              done.complete();
            },
          );

      controller.add('ab');
      await controller.close();

      expect(isDone, isFalse);

      await done.future;

      expect(chunks, ['a', 'b']);
      expect(isDone, isTrue);
    });

    test('cancels the upstream subscription when canceled', () async {
      var canceled = false;
      final controller = StreamController<String>(
        onCancel: () {
          canceled = true;
        },
      );
      final sub = controller.stream
          .smoothed(tick: _tick, window: _wideWindow)
          .listen((_) {});

      await sub.cancel();

      expect(canceled, isTrue);
      await controller.close();
    });

    test('propagates upstream errors and drops buffered text', () async {
      final controller = StreamController<String>();
      final error = Completer<Object>();
      final chunks = <String>[];
      controller.stream
          .smoothed(tick: _tick, window: _wideWindow)
          .listen(chunks.add, onError: error.complete);

      controller.add('abc');
      controller.addError(StateError('boom'));

      expect(await error.future, isA<StateError>());
      expect(chunks, isEmpty);
      await controller.close();
    });
  });
}

const _tick = Duration(milliseconds: 1);
const _wideWindow = Duration(milliseconds: 100);
