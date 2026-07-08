// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:extensions_flutter/extensions_flutter.dart';

import '../domain/channel.dart';
import '../domain/conversation.dart';
import 'channel_store.dart';
import 'conversation_store.dart';

/// Seeds throwaway demo content — channels, conversations, and one
/// markdown-rich transcript — for design review and screenshots.
///
/// Activated by loading the app with `?seedDemo=1` in the URL. Writes
/// through the real stores and is idempotent: it does nothing when any
/// conversation already exists. The referenced agents (`a1`..`a3`) must
/// be seeded separately through the configured-agents stores.
class DemoSeed {
  /// Creates a [DemoSeed] over the app's services.
  DemoSeed(this._services);

  final ServiceProvider _services;

  /// Whether the current page URL asks for demo seeding.
  static bool get requested => Uri.base.queryParameters['seedDemo'] == '1';

  /// Seeds the demo content once.
  Future<void> run() async {
    final records = _services.getRequiredService<RecordStore>();
    final conversations = ConversationStore(records);
    if ((await conversations.listAll()).isNotEmpty) return;

    final channels = ChannelStore(records);
    final base = DateTime.utc(2026, 7, 1, 9);

    await channels.save(
      Channel(
        id: 'demo-ch-research',
        name: 'Research',
        description: 'Digging into questions before we build.',
        agentIds: const ['a1', 'a2'],
        createdAt: base,
        updatedAt: base.add(const Duration(hours: 3)),
      ),
    );
    await channels.save(
      Channel(
        id: 'demo-ch-shipping',
        name: 'Shipping',
        description: 'Release checklists and launch notes.',
        agentIds: const ['a3'],
        createdAt: base,
        updatedAt: base.add(const Duration(hours: 1)),
      ),
    );

    Conversation conversation({
      required String id,
      required String title,
      required String agentId,
      required String preview,
      required int hoursAgo,
      String? channelId,
    }) => Conversation(
      id: id,
      kind: ConversationKind.direct,
      title: title,
      titleSource: ConversationTitleSource.firstMessage,
      participantAgentIds: [agentId],
      channelId: channelId,
      createdAt: base,
      updatedAt: base.add(Duration(hours: 12 - hoursAgo)),
      lastMessagePreview: preview,
    );

    await conversations.save(
      conversation(
        id: 'demo-c-storage',
        title: 'Wiring the storage layers',
        agentId: 'a1',
        preview: 'See the sembast docs for details.',
        hoursAgo: 1,
      ),
    );
    await conversations.save(
      conversation(
        id: 'demo-c-outline',
        title: 'Outline for the launch post',
        agentId: 'a2',
        preview: 'Draft two intros and compare tone.',
        hoursAgo: 5,
        channelId: 'demo-ch-shipping',
      ),
    );
    await conversations.save(
      conversation(
        id: 'demo-c-review',
        title: 'Review the retry logic',
        agentId: 'a3',
        preview: 'The backoff should cap at 30 seconds.',
        hoursAgo: 9,
      ),
    );
    await conversations.save(
      Conversation(
        id: 'demo-c-rollout',
        kind: ConversationKind.group,
        title: 'Plan the beta rollout',
        titleSource: ConversationTitleSource.firstMessage,
        participantAgentIds: const ['a1', 'a2'],
        coordinatorAgentId: 'a1',
        createdAt: base,
        updatedAt: base.add(const Duration(hours: 10)),
        lastMessagePreview: 'Ship to 10% of users first.',
      ),
    );

    await _writeTranscript(records, conversationId: 'demo-c-storage');
  }

  Future<void> _writeTranscript(
    RecordStore records, {
    required String conversationId,
  }) async {
    const assistantMarkdown =
        'Here is how the pieces fit together.\n'
        '\n'
        '## Storage layers\n'
        '\n'
        '- `RecordStore` — collection/record persistence\n'
        '- `KeyValueStore` — small settings\n'
        '- `SecretStore` — API keys\n'
        '\n'
        'Wire it up in the bootstrap:\n'
        '\n'
        '```dart\n'
        'final records = InMemoryRecordStore();\n'
        'services.addRecordStore(recordStore: (_) => records);\n'
        '```\n'
        '\n'
        '> Keep secrets out of configuration JSON entirely.\n'
        '\n'
        'See the [sembast docs](https://pub.dev/packages/sembast) '
        'for details.';

    final turns = <(ai.ChatRole, String)>[
      (ai.ChatRole.user, 'How do I wire the storage layers together?'),
      (ai.ChatRole.assistant, assistantMarkdown),
      (ai.ChatRole.user, 'Where do the docs live?'),
      (ai.ChatRole.assistant, 'See the sembast docs for details.'),
    ];

    var seq = 0;
    final now = DateTime.utc(2026, 7, 1, 20).toIso8601String();
    for (final (role, text) in turns) {
      await records.put(
        ChatMessageRecords.collection,
        '$conversationId-${seq.toString().padLeft(3, '0')}',
        {
          ChatMessageRecords.conversationIdField: conversationId,
          ChatMessageRecords.sessionIdField: 'demo-session',
          ChatMessageRecords.seqField: seq++,
          if (role != ai.ChatRole.user)
            ChatMessageRecords.senderAgentIdField: 'a1',
          ChatMessageRecords.createdAtField: now,
          ChatMessageRecords.messageField: ChatMessageCodec.encode(
            ai.ChatMessage.fromText(role, text),
          ),
        },
      );
    }
  }
}
