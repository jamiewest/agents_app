// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:tor_flutter/tor_flutter.dart';

/// Offers the shared agents over Tor as well as over the LAN.
///
/// The onion address is this device's shareable identity: it is derived from a
/// persisted key, so it survives restarts and peers keep working. Turning Tor
/// sharing on publishes the running A2A host at that address; turning it off
/// unpublishes it without touching the key, so the same address comes back.
///
/// This is a second *path* to the same host, not a second host. LAN sharing
/// and Tor sharing both serve the agents [NetworkSharingSettings] already
/// manages; only the address in the pairing offer differs.
class TorSharingSettings extends ChangeNotifier {
  /// Creates a [TorSharingSettings].
  TorSharingSettings(
    this._keyValueStore,
    this._runtime,
    this._network,
    this._identities, {
    this.bootstrapTimeout = const Duration(seconds: 90),
  });

  /// The identity used for agent sharing.
  ///
  /// A fixed id rather than a per-agent one: peers pair with the device, and
  /// one address per device is what makes the shared code stable.
  static const String identityId = 'agents_app.sharing';

  static const String _enabledKey = 'agents_app.tor.sharing.enabled';

  final KeyValueStore _keyValueStore;
  final TorRuntime _runtime;
  final NetworkSharingSettings _network;

  /// Held directly, and not reached through [TorRuntime], because deleting an
  /// identity is the one thing that has to work when the runtime cannot use
  /// it — which is exactly when it is asked for.
  final OnionIdentityStore _identities;

  /// Backstop for a backend that never settles.
  ///
  /// The platform is expected to report failure itself, but a switch that can
  /// stick on "turning on" forever is worse than one that gives up and says
  /// why.
  final Duration bootstrapTimeout;

  StreamSubscription<TorStatus>? _statusSubscription;
  OnionService? _service;
  String? _address;
  String? _error;
  bool _enabled = false;
  bool _busy = false;
  bool _identityLost = false;

  /// Whether Tor sharing is switched on.
  bool get enabled => _enabled;

  /// Whether a start or stop is in flight, so the UI can disable its controls.
  bool get busy => _busy;

  /// The onion address peers dial, once published.
  ///
  /// Available before Tor starts when an identity already exists, so the UI
  /// can show the address the user shared previously rather than a blank.
  String? get address => _address;

  /// Whether the service is published and reachable.
  bool get isPublished => _service?.isPublished ?? false;

  /// The current Tor lifecycle state, for progress and error display.
  TorStatus get status => _runtime.status;

  /// The last failure, if any.
  String? get error => _error;

  /// Whether the stored identity is known to exist but can no longer be read.
  ///
  /// Nothing can ever be published under the old address again, so switching
  /// sharing on cannot succeed until [resetIdentity] has been run. Tracked
  /// apart from [error] because every attempt clears that one, and a state the
  /// user has to act on must not vanish the moment they touch the switch.
  bool get isIdentityUnrecoverable => _identityLost;

  /// Whether this platform can host at all.
  ///
  /// Browsers cannot open server sockets, so there is nothing to publish.
  bool get isSupported => !kIsWeb;

  /// Loads the persisted preference and the previously issued address.
  ///
  /// Reads the address even when sharing is off: it is the identity the user
  /// has already handed out, and hiding it until Tor bootstraps would suggest
  /// it had changed.
  Future<void> load() async {
    if (!isSupported) return;
    _enabled = await _keyValueStore.read(_enabledKey) == 'true';
    try {
      _address = (await _runtime.identityFor(identityId))?.address;
    } on OnionIdentityUnrecoverableError catch (error) {
      // The key is gone, so the old address can never be served again. Say so
      // rather than quietly issuing a new one, because every paired peer is
      // about to stop working.
      _error = error.toString();
      _identityLost = true;
      // Not left remembered as on. Publishing reads the same missing key, but
      // only after Tor has bootstrapped, so every launch would spend a minute
      // arriving at a failure already known here.
      _enabled = false;
      await _keyValueStore.write(_enabledKey, 'false');
    }
    notifyListeners();
    if (_enabled) unawaited(_apply());
  }

  /// Switches Tor sharing on or off.
  Future<void> setEnabled(bool enabled) async {
    if (!isSupported || enabled == _enabled) return;
    // A lost key cannot be published under, and trying costs a full bootstrap
    // before failing, so switching on is refused rather than left to bounce.
    if (enabled && _identityLost) return;
    _enabled = enabled;
    await _apply();
    // Persisted after the fact, so storage records what actually happened. A
    // failed start saved as "on" would retry and fail again on every launch.
    await _keyValueStore.write(_enabledKey, '$_enabled');
  }

  /// Creates a single-use pairing offer that points at the onion address.
  ///
  /// Throws when nothing is published yet, since a peer given a LAN address
  /// by a Tor pairing code would fail in a way that looks like a Tor problem.
  Future<PairingPayload> createPairingOffer() async {
    final service = _service;
    if (service == null || !service.isPublished) {
      throw StateError('Turn on Tor sharing before creating a pairing code.');
    }
    return _network.createPairingOffer(
      advertisedHost: service.address,
      advertisedPort: service.virtualPort,
    );
  }

  /// Discards the stored identity so the next publish mints a new one.
  ///
  /// Destructive on purpose: the onion address *is* the identity, so every
  /// peer holding the old one loses its route to this device and has to pair
  /// again. Callers must confirm with the user first — this is the deliberate
  /// act [OnionIdentityUnrecoverableError] asks for, and the only way out of a
  /// key that can no longer be read.
  ///
  /// Nothing is republished afterwards. Minting an address waits for the user
  /// to switch sharing on again, so they are never handed a new identity to
  /// hand out as a side effect of clearing a broken one.
  Future<void> resetIdentity() async {
    if (!isSupported || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      // Unpublished first, so nothing is left serving the identity being
      // deleted and LAN sharing goes back to how it was.
      await _unpublish();
      await _identities.delete(identityId);
      _address = null;
      _error = null;
      _identityLost = false;
      _enabled = false;
      await _keyValueStore.write(_enabledKey, 'false');
    } on Object catch (error) {
      // A delete that fails leaves the identity exactly as unusable as it was,
      // so the flag stays set and the reset stays on offer. Clearing it here
      // would present a wedged app as repaired.
      _error = 'Could not reset the Tor identity: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _apply() async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      if (_enabled) {
        await _publish();
      } else {
        await _unpublish();
      }
    } on Object catch (error) {
      _error = error.toString();
      // Latched, never cleared here: _apply resets _error on entry, so without
      // a flag that survives the next attempt the offer to fix this would
      // disappear as soon as the user touched the switch again.
      if (error is OnionIdentityUnrecoverableError) _identityLost = true;
      _enabled = false;
      // Undo any half-applied publish, so a failure never leaves the host
      // bound to loopback with nothing forwarding to it.
      await _unpublish();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _publish() async {
    _statusSubscription ??= _runtime.statusChanges.listen(_onStatusChanged);
    await _runtime.start();

    // Bootstrap takes tens of seconds cold, so wait on the status stream
    // rather than blocking a call, and let the UI report progress meanwhile.
    // Waiting for readiness alone would wedge here forever when Tor fails,
    // because the stream stays open and no TorReady ever arrives.
    final settled = await _runtime.statusChanges
        .firstWhere((status) => status is TorReady || status is TorFailed)
        .timeout(
          bootstrapTimeout,
          onTimeout: () => TorFailed(
            error:
                'Tor did not finish starting within '
                '${bootstrapTimeout.inSeconds}s.',
          ),
        );
    if (settled is TorFailed) {
      throw StateError(_describe(settled));
    }

    // Narrowed only once Tor is actually up. Doing it earlier would leave LAN
    // sharing switched off after a failed start — silently taking away the
    // reachability the user already had.
    await _network.setLoopbackOnly(true);

    final port = _network.port;
    if (port == null) {
      throw StateError('Share an agent before turning on Tor sharing.');
    }

    _service = await _runtime.publish(identityId: identityId, localPort: port);
    _address = _service!.address;
  }

  Future<void> _unpublish() async {
    await _service?.close();
    _service = null;
    await _network.setLoopbackOnly(false);
    // The address is deliberately kept: the identity still exists, and
    // showing it lets the user confirm it will be the same when they
    // switch sharing back on.
  }

  void _onStatusChanged(TorStatus status) {
    if (status is TorFailed) _error = _describe(status);
    notifyListeners();
  }

  static String _describe(TorFailed status) => status.isClockSkew
      // Called out separately because a wrong clock reads as a network fault
      // and sends people looking in entirely the wrong place.
      ? "Tor could not start because this device's clock is wrong."
      : 'Tor could not start: ${status.error}';

  @override
  void dispose() {
    unawaited(_statusSubscription?.cancel());
    super.dispose();
  }
}
