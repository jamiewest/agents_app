// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Adds agents hosted on another device: paste a pairing code, redeem it,
/// pick which of the host's agents to add as teammates.
class NetworkPairingScreen extends StatefulWidget {
  /// Creates a [NetworkPairingScreen].
  const NetworkPairingScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<NetworkPairingScreen> createState() => _NetworkPairingScreenState();
}

class _NetworkPairingScreenState extends State<NetworkPairingScreen> {
  String _code = '';
  String? _error;
  bool _busy = false;
  PairingResult? _result;
  List<HostedAgentSummary> _agents = const [];
  final Set<String> _selected = {};

  Future<void> _pair() async {
    final payload = PairingPayload.decode(_code);
    if (payload == null) {
      setState(
        () => _error =
            'That does not look like a pairing code. Copy the '
            'full code from the host\'s sharing screen.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = PairingClient();
      final result = await client.pair(
        payload,
        clientName: 'agents_app',
        clientId: PairingCrypto.newToken().substring(0, 16),
      );
      final agents = await client.listAgents(result.baseUrl, result.credential);
      if (!mounted) return;
      setState(() {
        _result = result;
        _agents = agents;
        _selected
          ..clear()
          ..addAll(agents.map((agent) => agent.path));
      });
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Pairing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSelected() async {
    final result = _result!;
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final sourceId = 'net-${result.hostId}';
    await manager.saveSource(
      ModelSourceConfig(
        id: sourceId,
        providerType: ProviderType.network,
        displayName: result.deviceName,
        endpoint: result.baseUrl,
      ),
      // The pairing bearer lives where API keys live: the secret store.
      apiKey: result.credential,
    );

    for (final agent in _agents) {
      if (!_selected.contains(agent.path)) continue;
      final slug = agent.path.split('/').last;
      final modelId = '$sourceId-$slug';
      await manager.saveModel(
        ModelConfig(
          id: modelId,
          sourceId: sourceId,
          modelId: agent.path,
          displayName: '${agent.name} @ ${result.deviceName}',
        ),
      );
      await manager.saveAgent(
        SavedAgentConfig(
          id: '$modelId-agent',
          name: agent.name,
          modelId: modelId,
          description: agent.description,
        ),
      );
    }
    if (mounted) context.go('/chats');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add network agent')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'On the hosting device, open Settings → Share agents and '
              'generate a pairing code. Paste it here. Codes are single-use '
              'and expire after two minutes.',
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) => _code = value,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _pair,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: const Text('Pair'),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_result case final result?) ...[
              const SizedBox(height: 24),
              Text(
                'Paired with ${result.deviceName}. Choose agents to add:',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final agent in _agents)
                CheckboxListTile(
                  value: _selected.contains(agent.path),
                  title: Text(agent.name),
                  subtitle: agent.description.isEmpty
                      ? null
                      : Text(agent.description),
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      _selected.add(agent.path);
                    } else {
                      _selected.remove(agent.path);
                    }
                  }),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _selected.isEmpty ? null : _addSelected,
                icon: const Icon(Icons.group_add_outlined),
                label: Text('Add ${_selected.length} agent(s)'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
