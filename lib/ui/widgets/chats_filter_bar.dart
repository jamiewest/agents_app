// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../domain/chats_filter.dart';
import '../app_theme.dart';

/// Holds the chats list's search/filter/sort state.
///
/// Owned above the list widget (by the chats shell) so the state survives
/// sidebar collapse/restore and navigation for the session's lifetime. It
/// is never persisted across app restarts.
class ChatsFilterController extends ChangeNotifier {
  ChatsQuery _query = const ChatsQuery();

  /// The current query.
  ChatsQuery get query => _query;

  set query(ChatsQuery value) {
    if (value == _query) return;
    _query = value;
    notifyListeners();
  }
}

/// The filter/sort button, badged with the number of active filters.
///
/// Lives apart from [ChatsFilterBar] because the chats list hosts it in its
/// header row beside the New menu, not next to the search field.
class ChatsFilterButton extends StatelessWidget {
  /// Creates a [ChatsFilterButton].
  const ChatsFilterButton({
    required this.query,
    required this.onOpenFilters,
    super.key,
  });

  /// The query whose active-filter count drives the badge.
  final ChatsQuery query;

  /// Opens the filter/sort sheet.
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) => Badge.count(
    count: query.filterCount,
    isLabelVisible: query.filterCount > 0,
    child: IconButton(
      tooltip: 'Filter and sort',
      icon: const Icon(LucideIcons.slidersHorizontal300),
      visualDensity: VisualDensity.compact,
      onPressed: onOpenFilters,
    ),
  );
}

/// The compact search field and the horizontally scrollable row of removable
/// active-filter chips.
///
/// Sized to fit the ~300px desktop sidebar as well as full-width pages. The
/// filter button itself is [ChatsFilterButton], hosted in the list header.
class ChatsFilterBar extends StatelessWidget {
  /// Creates a [ChatsFilterBar].
  const ChatsFilterBar({
    required this.searchController,
    required this.query,
    required this.onQueryChanged,
    required this.agentNameOf,
    super.key,
  });

  /// The search field's text controller, owned by the host.
  final TextEditingController searchController;

  /// The query being displayed and edited.
  final ChatsQuery query;

  /// Called with the updated query when search text or a chip changes.
  final ValueChanged<ChatsQuery> onQueryChanged;

  /// Resolves an agent id to its display name for chips.
  final String Function(String agentId) agentNameOf;

  @override
  Widget build(BuildContext context) {
    final chips = _activeFilterChips(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchField(context),
        if (chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: SizedBox(
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: chips.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: AppSpacing.xs),
                itemBuilder: (context, index) => chips[index],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSearchField(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: searchController,
        builder: (context, value, _) => TextField(
          controller: searchController,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(
            hintText: 'Search chats',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            prefixIcon: const Icon(LucideIcons.search300, size: 20),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(LucideIcons.x300, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      searchController.clear();
                      onQueryChanged(query.copyWith(searchText: ''));
                    },
                  ),
          ),
          onChanged: (text) => onQueryChanged(query.copyWith(searchText: text)),
        ),
      );

  Widget _chip(String label, VoidCallback onRemoved) => InputChip(
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    deleteButtonTooltipMessage: 'Remove filter',
    onDeleted: onRemoved,
  );

  String _activityLabel(BuildContext context) {
    if (query.activity != ChatsActivityFilter.custom) {
      return query.activity.label;
    }
    final start = query.customStart;
    final end = query.customEnd;
    if (start == null || end == null) return query.activity.label;
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatShortDate(start)} – '
        '${localizations.formatShortDate(end)}';
  }

  List<Widget> _activeFilterChips(BuildContext context) {
    final agentIds = query.agentIds.toList()
      ..sort(
        (a, b) => agentNameOf(
          a,
        ).toLowerCase().compareTo(agentNameOf(b).toLowerCase()),
      );
    return [
      for (final agentId in agentIds)
        _chip(
          agentNameOf(agentId),
          () => onQueryChanged(
            query.copyWith(agentIds: {...query.agentIds}..remove(agentId)),
          ),
        ),
      if (query.activity != ChatsActivityFilter.anyTime)
        _chip(
          _activityLabel(context),
          () => onQueryChanged(
            query.copyWith(
              activity: ChatsActivityFilter.anyTime,
              customStart: null,
              customEnd: null,
            ),
          ),
        ),
      for (final capability in ChatsCapabilityFilter.values)
        if (query.capabilities.contains(capability))
          _chip(
            capability.label,
            () => onQueryChanged(
              query.copyWith(
                capabilities: {...query.capabilities}..remove(capability),
              ),
            ),
          ),
      for (final execution in ChatsExecutionType.values)
        if (query.executionTypes.contains(execution))
          _chip(
            execution.label,
            () => onQueryChanged(
              query.copyWith(
                executionTypes: {...query.executionTypes}..remove(execution),
              ),
            ),
          ),
    ];
  }
}
