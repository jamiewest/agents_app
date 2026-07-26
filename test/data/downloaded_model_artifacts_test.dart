// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/downloaded_model_artifacts.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_cpp_flutter/gguf.dart';

ModelConfig _model(String id, Map<String, String> settings) =>
    ModelConfig(id: id, sourceId: 'local', modelId: id, settings: settings);

void main() {
  // Deleting a downloaded artifact means naming the key the runtime stored it
  // under, and the runtime derives that from the URL alone. These tests pin
  // that derivation: a key computed any other way silently deletes nothing.
  group('downloadedArtifactKeysOf', () {
    const modelUrl =
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf';
    const mmprojUrl =
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/main/mmproj-F16.gguf';
    const draftUrl =
        'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/'
        'resolve/main/MTP/gemma-4-E4B-it-Q4_0-MTP.gguf';

    test('keys every declared artifact the way the runtime stores it', () {
      final keys = downloadedArtifactKeysOf(
        _model('m', const {
          'llama.modelSource': 'url',
          'llama.modelUrl': modelUrl,
          'llama.mmprojUrl': mmprojUrl,
          'llama.draftModelUrl': draftUrl,
        }),
      );

      expect(keys, <String>{
        stableArtifactFileName(Uri.parse(modelUrl)),
        stableArtifactFileName(Uri.parse(mmprojUrl)),
        stableArtifactFileName(Uri.parse(draftUrl)),
      });
    });

    test('treats a missing source setting as a URL model', () {
      // Models saved before `llama.modelSource` existed carry only a URL,
      // and `main.dart` still loads them as URL models — so their downloads
      // must still be reclaimable.
      expect(
        downloadedArtifactKeysOf(
          _model('legacy', const {'llama.modelUrl': modelUrl}),
        ),
        <String>{stableArtifactFileName(Uri.parse(modelUrl))},
      );
    });

    test('ignores picked-file models, which download nothing', () {
      expect(
        downloadedArtifactKeysOf(
          _model('picked', const {
            'llama.modelSource': 'file',
            'llama.modelFileName': 'local.gguf',
          }),
        ),
        isEmpty,
      );
    });

    test('ignores blank and unparseable URLs', () {
      expect(
        downloadedArtifactKeysOf(
          _model('m', const {
            'llama.modelSource': 'url',
            'llama.modelUrl': modelUrl,
            'llama.mmprojUrl': '   ',
            'llama.draftModelUrl': 'http://[',
          }),
        ),
        <String>{stableArtifactFileName(Uri.parse(modelUrl))},
      );
    });

    test('ignores non-llama models', () {
      expect(
        downloadedArtifactKeysOf(_model('claude', const {})),
        isEmpty,
      );
    });
  });

  group('downloadedArtifactKeysFor', () {
    test('unions the keep-set across every configured model', () {
      const first = 'https://example.com/a.gguf';
      const second = 'https://example.com/b.gguf';

      expect(
        downloadedArtifactKeysFor([
          _model('a', const {'llama.modelUrl': first}),
          _model('b', const {'llama.modelUrl': second}),
          // Two models pointing at one URL share the artifact; the key set
          // must collapse them, or deleting one would orphan the other.
          _model('c', const {'llama.modelUrl': first}),
        ]),
        <String>{
          stableArtifactFileName(Uri.parse(first)),
          stableArtifactFileName(Uri.parse(second)),
        },
      );
    });
  });
}
