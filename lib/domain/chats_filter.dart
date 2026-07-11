// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';

import 'channel.dart';
import 'conversation.dart';

/// How the chats list orders sections and rows.
enum ChatsSortOrder {
  /// Most recent activity first (the default).
  newestFirst('Newest activity'),

  /// Least recent activity first.
  oldestFirst('Oldest activity'),

  /// Agent sections alphabetized ascending.
  agentAToZ('Agent A–Z'),

  /// Agent sections alphabetized descending.
  agentZToA('Agent Z–A');

  const ChatsSortOrder(this.label);

  /// Human-readable name shown in the filter sheet.
  final String label;
}

/// The last-activity window a [ChatsQuery] filters on.
enum ChatsActivityFilter {
  /// No date restriction.
  anyTime('Any time'),

  /// Updated on the local calendar day of "now".
  today('Today'),

  /// Updated within the last 7 local calendar days, including today.
  last7Days('Last 7 days'),

  /// Updated within the last 30 local calendar days, including today.
  last30Days('Last 30 days'),

  /// Updated inside the query's inclusive custom date range.
  custom('Custom range');

  const ChatsActivityFilter(this.label);

  /// Human-readable name shown in the filter sheet.
  final String label;
}

/// A model capability a [ChatsQuery] can require of a participating agent.
enum ChatsCapabilityFilter {
  /// Tool calling.
  tools('Tools'),

  /// Image input.
  vision('Vision'),

  /// Audio input.
  audio('Audio'),

  /// Extended thinking.
  thinking('Thinking');

  const ChatsCapabilityFilter(this.label);

  /// Human-readable name shown in the filter sheet and chips.
  final String label;
}

/// Where an agent's model executes, derived from its source's
/// [ProviderType].
enum ChatsExecutionType {
  /// On-device local inference ([ProviderType.localLlama]).
  local('On-device'),

  /// A remote agent reached over A2A ([ProviderType.network]).
  network('Network (A2A)'),

  /// A hosted API provider (OpenAI-compatible, Anthropic, or Google).
  api('API provider');

  const ChatsExecutionType(this.label);

  /// Human-readable name shown in the filter sheet and chips.
  final String label;

  /// Maps a provider to the execution type it represents.
  static ChatsExecutionType of(ProviderType provider) => switch (provider) {
    ProviderType.localLlama => local,
    ProviderType.network => network,
    ProviderType.openAiCompatible ||
    ProviderType.anthropic ||
    ProviderType.google => api,
  };
}

/// An immutable search/filter/sort query over the chats list.
///
/// The empty query (all defaults) matches everything and keeps the list's
/// stock presentation.
class ChatsQuery {
  /// Creates a [ChatsQuery].
  const ChatsQuery({
    this.searchText = '',
    this.agentIds = const {},
    this.activity = ChatsActivityFilter.anyTime,
    this.customStart,
    this.customEnd,
    this.capabilities = const {},
    this.executionTypes = const {},
    this.sortOrder = ChatsSortOrder.newestFirst,
  });

  /// Raw search text; matching is case-insensitive on the trimmed value.
  final String searchText;

  /// Selected agent ids, OR-matched. Empty means "any agent".
  final Set<String> agentIds;

  /// The last-activity window.
  final ChatsActivityFilter activity;

  /// First day of the inclusive custom range (local calendar date).
  final DateTime? customStart;

  /// Last day of the inclusive custom range (local calendar date).
  final DateTime? customEnd;

  /// Required capabilities; one participating agent must support all of
  /// them. Empty means "no capability requirement".
  final Set<ChatsCapabilityFilter> capabilities;

  /// Selected execution types, OR-matched. Empty means "any".
  final Set<ChatsExecutionType> executionTypes;

  /// How sections and rows are ordered. Sorting applies even when no
  /// search or filters are active.
  final ChatsSortOrder sortOrder;

  static const Object _unset = Object();

  /// Returns a copy with the given fields replaced.
  ChatsQuery copyWith({
    String? searchText,
    Set<String>? agentIds,
    ChatsActivityFilter? activity,
    Object? customStart = _unset,
    Object? customEnd = _unset,
    Set<ChatsCapabilityFilter>? capabilities,
    Set<ChatsExecutionType>? executionTypes,
    ChatsSortOrder? sortOrder,
  }) => ChatsQuery(
    searchText: searchText ?? this.searchText,
    agentIds: agentIds ?? this.agentIds,
    activity: activity ?? this.activity,
    customStart: identical(customStart, _unset)
        ? this.customStart
        : customStart as DateTime?,
    customEnd: identical(customEnd, _unset)
        ? this.customEnd
        : customEnd as DateTime?,
    capabilities: capabilities ?? this.capabilities,
    executionTypes: executionTypes ?? this.executionTypes,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  /// The lowercase trimmed search needle; empty means "no search".
  String get normalizedSearch => searchText.trim().toLowerCase();

  /// Whether any filter dimension (not search, not sort) is active.
  bool get hasFilters =>
      agentIds.isNotEmpty ||
      activity != ChatsActivityFilter.anyTime ||
      capabilities.isNotEmpty ||
      executionTypes.isNotEmpty;

  /// Whether the agent, capability, or execution dimension is active.
  bool get hasAgentFilters =>
      agentIds.isNotEmpty ||
      capabilities.isNotEmpty ||
      executionTypes.isNotEmpty;

  /// Whether search or any filter narrows the list (sort alone does not).
  bool get isActive => normalizedSearch.isNotEmpty || hasFilters;

  /// How many individual filters are active, for the badge and chips.
  int get filterCount =>
      agentIds.length +
      capabilities.length +
      executionTypes.length +
      (activity == ChatsActivityFilter.anyTime ? 0 : 1);

  @override
  bool operator ==(Object other) =>
      other is ChatsQuery &&
      other.searchText == searchText &&
      _setEquals(other.agentIds, agentIds) &&
      other.activity == activity &&
      other.customStart == customStart &&
      other.customEnd == customEnd &&
      _setEquals(other.capabilities, capabilities) &&
      _setEquals(other.executionTypes, executionTypes) &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(
    searchText,
    Object.hashAllUnordered(agentIds),
    activity,
    customStart,
    customEnd,
    Object.hashAllUnordered(capabilities),
    Object.hashAllUnordered(executionTypes),
    sortOrder,
  );

  static bool _setEquals<T>(Set<T> a, Set<T> b) =>
      a.length == b.length && a.containsAll(b);
}

/// Read-only lookup maps over the configured agents, models, and sources,
/// resolving the `SavedAgentConfig → ModelConfig → ModelSourceConfig`
/// chain without asynchronous reads per row.
class AgentFilterIndex {
  /// Creates an index over the given configuration snapshots.
  AgentFilterIndex({
    Iterable<SavedAgentConfig> agents = const [],
    Iterable<ModelConfig> models = const [],
    Iterable<ModelSourceConfig> sources = const [],
  }) : agentsById = Map.unmodifiable({
         for (final agent in agents) agent.id: agent,
       }),
       modelsById = Map.unmodifiable({
         for (final model in models) model.id: model,
       }),
       sourcesById = Map.unmodifiable({
         for (final source in sources) source.id: source,
       });

  /// Saved agents keyed by id.
  final Map<String, SavedAgentConfig> agentsById;

  /// Model configs keyed by id.
  final Map<String, ModelConfig> modelsById;

  /// Model sources keyed by id.
  final Map<String, ModelSourceConfig> sourcesById;

  /// The agent's display name, or `null` when the agent record is missing.
  String? agentName(String agentId) => agentsById[agentId]?.name;

  ModelConfig? _modelOf(String agentId) {
    final agent = agentsById[agentId];
    return agent == null ? null : modelsById[agent.modelId];
  }

  /// The agent's execution type, or `null` when the agent, model, or
  /// source record is missing.
  ChatsExecutionType? executionTypeOf(String agentId) {
    final model = _modelOf(agentId);
    final source = model == null ? null : sourcesById[model.sourceId];
    return source == null ? null : ChatsExecutionType.of(source.providerType);
  }

  /// The agent's model capabilities, or `null` when the agent or model
  /// record is missing.
  ModelCapabilities? capabilitiesOf(String agentId) =>
      _modelOf(agentId)?.capabilities;

  /// Whether one agent satisfies the complete agent, execution-type, and
  /// capability criteria of [query].
  ///
  /// A dimension whose metadata cannot be resolved fails when that
  /// dimension is filtered, and is ignored otherwise.
  bool agentSatisfiesFilters(String agentId, ChatsQuery query) {
    if (query.agentIds.isNotEmpty && !query.agentIds.contains(agentId)) {
      return false;
    }
    if (query.executionTypes.isNotEmpty) {
      final execution = executionTypeOf(agentId);
      if (execution == null || !query.executionTypes.contains(execution)) {
        return false;
      }
    }
    if (query.capabilities.isNotEmpty) {
      final capabilities = capabilitiesOf(agentId);
      if (capabilities == null) return false;
      for (final required in query.capabilities) {
        final supported = switch (required) {
          ChatsCapabilityFilter.tools => capabilities.supportsTools,
          ChatsCapabilityFilter.vision => capabilities.supportsVision,
          ChatsCapabilityFilter.audio => capabilities.supportsAudio,
          ChatsCapabilityFilter.thinking => capabilities.supportsThinking,
        };
        if (!supported) return false;
      }
    }
    return true;
  }
}

DateTime _dateOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

bool _inCalendarWindow(DateTime updatedAt, DateTime now, int days) {
  final date = _dateOnly(updatedAt);
  final today = _dateOnly(now);
  return !date.isAfter(today) &&
      !date.isBefore(today.subtract(Duration(days: days - 1)));
}

/// Whether [updatedAt] falls inside the query's last-activity window,
/// evaluated on the user's local calendar relative to [now].
bool matchesActivityWindow(DateTime updatedAt, ChatsQuery query, DateTime now) {
  switch (query.activity) {
    case ChatsActivityFilter.anyTime:
      return true;
    case ChatsActivityFilter.today:
      return _dateOnly(updatedAt) == _dateOnly(now);
    case ChatsActivityFilter.last7Days:
      return _inCalendarWindow(updatedAt, now, 7);
    case ChatsActivityFilter.last30Days:
      return _inCalendarWindow(updatedAt, now, 30);
    case ChatsActivityFilter.custom:
      final start = query.customStart;
      final end = query.customEnd;
      if (start == null || end == null) return true;
      final date = _dateOnly(updatedAt);
      return !date.isBefore(_dateOnly(start)) && !date.isAfter(_dateOnly(end));
  }
}

Iterable<String> _participantsOf(Conversation conversation) sync* {
  yield* conversation.participantAgentIds;
  final coordinator = conversation.coordinatorAgentId;
  if (coordinator != null &&
      !conversation.participantAgentIds.contains(coordinator)) {
    yield coordinator;
  }
}

bool _textMatches(String needle, Iterable<String?> haystacks) => haystacks.any(
  (haystack) => haystack != null && haystack.toLowerCase().contains(needle),
);

/// Whether [conversation] matches [query].
///
/// Search covers the title, latest-message preview, and participant agent
/// names; agent-related filters match when at least one participant
/// satisfies all of them at once.
bool conversationMatchesQuery(
  Conversation conversation,
  ChatsQuery query,
  AgentFilterIndex index, {
  required DateTime now,
}) {
  if (!matchesActivityWindow(conversation.updatedAt, query, now)) {
    return false;
  }
  if (query.hasAgentFilters &&
      !_participantsOf(
        conversation,
      ).any((agentId) => index.agentSatisfiesFilters(agentId, query))) {
    return false;
  }
  final needle = query.normalizedSearch;
  if (needle.isEmpty) return true;
  return _textMatches(needle, [
    conversation.title,
    conversation.lastMessagePreview,
    for (final agentId in _participantsOf(conversation))
      index.agentName(agentId),
  ]);
}

/// Whether [channel] matches [query].
///
/// Search covers the channel name, description, and member agent names;
/// agent-related filters match when at least one member satisfies all of
/// them at once.
bool channelMatchesQuery(
  Channel channel,
  ChatsQuery query,
  AgentFilterIndex index, {
  required DateTime now,
}) {
  if (!matchesActivityWindow(channel.updatedAt, query, now)) return false;
  if (query.hasAgentFilters &&
      !channel.agentIds.any(
        (agentId) => index.agentSatisfiesFilters(agentId, query),
      )) {
    return false;
  }
  final needle = query.normalizedSearch;
  if (needle.isEmpty) return true;
  return _textMatches(needle, [
    channel.name,
    channel.description,
    for (final agentId in channel.agentIds) index.agentName(agentId),
  ]);
}

/// The title a conversation tile displays: its own title, falling back to
/// the primary agent's name and then a generic placeholder.
String conversationDisplayTitleFor(
  Conversation conversation,
  AgentFilterIndex index,
) {
  final title = conversation.title.trim();
  if (title.isNotEmpty) return title;
  return index.agentName(conversation.primaryAgentId) ??
      'Untitled conversation';
}

int _compareTitlesThenIds(
  String titleA,
  String idA,
  String titleB,
  String idB, {
  bool descending = false,
}) {
  final byTitle = titleA.toLowerCase().compareTo(titleB.toLowerCase());
  if (byTitle != 0) return descending ? -byTitle : byTitle;
  return idA.compareTo(idB);
}

int _compareByActivity(
  DateTime a,
  DateTime b,
  String titleA,
  String idA,
  String titleB,
  String idB, {
  required bool newestFirst,
}) {
  final byDate = newestFirst ? b.compareTo(a) : a.compareTo(b);
  if (byDate != 0) return byDate;
  return _compareTitlesThenIds(titleA, idA, titleB, idB);
}

/// Sorts the conversations of one agent section.
///
/// Activity orders sort by `updatedAt`; under agent-name orders the rows
/// stay newest-first. Ties break on display title, then id.
List<Conversation> sortSectionConversations(
  List<Conversation> conversations,
  ChatsSortOrder order,
  AgentFilterIndex index,
) {
  final sorted = List.of(conversations);
  final newestFirst = order != ChatsSortOrder.oldestFirst;
  sorted.sort(
    (a, b) => _compareByActivity(
      a.updatedAt,
      b.updatedAt,
      conversationDisplayTitleFor(a, index),
      a.id,
      conversationDisplayTitleFor(b, index),
      b.id,
      newestFirst: newestFirst,
    ),
  );
  return sorted;
}

/// Sorts the group-chats section rows.
///
/// Activity orders sort by `updatedAt`; agent-name orders fall back to the
/// closest applicable ordering, alphabetizing by display title. Ties break
/// on display title, then id.
List<Conversation> sortGroupConversations(
  List<Conversation> conversations,
  ChatsSortOrder order,
  AgentFilterIndex index,
) {
  switch (order) {
    case ChatsSortOrder.newestFirst:
    case ChatsSortOrder.oldestFirst:
      return sortSectionConversations(conversations, order, index);
    case ChatsSortOrder.agentAToZ:
    case ChatsSortOrder.agentZToA:
      final sorted = List.of(conversations);
      sorted.sort(
        (a, b) => _compareTitlesThenIds(
          conversationDisplayTitleFor(a, index),
          a.id,
          conversationDisplayTitleFor(b, index),
          b.id,
          descending: order == ChatsSortOrder.agentZToA,
        ),
      );
      return sorted;
  }
}

/// Sorts the channel rows.
///
/// Activity orders sort by `updatedAt`; agent-name orders fall back to the
/// closest applicable ordering, alphabetizing by channel name. Ties break
/// on name, then id.
List<Channel> sortChannels(List<Channel> channels, ChatsSortOrder order) {
  final sorted = List.of(channels);
  switch (order) {
    case ChatsSortOrder.newestFirst:
    case ChatsSortOrder.oldestFirst:
      sorted.sort(
        (a, b) => _compareByActivity(
          a.updatedAt,
          b.updatedAt,
          a.name,
          a.id,
          b.name,
          b.id,
          newestFirst: order == ChatsSortOrder.newestFirst,
        ),
      );
    case ChatsSortOrder.agentAToZ:
    case ChatsSortOrder.agentZToA:
      sorted.sort(
        (a, b) => _compareTitlesThenIds(
          a.name,
          a.id,
          b.name,
          b.id,
          descending: order == ChatsSortOrder.agentZToA,
        ),
      );
  }
  return sorted;
}

/// Orders the per-agent section keys of [byAgent].
///
/// Activity orders rank sections by their most (or least) recently updated
/// visible conversation; agent-name orders alphabetize by section title.
/// Ties break on section title, then agent id.
List<String> orderAgentSections(
  Map<String, List<Conversation>> byAgent,
  ChatsSortOrder order,
  AgentFilterIndex index,
) {
  String titleOf(String agentId) => index.agentName(agentId) ?? 'Unknown agent';
  DateTime newestOf(String agentId) => byAgent[agentId]!
      .map((conversation) => conversation.updatedAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  DateTime oldestOf(String agentId) => byAgent[agentId]!
      .map((conversation) => conversation.updatedAt)
      .reduce((a, b) => a.isBefore(b) ? a : b);

  final ids = byAgent.keys.toList();
  switch (order) {
    case ChatsSortOrder.newestFirst:
      ids.sort(
        (a, b) => _compareByActivity(
          newestOf(a),
          newestOf(b),
          titleOf(a),
          a,
          titleOf(b),
          b,
          newestFirst: true,
        ),
      );
    case ChatsSortOrder.oldestFirst:
      ids.sort(
        (a, b) => _compareByActivity(
          oldestOf(a),
          oldestOf(b),
          titleOf(a),
          a,
          titleOf(b),
          b,
          newestFirst: false,
        ),
      );
    case ChatsSortOrder.agentAToZ:
    case ChatsSortOrder.agentZToA:
      ids.sort(
        (a, b) => _compareTitlesThenIds(
          titleOf(a),
          a,
          titleOf(b),
          b,
          descending: order == ChatsSortOrder.agentZToA,
        ),
      );
  }
  return ids;
}
