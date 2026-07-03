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
import '../ui/screens/manage_agents_screen.dart';
import '../ui/screens/onboarding_screen.dart';
import '../ui/screens/hosting_screen.dart';
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
    final atOnboarding = state.matchedLocation == '/onboarding';
    // Setup routes stay reachable so onboarding can add the first agent.
    final atSetup =
        state.matchedLocation.startsWith('/settings/agents') ||
        state.matchedLocation.startsWith('/settings/network');
    final usable = await bootstrap.hasUsableAgent();
    if (!usable && !atOnboarding && !atSetup) return '/onboarding';
    if (usable && atOnboarding) return '/chats';
    return null;
  },
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/chats'),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => OnboardingScreen(services: services),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(shell: navigationShell),
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
                  path: 'agents',
                  builder: (context, state) =>
                      ManageAgentsScreen(services: services),
                  routes: [
                    GoRoute(
                      path: 'add',
                      builder: (context, state) =>
                          AddAgentWizard(services: services),
                    ),
                  ],
                ),
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
              ],
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
