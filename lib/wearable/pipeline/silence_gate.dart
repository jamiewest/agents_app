/// Pre-transcription dead-air detection over archived WAV captures.
///
/// Wearable audio segments are fixed-length, so most of a quiet day is
/// silence. Detecting that is plain arithmetic — a windowed RMS scan over
/// the PCM samples — and far cheaper than the speech-recognition pass it
/// avoids.
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'transcription_engine.dart';

/// Detects whether a 16-bit PCM WAV contains any audible signal.
class SilenceGate {
  /// Creates a [SilenceGate].
  const SilenceGate({this.thresholdDbfs = -45.0, this.windowMs = 300});

  /// RMS level, in dBFS, that at least one window must reach for the file
  /// to count as signal.
  ///
  /// The default sits between a quiet-room MEMS mic noise floor (roughly
  /// -55 dBFS and below) and conversational speech (-35 dBFS and above).
  /// Lower it (more negative) if real speech is being skipped; raise it if
  /// noise-only captures keep reaching transcription.
  final double thresholdDbfs;

  /// RMS window length in milliseconds.
  final int windowMs;

  /// Whether every [windowMs] window of the WAV at [path] stays below
  /// [thresholdDbfs].
  ///
  /// Permissive by design: unreadable or non-16-bit-PCM files report
  /// `false` (not silent), so a gate misjudgment can never discard audio —
  /// at worst the file takes a transcription pass it didn't need.
  Future<bool> isSilent(String path) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on IOException {
      return false;
    }
    final pcm = _pcmInfo(bytes);
    if (pcm == null) return false;
    final sampleCount = pcm.length ~/ 2;
    if (sampleCount == 0) return true;

    final thresholdRms =
        32768.0 * math.pow(10.0, thresholdDbfs / 20.0).toDouble();
    final windowSamples = math.max(
      1,
      pcm.sampleRate * pcm.channels * windowMs ~/ 1000,
    );
    final data = ByteData.sublistView(
      bytes,
      pcm.offset,
      pcm.offset + sampleCount * 2,
    );
    var sumSquares = 0.0;
    var windowFill = 0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little).toDouble();
      sumSquares += sample * sample;
      windowFill++;
      final isLast = i == sampleCount - 1;
      if (windowFill == windowSamples || isLast) {
        if (math.sqrt(sumSquares / windowFill) > thresholdRms) {
          return false;
        }
        sumSquares = 0.0;
        windowFill = 0;
      }
    }
    return true;
  }

  /// Locates the PCM samples inside a RIFF/WAVE container; null when the
  /// file is not a well-formed 16-bit PCM WAV.
  ({int sampleRate, int channels, int offset, int length})? _pcmInfo(
    Uint8List bytes,
  ) {
    if (bytes.length < 12 ||
        !_tagAt(bytes, 0, 'RIFF') ||
        !_tagAt(bytes, 8, 'WAVE')) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    int? sampleRate;
    int? channels;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (_tagAt(bytes, offset, 'fmt ') && body + 16 <= bytes.length) {
        final audioFormat = data.getUint16(body, Endian.little);
        final bitsPerSample = data.getUint16(body + 14, Endian.little);
        if (audioFormat != 1 || bitsPerSample != 16) return null;
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
      } else if (_tagAt(bytes, offset, 'data')) {
        if (sampleRate == null || channels == null || channels == 0) {
          return null;
        }
        // Tolerate a truncated final chunk (e.g. a capture cut by power
        // loss): scan whatever samples are actually present.
        final length = math.min(chunkSize, bytes.length - body);
        return (
          sampleRate: sampleRate,
          channels: channels,
          offset: body,
          length: length,
        );
      }
      offset = body + chunkSize + (chunkSize & 1);
    }
    return null;
  }

  static bool _tagAt(Uint8List bytes, int offset, String tag) {
    for (var i = 0; i < 4; i++) {
      if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
    }
    return true;
  }
}

/// A [TranscriptionEngine] that answers dead-air captures with an empty
/// transcript instead of running [inner].
///
/// The empty result flows through the normal pipeline: the capture is
/// marked done and the distillation batch filter drops it.
class SilenceGatedEngine implements TranscriptionEngine {
  /// Wraps [inner] behind [gate].
  const SilenceGatedEngine(this.inner, {this.gate = const SilenceGate()});

  /// The engine that handles captures with signal.
  final TranscriptionEngine inner;

  /// The dead-air detector consulted before [inner].
  final SilenceGate gate;

  @override
  Future<String> transcribe(String path) async {
    if (await gate.isSilent(path)) {
      developer.log(
        'skipping transcription, dead air: $path',
        name: 'wearable.pipeline',
      );
      return '';
    }
    return inner.transcribe(path);
  }
}
