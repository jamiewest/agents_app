/// Measures wearable bulk-transfer throughput against a live device.
///
/// Connects over BLE, joins WiFi, then downloads every manifest entry with
/// per-file timing. It never sends `/ack`, so nothing is deleted on the
/// device and the app's next real sync ingests the files normally.
///
/// Build and launch via `open` (NOT `flutter run` from a terminal — macOS
/// TCC attributes Bluetooth access to the launching process and aborts):
///
///   flutter build macos --debug -t tool/sync_speed_probe.dart
///   open build/macos/Build/Products/Debug/agents_app.app
///
/// Progress is appended to `probe_result.log` in the app's sandboxed
/// Application Support directory
/// (~/Library/Containers/dev.jamiewest.agentsApp/Data/Library/Application
/// Support/dev.jamiewest.agentsApp/probe_result.log).
library;

import 'dart:io';

import 'package:agents_app/wearable/protocol/protocol.dart';
import 'package:agents_app/wearable/transport/ble_device_transport.dart';
import 'package:agents_app/wearable/transport/capture_http_client.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

File? _resultFile;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('sync speed probe'))),
    ),
  );
  Future<void>.delayed(const Duration(seconds: 1), () async {
    final support = await getApplicationSupportDirectory();
    _resultFile = File('${support.path}/probe_result.log')
      ..writeAsStringSync('');
    await _probe();
  });
}

void _log(String message) {
  // ignore: avoid_print — CLI probe output, read from the flutter run log.
  print('[probe] $message');
  _resultFile?.writeAsStringSync('$message\n', mode: FileMode.append);
}

Future<void> _probe() async {
  var exitCode = 0;
  try {
    final transport = BleDeviceTransport();
    _log('connecting over BLE…');
    await transport.connect(timeout: const Duration(seconds: 30));
    await transport.sendCommand(
      CaptureCommands.timeSync(DateTime.now().millisecondsSinceEpoch),
    );
    var endpoint = await transport.readEndpoint();
    if (endpoint == null) {
      _log('joining wifi…');
      final joined = await transport.sendCommand(
        CaptureCommands.wifiJoin(),
        timeout: const Duration(seconds: 25),
      );
      if (!joined.ok) {
        throw Exception('wifi_join failed: ${joined.error?.wireValue}');
      }
      endpoint = await transport.readEndpoint();
    }
    if (endpoint == null) throw Exception('no endpoint published');
    _log('endpoint ${endpoint.ip}:${endpoint.port}');
    // Escape hatch for sandbox/local-network TCC denials: with the token on
    // record, the pull can be timed with curl from a terminal instead.
    _log('auth ${endpoint.authorizationHeader}');

    final client = CaptureHttpClient(endpoint);
    final manifestWatch = Stopwatch()..start();
    final manifest = await client.fetchManifest();
    _log(
      'manifest: ${manifest.entries.length} files in '
      '${manifestWatch.elapsedMilliseconds} ms',
    );

    var totalBytes = 0;
    final totalWatch = Stopwatch()..start();
    for (final entry in manifest.entries) {
      final watch = Stopwatch()..start();
      final bytes = await client.download(entry);
      watch.stop();
      totalBytes += bytes.length;
      final kbps = bytes.length / 1024 / (watch.elapsedMilliseconds / 1000);
      _log(
        'id ${entry.id} (${entry.kind.name}): '
        '${(bytes.length / 1024).toStringAsFixed(0)} KB in '
        '${watch.elapsedMilliseconds} ms — ${kbps.toStringAsFixed(0)} KB/s '
        '(crc ok)',
      );
    }
    totalWatch.stop();
    final seconds = totalWatch.elapsedMilliseconds / 1000;
    _log(
      'TOTAL ${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB in '
      '${seconds.toStringAsFixed(1)} s — '
      '${(totalBytes / 1024 / seconds).toStringAsFixed(0)} KB/s '
      '(no ack sent; files remain on device)',
    );
    client.close();
  } catch (e) {
    _log('FAILED: $e');
    exitCode = 1;
  }
  exit(exitCode);
}
