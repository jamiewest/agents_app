/// Speech-to-text over archived WAV captures.
///
/// [AppleSpeechEngine] is the mac/iOS on-device engine; whisper.cpp can
/// implement the same interface later without touching the pipeline.
library;

import 'package:flutter/services.dart';

/// Transcribes one audio file to text.
abstract interface class TranscriptionEngine {
  /// Transcribes the WAV at [path]; returns the (possibly empty) text.
  ///
  /// Throws on engine failure — the processor retries per its policy.
  Future<String> transcribe(String path);
}

/// On-device transcription via Apple's Speech framework (SFSpeechRecognizer),
/// bridged by `SpeechBridge` in the platform Runner.
class AppleSpeechEngine implements TranscriptionEngine {
  /// Creates an [AppleSpeechEngine].
  const AppleSpeechEngine();

  static const _channel = MethodChannel('agents_app/wearable_speech');

  @override
  Future<String> transcribe(String path) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'transcribeFile',
      {'path': path},
    );
    return result?['text'] as String? ?? '';
  }
}
