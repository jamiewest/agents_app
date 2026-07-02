// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:animations/animations.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/screens/add_agent_wizard.dart';
import '../ui/screens/channel_screen.dart';
import '../ui/screens/chats_home.dart';
import '../ui/screens/manage_agents_screen.dart';
import '../ui/screens/onboarding_screen.dart';
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
    final atSetup = state.matchedLocation.startsWith('/settings/agents');
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
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/chats',
              pageBuilder: (context, state) =>
                  _fadeThroughPage(state, ChatsHome(services: services)),
              routes: [
                GoRoute(
                  path: 'c/:conversationId',
                  pageBuilder: (context, state) => _fadeThroughPage(
                    state,
                    ChatsHome(
                      services: services,
                      conversationId: state.pathParameters['conversationId'],
                    ),
                  ),
                ),
                GoRoute(
                  path: 'new/:agentId',
                  pageBuilder: (context, state) => _fadeThroughPage(
                    state,
                    ChatsHome(
                      services: services,
                      newChatAgentId: state.pathParameters['agentId'],
                      privateChat: state.uri.queryParameters['private'] == '1',
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
CustomTransitionPage<void> _fadeThroughPage(
  GoRouterState state,
  Widget child,
) => CustomTransitionPage<void>(
  key: state.pageKey,
  child: child,
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      ),
);
