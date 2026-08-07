// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;

import 'package:agents_app/features/local_models/local_model_disk.dart';
import 'package:agents_app/features/local_models/local_model_store_io.dart';
import 'package:agents_flutter/agents_flutter.dart' show ModelConfig;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late io.Directory root;

  setUp(() {
    root = io.Directory.systemTemp.createTempSync('local_model_disk_test');
    debugLocalModelStoreRoot = root;
  });
  tearDown(() {
    debugLocalModelStoreRoot = null;
    root.deleteSync(recursive: true);
  });

  void write(String relativePath, int bytes) =>
      io.File('${root.path}/$relativePath')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(bytes, 7));

  bool exists(String relativePath) =>
      io.Directory('${root.path}/$relativePath').existsSync();

  const model = ModelConfig(id: 'model-1', sourceId: 's', modelId: 'm');

  test('usage sums the picked-file and download stores', () async {
    write('local_models/model-1/model', 1024);
    write('local_llama/model-1/weights.gguf', 2048);
    expect(await localModelDiskUsage(model), 3072);
  });

  test('usage is zero with nothing stored', () async {
    expect(await localModelDiskUsage(model), 0);
  });

  test('deleting bytes clears both stores and spares other models', () async {
    write('local_models/model-1/model', 10);
    write('local_llama/model-1/weights.gguf', 10);
    write('local_llama/model-2/weights.gguf', 10);

    await deleteLocalModelBytes(model);

    expect(exists('local_models/model-1'), isFalse);
    expect(exists('local_llama/model-1'), isFalse);
    expect(exists('local_llama/model-2'), isTrue);
  });

  test('pruning downloads keeps only the named models', () async {
    write('local_llama/model-1/weights.gguf', 10);
    write('local_llama/model-2/weights.gguf', 10);

    await pruneLocalModelDownloads(const {'model-1'});

    expect(exists('local_llama/model-1'), isTrue);
    expect(exists('local_llama/model-2'), isFalse);
  });

  test('an empty prune keep-set clears every download', () async {
    write('local_llama/model-1/weights.gguf', 10);
    write('local_llama/model-2/weights.gguf', 10);

    await pruneLocalModelDownloads(const {});

    expect(exists('local_llama/model-1'), isFalse);
    expect(exists('local_llama/model-2'), isFalse);
  });
}
