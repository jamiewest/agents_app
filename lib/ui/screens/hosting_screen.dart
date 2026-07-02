// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../features/network/a2a_host_service.dart'
    if (dart.library.js_interop) '../../features/network/a2a_host_service_web.dart';

/// Shares selected local agents with other devices over the LAN.
///
/// The host keeps this app open; paired devices add the shared agents as
/// network teammates. Traffic is plain HTTP on the local network — pair
/// only on networks you trust.
class HostingScreen extends StatefulWidget {
  /// Creates a [HostingScreen].
  const HostingScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  /// The app-wide host instance, kept across screen visits so hosting
  /// survives navigation.
  static A2AHostService? instance;

  @override
  State<HostingScreen> createState() => _HostingScreenState();
}

class _HostingScreenState extends State<HostingScreen> {
  List<SavedAgentConfig> _agents = const [];
  final Set<String> _selected = {};
  PairingPayload? _offer;
  String? _error;

  A2AHostService get _host =>
      HostingScreen.instance ??= A2AHostService(widget.services);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final agents = await manager.agents.listAgents();
    if (!mounted) return;
    setState(() => _agents = agents);
  }

  Future<void> _toggleHosting() async {
    setState(() {
      _error = null;
      _offer = null;
    });
    try {
      if (_host.isRunning) {
        await _host.stop();
      } else {
        final shared = [
          for (final agent in _agents)
            if (_selected.contains(agent.id)) agent,
        ];
        await _host.start(shared);
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _generateOffer() async {
    try {
      final offer = await _host.createPairingOffer();
      if (mounted) setState(() => _offer = offer);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('Share agents')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Hosting is not available in the browser. Run the app on '
              'desktop or mobile to share agents; this device can still '
              'ADD network agents via a pairing code.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final running = _host.isRunning;
    return Scaffold(
      appBar: AppBar(title: const Text('Share agents')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Other devices on your network can use the agents you '
                'share here as their own teammates. Keep this app open '
                'while sharing. Traffic is unencrypted local HTTP — use '
                'trusted networks only.',
              ),
              const SizedBox(height: 16),
              for (final agent in _agents)
                CheckboxListTile(
                  value: _selected.contains(agent.id),
                  title: Text(agent.name),
                  subtitle: agent.description.isEmpty
                      ? null
                      : Text(
                          agent.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onChanged: running
                      ? null
                      : (checked) => setState(() {
                          if (checked ?? false) {
                            _selected.add(agent.id);
                          } else {
                            _selected.remove(agent.id);
                          }
                        }),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: running || _selected.isNotEmpty
                    ? _toggleHosting
                    : null,
                icon: Icon(running ? Icons.stop : Icons.wifi_tethering),
                label: Text(
                  running
                      ? 'Stop sharing (port ${_host.port})'
                      : 'Start sharing',
                ),
              ),
              if (running) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _generateOffer,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Generate pairing code'),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_offer case final offer?) ...[
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(data: offer.encode(), size: 220),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scan on the other device, or copy the code below into '
                  'its "Add network agent" screen. Single-use; expires in '
                  'two minutes.',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  offer.encode(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
