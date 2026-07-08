// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// What kind of conversation a [Conversation] is.
enum ConversationKind {
  /// One human talking to one agent.
  direct,

  /// One human talking to multiple agents through a coordinator.
  group,

  /// A conversation living inside a channel.
  channelThread,
}

/// How a conversation title was chosen.
enum ConversationTitleSource {
  /// The title has not been chosen yet.
  none,

  /// The title was derived from the first user message.
  firstMessage,

  /// The title was explicitly entered by the user.
  manual,

  /// The title was generated from an agent summary.
  summary,
}

/// A persistent conversation between the human and one or more agents.
///
/// The message transcript itself is stored separately (written by the
/// agent's chat history provider); this record carries identity and
/// list-view metadata.
class Conversation {
  /// Creates a [Conversation].
  const Conversation({
    required this.id,
    required this.kind,
    required this.title,
    required this.titleSource,
    required this.participantAgentIds,
    required this.createdAt,
    required this.updatedAt,
    this.coordinatorAgentId,
    this.channelId,
    this.isPrivate = false,
    this.lastMessagePreview,
    this.hasUnread = false,
  });

  /// Stable conversation id.
  final String id;

  /// The kind of conversation.
  final ConversationKind kind;

  /// Human-readable title.
  final String title;

  /// How [title] was chosen.
  final ConversationTitleSource titleSource;

  /// The configured agents participating in the conversation.
  final List<String> participantAgentIds;

  /// The agent coordinating a [ConversationKind.group] conversation.
  final String? coordinatorAgentId;

  /// The channel this conversation belongs to, when any.
  final String? channelId;

  /// Whether durable transcript persistence is disabled.
  final bool isPrivate;

  /// When the conversation was first persisted.
  final DateTime createdAt;

  /// When the conversation last changed.
  final DateTime updatedAt;

  /// A short preview of the most recent message, for list views.
  final String? lastMessagePreview;

  /// Whether the conversation has activity the user has not seen yet.
  ///
  /// Set when a background task run leaves a new message, and cleared when
  /// the conversation is opened. Surfaced as an unread dot in the chats list.
  final bool hasUnread;

  /// The primary agent of a direct conversation.
  String get primaryAgentId => participantAgentIds.first;

  /// Returns a copy with the given fields replaced.
  Conversation copyWith({
    String? title,
    ConversationTitleSource? titleSource,
    DateTime? updatedAt,
    String? lastMessagePreview,
    bool? hasUnread,
  }) => Conversation(
    id: id,
    kind: kind,
    title: title ?? this.title,
    titleSource: titleSource ?? this.titleSource,
    participantAgentIds: participantAgentIds,
    coordinatorAgentId: coordinatorAgentId,
    channelId: channelId,
    isPrivate: isPrivate,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    hasUnread: hasUnread ?? this.hasUnread,
  );

  /// Serializes to a [RecordStore]-compatible map.
  ///
  /// `agentId` is duplicated top-level for direct conversations so list
  /// screens can query by agent with a simple field-equality filter.
  Map<String, Object?> toRecord() => {
    'kind': kind.name,
    'title': title,
    'titleSource': titleSource.name,
    'participantAgentIds': participantAgentIds,
    'agentId': participantAgentIds.first,
    if (coordinatorAgentId != null) 'coordinatorAgentId': coordinatorAgentId,
    if (channelId != null) 'channelId': channelId,
    'isPrivate': isPrivate,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (lastMessagePreview != null) 'lastMessagePreview': lastMessagePreview,
    if (hasUnread) 'hasUnread': true,
  };

  /// Reconstructs a [Conversation] from a stored record.
  static Conversation fromRecord(String id, Map<String, Object?> record) =>
      Conversation(
        id: id,
        kind: ConversationKind.values.byName(record['kind']! as String),
        title: record['title']! as String,
        titleSource: ConversationTitleSource.values.byName(
          record['titleSource']! as String,
        ),
        participantAgentIds: (record['participantAgentIds']! as List)
            .cast<String>()
            .toList(),
        coordinatorAgentId: record['coordinatorAgentId'] as String?,
        channelId: record['channelId'] as String?,
        isPrivate: record['isPrivate'] as bool? ?? false,
        createdAt: DateTime.parse(record['createdAt']! as String),
        updatedAt: DateTime.parse(record['updatedAt']! as String),
        lastMessagePreview: record['lastMessagePreview'] as String?,
        hasUnread: record['hasUnread'] as bool? ?? false,
      );
}

/// One model-context epoch within a [Conversation].
///
/// A conversation displays as one continuous transcript, but is segmented
/// into sessions; each session carries the agent's serialized session state
/// so the conversation can resume where it left off.
class ConversationSession {
  /// Creates a [ConversationSession].
  const ConversationSession({
    required this.id,
    required this.conversationId,
    required this.startedAt,
    this.endedAt,
    this.serializedAgentSession,
  });

  /// Stable session id.
  final String id;

  /// The conversation this session belongs to.
  final String conversationId;

  /// When the session started.
  final DateTime startedAt;

  /// When the session was ended, or `null` while active.
  final DateTime? endedAt;

  /// The agent's serialized session state, when available.
  final String? serializedAgentSession;

  /// Returns a copy with the given fields replaced.
  ConversationSession copyWith({
    DateTime? endedAt,
    String? serializedAgentSession,
  }) => ConversationSession(
    id: id,
    conversationId: conversationId,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    serializedAgentSession:
        serializedAgentSession ?? this.serializedAgentSession,
  );

  /// Serializes to a [RecordStore]-compatible map.
  Map<String, Object?> toRecord() => {
    'conversationId': conversationId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    if (serializedAgentSession != null)
      'serializedAgentSession': serializedAgentSession,
  };

  /// Reconstructs a [ConversationSession] from a stored record.
  static ConversationSession fromRecord(
    String id,
    Map<String, Object?> record,
  ) => ConversationSession(
    id: id,
    conversationId: record['conversationId']! as String,
    startedAt: DateTime.parse(record['startedAt']! as String),
    endedAt: switch (record['endedAt']) {
      final String value => DateTime.parse(value),
      _ => null,
    },
    serializedAgentSession: record['serializedAgentSession'] as String?,
  );
}
