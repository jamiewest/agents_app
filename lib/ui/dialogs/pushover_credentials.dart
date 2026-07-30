// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';

/// Shows the Pushover credentials dialog, prefilled with the stored values.
///
/// Shared by the Settings tile and the agent editor's "not configured"
/// hint, so credentials can be added from wherever the gap is noticed.
/// [PushoverSettings] notifies on save, letting either caller's UI react
/// immediately.
Future<void> showPushoverCredentialsDialog(
  BuildContext context,
  PushoverSettings settings,
) async {
  final token = await settings.storedToken();
  final user = await settings.storedUser();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => _PushoverDialog(
      settings: settings,
      initialToken: token,
      initialUser: user,
    ),
  );
}

/// Edits the Pushover application token and user key.
///
/// Saving with both fields blank clears the configuration (and with it the
/// agents' notification tools); anything else requires both values.
class _PushoverDialog extends StatefulWidget {
  const _PushoverDialog({
    required this.settings,
    required this.initialToken,
    required this.initialUser,
  });

  final PushoverSettings settings;
  final String initialToken;
  final String initialUser;

  @override
  State<_PushoverDialog> createState() => _PushoverDialogState();
}

class _PushoverDialogState extends State<_PushoverDialog> {
  late final TextEditingController _token = TextEditingController(
    text: widget.initialToken,
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initialUser,
  );
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    _user.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _token.text.trim();
    final user = _user.text.trim();
    if (token.isEmpty != user.isEmpty) {
      setState(() {
        _error = 'Enter both values, or clear both to turn Pushover off.';
      });
      return;
    }
    if (token.isEmpty) {
      await widget.settings.clear();
    } else {
      await widget.settings.save(token: token, user: user);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Pushover notifications'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Agents get tools to notify your own devices through Pushover. '
          'Create an application at pushover.net to get a token; your user '
          'key is on the dashboard.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _token,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Application token',
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _user,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'User key',
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
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
