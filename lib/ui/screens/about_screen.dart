// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/settings_page.dart';

/// Where the app's source lives; shown and opened from the About page.
const _repositoryUrl = 'https://github.com/jamiewest/agents_app';

/// The About sub-page: what build this is, and the licenses it ships under.
///
/// Reads the harness's [AppInfo], which the package-info background service
/// populates at startup — the same metadata the `get_app_info` agent tool
/// reports, so the page and the agents never disagree about the version.
class AboutScreen extends StatefulWidget {
  /// Creates an [AboutScreen].
  const AboutScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  AppInfo? _appInfo;

  @override
  void initState() {
    super.initState();
    _appInfo = widget.services.getService<AppInfo>();
    // The cache is normally filled by the package-info background service at
    // startup, but not every platform runs it (web does not). Loading here
    // makes the page self-sufficient: populate shares the cache, so a load
    // that already happened is a no-op and a failure just keeps the dashes.
    final info = _appInfo;
    if (info != null && !info.isReady) {
      unawaited(
        populateAppInfo(info).then((_) {
          if (mounted && info.isReady) setState(() {});
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _appInfo;
    final ready = info?.isReady ?? false;
    final version = ready ? info!.version! : null;
    return SettingsPage(
      title: 'About',
      children: [
        const SettingsGroupLabel('This app'),
        _ValueTile(label: 'App', value: ready ? info!.appName! : 'Agent Teams'),
        _ValueTile(
          label: 'Version',
          value: version == null
              ? '—'
              : '$version (${info!.buildNumber!.isEmpty ? '0' : info.buildNumber!})',
        ),
        if (ready) _ValueTile(label: 'Bundle id', value: info!.packageName!),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(LucideIcons.scrollText300),
          title: const Text('Open source licenses'),
          subtitle: const Text('Every package this app ships with'),
          trailing: const Icon(LucideIcons.chevronRight300),
          onTap: () => showLicensePage(
            context: context,
            applicationName: ready ? info!.appName : 'Agent Teams',
            applicationVersion: version,
          ),
        ),
        ListTile(
          leading: const Icon(LucideIcons.code300),
          title: const Text('Source code'),
          subtitle: const Text(_repositoryUrl),
          trailing: const Icon(LucideIcons.externalLink300),
          onTap: () => unawaited(launchUrl(Uri.parse(_repositoryUrl))),
        ),
      ],
    );
  }
}

/// A read-only About row: a label with its value on the trailing edge.
class _ValueTile extends StatelessWidget {
  const _ValueTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    trailing: Text(
      value,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
