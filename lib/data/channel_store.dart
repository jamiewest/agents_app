// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math';

import 'package:agents_flutter/agents_flutter.dart';

import '../domain/channel.dart';

/// Persists [Channel] records.
class ChannelStore {
  /// Creates a [ChannelStore] over [records].
  ChannelStore(this._records);

  /// The record collection holding channels.
  static const String collection = 'channels';

  final RecordStore _records;

  /// Generates a unique channel id.
  String newChannelId() {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return 'chan-${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  /// Saves [channel].
  Future<void> save(Channel channel) =>
      _records.put(collection, channel.id, channel.toRecord());

  /// Loads the channel with [id], or `null` when missing.
  Future<Channel?> get(String id) async {
    final record = await _records.get(collection, id);
    return record == null ? null : Channel.fromRecord(id, record);
  }

  /// Deletes the channel with [id]. Conversations keep their records.
  Future<void> delete(String id) => _records.delete(collection, id);

  /// Watches all channels, most recently updated first.
  Stream<List<Channel>> watchAll() => _records
      .watch(
        collection,
        query: const RecordQuery(orderBy: 'updatedAt', descending: true),
      )
      .map(
        (records) => [
          for (final record in records)
            Channel.fromRecord(record.id, record.value),
        ],
      );

  /// Lists all channels, most recently updated first.
  Future<List<Channel>> listAll() async {
    final records = await _records.query(
      collection,
      query: const RecordQuery(orderBy: 'updatedAt', descending: true),
    );
    return [
      for (final record in records) Channel.fromRecord(record.id, record.value),
    ];
  }
}
