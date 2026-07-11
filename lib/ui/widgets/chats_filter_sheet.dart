// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

import '../../domain/chats_filter.dart';
import '../app_theme.dart';

/// Shows the chats filter/sort editor and returns the applied query, or
/// `null` when dismissed.
///
/// Adaptive: a modal bottom sheet on compact widths, a dialog on wide
/// layouts (where the sheet would stretch across the whole desktop
/// window).
Future<ChatsQuery?> showChatsFilterSheet(
  BuildContext context, {
  required ChatsQuery query,
  required List<SavedAgentConfig> agents,
}) {
  final useDialog = MediaQuery.sizeOf(context).width >= 600;
  if (useDialog) {
    return showDialog<ChatsQuery>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
          child: ChatsFilterSheet(query: query, agents: agents),
        ),
      ),
    );
  }
  return showModalBottomSheet<ChatsQuery>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ChatsFilterSheet(query: query, agents: agents),
      ),
    ),
  );
}

/// The filter/sort editor: agent, last-activity, capability, and execution
/// filters plus the sort order, applied as one draft via the Apply button.
class ChatsFilterSheet extends StatefulWidget {
  /// Creates a [ChatsFilterSheet] editing a copy of [query].
  const ChatsFilterSheet({
    required this.query,
    required this.agents,
    super.key,
  });

  /// The query the draft starts from.
  final ChatsQuery query;

  /// The configured agents offered by the agent filter, in display order.
  final List<SavedAgentConfig> agents;

  @override
  State<ChatsFilterSheet> createState() => _ChatsFilterSheetState();
}

class _ChatsFilterSheetState extends State<ChatsFilterSheet> {
  late ChatsQuery _draft = widget.query;

  void _update(ChatsQuery draft) => setState(() => _draft = draft);

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final start = _draft.customStart;
    final end = _draft.customEnd;
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: start != null && end != null
          ? DateTimeRange(start: start, end: end)
          : null,
    );
    if (range == null) return;
    _update(
      _draft.copyWith(
        activity: ChatsActivityFilter.custom,
        customStart: range.start,
        customEnd: range.end,
      ),
    );
  }

  String _customRangeLabel(BuildContext context) {
    final start = _draft.customStart;
    final end = _draft.customEnd;
    if (start == null || end == null) return ChatsActivityFilter.custom.label;
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatShortDate(start)} – '
        '${localizations.formatShortDate(end)}';
  }

  Widget _sectionLabel(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _choices(List<Widget> chips) =>
      Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: chips);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.sm,
      AppSpacing.lg,
      AppSpacing.lg,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (widget.agents.isNotEmpty) ...[
                _sectionLabel(context, 'Agents'),
                _choices([
                  for (final agent in widget.agents)
                    FilterChip(
                      label: Text(agent.name),
                      selected: _draft.agentIds.contains(agent.id),
                      onSelected: (selected) => _update(
                        _draft.copyWith(
                          agentIds: selected
                              ? {..._draft.agentIds, agent.id}
                              : ({..._draft.agentIds}..remove(agent.id)),
                        ),
                      ),
                    ),
                ]),
              ],
              _sectionLabel(context, 'Last activity'),
              _choices([
                for (final activity in ChatsActivityFilter.values)
                  if (activity != ChatsActivityFilter.custom)
                    ChoiceChip(
                      label: Text(activity.label),
                      selected: _draft.activity == activity,
                      onSelected: (_) => _update(
                        _draft.copyWith(
                          activity: activity,
                          customStart: null,
                          customEnd: null,
                        ),
                      ),
                    ),
                ChoiceChip(
                  label: Text(_customRangeLabel(context)),
                  selected: _draft.activity == ChatsActivityFilter.custom,
                  onSelected: (_) => _pickCustomRange(),
                ),
              ]),
              _sectionLabel(context, 'Capabilities'),
              _choices([
                for (final capability in ChatsCapabilityFilter.values)
                  FilterChip(
                    label: Text(capability.label),
                    selected: _draft.capabilities.contains(capability),
                    onSelected: (selected) => _update(
                      _draft.copyWith(
                        capabilities: selected
                            ? {..._draft.capabilities, capability}
                            : ({..._draft.capabilities}..remove(capability)),
                      ),
                    ),
                  ),
              ]),
              _sectionLabel(context, 'Execution'),
              _choices([
                for (final execution in ChatsExecutionType.values)
                  FilterChip(
                    label: Text(execution.label),
                    selected: _draft.executionTypes.contains(execution),
                    onSelected: (selected) => _update(
                      _draft.copyWith(
                        executionTypes: selected
                            ? {..._draft.executionTypes, execution}
                            : ({..._draft.executionTypes}..remove(execution)),
                      ),
                    ),
                  ),
              ]),
              _sectionLabel(context, 'Sort'),
              _choices([
                for (final order in ChatsSortOrder.values)
                  ChoiceChip(
                    label: Text(order.label),
                    selected: _draft.sortOrder == order,
                    onSelected: (_) =>
                        _update(_draft.copyWith(sortOrder: order)),
                  ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            TextButton(
              onPressed: () =>
                  _update(ChatsQuery(searchText: _draft.searchText)),
              child: const Text('Clear all'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_draft),
              child: const Text('Apply'),
            ),
          ],
        ),
      ],
    ),
  );
}
