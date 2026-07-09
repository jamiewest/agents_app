import 'dart:io';
import 'dart:typed_data';

import 'package:agents_app/wearable/pipeline/silence_gate.dart';
import 'package:agents_app/wearable/pipeline/transcription_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a 16-bit PCM mono WAV around [samples].
Uint8List wavBytes(List<int> samples, {int sampleRate = 16000}) {
  final dataLen = samples.length * 2;
  final bytes = Uint8List(44 + dataLen);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + 4, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, 36 + dataLen, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes;
}

/// One second of a ±[amplitude] square wave (RMS == amplitude).
List<int> squareWave(int amplitude, {int samples = 16000}) => [
  for (var i = 0; i < samples; i++) i.isEven ? amplitude : -amplitude,
];

class _RecordingEngine implements TranscriptionEngine {
  final List<String> calls = [];

  @override
  Future<String> transcribe(String path) async {
    calls.add(path);
    return 'a transcript';
  }
}

void main() {
  late Directory dir;
  const gate = SilenceGate();

  setUp(() => dir = Directory.systemTemp.createTempSync('silence_gate'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  group('SilenceGate', () {
    test('all-zero audio is silent', () async {
      final path = await write('zero.wav', wavBytes(List.filled(16000, 0)));
      expect(await gate.isSilent(path), isTrue);
    });

    test('mic noise floor below the threshold is silent', () async {
      // ±40 square wave is about -58 dBFS, under the -45 dBFS default.
      final path = await write('noise.wav', wavBytes(squareWave(40)));
      expect(await gate.isSilent(path), isTrue);
    });

    test('speech-level audio is not silent', () async {
      // ±3000 is about -21 dBFS, comfortably over the threshold.
      final path = await write('speech.wav', wavBytes(squareWave(3000)));
      expect(await gate.isSilent(path), isFalse);
    });

    test('a short burst inside a mostly-silent file is not silent', () async {
      final samples = List.filled(16000, 0);
      samples.setRange(12000, 16000, squareWave(3000, samples: 4000));
      final path = await write('burst.wav', wavBytes(samples));
      expect(await gate.isSilent(path), isFalse);
    });

    test('a missing file is treated as not silent', () async {
      expect(await gate.isSilent('${dir.path}/nope.wav'), isFalse);
    });

    test('a non-WAV file is treated as not silent', () async {
      final path = await write('junk.wav', List.filled(64, 0x42));
      expect(await gate.isSilent(path), isFalse);
    });

    test('a truncated data chunk is scanned as far as it goes', () async {
      final full = wavBytes(squareWave(3000));
      final path = await write('cut.wav', full.sublist(0, full.length ~/ 2));
      expect(await gate.isSilent(path), isFalse);
    });
  });

  group('SilenceGatedEngine', () {
    test(
      'answers dead air with an empty transcript, inner untouched',
      () async {
        final path = await write('quiet.wav', wavBytes(squareWave(40)));
        final inner = _RecordingEngine();
        final engine = SilenceGatedEngine(inner);
        expect(await engine.transcribe(path), isEmpty);
        expect(inner.calls, isEmpty);
      },
    );

    test('delegates captures with signal to the inner engine', () async {
      final path = await write('loud.wav', wavBytes(squareWave(3000)));
      final inner = _RecordingEngine();
      final engine = SilenceGatedEngine(inner);
      expect(await engine.transcribe(path), 'a transcript');
      expect(inner.calls, [path]);
    });

    test('delegates unreadable files so retry semantics stay with the '
        'real engine', () async {
      final inner = _RecordingEngine();
      final engine = SilenceGatedEngine(inner);
      await engine.transcribe('${dir.path}/gone.wav');
      expect(inner.calls, hasLength(1));
    });
  });
}
