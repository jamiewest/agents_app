// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A workspace grouping agents, conversations, shared files, and (later)
/// tasks around one purpose — e.g. "Accounts" or "Research".
///
/// Conversations join a channel by carrying its id; agent-written files in
/// channel conversations share the channel's file namespace, so channel
/// members work over the same resources.
class Channel {
  /// Creates a [Channel].
  const Channel({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.agentIds = const [],
  });

  /// Stable channel id.
  final String id;

  /// Human-readable channel name.
  final String name;

  /// What the channel is for.
  final String description;

  /// The configured agents that are members of this channel.
  final List<String> agentIds;

  /// When the channel was created.
  final DateTime createdAt;

  /// When the channel last changed.
  final DateTime updatedAt;

  /// Returns a copy with the given fields replaced.
  Channel copyWith({
    String? name,
    String? description,
    List<String>? agentIds,
    DateTime? updatedAt,
  }) => Channel(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    agentIds: agentIds ?? this.agentIds,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Serializes to a `RecordStore`-compatible map.
  Map<String, Object?> toRecord() => {
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'agentIds': agentIds,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Reconstructs a [Channel] from a stored record.
  static Channel fromRecord(String id, Map<String, Object?> record) => Channel(
    id: id,
    name: record['name']! as String,
    description: record['description'] as String? ?? '',
    agentIds:
        (record['agentIds'] as List?)?.cast<String>().toList() ?? const [],
    createdAt: DateTime.parse(record['createdAt']! as String),
    updatedAt: DateTime.parse(record['updatedAt']! as String),
  );
}
