import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:characters/characters.dart';

/// Whether [chunk] should be released whole rather than paced grapheme by
/// grapheme. The default treats every chunk as ordinary text.
typedef AtomicChunkPredicate = bool Function(String chunk);

bool _neverAtomic(String chunk) => false;

/// Re-paces a token stream into a steady, typewriter-style character stream.
///
/// LLM token streams often arrive in bursts, which makes streamed text jump
/// and stutter. [TokenSmoother] buffers incoming chunks and releases them one
/// grapheme at a time on a frame timer, with the release rate scaled to the
/// backlog. Lag behind the source is bounded by [window].
///
/// A chunk for which [atomic] returns true is never split; it is released whole
/// in a single emission. Use this for in-band markers or control sequences
/// that must not appear half-rendered.
///
/// The transformer is single-subscription. Cancelling the output subscription
/// cancels the upstream subscription, so stopping a generation propagates down
/// to the provider.
class TokenSmoother extends StreamTransformerBase<String, String> {
  /// Creates a token stream smoother.
  const TokenSmoother({
    this.tick = const Duration(milliseconds: 16),
    this.window = const Duration(milliseconds: 250),
    this.minRelease = 1,
    this.atomic = _neverAtomic,
  }) : assert(minRelease >= 1, 'minRelease must be at least 1');

  /// How often buffered output is released. One release budget per tick.
  final Duration tick;

  /// Target maximum lag behind the source.
  final Duration window;

  /// Minimum graphemes released per [tick] while the buffer is non-empty.
  final int minRelease;

  /// Decides which chunks are emitted whole instead of paced.
  final AtomicChunkPredicate atomic;

  @override
  Stream<String> bind(Stream<String> stream) {
    final framesPerWindow = math.max(
      1,
      (window.inMicroseconds / tick.inMicroseconds).ceil(),
    );

    final queue = Queue<String>();
    StreamSubscription<String>? upstream;
    Timer? timer;
    var sourceDone = false;
    late StreamController<String> controller;

    void emitBudget() {
      if (queue.isEmpty) return;
      final budget = math.max(
        minRelease,
        (queue.length / framesPerWindow).ceil(),
      );
      final out = StringBuffer();
      for (var i = 0; i < budget && queue.isNotEmpty; i++) {
        out.write(queue.removeFirst());
      }
      controller.add(out.toString());
    }

    void stopTimer() {
      timer?.cancel();
      timer = null;
    }

    void onTick(Timer _) {
      emitBudget();
      if (queue.isEmpty) {
        stopTimer();
        if (sourceDone) controller.close();
      }
    }

    void ensureTimer() {
      timer ??= Timer.periodic(tick, onTick);
    }

    void onData(String chunk) {
      if (chunk.isEmpty) return;
      if (atomic(chunk)) {
        queue.add(chunk);
      } else {
        for (final grapheme in chunk.characters) {
          queue.add(grapheme);
        }
      }
      ensureTimer();
    }

    void onDone() {
      sourceDone = true;
      if (queue.isEmpty) {
        stopTimer();
        controller.close();
      }
    }

    controller = StreamController<String>(
      onListen: () {
        upstream = stream.listen(
          onData,
          onError: (Object error, StackTrace stackTrace) {
            stopTimer();
            queue.clear();
            controller.addError(error, stackTrace);
          },
          onDone: onDone,
        );
      },
      onCancel: () {
        stopTimer();
        final sub = upstream;
        upstream = null;
        return sub?.cancel();
      },
    );

    return controller.stream;
  }
}

/// Convenience methods for smoothing text streams.
extension SmoothedStream on Stream<String> {
  /// Returns this stream re-paced by a [TokenSmoother].
  Stream<String> smoothed({
    Duration tick = const Duration(milliseconds: 16),
    Duration window = const Duration(milliseconds: 250),
    int minRelease = 1,
    AtomicChunkPredicate atomic = _neverAtomic,
  }) {
    return transform(
      TokenSmoother(
        tick: tick,
        window: window,
        minRelease: minRelease,
        atomic: atomic,
      ),
    );
  }
}
