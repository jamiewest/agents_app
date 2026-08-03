// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:tor_flutter/tor_flutter.dart';

/// The app-wide Tor switch.
///
/// Owns the runtime's lifetime. Everything else — sharing agents at an onion
/// address, pairing with a peer that published one — needs Tor running but
/// none of it decides whether Tor *should* run; that is this setting.
///
/// The distinction matters most on a phone. Dialing a peer's onion address
/// requires the runtime, but not the ability to host one, and tying the two
/// together would mean a device could only reach a peer by publishing an
/// address of its own — backwards on iOS, where the app is suspended in the
/// background and cannot be reached anyway.
class TorSettings extends ChangeNotifier {
  /// Creates a [TorSettings] over [keyValueStore] and [runtime].
  TorSettings(this._keyValueStore, this._runtime, {this.startTimeout});

  /// Creates a [TorSettings] from a service provider.
  factory TorSettings.fromServices(ServiceProvider services) => TorSettings(
    services.getRequiredService<KeyValueStore>(),
    services.getRequiredService<TorRuntime>(),
  );

  static const String _enabledKey = 'agents_app.tor.enabled';
  static const String _gatewayKey = 'agents_app.tor.gateway';

  final KeyValueStore _keyValueStore;
  final TorRuntime _runtime;

  /// Backstop for a backend that never settles. Defaults to the runtime's own
  /// bootstrap timeout when absent.
  final Duration? startTimeout;

  StreamSubscription<TorStatus>? _subscription;
  bool _enabled = false;
  bool _busy = false;
  String? _error;
  String _gateway = '';

  /// Whether Tor is switched on.
  bool get enabled => _enabled;

  /// Whether a start or stop is in flight.
  bool get busy => _busy;

  /// The runtime's current state, for progress and error display.
  TorStatus get status => _runtime.status;

  /// Whether Tor is bootstrapped and usable.
  bool get isReady => _runtime.status.isReady;

  /// The last failure, if any.
  String? get error => _error;

  /// Whether this platform has a Tor backend at all.
  ///
  /// True on the web as well as natively, but the two get there differently:
  /// natively the backend talks to the Tor network itself, while a browser
  /// cannot open a connection to a relay and has to be pointed at a [gateway]
  /// that forwards on its behalf.
  bool get isSupported => true;

  /// Whether a gateway address has to be supplied before Tor can start.
  bool get requiresGateway => kIsWeb;

  /// The gateway to dial, as `ip:port:certhash`.
  ///
  /// Empty when unset. Ignored off the web, where the backend reaches relays
  /// directly.
  String get gateway => _gateway;

  /// The gateway list handed to the web backend.
  ///
  /// A single entry today. The backend takes a list because several gateways
  /// can be given for redundancy, and reads it at every start so a correction
  /// takes effect without a restart.
  List<String> get gateways =>
      _gateway.trim().isEmpty ? const [] : [_gateway.trim()];

  /// Whether Tor could be started right now.
  bool get canStart => !requiresGateway || gateways.isNotEmpty;

  /// Records the gateway to dial.
  ///
  /// Does not restart a running client: changing the address while connected
  /// would drop circuits mid-request. It takes effect on the next start.
  Future<void> setGateway(String value) async {
    final trimmed = value.trim();
    if (trimmed == _gateway) return;
    _gateway = trimmed;
    await _keyValueStore.write(_gatewayKey, trimmed);
    notifyListeners();
  }

  /// Loads the persisted preference and starts Tor if it was left on.
  ///
  /// The start is deliberately not awaited: bootstrap takes tens of seconds
  /// and holding up the first frame for it would read as a hang.
  Future<void> load() async {
    if (!isSupported) return;
    _gateway = await _keyValueStore.read(_gatewayKey) ?? '';
    _enabled = await _keyValueStore.read(_enabledKey) == 'true';
    notifyListeners();
    // Not started without somewhere to connect: on the web that is a
    // configuration gap, not a failure, and reporting it as one on every
    // launch would be noise.
    if (_enabled && canStart) unawaited(_apply());
  }

  /// Switches Tor on or off.
  Future<void> setEnabled(bool enabled) async {
    if (!isSupported || enabled == _enabled) return;
    _enabled = enabled;
    await _apply();
    // Persisted after the fact so storage records what happened rather than
    // what was asked for; a failed start saved as "on" retries and fails again
    // on every launch.
    await _keyValueStore.write(_enabledKey, '$_enabled');
  }

  Future<void> _apply() async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      if (_enabled) {
        await _start();
      } else {
        // Stopping takes any published onion service with it — the runtime
        // closes them before shutting down — so this is the master switch in
        // the literal sense.
        await _runtime.stop();
      }
    } on Object catch (error) {
      _error = error.toString();
      _enabled = false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _start() async {
    _subscription ??= _runtime.statusChanges.listen((_) => notifyListeners());
    await _runtime.start();

    // Settle on ready *or* failed. Waiting only for readiness would hang
    // forever when Tor fails, because the status stream stays open and no
    // ready state ever arrives.
    final settled = await _runtime.statusChanges
        .firstWhere((status) => status is TorReady || status is TorFailed)
        .timeout(
          startTimeout ?? const Duration(seconds: 90),
          onTimeout: () =>
              TorFailed(error: 'Tor did not finish starting in time.'),
        );
    if (settled is TorFailed) {
      throw StateError(
        settled.isClockSkew
            // Named separately because a wrong clock fails bootstrap in a way
            // that otherwise reads as a network fault.
            ? "Tor could not start because this device's clock is wrong."
            : 'Tor could not start: ${settled.error}',
      );
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
