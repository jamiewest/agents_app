// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:animations/animations.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/screens/add_agent_wizard.dart';
import '../ui/screens/channel_screen.dart';
import '../ui/screens/chats_home.dart'
    show ChatDetailPane, ChatsHome, ChatsRootPane;
import '../ui/screens/agent_catalog_view.dart';
import '../ui/screens/agent_center_nav.dart';
import '../ui/screens/agent_center_overview_screen.dart';
import '../ui/screens/agent_center_shell.dart';
import '../ui/screens/agent_detail_screen.dart';
import '../ui/screens/agent_editor_page.dart';
import '../ui/screens/onboarding_screen.dart';
import '../ui/screens/hosting_screen.dart';
import '../ui/screens/logging_screen.dart';
import '../ui/screens/network_pairing_screen.dart';
import '../ui/screens/settings_home_screen.dart';
import '../data/task_scheduler_service.dart';
import '../ui/screens/tasks_screen.dart';
import 'app_bootstrap.dart';
import 'app_shell.dart';

/// Builds the app's router: an onboarding guard plus a stateful shell with
/// Chats, Tasks, and Settings branches.
GoRouter createAppRouter({
  required ServiceProvider services,
  required AppBootstrap bootstrap,
  required TaskSchedulerService scheduler,
  String initialLocation = '/chats',
}) => GoRouter(
  initialLocation: initialLocation,
  redirect: (context, state) async {
    // Onboarding hosts its own full-screen setup subroutes, so until the
    // app is usable everything else redirects there — the shell (rail,
    // drawer) never shows around an unconfigured app.
    final atOnboarding = state.matchedLocation.startsWith('/onboarding');
    final usable = await bootstrap.hasUsableAgent();
    if (!usable && !atOnboarding) return '/onboarding';
    if (usable && atOnboarding) return '/chats';
    return null;
  },
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/chats'),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => OnboardingScreen(services: services),
      routes: [
        GoRoute(
          path: 'add',
          builder: (context, state) => AddAgentWizard(
            services: services,
            initialKind: agentSetupKindFromName(
              state.uri.queryParameters['type'],
            ),
          ),
        ),
        GoRoute(
          path: 'pair',
          builder: (context, state) => NetworkPairingScreen(services: services),
        ),
      ],
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(services: services, shell: navigationShell),
      branches: [
        // The Chats branch is itself a stateful shell: its builder renders
        // the persistent conversations/channels sidebar, and its single
        // inner branch is the detail navigator that swaps between the open
        // chat, a channel, or an empty-state placeholder with a fade-through
        // transition. Nesting keeps the sidebar mounted (and un-animated)
        // while only the detail pane transitions.
        StatefulShellBranch(
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (context, state, navigationShell) => ChatsHome(
                services: services,
                navigationShell: navigationShell,
              ),
              branches: [
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/chats',
                      builder: (context, state) =>
                          ChatsRootPane(services: services),
                      routes: [
                        GoRoute(
                          path: 'c/:conversationId',
                          pageBuilder: (context, state) => _fadeThroughPage(
                            state,
                            ChatDetailPane(
                              services: services,
                              conversationId:
                                  state.pathParameters['conversationId'],
                            ),
                          ),
                        ),
                        GoRoute(
                          path: 'new/:agentId',
                          pageBuilder: (context, state) => _fadeThroughPage(
                            state,
                            ChatDetailPane(
                              services: services,
                              newChatAgentId: state.pathParameters['agentId'],
                              privateChat:
                                  state.uri.queryParameters['private'] == '1',
                              channelId: state.uri.queryParameters['channel'],
                            ),
                          ),
                        ),
                        GoRoute(
                          path: 'channel/:channelId',
                          pageBuilder: (context, state) => _fadeThroughPage(
                            state,
                            ChannelScreen(
                              services: services,
                              channelId: state.pathParameters['channelId']!,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/tasks',
              builder: (context, state) =>
                  TasksScreen(services: services, scheduler: scheduler),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) =>
                  SettingsHomeScreen(services: services),
              routes: [
                GoRoute(
                  path: 'network/pair',
                  builder: (context, state) =>
                      NetworkPairingScreen(services: services),
                ),
                GoRoute(
                  path: 'hosting',
                  builder: (context, state) =>
                      HostingScreen(services: services),
                ),
                GoRoute(
                  path: 'logging',
                  builder: (context, state) =>
                      LoggingScreen(services: services),
                ),
              ],
            ),
            // The Agent Center is its own nested stateful shell, a sibling of
            // the /settings page (mirroring how the Chats sidebar shell sits
            // in the Chats branch). The secondary nav is built once and only
            // the content branch swaps, so changing tabs never re-animates
            // the menu; each branch is a navigator, so a list pushes to an
            // item's page in place with the nav still visible. Branch order
            // matches [AgentCenterTab.values] so the shell maps its index.
            _agentCenterShell(services),
          ],
        ),
      ],
    ),
  ],
);

/// The Agent Center's nested stateful shell.
///
/// Four branches — overview, agents, models, sources, in
/// [AgentCenterTab.values] order so [AgentCenterShell] maps the active index
/// straight to a tab. The agents branch owns the create/edit/detail and the
/// guided-setup wizard as pushed routes; models and sources own their own
/// create/edit. Every nested route hangs off its branch root with no
/// `parentNavigatorKey`, so a pushed page renders in the content area beside
/// the persistent nav rather than covering it.
StatefulShellRoute _agentCenterShell(ServiceProvider services) =>
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AgentCenterShell(services: services, shell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings/agents/overview',
              builder: (context, state) =>
                  AgentCenterOverviewBody(services: services),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings/agents',
              builder: (context, state) => AgentCatalogView(
                services: services,
                kind: AgentCenterTab.agents,
              ),
              routes: [
                GoRoute(
                  path: 'add',
                  builder: (context, state) => AddAgentWizard(
                    services: services,
                    initialKind: agentSetupKindFromName(
                      state.uri.queryParameters['type'],
                    ),
                  ),
                ),
                GoRoute(
                  path: 'new',
                  builder: (context, state) => AgentEditorPage(
                    services: services,
                    kind: AgentCenterTab.agents,
                  ),
                ),
                GoRoute(
                  path: 'view/:id',
                  builder: (context, state) => AgentDetailScreen(
                    services: services,
                    agentId: state.pathParameters['id']!,
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => AgentEditorPage(
                    services: services,
                    kind: AgentCenterTab.agents,
                    editingId: state.pathParameters['id'],
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings/agents/models',
              builder: (context, state) => AgentCatalogView(
                services: services,
                kind: AgentCenterTab.models,
              ),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => AgentEditorPage(
                    services: services,
                    kind: AgentCenterTab.models,
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => AgentEditorPage(
                    services: services,
                    kind: AgentCenterTab.models,
                    editingId: state.pathParameters['id'],
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings/agents/sources',
              builder: (context, state) => AgentCatalogView(
                services: services,
                kind: AgentCenterTab.sources,
              ),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => AgentEditorPage(
                    services: services,
                    kind: AgentCenterTab.sources,
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => AgentEditorPage(
                    services: services,
                    kind: AgentCenterTab.sources,
                    editingId: state.pathParameters['id'],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );

/// Wraps [child] in a fade-through page transition, used for content
/// changes within a section (for example switching conversations).
///
/// Keyed by the full location so switching between two conversations (both
/// matching `c/:id`) is seen as distinct pages and animates, rather than an
/// in-place swap.
CustomTransitionPage<void> _fadeThroughPage(
  GoRouterState state,
  Widget child,
) => CustomTransitionPage<void>(
  key: ValueKey(state.uri.toString()),
  child: child,
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      ),
);
