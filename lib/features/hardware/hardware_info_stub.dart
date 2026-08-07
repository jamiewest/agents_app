// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Web fallback: the browser exposes nothing worth reporting.
library;

/// The CPU facts a platform can report; every field optional.
typedef HardwareFacts = ({String? chipName, String? architecture, int? cores});

/// The system disk's capacity and free space.
typedef DiskFacts = ({int totalBytes, int freeBytes});

/// Reads the CPU facts, or null when the platform reports none.
Future<HardwareFacts?> readHardwareFacts() async => null;

/// Reads the system disk's capacity, or null when the platform cannot.
Future<DiskFacts?> readDiskFacts() async => null;

/// Whole-machine CPU usage since the previous call, 0–1, or null when the
/// platform cannot measure it.
Future<double?> readCpuUsage() async => null;
