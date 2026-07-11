// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/domain/channel.dart';
import 'package:agents_app/domain/chats_filter.dart';
import 'package:agents_app/domain/conversation.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 7, 10, 15, 30);

Conversation _conversation({
  required String id,
  String title = 'Chat',
  List<String> agents = const ['alpha'],
  String? coordinator,
  DateTime? updatedAt,
  String? preview,
  ConversationKind kind = ConversationKind.direct,
}) => Conversation(
  id: id,
  kind: kind,
  title: title,
  titleSource: ConversationTitleSource.firstMessage,
  participantAgentIds: agents,
  coordinatorAgentId: coordinator,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updatedAt ?? _now,
  lastMessagePreview: preview,
);

Channel _channel({
  required String id,
  String name = 'General',
  String description = '',
  List<String> agents = const [],
  DateTime? updatedAt,
}) => Channel(
  id: id,
  name: name,
  description: description,
  agentIds: agents,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updatedAt ?? _now,
);

AgentFilterIndex _buildIndex() => AgentFilterIndex(
  sources: const [
    ModelSourceConfig(
      id: 'src-local',
      providerType: ProviderType.localLlama,
      displayName: 'Local',
    ),
    ModelSourceConfig(
      id: 'src-api',
      providerType: ProviderType.anthropic,
      displayName: 'API',
    ),
    ModelSourceConfig(
      id: 'src-net',
      providerType: ProviderType.network,
      displayName: 'Remote',
    ),
  ],
  models: const [
    ModelConfig(id: 'm-local', sourceId: 'src-local', modelId: 'plain'),
    ModelConfig(
      id: 'm-vision',
      sourceId: 'src-api',
      modelId: 'vision',
      settings: {ModelCapabilities.visionKey: 'true'},
    ),
    ModelConfig(
      id: 'm-audio',
      sourceId: 'src-api',
      modelId: 'audio',
      settings: {
        ModelCapabilities.audioKey: 'true',
        ModelCapabilities.toolsKey: 'false',
      },
    ),
    ModelConfig(
      id: 'm-multi',
      sourceId: 'src-api',
      modelId: 'multi',
      settings: {
        ModelCapabilities.visionKey: 'true',
        ModelCapabilities.audioKey: 'true',
        ModelCapabilities.thinkingKey: 'true',
      },
    ),
    ModelConfig(id: 'm-net', sourceId: 'src-net', modelId: 'remote'),
    ModelConfig(id: 'm-orphan', sourceId: 'src-missing', modelId: 'orphan'),
  ],
  agents: const [
    SavedAgentConfig(id: 'alpha', name: 'Alpha Agent', modelId: 'm-local'),
    SavedAgentConfig(id: 'bravo', name: 'Bravo Vision', modelId: 'm-vision'),
    SavedAgentConfig(id: 'charlie', name: 'Charlie Audio', modelId: 'm-audio'),
    SavedAgentConfig(id: 'delta', name: 'Delta Remote', modelId: 'm-net'),
    SavedAgentConfig(id: 'echo', name: 'Echo Multi', modelId: 'm-multi'),
    SavedAgentConfig(id: 'ghost', name: 'Ghost', modelId: 'missing-model'),
    SavedAgentConfig(id: 'orphan', name: 'Orphan', modelId: 'm-orphan'),
  ],
);

void main() {
  final index = _buildIndex();

  bool matches(Conversation conversation, ChatsQuery query) =>
      conversationMatchesQuery(conversation, query, index, now: _now);

  bool channelMatches(Channel channel, ChatsQuery query) =>
      channelMatchesQuery(channel, query, index, now: _now);

  group('search', () {
    test('matches titles case-insensitively', () {
      final chat = _conversation(id: 'c1', title: 'Trip Planning');
      expect(matches(chat, const ChatsQuery(searchText: 'tRiP')), isTrue);
      expect(matches(chat, const ChatsQuery(searchText: 'lunch')), isFalse);
    });

    test('matches latest-message previews', () {
      final chat = _conversation(id: 'c1', preview: 'See you at Noon');
      expect(matches(chat, const ChatsQuery(searchText: 'NOON')), isTrue);
    });

    test('matches participant agent names', () {
      final chat = _conversation(id: 'c1', agents: ['bravo']);
      expect(matches(chat, const ChatsQuery(searchText: 'bravo')), isTrue);
      expect(matches(chat, const ChatsQuery(searchText: 'alpha')), isFalse);
    });

    test('matches the group coordinator agent name', () {
      final group = _conversation(
        id: 'g1',
        kind: ConversationKind.group,
        agents: ['alpha'],
        coordinator: 'echo',
      );
      expect(matches(group, const ChatsQuery(searchText: 'echo')), isTrue);
    });

    test('matches channel names and descriptions', () {
      final channel = _channel(
        id: 'ch1',
        name: 'Research',
        description: 'Deep dives',
      );
      expect(
        channelMatches(channel, const ChatsQuery(searchText: 'research')),
        isTrue,
      );
      expect(
        channelMatches(channel, const ChatsQuery(searchText: 'DIVES')),
        isTrue,
      );
      expect(
        channelMatches(channel, const ChatsQuery(searchText: 'nope')),
        isFalse,
      );
    });
  });

  group('agent and execution filters', () {
    test('multiple selected agents OR-match', () {
      const query = ChatsQuery(agentIds: {'alpha', 'bravo'});
      expect(
        matches(_conversation(id: 'c1', agents: ['alpha']), query),
        isTrue,
      );
      expect(
        matches(_conversation(id: 'c2', agents: ['bravo']), query),
        isTrue,
      );
      expect(
        matches(_conversation(id: 'c3', agents: ['charlie']), query),
        isFalse,
      );
    });

    test('multiple selected execution types OR-match', () {
      const query = ChatsQuery(
        executionTypes: {ChatsExecutionType.local, ChatsExecutionType.api},
      );
      expect(
        matches(_conversation(id: 'c1', agents: ['alpha']), query),
        isTrue,
      );
      expect(
        matches(_conversation(id: 'c2', agents: ['bravo']), query),
        isTrue,
      );
      expect(
        matches(_conversation(id: 'c3', agents: ['delta']), query),
        isFalse,
      );
    });

    test('provider types map to execution types', () {
      expect(
        ChatsExecutionType.of(ProviderType.localLlama),
        ChatsExecutionType.local,
      );
      expect(
        ChatsExecutionType.of(ProviderType.network),
        ChatsExecutionType.network,
      );
      expect(
        ChatsExecutionType.of(ProviderType.openAiCompatible),
        ChatsExecutionType.api,
      );
      expect(
        ChatsExecutionType.of(ProviderType.anthropic),
        ChatsExecutionType.api,
      );
      expect(
        ChatsExecutionType.of(ProviderType.google),
        ChatsExecutionType.api,
      );
    });
  });

  group('capability filters', () {
    test('all selected capabilities must come from one participant', () {
      const query = ChatsQuery(
        capabilities: {
          ChatsCapabilityFilter.vision,
          ChatsCapabilityFilter.audio,
        },
      );
      // bravo has vision, charlie has audio — no single agent has both.
      final split = _conversation(
        id: 'g1',
        kind: ConversationKind.group,
        agents: ['bravo', 'charlie'],
      );
      expect(matches(split, query), isFalse);

      // echo supports both on its own.
      final qualified = _conversation(
        id: 'g2',
        kind: ConversationKind.group,
        agents: ['bravo', 'echo'],
      );
      expect(matches(qualified, query), isTrue);
    });

    test('tools defaults on; audio model opted out of tools', () {
      const tools = ChatsQuery(capabilities: {ChatsCapabilityFilter.tools});
      expect(
        matches(_conversation(id: 'c1', agents: ['alpha']), tools),
        isTrue,
      );
      expect(
        matches(_conversation(id: 'c2', agents: ['charlie']), tools),
        isFalse,
      );
    });

    test('one participant must satisfy agent, execution, and capability '
        'criteria together', () {
      // bravo satisfies vision but is API; alpha is local without vision.
      const query = ChatsQuery(
        capabilities: {ChatsCapabilityFilter.vision},
        executionTypes: {ChatsExecutionType.local},
      );
      final group = _conversation(
        id: 'g1',
        kind: ConversationKind.group,
        agents: ['alpha', 'bravo'],
      );
      expect(matches(group, query), isFalse);
    });
  });

  group('missing metadata', () {
    test('unknown participants stay visible without agent filters', () {
      final chat = _conversation(
        id: 'c1',
        title: 'Legacy',
        agents: ['deleted-agent'],
      );
      expect(matches(chat, const ChatsQuery()), isTrue);
      expect(matches(chat, const ChatsQuery(searchText: 'legacy')), isTrue);
    });

    test('unknown participants never satisfy metadata filters', () {
      final chat = _conversation(id: 'c1', agents: ['deleted-agent']);
      expect(matches(chat, const ChatsQuery(agentIds: {'alpha'})), isFalse);
      expect(
        matches(
          chat,
          const ChatsQuery(capabilities: {ChatsCapabilityFilter.tools}),
        ),
        isFalse,
      );
      expect(
        matches(
          chat,
          const ChatsQuery(executionTypes: {ChatsExecutionType.local}),
        ),
        isFalse,
      );
    });

    test('an agent with a missing model matches by id only', () {
      final chat = _conversation(id: 'c1', agents: ['ghost']);
      expect(matches(chat, const ChatsQuery(agentIds: {'ghost'})), isTrue);
      expect(
        matches(
          chat,
          const ChatsQuery(capabilities: {ChatsCapabilityFilter.tools}),
        ),
        isFalse,
      );
      expect(
        matches(
          chat,
          const ChatsQuery(executionTypes: {ChatsExecutionType.local}),
        ),
        isFalse,
      );
    });

    test('a model with a missing source fails execution filters only', () {
      final chat = _conversation(id: 'c1', agents: ['orphan']);
      expect(
        matches(
          chat,
          const ChatsQuery(
            executionTypes: {
              ChatsExecutionType.local,
              ChatsExecutionType.network,
              ChatsExecutionType.api,
            },
          ),
        ),
        isFalse,
      );
      expect(
        matches(
          chat,
          const ChatsQuery(capabilities: {ChatsCapabilityFilter.tools}),
        ),
        isTrue,
        reason: 'capabilities resolve from the model alone',
      );
    });
  });

  group('date filters', () {
    Conversation at(DateTime updatedAt) =>
        _conversation(id: 'c1', updatedAt: updatedAt);

    test('today uses the local calendar day', () {
      const query = ChatsQuery(activity: ChatsActivityFilter.today);
      expect(matches(at(DateTime(2026, 7, 10, 0, 5)), query), isTrue);
      expect(matches(at(DateTime(2026, 7, 9, 23, 59)), query), isFalse);
    });

    test('last 7 days includes today and six days back', () {
      const query = ChatsQuery(activity: ChatsActivityFilter.last7Days);
      expect(matches(at(DateTime(2026, 7, 4, 0, 0)), query), isTrue);
      expect(matches(at(DateTime(2026, 7, 3, 23, 59)), query), isFalse);
    });

    test('last 30 days includes today and 29 days back', () {
      const query = ChatsQuery(activity: ChatsActivityFilter.last30Days);
      expect(matches(at(DateTime(2026, 6, 11)), query), isTrue);
      expect(matches(at(DateTime(2026, 6, 10, 23, 59)), query), isFalse);
    });

    test('custom ranges are inclusive of both calendar days', () {
      final query = ChatsQuery(
        activity: ChatsActivityFilter.custom,
        customStart: DateTime(2026, 7, 1, 10),
        customEnd: DateTime(2026, 7, 5, 9),
      );
      expect(matches(at(DateTime(2026, 7, 1, 0, 30)), query), isTrue);
      expect(matches(at(DateTime(2026, 7, 5, 23, 0)), query), isTrue);
      expect(matches(at(DateTime(2026, 6, 30, 23, 59)), query), isFalse);
      expect(matches(at(DateTime(2026, 7, 6, 0, 1)), query), isFalse);
    });
  });

  group('group and channel participant matching', () {
    test('a group matches when any member qualifies', () {
      const query = ChatsQuery(capabilities: {ChatsCapabilityFilter.vision});
      final group = _conversation(
        id: 'g1',
        kind: ConversationKind.group,
        agents: ['alpha', 'bravo'],
      );
      expect(matches(group, query), isTrue);
    });

    test('a channel matches when any member qualifies', () {
      const query = ChatsQuery(executionTypes: {ChatsExecutionType.network});
      expect(
        channelMatches(_channel(id: 'ch1', agents: ['alpha', 'delta']), query),
        isTrue,
      );
      expect(
        channelMatches(_channel(id: 'ch2', agents: ['alpha']), query),
        isFalse,
      );
    });

    test('a channel without members fails agent filters but stays visible '
        'otherwise', () {
      final channel = _channel(id: 'ch1');
      expect(channelMatches(channel, const ChatsQuery()), isTrue);
      expect(
        channelMatches(channel, const ChatsQuery(agentIds: {'alpha'})),
        isFalse,
      );
    });
  });

  group('sorting', () {
    final older = _conversation(
      id: 'b-id',
      title: 'Older',
      updatedAt: DateTime(2026, 7, 1),
    );
    final newer = _conversation(
      id: 'a-id',
      title: 'Newer',
      updatedAt: DateTime(2026, 7, 9),
    );

    test('newest and oldest activity orders rows', () {
      expect(
        sortSectionConversations(
          [older, newer],
          ChatsSortOrder.newestFirst,
          index,
        ).map((c) => c.id),
        ['a-id', 'b-id'],
      );
      expect(
        sortSectionConversations(
          [newer, older],
          ChatsSortOrder.oldestFirst,
          index,
        ).map((c) => c.id),
        ['b-id', 'a-id'],
      );
    });

    test('agent-name orders keep section rows newest-first', () {
      expect(
        sortSectionConversations(
          [older, newer],
          ChatsSortOrder.agentAToZ,
          index,
        ).map((c) => c.id),
        ['a-id', 'b-id'],
      );
    });

    test('ties break on display title, then id', () {
      final sameTime = DateTime(2026, 7, 5);
      final beta = _conversation(id: 'z', title: 'Beta', updatedAt: sameTime);
      final acme2 = _conversation(id: 'y', title: 'Acme', updatedAt: sameTime);
      final acme1 = _conversation(id: 'x', title: 'Acme', updatedAt: sameTime);
      expect(
        sortSectionConversations(
          [beta, acme2, acme1],
          ChatsSortOrder.newestFirst,
          index,
        ).map((c) => c.id),
        ['x', 'y', 'z'],
      );
    });

    test('group rows alphabetize under agent-name orders', () {
      final groups = [
        _conversation(
          id: 'g1',
          title: 'Zulu group',
          kind: ConversationKind.group,
          updatedAt: DateTime(2026, 7, 9),
        ),
        _conversation(
          id: 'g2',
          title: 'Alpha group',
          kind: ConversationKind.group,
          updatedAt: DateTime(2026, 7, 1),
        ),
      ];
      expect(
        sortGroupConversations(
          groups,
          ChatsSortOrder.agentAToZ,
          index,
        ).map((c) => c.id),
        ['g2', 'g1'],
      );
      expect(
        sortGroupConversations(
          groups,
          ChatsSortOrder.agentZToA,
          index,
        ).map((c) => c.id),
        ['g1', 'g2'],
      );
      expect(
        sortGroupConversations(
          groups,
          ChatsSortOrder.newestFirst,
          index,
        ).map((c) => c.id),
        ['g1', 'g2'],
      );
    });

    test('channels sort by activity or name', () {
      final channels = [
        _channel(id: 'ch1', name: 'Zebra', updatedAt: DateTime(2026, 7, 9)),
        _channel(id: 'ch2', name: 'Apple', updatedAt: DateTime(2026, 7, 1)),
      ];
      expect(
        sortChannels(channels, ChatsSortOrder.newestFirst).map((c) => c.id),
        ['ch1', 'ch2'],
      );
      expect(
        sortChannels(channels, ChatsSortOrder.oldestFirst).map((c) => c.id),
        ['ch2', 'ch1'],
      );
      expect(
        sortChannels(channels, ChatsSortOrder.agentAToZ).map((c) => c.id),
        ['ch2', 'ch1'],
      );
      expect(
        sortChannels(channels, ChatsSortOrder.agentZToA).map((c) => c.id),
        ['ch1', 'ch2'],
      );
    });

    test('agent sections order by matched activity or name', () {
      final byAgent = {
        'alpha': [
          _conversation(id: 'c1', updatedAt: DateTime(2026, 7, 2)),
          _conversation(id: 'c2', updatedAt: DateTime(2026, 7, 8)),
        ],
        'bravo': [_conversation(id: 'c3', updatedAt: DateTime(2026, 7, 5))],
      };
      expect(
        orderAgentSections(byAgent, ChatsSortOrder.newestFirst, index),
        ['alpha', 'bravo'],
        reason: 'alpha has the newest visible conversation',
      );
      expect(
        orderAgentSections(byAgent, ChatsSortOrder.oldestFirst, index),
        ['alpha', 'bravo'],
        reason: 'alpha also has the oldest visible conversation',
      );
      expect(orderAgentSections(byAgent, ChatsSortOrder.agentAToZ, index), [
        'alpha',
        'bravo',
      ]);
      expect(orderAgentSections(byAgent, ChatsSortOrder.agentZToA, index), [
        'bravo',
        'alpha',
      ]);
    });

    test('agent sections break name ties on the stable id', () {
      final byAgent = {
        'twin-b': [_conversation(id: 'c1')],
        'twin-a': [_conversation(id: 'c2')],
      };
      // Neither id is a known agent, so both sections fall back to the
      // same "Unknown agent" title and the id decides.
      expect(orderAgentSections(byAgent, ChatsSortOrder.agentAToZ, index), [
        'twin-a',
        'twin-b',
      ]);
    });
  });
}
