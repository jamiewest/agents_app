// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';

import '../../chat_toolkit/views/chat_message_view/llm_message_view.dart'
    show formatTokenCount;
import '../app_theme.dart';
import '../widgets/settings_page.dart';

/// The Profile sub-page: what every agent is told about the person it is
/// talking to.
///
/// Saved rather than live-bound: a half-typed sentence should not reach a
/// model mid-thought, so the profile applies from the next turn after Save.
class ProfileSettingsScreen extends StatefulWidget {
  /// Creates a [ProfileSettingsScreen].
  const ProfileSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  late final UserProfileSettings _settings;
  late final TextEditingController _name;
  late final TextEditingController _bio;

  /// What was on screen when the page opened, or when Save last succeeded —
  /// not the live settings, which another surface could change underneath an
  /// edit in progress and silently mark it clean.
  late String _savedName;
  late String _savedBio;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.services.getRequiredService<UserProfileSettings>();
    _savedName = _settings.name;
    _savedBio = _settings.bio;
    _name = TextEditingController(text: _savedName)..addListener(_markDirty);
    _bio = TextEditingController(text: _savedBio)..addListener(_markDirty);
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  void _markDirty() {
    final dirty =
        _name.text.trim() != _savedName || _bio.text.trim() != _savedBio;
    if (dirty == _dirty) return;
    setState(() => _dirty = dirty);
  }

  Future<void> _save() async {
    await _settings.save(name: _name.text, bio: _bio.text);
    if (!mounted) return;
    _savedName = _settings.name;
    _savedBio = _settings.bio;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Profile saved')));
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Profile',
    children: [
      const SettingsGroupCaption(
        'Agents are told this at the start of every conversation, so they '
        'can address you by name and answer with your situation in mind. It '
        'stays on this device and is sent only to the model providers your '
        'agents already use.',
      ),
      const SettingsGroupLabel('Name'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'What agents should call you',
          ),
        ),
      ),
      const SettingsGroupLabel('About you'),
      const SettingsGroupCaption(
        'What you work on, what you are building, how you like answers '
        'written — anything worth repeating in every chat.',
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _bio,
          minLines: 5,
          maxLines: 12,
          textCapitalization: TextCapitalization.sentences,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
            hintText:
                'I am a Flutter developer working mostly on mobile apps. '
                'Keep answers short and show code before explaining it.',
          ),
        ),
      ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _dirty ? _save : null,
            child: const Text('Save'),
          ),
        ),
      ),
      const Divider(height: 32),
      const SettingsGroupLabel('Your stats'),
      const SettingsGroupCaption(
        'Computed on this device from its own chat history. Nothing is '
        'collected or sent anywhere.',
      ),
      _ProfileStats(usage: widget.services.getRequiredService<UsageStore>()),
    ],
  );
}

/// Lifetime usage numbers, computed locally from the durable usage ledger.
class _ProfileStats extends StatefulWidget {
  const _ProfileStats({required this.usage});

  final UsageStore usage;

  @override
  State<_ProfileStats> createState() => _ProfileStatsState();
}

/// The computed stat values, or null while loading.
typedef _Stats = ({
  int tokens,
  int calls,
  int daysActive,
  DateTime? busiestDay,
});

class _ProfileStatsState extends State<_ProfileStats> {
  _Stats? _stats;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Aggregates every attributed usage row: total tokens, call count,
  /// distinct active days, and the day with the most tokens.
  Future<void> _load() async {
    final points = await widget.usage.tokenPointsSince(DateTime.utc(2000));
    var tokens = 0;
    final byDay = <DateTime, int>{};
    for (final point in points) {
      final dayTokens = point.input + point.output;
      tokens += dayTokens;
      final day = DateTime(point.at.year, point.at.month, point.at.day);
      byDay[day] = (byDay[day] ?? 0) + dayTokens;
    }
    DateTime? busiest;
    var busiestTokens = -1;
    for (final entry in byDay.entries) {
      if (entry.value > busiestTokens) {
        busiest = entry.key;
        busiestTokens = entry.value;
      }
    }
    if (!mounted) return;
    setState(() {
      _stats = (
        tokens: tokens,
        calls: points.length,
        daysActive: byDay.length,
        busiestDay: busiest,
      );
    });
  }

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    if (stats == null) return const SizedBox(height: 96);
    if (stats.calls == 0) {
      return const SettingsGroupCaption(
        'No usage yet — the numbers fill in as you chat.',
      );
    }
    final busiest = stats.busiestDay;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card.filled(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Wrap(
            spacing: AppSpacing.xxxl,
            runSpacing: AppSpacing.lg,
            children: [
              _Stat(
                value: formatTokenCount(stats.tokens),
                label: 'Lifetime tokens',
              ),
              _Stat(value: '${stats.calls}', label: 'Model calls'),
              _Stat(value: '${stats.daysActive}', label: 'Days active'),
              _Stat(
                value: busiest == null
                    ? '—'
                    : '${_months[busiest.month - 1]} ${busiest.day}',
                label: 'Busiest day',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One stat: a large value over its small label.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
