// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';

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
    ],
  );
}
