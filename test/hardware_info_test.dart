// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/features/hardware/hardware_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.jamiewest.agentsApp/hardware');

  void mockChannel(Future<Object?> Function(MethodCall call)? handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);

  tearDown(() => mockChannel(null));

  test('cpu usage comes from the hardware channel', () async {
    mockChannel((call) async {
      expect(call.method, 'cpuUsage');
      return 0.42;
    });
    expect(await readCpuUsage(), 0.42);
  });

  test('the sampler\'s first-call null passes through', () async {
    mockChannel((call) async => null);
    expect(await readCpuUsage(), isNull);
  });

  test('a Runner without the channel reads as unmeasurable', () async {
    expect(await readCpuUsage(), isNull);
  });
}
