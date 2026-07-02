// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../domain/conversation.dart';
import 'conversation_store.dart';

/// Conversation-level operations above the raw stores.
class ConversationService {
  /// Creates a [ConversationService].
  ConversationService(this._conversations);

  final ConversationStore _conversations;

  /// Creates a NEW group conversation from [original], leaving the original
  /// untouched.
  ///
  /// Participants are the original's plus [addedAgentIds] (deduplicated).
  /// [coordinatorAgentId] must be a participant; it runs the group with the
  /// other participants attached as background agents. The default title
  /// lists the participant names from [agentNamesById].
  Future<Conversation> createGroupFromDirect({
    required Conversation original,
    required List<String> addedAgentIds,
    required String coordinatorAgentId,
    required Map<String, String> agentNamesById,
  }) async {
    final participants = <String>[
      ...original.participantAgentIds,
      ...addedAgentIds.where(
        (id) => !original.participantAgentIds.contains(id),
      ),
    ];
    if (!participants.contains(coordinatorAgentId)) {
      throw ArgumentError.value(
        coordinatorAgentId,
        'coordinatorAgentId',
        'The coordinator must be a participant.',
      );
    }

    final now = DateTime.now();
    final group = Conversation(
      id: _conversations.newConversationId(),
      kind: ConversationKind.group,
      title: participants.map((id) => agentNamesById[id] ?? 'Agent').join(', '),
      // A generated title that sticks; the first message does not
      // overwrite it.
      titleSource: ConversationTitleSource.summary,
      participantAgentIds: participants,
      coordinatorAgentId: coordinatorAgentId,
      channelId: original.channelId,
      createdAt: now,
      updatedAt: now,
    );
    await _conversations.save(group);
    return group;
  }
}
