import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../wearable/pipeline/agent_transcription_engine.dart';
import '../../wearable/pipeline/distillation_service.dart';
import '../../wearable/protocol/protocol.dart';
import '../../wearable/transport/device_transport.dart';
import '../../wearable/wearable_service.dart';

/// Wearable capture device: one-tap sync (connect → clock sync → WiFi →
/// pull → archive → ack → transcribe → distill), recording consent, manual
/// image capture, one-time WiFi provisioning, and agent access controls.
///
/// A thin view over the app-wide [WearableService]; the same service backs
/// the agent tools.
class WearableScreen extends StatefulWidget {
  /// Creates a [WearableScreen].
  const WearableScreen({required this.services, super.key});

  /// The application service provider.
  final ServiceProvider services;

  @override
  State<WearableScreen> createState() => _WearableScreenState();
}

class _WearableScreenState extends State<WearableScreen> {
  late final WearableService _service = widget.services
      .getRequiredService<WearableService>();

  final _ssidController = TextEditingController();
  final _pskController = TextEditingController();
  final List<String> _log = [];

  DeviceConnectionState _connection = DeviceConnectionState.disconnected;
  bool _busy = false;
  bool _agentAccess = true;
  List<SavedAgentConfig> _agents = const [];
  String? _distillerAgentId;
  String? _transcriptionEngine;
  int? _imageInterval;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Camera interval choices: seconds → label. 0 turns the camera off.
  static const Map<int, String> _imageIntervals = {
    0: 'Off',
    60: 'Every minute',
    300: 'Every 5 minutes',
    900: 'Every 15 minutes',
    3600: 'Every hour',
    21600: 'Every 6 hours',
  };

  @override
  void initState() {
    super.initState();
    _connection = _service.transport.connectionState;
    _subscriptions.add(
      _service.transport.connectionStates.listen(
        (s) => setState(() => _connection = s),
      ),
    );
    _subscriptions.add(
      _service.transport.statusUpdates.listen((_) => setState(() {})),
    );
    _subscriptions.add(_service.logs.listen(_logLine));
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final manager = widget.services
        .getRequiredService<ConfiguredAgentsManager>();
    final settings = widget.services.getRequiredService<KeyValueStore>();
    final agents = await manager.agents.listAgents();
    final selected = await settings.read(
      DistillationService.distillerAgentIdKey,
    );
    final engine = await settings.read(SettingSwitchedEngine.engineSettingKey);
    final agentAccess = await _service.agentAccessEnabled();
    final imageInterval = await _service.imageInterval();
    if (!mounted) return;
    setState(() {
      _agents = agents;
      _distillerAgentId = agents.any((a) => a.id == selected) ? selected : null;
      _transcriptionEngine = engine;
      _agentAccess = agentAccess;
      _imageInterval = _imageIntervals.containsKey(imageInterval)
          ? imageInterval
          : null;
    });
  }

  Future<void> _setDistiller(String? agentId) async {
    final settings = widget.services.getRequiredService<KeyValueStore>();
    if (agentId == null) {
      await settings.delete(DistillationService.distillerAgentIdKey);
    } else {
      await settings.write(DistillationService.distillerAgentIdKey, agentId);
    }
    setState(() => _distillerAgentId = agentId);
  }

  Future<void> _setTranscriptionEngine(String? engine) async {
    final settings = widget.services.getRequiredService<KeyValueStore>();
    if (engine == null) {
      await settings.delete(SettingSwitchedEngine.engineSettingKey);
    } else {
      await settings.write(SettingSwitchedEngine.engineSettingKey, engine);
    }
    setState(() => _transcriptionEngine = engine);
  }

  Future<void> _setAgentAccess(bool enabled) async {
    await _service.setAgentAccess(enabled: enabled);
    setState(() => _agentAccess = enabled);
  }

  Future<void> _setImageInterval(int? seconds) async {
    if (seconds == null) return;
    await _guard('camera interval', () async {
      await _service.setImageInterval(seconds: seconds);
      setState(() => _imageInterval = seconds);
    });
  }

  /// Confirmation gate for the destructive maintenance actions.
  Future<bool> _confirm(String title, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _wipeDevice() async {
    if (!await _confirm(
      'Wipe device storage?',
      'Deletes every capture on the device SD card, including recordings '
          'that have not been synced yet. This cannot be undone.',
    )) {
      return;
    }
    await _guard('wipe device', _service.wipeDeviceCaptures);
  }

  Future<void> _clearLocalCaptures() async {
    if (!await _confirm(
      'Clear local captures?',
      'Deletes all downloaded audio and image files and their archive '
          'entries, including transcripts. Wearable memories are kept.',
    )) {
      return;
    }
    await _guard('clear captures', _service.clearLocalCaptures);
  }

  Future<void> _clearMemory() async {
    if (!await _confirm(
      'Clear wearable memory?',
      'Deletes everything the wearable pipeline has saved to memory. '
          'Agents will no longer be able to recall these observations.',
    )) {
      return;
    }
    await _guard('clear memory', _service.clearMemory);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _ssidController.dispose();
    _pskController.dispose();
    // The service is app-wide; it stays alive for the agent tools.
    super.dispose();
  }

  void _logLine(String message) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, '${TimeOfDay.now().format(context)}  $message');
    });
  }

  Future<void> _guard(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _logLine('$label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _connected => _connection == DeviceConnectionState.connected;

  @override
  Widget build(BuildContext context) {
    final status = _service.lastStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('Wearable device')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    _connected
                        ? Symbols.bluetooth_connected
                        : Symbols.bluetooth,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_connection.name)),
                  if (!_connected)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _guard('connect', () async {
                              await _service.ensureConnected();
                              setState(() {});
                            }),
                      child: const Text('Connect'),
                    )
                  else
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _guard('disconnect', _service.disconnect),
                      child: const Text('Disconnect'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Symbols.sync),
                    label: const Text('Sync'),
                    onPressed: _busy
                        ? null
                        : () => _guard('sync', () async {
                            await _service.syncNow();
                          }),
                  ),
                ],
              ),
            ),
          ),
          if (_connected && status != null) ...[
            const SizedBox(height: 12),
            _StatusCard(
              status: status,
              busy: _busy,
              onCaptureImage: () => _guard('capture_image', () async {
                await _service.captureImage();
              }),
              onRecordChanged: (enabled) => _guard('record', () async {
                await _service.setRecording(enabled: enabled);
                setState(() {});
              }),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              leading: const Icon(Symbols.wifi_password),
              title: const Text('WiFi credentials'),
              subtitle: const Text(
                'Stored on the device; only needed when the network changes',
              ),
              childrenPadding: const EdgeInsets.all(12),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ssidController,
                        decoration: const InputDecoration(labelText: 'SSID'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _pskController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _guard('provision', () async {
                              await _service.provisionWifi(
                                ssid: _ssidController.text,
                                psk: _pskController.text,
                              );
                              _pskController.clear();
                            }),
                      child: const Text('Provision'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Symbols.psychology),
                  title: const Text('Distiller agent'),
                  subtitle: const Text(
                    'Summarizes synced captures into wearable memory; raw '
                    'transcripts are stored when unset',
                  ),
                  trailing: DropdownButton<String?>(
                    value: _distillerAgentId,
                    hint: const Text('None'),
                    onChanged: _busy ? null : _setDistiller,
                    items: [
                      const DropdownMenuItem(child: Text('None')),
                      for (final agent in _agents)
                        DropdownMenuItem(
                          value: agent.id,
                          child: Text(agent.name),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Symbols.graphic_eq),
                  title: const Text('Transcription'),
                  subtitle: const Text(
                    'Auto uses the local model (through the distiller '
                    'agent) when one is set, else Apple Speech',
                  ),
                  trailing: DropdownButton<String?>(
                    value: _transcriptionEngine,
                    hint: const Text('Auto'),
                    onChanged: _busy ? null : _setTranscriptionEngine,
                    items: const [
                      DropdownMenuItem(child: Text('Auto')),
                      DropdownMenuItem(
                        value: SettingSwitchedEngine.localEngine,
                        child: Text('Local model'),
                      ),
                      DropdownMenuItem(
                        value: SettingSwitchedEngine.appleEngine,
                        child: Text('Apple Speech'),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Symbols.photo_camera),
                  title: const Text('Camera'),
                  subtitle: const Text(
                    'How often the device takes a picture; Off disables '
                    'the camera (manual capture still works)',
                  ),
                  trailing: DropdownButton<int>(
                    value: _imageInterval,
                    hint: const Text('Device default'),
                    onChanged: _busy ? null : _setImageInterval,
                    items: [
                      for (final MapEntry(:key, :value)
                          in _imageIntervals.entries)
                        DropdownMenuItem(value: key, child: Text(value)),
                    ],
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Symbols.smart_toy),
                  title: const Text('Agent access'),
                  subtitle: const Text(
                    'Let agents search wearable memory, check status, '
                    'capture images, and trigger syncs',
                  ),
                  value: _agentAccess,
                  onChanged: _busy ? null : _setAgentAccess,
                ),
                ListTile(
                  leading: const Icon(Symbols.memory),
                  title: const Text('Wearable memories'),
                  subtitle: const Text(
                    'Audit what the pipeline has saved to memory',
                  ),
                  trailing: const Icon(Symbols.chevron_right),
                  onTap: () => context.go('/settings/wearable/memories'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Symbols.mobile_off),
                  title: const Text('Wipe device storage'),
                  subtitle: const Text(
                    'Delete all captures on the device SD card, synced '
                    'or not',
                  ),
                  enabled: !_busy,
                  onTap: _wipeDevice,
                ),
                ListTile(
                  leading: const Icon(Symbols.folder_delete),
                  title: const Text('Clear local captures'),
                  subtitle: const Text(
                    'Delete downloaded files, transcripts, and the '
                    'capture archive on this Mac',
                  ),
                  enabled: !_busy,
                  onTap: _clearLocalCaptures,
                ),
                ListTile(
                  leading: const Icon(Symbols.delete_forever),
                  title: const Text('Clear wearable memory'),
                  subtitle: const Text(
                    'Delete everything the pipeline has saved to memory',
                  ),
                  enabled: !_busy,
                  onTap: _clearMemory,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Symbols.folder_open),
                label: const Text('Open captures folder'),
                onPressed: () async {
                  final dir = await _service.capturesDirectory();
                  await launchUrl(Uri.file(dir.path));
                },
              ),
            ],
          ),
          const Divider(),
          for (final line in _log.take(50))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.busy,
    required this.onCaptureImage,
    required this.onRecordChanged,
  });

  final DeviceStatus status;
  final bool busy;
  final VoidCallback onCaptureImage;
  final ValueChanged<bool> onRecordChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'fw ${status.firmwareVersion} · '
              '${status.fileCount} files · '
              '${(status.bufferedBytes / (1024 * 1024)).toStringAsFixed(1)} '
              'MB buffered · wifi ${status.wifi.name}',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Recording'),
                Switch(
                  value: status.recording,
                  onChanged: busy ? null : onRecordChanged,
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Symbols.photo_camera),
                  label: const Text('Capture image'),
                  onPressed: busy ? null : onCaptureImage,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
