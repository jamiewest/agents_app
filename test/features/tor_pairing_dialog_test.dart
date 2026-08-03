// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A pairing offer the size a Tor one actually is.
///
/// The onion address is 56 characters against a LAN address's 13 or so, which
/// is the whole reason this is worth testing separately: the dialog renders
/// fine for the short payload and can still fail for the long one.
PairingPayload _torOffer() => PairingPayload(
  hostId: '0123456789abcdef',
  host: 'vf7vhw3xqzrfqm4kqdmcyhzbfvvbfnvbfnvbfnvbfnvbfnvbfnvbfnid.onion',
  port: 80,
  token: '0123456789abcdef' * 4,
  expiresAt: DateTime.utc(2026, 8, 3, 12, 34, 56),
);

void main() {
  test('a Tor pairing payload round-trips', () {
    final encoded = _torOffer().encode();
    final decoded = PairingPayload.decode(encoded);

    expect(decoded, isNotNull);
    expect(decoded!.host, endsWith('.onion'));
    expect(decoded.baseUrl, startsWith('http://'));
  });

  testWidgets('the pairing dialog renders a Tor-sized code', (tester) async {
    final offer = _torOffer();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Pairing code'),
                  // Mirrors the real dialog: the explicit width is what
                  // stops the dialog measuring an intrinsic width that
                  // QrImageView's internal LayoutBuilder cannot answer.
                  content: SizedBox(
                    width: 320,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(12),
                              child: SizedBox(
                                width: 220,
                                height: 220,
                                child: QrImageView(
                                  data: offer.encode(),
                                  size: 220,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SelectableText(offer.encode()),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The reported symptom is a dimmed barrier with nothing on it, which is
    // what a throw during the dialog's build looks like from outside.
    expect(tester.takeException(), isNull);
    expect(find.text('Pairing code'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
