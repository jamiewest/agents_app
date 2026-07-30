// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

import '../../strings/configured_agents_strings.dart';
import '../../styles/configured_agents_style.dart';

/// A compact list that lets the user pick one of the saved [agents].
///
/// Embeddable on its own; selecting an entry invokes [onSelected]. The
/// currently active agent (matched by [selectedId]) is highlighted.
class ConfiguredAgentPicker extends StatelessWidget {
  /// Creates a [ConfiguredAgentPicker].
  const ConfiguredAgentPicker({
    required this.agents,
    required this.onSelected,
    this.selectedId,
    this.style,
    this.strings,
    super.key,
  });

  /// The saved agents to choose from.
  final List<SavedAgentConfig> agents;

  /// Invoked when an agent is tapped.
  final void Function(SavedAgentConfig agent) onSelected;

  /// The id of the currently selected agent, if any.
  final String? selectedId;

  /// Optional style override.
  final ConfiguredAgentsStyle? style;

  /// Optional strings override.
  final ConfiguredAgentsStrings? strings;

  @override
  Widget build(BuildContext context) {
    final resolvedStyle = ConfiguredAgentsStyle.resolveFor(context, style);
    final resolvedStrings =
        strings ?? resolvedStyle.strings ?? ConfiguredAgentsStrings.defaults;

    if (agents.isEmpty) {
      return Padding(
        padding: resolvedStyle.contentPadding ?? const EdgeInsets.all(16),
        child: Text(
          resolvedStrings.noAgents,
          style: resolvedStyle.bodyTextStyle,
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: agents.length,
      itemBuilder: (context, index) {
        final agent = agents[index];
        return ListTile(
          selected: agent.id == selectedId,
          title: Text(agent.name, style: resolvedStyle.titleTextStyle),
          subtitle: agent.description.isEmpty
              ? null
              : Text(agent.description, style: resolvedStyle.subtitleTextStyle),
          onTap: () => onSelected(agent),
        );
      },
    );
  }
}
