// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../widgets/settings_page.dart';

/// Manages the local web-search configuration: saved search clients and the
/// reusable user-agent profiles they can send.
///
/// The checked client is the one the `web_search` tool uses; the rest are
/// stored, ready to switch to. A client without a profile association sends
/// the HTTP client's default user agent.
class WebSearchSettingsScreen extends StatelessWidget {
  /// Creates a [WebSearchSettingsScreen].
  const WebSearchSettingsScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  Widget build(BuildContext context) {
    final settings = services.getRequiredService<WebSearchSettings>();
    return SettingsPage(
      title: 'Web search',
      children: [
        ListenableBuilder(
          listenable: settings,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionIntro(
                'Agents search through the checked client: the query is '
                'appended to its URL as the q parameter, then anything the '
                'client adds after the query. A JSON response in SearXNG\'s '
                'shape is parsed directly; anything else is read as HTML. '
                'Clients with a category — finance, technology — are offered '
                'to agents as focus options, so a question searches the '
                'endpoint suited to its topic. With no clients, agents fall '
                'back to the model provider\'s built-in search, where '
                'available.',
              ),
              _SectionHeader('Search clients'),
              if (settings.clients.isEmpty)
                const _EmptyHint('No search clients yet.'),
              for (final client in settings.clients)
                _ClientTile(settings: settings, client: client),
              _AddButton(
                label: 'Add search client',
                onPressed: () => _editClient(context, settings, null),
              ),
              const Divider(height: 32),
              _SectionHeader('User agent profiles'),
              const _SectionIntro(
                'A search client can send one of these User-Agent values with '
                'its requests, and the browsing user agent below is sent when '
                'agents open pages. Without a profile, the default user agent '
                'is used.',
              ),
              if (settings.profiles.isEmpty)
                const _EmptyHint('No user agent profiles yet.'),
              for (final profile in settings.profiles)
                _ProfileTile(settings: settings, profile: profile),
              _AddButton(
                label: 'Add user agent profile',
                onPressed: () => _editProfile(context, settings, null),
              ),
              _BrowsingUserAgentTile(settings: settings),
              if (services.getService<WebSearchTraceLog>()
                  case final trace?) ...[
                const Divider(height: 32),
                _SectionHeader('Request tracing'),
                const _SectionIntro(
                  'While tracing is on, every web_search and open_web_page '
                  'call an agent makes is captured for inspection: the exact '
                  'request URL and query string, the user agent sent, the '
                  'response status, and the data received. Events are kept '
                  'in memory only and never leave this device.',
                ),
                _TracingSection(trace: trace),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Picks the profile whose User-Agent is sent when agents open pages
/// (`open_web_page`); "Default" keeps the platform WebView's own value.
class _BrowsingUserAgentTile extends StatelessWidget {
  const _BrowsingUserAgentTile({required this.settings});

  final WebSearchSettings settings;

  @override
  Widget build(BuildContext context) {
    final profile = settings.browsingProfile;
    return ListTile(
      leading: const Icon(LucideIcons.globe300),
      title: const Text('Browsing user agent'),
      subtitle: Text(
        profile == null
            ? 'Default — pages open with the system WebView\'s user agent'
            : 'Pages open as "${profile.name}"',
      ),
      trailing: const Icon(LucideIcons.chevronRight300),
      onTap: () => _pick(context),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final current = settings.browsingProfile?.id;
    final selection = await showDialog<(String?,)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Browsing user agent'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop((null,)),
            child: Row(
              children: [
                if (current == null) const Icon(LucideIcons.check300, size: 18),
                if (current == null) const SizedBox(width: 8),
                const Text('Default (system WebView)'),
              ],
            ),
          ),
          for (final profile in settings.profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop((profile.id,)),
              child: Row(
                children: [
                  if (current == profile.id)
                    const Icon(LucideIcons.check300, size: 18),
                  if (current == profile.id) const SizedBox(width: 8),
                  Flexible(
                    child: Text(profile.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selection == null) return;
    await settings.selectBrowsingProfile(selection.$1);
  }
}

/// The tracing toggle plus the entry point into the captured-request list.
class _TracingSection extends StatelessWidget {
  const _TracingSection({required this.trace});

  final WebSearchTraceLog trace;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: trace,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(LucideIcons.logs300),
          title: const Text('Trace web requests'),
          value: trace.isEnabled,
          onChanged: (value) => trace.setEnabled(value),
        ),
        ListTile(
          leading: const Icon(LucideIcons.list300),
          title: const Text('Captured requests'),
          subtitle: Text(
            trace.events.isEmpty
                ? 'None captured yet'
                : trace.events.length == 1
                ? '1 request'
                : '${trace.events.length} requests',
          ),
          trailing: const Icon(LucideIcons.chevronRight300),
          onTap: () => context.go('/settings/web-search/trace'),
        ),
      ],
    ),
  );
}

Future<void> _editClient(
  BuildContext context,
  WebSearchSettings settings,
  SearchClientConfig? client,
) => showDialog<void>(
  context: context,
  builder: (context) => _ClientDialog(settings: settings, client: client),
);

Future<void> _editProfile(
  BuildContext context,
  WebSearchSettings settings,
  UserAgentProfile? profile,
) => showDialog<void>(
  context: context,
  builder: (context) => _ProfileDialog(settings: settings, profile: profile),
);

Future<bool> _confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _SectionIntro extends StatelessWidget {
  const _SectionIntro(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(LucideIcons.plus300, size: 18),
        label: Text(label),
      ),
    ),
  );
}

/// One saved search client: check to use it, tap to edit it.
class _ClientTile extends StatelessWidget {
  const _ClientTile({required this.settings, required this.client});

  final WebSearchSettings settings;
  final SearchClientConfig client;

  @override
  Widget build(BuildContext context) {
    final selected = settings.selectedClientId == client.id;
    final profile = settings.profileFor(client);
    return ListTile(
      leading: IconButton(
        tooltip: selected ? 'In use' : 'Use this search client',
        icon: Icon(
          selected ? LucideIcons.circleCheck300 : LucideIcons.circle300,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        onPressed: () => settings.selectClient(client.id),
      ),
      title: Text(client.name),
      subtitle: Text(
        '${client.searchUrl}${client.urlSuffix.isEmpty ? '' : ' '
                  '(+${client.urlSuffix})'}\n'
        '${client.category.isEmpty ? '' : 'Category: ${client.category} · '}'
        'User agent: ${profile?.name ?? 'default'}'
        '${client.renderJavaScript ? ' · renders JavaScript' : ''}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(LucideIcons.trash2300),
        onPressed: () async {
          final confirmed = await _confirmDelete(
            context,
            title: 'Delete "${client.name}"?',
            message: settings.selectedClientId == client.id
                ? 'This client is in use; web search moves to the next '
                      'saved client, or back to the model provider\'s '
                      'built-in search when none remain.'
                : 'The saved search client is removed.',
          );
          if (confirmed) await settings.deleteClient(client.id);
        },
      ),
      onTap: () => _editClient(context, settings, client),
    );
  }
}

/// One saved user-agent profile: tap to edit.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.settings, required this.profile});

  final WebSearchSettings settings;
  final UserAgentProfile profile;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(LucideIcons.userCog300),
    title: Text(profile.name),
    subtitle: Text(
      profile.userAgent,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      tooltip: 'Delete',
      icon: const Icon(LucideIcons.trash2300),
      onPressed: () async {
        final confirmed = await _confirmDelete(
          context,
          title: 'Delete "${profile.name}"?',
          message:
              'Search clients using this profile fall back to the default '
              'user agent.',
        );
        if (confirmed) await settings.deleteProfile(profile.id);
      },
    ),
    onTap: () => _editProfile(context, settings, profile),
  );
}

/// Creates or edits one search client.
class _ClientDialog extends StatefulWidget {
  const _ClientDialog({required this.settings, this.client});

  final WebSearchSettings settings;
  final SearchClientConfig? client;

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.client?.name ?? '',
  );
  late final TextEditingController _searchUrl = TextEditingController(
    text: widget.client?.searchUrl ?? '',
  );
  late final TextEditingController _urlSuffix = TextEditingController(
    text: widget.client?.urlSuffix ?? '',
  );
  late final TextEditingController _category = TextEditingController(
    text: widget.client?.category ?? '',
  );
  // Guarded against a dangling association: an id absent from the profile
  // list would leave the dropdown's initial value without a matching item.
  late String? _profileId =
      widget.settings.profiles.any(
        (profile) => profile.id == widget.client?.userAgentProfileId,
      )
      ? widget.client?.userAgentProfileId
      : null;
  late bool _renderJavaScript = widget.client?.renderJavaScript ?? false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _searchUrl.dispose();
    _urlSuffix.dispose();
    _category.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.settings.saveClient(
        SearchClientConfig(
          id: widget.client?.id ?? '',
          name: _name.text,
          searchUrl: _searchUrl.text,
          urlSuffix: _urlSuffix.text,
          userAgentProfileId: _profileId,
          renderJavaScript: _renderJavaScript,
          category: _category.text,
        ),
      );
    } on ArgumentError {
      setState(() {
        _error =
            'Enter a valid web address, like '
            'https://searx.example.com/search.';
      });
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.client == null ? 'Add search client' : 'Edit search client',
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'My SearXNG',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchUrl,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Search URL',
                hintText: 'https://searx.example.com/search',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlSuffix,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'After the query (optional)',
                hintText: '&format=json&language=en',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _category,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Category (optional)',
                hintText: 'finance, technology, news…',
                helperText:
                    'Offered to agents as a search focus option; the '
                    'category name is visible to models.',
                helperMaxLines: 2,
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _profileId ?? '',
              decoration: const InputDecoration(
                labelText: 'User agent profile',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Default')),
                for (final profile in widget.settings.profiles)
                  DropdownMenuItem(
                    value: profile.id,
                    child: Text(profile.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) =>
                  _profileId = (value == null || value.isEmpty) ? null : value,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Render JavaScript'),
              subtitle: const Text(
                'Load results in a hidden browser first. Needed for engines '
                'that build their results with scripts, like google.com.',
              ),
              value: _renderJavaScript,
              onChanged: (value) => setState(() => _renderJavaScript = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

/// Creates or edits one user-agent profile.
class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.settings, this.profile});

  final WebSearchSettings settings;
  final UserAgentProfile? profile;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late final TextEditingController _userAgent = TextEditingController(
    text: widget.profile?.userAgent ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _userAgent.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.settings.saveProfile(
        UserAgentProfile(
          id: widget.profile?.id ?? '',
          name: _name.text,
          userAgent: _userAgent.text,
        ),
      );
    } on ArgumentError {
      setState(() => _error = 'Enter a user-agent value.');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.profile == null
          ? 'Add user agent profile'
          : 'Edit user agent profile',
    ),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Desktop Safari',
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _userAgent,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'User agent',
              hintText: 'Mozilla/5.0 (Macintosh; …) Safari/605.1.15',
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
