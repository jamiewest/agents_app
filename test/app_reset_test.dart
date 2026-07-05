// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:agents_app/data/app_reset.dart';
// The io variant directly: VM tests always run with dart:io, and the
// analyzer resolves the conditional export to the stub, which has no
// debugLocalModelStoreRoot.
import 'package:agents_app/data/local_model_store_io.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory modelRoot;
  late KeyValueStore keyValue;
  late SecretStore secrets;
  late RecordStore records;
  late ServiceProvider services;

  setUp(() {
    modelRoot = Directory.systemTemp.createTempSync('app_reset_test');
    debugLocalModelStoreRoot = modelRoot;
    keyValue = InMemoryKeyValueStore();
    secrets = InMemorySecretStore();
    records = InMemoryRecordStore();
    services = (ServiceCollection()
          ..addSingleton<KeyValueStore>((_) => keyValue)
          ..addSingleton<SecretStore>((_) => secrets)
          ..addSingleton<RecordStore>((_) => records))
        .buildServiceProvider();
  });

  tearDown(() {
    debugLocalModelStoreRoot = null;
    if (modelRoot.existsSync()) modelRoot.deleteSync(recursive: true);
  });

  test('resetAppData wipes every persistence surface', () async {
    // Arrange: one configured source with an API key, assorted settings,
    // records in two collections, and a stored local model file.
    const sourceId = 'src-1';
    await keyValue.write(
      '${ConfiguredAgentsKeys.sourcePrefix}$sourceId',
      '{"id":"$sourceId"}',
    );
    await keyValue.write('app.theme.mode', 'dark');
    await secrets.write(
      ConfiguredAgentsKeys.sourceApiKeyKey(sourceId),
      'sk-test',
    );
    await records.put('conversations', 'c1', {'title': 'hello'});
    await records.put('agent_tasks', 't1', {'state': 'pending'});
    final modelFile = File('${modelRoot.path}/local_models/m1/model')
      ..createSync(recursive: true)
      ..writeAsStringSync('gguf');

    // Act.
    await resetAppData(services);

    // Assert.
    expect(await keyValue.keys(), isEmpty);
    expect(
      await secrets.read(ConfiguredAgentsKeys.sourceApiKeyKey(sourceId)),
      isNull,
    );
    expect(await records.query('conversations'), isEmpty);
    expect(await records.query('agent_tasks'), isEmpty);
    expect(modelFile.existsSync(), isFalse);
  });
}
