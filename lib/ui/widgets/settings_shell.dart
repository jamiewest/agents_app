// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/app_reset.dart';
import '../../features/tor/tor_settings.dart';
import '../app_theme.dart';
import '../screens/agent_center_nav.dart';
import 'settings_page.dart';

/// The width at which the Settings branch shows the section sidebar and the
/// open page side by side. Matches the Chats branch's two-pane breakpoint so
/// the app's two master-detail surfaces switch layouts together.
const double settingsTwoPaneBreakpoint = 1000;

/// The fixed width of the settings section sidebar.
///
/// Narrower than the chats sidebar ([AppSidePanel.defaultWidth]): section
/// names are short and never wrap, and the reading column beside it wants
/// the room.
const double _sidebarWidth = 280;

/// The persistent chrome around every page in the Settings branch.
///
/// On wide layouts this is the two-pane settings surface: a fixed section
/// sidebar beside the open page, in the style of a desktop settings dialog.
/// On narrow layouts it renders only the page, so phones keep the existing
/// list-and-drill-down flow untouched. Either way it publishes the layout
/// mode through [SettingsScope] so pages can drop chrome the sidebar makes
/// redundant.
///
/// Built once by the Settings branch's [ShellRoute]; navigation swaps only
/// [child], so the sidebar never re-animates as sections change.
class SettingsShell extends StatelessWidget {
  /// Creates a [SettingsShell] around the branch navigator [child].
  const SettingsShell({required this.services, required this.child, super.key});

  /// The application service provider.
  final ServiceProvider services;

  /// The navigator hosting the open settings page.
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // Sized from our own constraints (not the window): the adaptive shell
    // reclaims width for the rail, and the body must degrade gracefully.
    builder: (context, constraints) {
      final twoPane = constraints.maxWidth >= settingsTwoPaneBreakpoint;
      return SettingsScope(
        twoPane: twoPane,
        child: !twoPane
            ? child
            : Row(
                children: [
                  SizedBox(
                    width: _sidebarWidth,
                    child: SettingsSidebar(services: services),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: child),
                ],
              ),
      );
    },
  );
}

/// The top-level Settings sections a sidebar row can open.
///
/// One entry per drill-down destination on the Settings page, in that page's
/// order. The Agent Center's pages are not listed here — the sidebar renders
/// them from [AgentCenterTab], the same source its compact tab strip uses,
/// as its leading group.
enum SettingsNavItem {
  /// The user profile sent to agents.
  profile(LucideIcons.userRound300, 'Profile', '/settings/profile'),

  /// Onboarding revisit and the danger zone.
  general(LucideIcons.slidersHorizontal300, 'General', '/settings/general'),

  /// Theme mode and accent colour.
  appearance(LucideIcons.palette300, 'Appearance', '/settings/appearance'),

  /// Live logs, prompt inspector, and log levels.
  logging(
    LucideIcons.receiptText300,
    'Logs & diagnostics',
    '/settings/logging',
  ),

  /// Local-model files on this device.
  storage(LucideIcons.hardDrive300, 'Storage', '/settings/storage'),

  /// What this machine is, and live memory readings.
  hardware(LucideIcons.cpu300, 'Hardware', '/settings/hardware'),

  /// How agents search what they remember.
  memory(LucideIcons.brain300, 'Memory', '/settings/memory'),

  /// The local web-search tools.
  webSearch(LucideIcons.globe300, 'Web search', '/settings/web-search'),

  /// The Pushover credentials agents notify through.
  notifications(
    LucideIcons.bellRing300,
    'Notifications',
    '/settings/notifications',
  ),

  /// The app-wide Tor switch.
  tor(LucideIcons.shield300, 'Tor', '/settings/tor'),

  /// Consuming an agent shared by another device.
  pairDevice(
    LucideIcons.qrCode300,
    'Pair with a device',
    '/settings/network/pair',
  ),

  /// Devices allowed to use agents shared from here.
  pairedDevices(
    LucideIcons.monitorSmartphone300,
    'Paired devices',
    '/settings/network/devices',
  ),

  /// Version, licenses, and the source repository.
  about(LucideIcons.info300, 'About', '/settings/about');

  const SettingsNavItem(this.icon, this.label, this.location);

  /// The row icon.
  final IconData icon;

  /// The row label.
  final String label;

  /// The route the row opens.
  final String location;

  /// Whether [path] is this section or a page inside it.
  bool isActive(String path) =>
      path == location || path.startsWith('$location/');
}

/// The sidebar's sections, grouped under the same labels the Settings page
/// uses, with the same availability rules: rows never offer something the
/// device cannot do (see the Settings page for the reasoning per row).
List<({String label, List<SettingsNavItem> items})> _groupsFor(
  ServiceProvider services,
) => [
  // Named "Agent tools" rather than the Settings page's "Agents": here the
  // section sits right under the Agent Center rows, whose Agents tab
  // already owns that word.
  (
    label: 'Agent tools',
    items: [
      SettingsNavItem.memory,
      // Absent on web, where the local web tools are unsupported and the
      // service is never registered.
      if (services.getService<WebSearchSettings>() != null)
        SettingsNavItem.webSearch,
      if (services.getService<PushoverSettings>() != null)
        SettingsNavItem.notifications,
    ],
  ),
  (label: 'You', items: [SettingsNavItem.profile, SettingsNavItem.appearance]),
  (
    label: 'App',
    items: [
      SettingsNavItem.general,
      SettingsNavItem.storage,
      SettingsNavItem.hardware,
      SettingsNavItem.about,
    ],
  ),
  (
    label: 'Connections',
    items: [
      if (services.getService<TorSettings>() != null) SettingsNavItem.tor,
      SettingsNavItem.pairDevice,
      SettingsNavItem.pairedDevices,
    ],
  ),
  (label: 'Diagnostics', items: [SettingsNavItem.logging]),
];

/// The persistent section list beside the open settings page.
///
/// Icon-and-title rows only: the live one-line summaries stay on the compact
/// Settings page, where they are the only status in view — here the open
/// page itself is right beside the row. The Agent Center keeps its summary
/// because it reports a problem state (agents needing setup) worth seeing
/// from anywhere in Settings.
class SettingsSidebar extends StatelessWidget {
  /// Creates a [SettingsSidebar].
  const SettingsSidebar({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = GoRouterState.of(context).uri.path;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: AppHeaderBand.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Settings', style: theme.textTheme.titleLarge),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              children: [
                // The Agent Center leads, merged in as first-class rows: on
                // this layout there is no drill-in section to give a card
                // to, and its pages deserve the same one-click reach as any
                // other section.
                const SettingsGroupLabel('Agent Center'),
                for (final tab in AgentCenterTab.values)
                  _SidebarRow(
                    icon: tab.icon,
                    label: tab.label,
                    selected: _agentCenterTabIsActive(tab, path),
                    // Not a plain go: through the live shell, switching
                    // tabs keeps each branch's pushed stack.
                    onTap: () => openAgentCenterTab(context, tab),
                  ),
                for (final group in _groupsFor(services)) ...[
                  SettingsGroupLabel(group.label),
                  for (final item in group.items)
                    _SidebarRow(
                      icon: item.icon,
                      label: item.label,
                      selected: item.isActive(path),
                      onTap: () => context.go(item.location),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether [tab] is the Agent Center page [path] is on.
///
/// The Agents tab's path is the section root, so a plain prefix test would
/// light it up for every sibling tab too; the active tab is the one whose
/// path is the longest match.
bool _agentCenterTabIsActive(AgentCenterTab tab, String path) {
  AgentCenterTab? best;
  for (final candidate in AgentCenterTab.values) {
    if (path != candidate.path && !path.startsWith('${candidate.path}/')) {
      continue;
    }
    if (best == null || candidate.path.length > best.path.length) {
      best = candidate;
    }
  }
  return best == tab;
}

/// One stadium-shaped sidebar row, in the style of the chats sidebar's
/// entries so the app's two sidebars read as the same control.
class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 1,
      ),
      child: Material(
        shape: const StadiumBorder(),
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Live Agent Center configuration state: how many agents exist, and how
/// many need setup before they can run, handed to [builder] as it loads and
/// reloads on configuration changes.
///
/// A builder rather than a fixed line of text so the Settings page's Agent
/// Center row can split the counts across its subtitle and warning badge.
class AgentCenterSummary extends StatefulWidget {
  /// Creates an [AgentCenterSummary].
  const AgentCenterSummary({
    required this.manager,
    required this.builder,
    super.key,
  });

  /// The saved-agents manager the summary is computed from.
  final ConfiguredAgentsManager manager;

  /// Builds the row from the loaded counts; `summary` is null until the
  /// first load completes.
  final Widget Function(
    BuildContext context,
    ({int agents, int needsSetup})? summary,
  )
  builder;

  @override
  State<AgentCenterSummary> createState() => _AgentCenterSummaryState();
}

class _AgentCenterSummaryState extends State<AgentCenterSummary> {
  late Future<({int agents, int needsSetup})> _summary;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _summary = _load();
    _changes = widget.manager.configurationChanges.listen((_) {
      if (!mounted) return;
      // Start the reload outside setState: an arrow body would hand the
      // framework a Future as the callback's return value.
      final reloaded = _load();
      setState(() {
        _summary = reloaded;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Counts saved agents, and those whose model or source no longer
  /// resolves. Configuration only — this makes no network call, so it never
  /// implies a provider is reachable.
  Future<({int agents, int needsSetup})> _load() async {
    final agents = await widget.manager.agents.listAgents();
    final models = await widget.manager.sources.listModels();
    final sources = await widget.manager.sources.listSources();
    final modelsById = {for (final model in models) model.id: model};
    final sourceIds = {for (final source in sources) source.id};
    var needsSetup = 0;
    for (final agent in agents) {
      final model = modelsById[agent.modelId];
      if (model == null || !sourceIds.contains(model.sourceId)) needsSetup++;
    }
    return (agents: agents.length, needsSetup: needsSetup);
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<({int agents, int needsSetup})>(
        future: _summary,
        builder: (context, snapshot) => widget.builder(context, snapshot.data),
      );
}

/// Asks for confirmation, then erases all app data and restarts.
///
/// Shared by the Settings page's reset row and the sidebar's, so the wording
/// of the confirmation never drifts between the two entry points.
Future<void> confirmAndResetAppData(
  BuildContext context,
  ServiceProvider services,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reset app data?'),
      content: const Text(
        'This permanently erases all model sources, API keys, models, '
        'saved agents, conversations, channels, tasks, agent memory, and '
        'downloaded local models.\n\n'
        'The app closes when the reset finishes; launch it again to '
        'start fresh.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Erase everything'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    await resetAppData(services);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Reset failed: $error')));
    return;
  }
  restartApp();
}
