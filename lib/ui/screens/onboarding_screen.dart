// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// First-run screen shown while the app has no usable agent.
///
/// Offers the three ways to add one: an API provider, a local model, or a
/// network agent on another machine (available once agent-to-agent pairing
/// ships).
///
/// Also reachable later from Settings > General as a revisit: the router
/// guard sends configured users away from `/onboarding`, so the revisit is
/// hosted inside Settings and its actions route to the equivalent Settings
/// flows instead of the guarded onboarding sub-routes.
class OnboardingScreen extends StatelessWidget {
  /// Creates an [OnboardingScreen].
  const OnboardingScreen({
    required this.services,
    this.revisit = false,
    super.key,
  });

  /// The application service provider.
  final ServiceProvider services;

  /// Whether this is a return visit from Settings rather than first run —
  /// pushed over Settings (so it wears an app bar with a back control) with
  /// actions routed to the Settings-hosted flows.
  final bool revisit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: revisit ? AppBar() : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  // A revisit reads oddly claiming "first" at someone whose
                  // agents already exist.
                  revisit ? 'Add an agent' : 'Add your first agent',
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Agents are AI coworkers. Each one runs on a model from a '
                  'provider you configure.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _OnboardingAction(
                  icon: LucideIcons.cloud300,
                  title: 'API agent',
                  subtitle:
                      'Anthropic, Google, or any OpenAI-compatible endpoint. '
                      'Needs an API key.',
                  onTap: () => context.go(
                    revisit
                        ? '/settings/agents/add?type=api'
                        : '/onboarding/add?type=api',
                  ),
                ),
                const SizedBox(height: 12),
                _OnboardingAction(
                  icon: LucideIcons.cpu300,
                  title: 'Local agent',
                  subtitle:
                      'Runs a downloaded model on this device. No key '
                      'required, works offline.',
                  onTap: () => context.go(
                    revisit
                        ? '/settings/agents/add?type=local'
                        : '/onboarding/add?type=local',
                  ),
                ),
                const SizedBox(height: 12),
                _OnboardingAction(
                  icon: LucideIcons.network300,
                  title: 'Network agent',
                  subtitle:
                      'Use an agent shared by another device on your '
                      'network. Pair with a code from that device.',
                  onTap: () => context.go(
                    revisit ? '/settings/network/pair' : '/onboarding/pair',
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

class _OnboardingAction extends StatelessWidget {
  const _OnboardingAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Card(
      child: ListTile(
        enabled: enabled,
        leading: Icon(icon, size: 32),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: enabled ? const Icon(LucideIcons.chevronRight300) : null,
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
    );
  }
}
