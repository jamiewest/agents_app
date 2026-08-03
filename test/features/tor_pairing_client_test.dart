// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client that never answers, so the caller's timeout is what ends the wait.
class _SilentClient extends http.BaseClient {
  final completer = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      completer.future;
}

PairingPayload _offer({required String host, int port = 80}) => PairingPayload(
  hostId: '0123456789abcdef',
  host: host,
  port: port,
  token: '0123456789abcdef' * 4,
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
);

const _onion = 'vf7vhw3xqzrfqm4kqdmcyhzbfvvbfnvbfnvbfnvbfnvbfnvbfnvbfnid.onion';

void main() {
  group('pairing over Tor', () {
    test('does not give up at LAN speed', () async {
      // The first connection to an onion address has to fetch a descriptor and
      // build a rendezvous circuit — tens of seconds. An 8-second timeout
      // reported a working setup as unreachable.
      final client = PairingClient(httpClient: _SilentClient());
      addTearDown(client.close);

      final pairing = client.pair(
        _offer(host: _onion),
        clientName: 'phone',
        clientId: 'client-1',
      );

      await expectLater(
        pairing.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('still waiting'),
        ),
        throwsA(isA<TimeoutException>()),
        reason: 'gave up on Tor within 20s; it should still be waiting',
      );
    });

    test('explains Tor failures in terms of Tor', () async {
      final client = PairingClient(
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );
      addTearDown(client.close);

      await expectLater(
        client.pair(
          _offer(host: _onion),
          clientName: 'phone',
          clientId: 'client-1',
        ),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('over Tor'),
              // Pointing at the local network is worse than unhelpful here:
              // Tor exists so the devices need not share one.
              isNot(contains('same network')),
            ),
          ),
        ),
      );
    });

    test('still names the network for a LAN address', () async {
      final client = PairingClient(
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );
      addTearDown(client.close);

      await expectLater(
        client.pair(
          _offer(host: '192.168.1.20', port: 41888),
          clientName: 'phone',
          clientId: 'client-1',
        ),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('same network'),
          ),
        ),
      );
    });
  });
}
