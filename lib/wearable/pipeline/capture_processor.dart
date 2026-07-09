/// Drains pending archived captures through their processors.
library;

import 'dart:developer' as developer;

import 'capture_archive.dart';
import 'image_describer.dart' show DescriberUnavailableException;
import 'transcription_engine.dart';

/// Describes one image file (local multimodal model). Optional until the
/// describe path is wired; JPEGs stay pending without one.
abstract interface class ImageDescriber {
  /// Returns a text description of the image at [path].
  Future<String> describe(String path);
}

/// Processes pending captures one at a time (transcription is heavyweight;
/// serialization keeps memory and thermals sane).
class CaptureProcessor {
  /// Creates a [CaptureProcessor].
  CaptureProcessor({
    required this.archive,
    required this.transcription,
    this.imageDescriber,
    this.onProcessed,
    this.onBatchComplete,
  });

  /// The durable archive being drained.
  final CaptureArchive archive;

  /// Engine for WAV captures.
  final TranscriptionEngine transcription;

  /// Engine for JPEG captures; JPEGs are skipped while `null`.
  final ImageDescriber? imageDescriber;

  /// Called after each capture completes (id, result text).
  final void Function(ArchivedCapture capture, String text)? onProcessed;

  /// Called once per [processPending] run that produced results — the
  /// distillation trigger.
  final void Function(List<ArchivedCapture> processed)? onBatchComplete;

  bool _running = false;

  /// Whether a drain run is in progress.
  bool get isRunning => _running;

  /// Processes every currently-pending capture once. Failures are recorded
  /// (with retry budget) and do not stop the batch. Reentrant calls no-op.
  Future<void> processPending() async {
    if (_running) return;
    _running = true;
    try {
      final pending = await archive.pending();
      final processed = <ArchivedCapture>[];
      for (final capture in pending) {
        final handled = await _process(capture);
        if (handled != null) {
          processed.add(handled);
        }
      }
      if (processed.isNotEmpty) {
        onBatchComplete?.call(processed);
      }
    } finally {
      _running = false;
    }
  }

  Future<ArchivedCapture?> _process(ArchivedCapture capture) async {
    try {
      final String text;
      switch (capture.kind) {
        case 'wav':
          text = await transcription.transcribe(capture.filePath);
        case 'jpg':
          final describer = imageDescriber;
          if (describer == null) return null;
          text = await describer.describe(capture.filePath);
        default:
          return null;
      }
      await archive.markDone(capture.id, text);
      onProcessed?.call(capture, text);
      return capture;
    } on DescriberUnavailableException {
      // No describer agent configured yet: leave the image pending without
      // burning a retry; it processes once the user selects one.
      return null;
    } catch (e, s) {
      developer.log(
        'processing ${capture.id} failed',
        name: 'wearable.pipeline',
        error: e,
        stackTrace: s,
      );
      await archive.markFailed(capture.id, e.toString());
      return null;
    }
  }
}
