// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// First-run screen shown while the app has no usable agent.
///
/// Offers the three ways to add one: an API provider, a local model, or a
/// network agent on another machine (available once agent-to-agent pairing
/// ships).
class OnboardingScreen extends StatelessWidget {
  /// Creates an [OnboardingScreen].
  const OnboardingScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
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
                  'Add your first agent',
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
                  icon: Icons.cloud_outlined,
                  title: 'API agent',
                  subtitle:
                      'Anthropic, Google, or any OpenAI-compatible endpoint. '
                      'Needs an API key.',
                  onTap: () => context.go('/settings/agents/add'),
                ),
                const SizedBox(height: 12),
                _OnboardingAction(
                  icon: Icons.memory_outlined,
                  title: 'Local agent',
                  subtitle:
                      'Runs a GGUF model on this device with llama.cpp. '
                      'No key required.',
                  onTap: () => context.go('/settings/agents/add'),
                ),
                const SizedBox(height: 12),
                _OnboardingAction(
                  icon: Icons.lan_outlined,
                  title: 'Network agent',
                  subtitle:
                      'Use an agent hosted on another machine. Available '
                      'soon.',
                  onTap: null,
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
        trailing: enabled ? const Icon(Icons.chevron_right) : null,
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
    );
  }
}
