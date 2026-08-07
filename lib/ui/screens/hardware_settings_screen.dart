// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:llama_cpp_flutter/orchestration.dart' as llama;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../features/hardware/hardware_info.dart';
import '../../features/local_models/local_llama_model_host.dart';
import '../app_theme.dart';
import '../widgets/settings_page.dart';
import 'storage_settings_screen.dart' show formatBytes;

/// How often the live readings refresh while the page is open.
const _refreshInterval = Duration(seconds: 2);

/// The Hardware sub-page: what this machine is, and how its memory and disk
/// are doing right now, as a grid of live monitor cards.
///
/// Every number is a real measurement or absent — the memory readings come
/// from the same mach/sysctl monitor the local runtime plans model loads
/// with, so this page and the loader can never disagree about headroom.
/// There is deliberately no separate VRAM card: on the Apple Silicon
/// hardware local models target, the GPU shares the one pool of unified
/// memory, and inventing a split number would be theater.
class HardwareSettingsScreen extends StatefulWidget {
  /// Creates a [HardwareSettingsScreen].
  const HardwareSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<HardwareSettingsScreen> createState() => _HardwareSettingsScreenState();
}

class _HardwareSettingsScreenState extends State<HardwareSettingsScreen> {
  final llama.SystemMemoryMonitor _monitor = llama.createSystemMemoryMonitor();

  HardwareFacts? _facts;
  DiskFacts? _disk;
  double? _cpuUsage;
  llama.MemorySnapshot? _memory;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFacts());
    unawaited(_sample());
    _refresh = Timer.periodic(_refreshInterval, (_) => unawaited(_sample()));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _loadFacts() async {
    final facts = await readHardwareFacts();
    if (!mounted || facts == null) return;
    setState(() => _facts = facts);
  }

  Future<void> _sample() async {
    final memory = await _monitor.sample();
    final disk = await readDiskFacts();
    final cpuUsage = await readCpuUsage();
    if (!mounted) return;
    setState(() {
      _memory = memory;
      _disk = disk;
      // The sampler measures between calls, so the first tick has nothing
      // to report; keep the previous reading rather than blanking the card.
      if (cpuUsage != null) _cpuUsage = cpuUsage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final facts = _facts;
    final disk = _disk;
    final memory = _memory;
    final measured = memory != null && !memory.isEstimated;
    final device = widget.services.getService<DeviceInfo>();
    final host = widget.services.getService<LocalLlamaModelHost>();
    return SettingsPage(
      title: 'Hardware',
      children: [
        if (device != null && device.isReady && device.summary != null)
          SettingsGroupCaption(device.summary!),
        const SettingsGroupLabel('Live monitor'),
        if (memory == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          if (!measured && facts == null)
            const SettingsGroupCaption(
              'Live readings are not available on this platform.',
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: _MonitorGrid(
              cards: [
                if (facts != null)
                  _MonitorCard(
                    label: 'CPU',
                    value: facts.chipName ?? facts.architecture ?? '—',
                    detail: [
                      if (facts.cores case final cores?) '$cores cores',
                      if (facts.chipName != null && facts.architecture != null)
                        facts.architecture!,
                    ].join(' · '),
                    fraction: _cpuUsage,
                  ),
                if (measured)
                  _MonitorCard(
                    label: 'RAM',
                    value:
                        '${formatBytes(memory.totalBytes - memory.availableBytes)}'
                        ' / ${formatBytes(memory.totalBytes)}',
                    detail: '${formatBytes(memory.availableBytes)} free',
                    fraction:
                        (memory.totalBytes - memory.availableBytes) /
                        memory.totalBytes,
                  ),
                if (measured)
                  if (memory.appFootprintBytes case final footprint?)
                    _MonitorCard(
                      label: 'This app',
                      value: formatBytes(footprint),
                      detail: 'of ${formatBytes(memory.totalBytes)} installed',
                      fraction: footprint / memory.totalBytes,
                    ),
                if (disk != null)
                  _MonitorCard(
                    label: 'Disk',
                    value:
                        '${formatBytes(disk.totalBytes - disk.freeBytes)}'
                        ' / ${formatBytes(disk.totalBytes)}',
                    detail: '${formatBytes(disk.freeBytes)} free',
                    fraction:
                        (disk.totalBytes - disk.freeBytes) / disk.totalBytes,
                  ),
              ],
            ),
          ),
          if (measured)
            const SettingsGroupCaption(
              'Memory is unified on Apple Silicon: the GPU running local '
              'models draws from this same pool, so RAM free is the honest '
              'budget for loading one. Refreshes every two seconds.',
            ),
        ],
        const Divider(height: 32),
        const SettingsGroupLabel('Local models'),
        if (host != null)
          ListTile(
            leading: const Icon(LucideIcons.cpu300),
            title: const Text('Resident model'),
            subtitle: Text(
              host.currentKey == null
                  ? 'None loaded — one loads on first use'
                  : 'Loaded and ready',
            ),
          ),
        ListTile(
          leading: const Icon(LucideIcons.hardDrive300),
          title: const Text('Storage'),
          subtitle: const Text('What local models keep on disk'),
          trailing: const Icon(LucideIcons.chevronRight300),
          onTap: () => context.go('/settings/storage'),
        ),
      ],
    );
  }
}

/// Lays [cards] out two per row where they fit, one per row when narrow.
class _MonitorGrid extends StatelessWidget {
  const _MonitorGrid({required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final twoUp = constraints.maxWidth >= 480;
      final width = twoUp
          ? (constraints.maxWidth - AppSpacing.md) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.md,
        children: [
          for (final card in cards) SizedBox(width: width, child: card),
        ],
      );
    },
  );
}

/// One live-monitor card: a small label (with a percentage when the reading
/// has one), the headline value, a one-line detail, and a usage bar.
class _MonitorCard extends StatelessWidget {
  const _MonitorCard({
    required this.label,
    required this.value,
    required this.detail,
    this.fraction,
  });

  final String label;
  final String value;
  final String detail;

  /// The used share of the resource, 0–1, or null for bar-less cards.
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fraction = this.fraction?.clamp(0.0, 1.0);
    // High pressure reads as a warning, matching what it means for the next
    // model load.
    final barColor = fraction != null && fraction >= 0.85
        ? scheme.error
        : scheme.primary;
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (fraction != null)
                  Text(
                    '${(fraction * 100).round()}%',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: barColor,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (fraction != null) ...[
              const SizedBox(height: AppSpacing.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: fraction,
                  color: barColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
