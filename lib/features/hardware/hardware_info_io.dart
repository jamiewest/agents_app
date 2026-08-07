// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Native CPU facts: core count and ABI from the Dart runtime, plus the
/// marketing name on macOS (`machdep.cpu.brand_string`, which reads
/// "Apple M1" on Apple Silicon). iOS forbids spawning processes, so there
/// the name is left null and the page falls back to the architecture.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

/// The CPU facts a platform can report; every field optional.
typedef HardwareFacts = ({String? chipName, String? architecture, int? cores});

/// The system disk's capacity and free space.
typedef DiskFacts = ({int totalBytes, int freeBytes});

/// Reads the CPU facts, or null when the platform reports none.
Future<HardwareFacts?> readHardwareFacts() async {
  String? chipName;
  if (Platform.isMacOS) {
    try {
      final result = await Process.run('sysctl', [
        '-n',
        'machdep.cpu.brand_string',
      ]);
      final out = (result.stdout as String).trim();
      if (result.exitCode == 0 && out.isNotEmpty) chipName = out;
    } catch (_) {
      // Sandbox or platform refusal: the architecture still identifies it.
    }
  }
  return (
    chipName: chipName,
    // `Abi` values read like `macos_arm64`; the tail is the CPU part.
    architecture: Abi.current().toString().split('_').last.toUpperCase(),
    cores: Platform.numberOfProcessors,
  );
}

/// The Runner-hosted channel serving Mach readings Dart cannot take itself.
const MethodChannel _hardwareChannel = MethodChannel(
  'dev.jamiewest.agentsApp/hardware',
);

/// Whole-machine CPU usage since the previous call, 0–1, or null when the
/// platform cannot measure it.
///
/// Served by the `CpuUsageSampler` in each Apple Runner
/// (`host_processor_info` tick deltas). The sampler measures between calls,
/// so the caller's poll interval is the measurement window — and the first
/// call of a run returns null, there being no interval yet. Null likewise
/// on other platforms, in tests, and on a Runner without the channel.
Future<double?> readCpuUsage() async {
  if (!Platform.isMacOS && !Platform.isIOS) return null;
  try {
    return await _hardwareChannel.invokeMethod<double>('cpuUsage');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Reads the system disk's capacity, or null when the platform cannot.
///
/// `df -k /` on macOS; iOS cannot spawn processes and Dart has no statvfs,
/// so there the card is simply absent.
Future<DiskFacts?> readDiskFacts() async {
  if (!Platform.isMacOS) return null;
  try {
    final result = await Process.run('df', ['-k', '/']);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    // Filesystem 1024-blocks Used Available Capacity ... Mounted on
    final columns = lines.last.split(RegExp(r'\s+'));
    if (columns.length < 4) return null;
    final total = int.tryParse(columns[1]);
    final available = int.tryParse(columns[3]);
    if (total == null || available == null) return null;
    return (totalBytes: total * 1024, freeBytes: available * 1024);
  } catch (_) {
    return null;
  }
}
