// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/screens/paired_devices_screen.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/extensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairedDevicesScreen', () {
    late InMemoryKeyValueStore kv;
    late ServiceProvider services;
    late AuthorizedClientsStore store;

    setUp(() {
      kv = InMemoryKeyValueStore();
      services = (ServiceCollection()..addSingleton<KeyValueStore>((_) => kv))
          .buildServiceProvider();
      store = AuthorizedClientsStore(kv);
    });

    Widget host() => MaterialApp(home: PairedDevicesScreen(services: services));

    testWidgets('says so when nothing is paired', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.textContaining('No devices are paired'), findsOneWidget);
    });

    testWidgets('lists paired devices', (tester) async {
      await store.add(
        clientId: 'c1',
        clientName: 'Jamie iPhone',
        bearerHash: 'a' * 64,
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.text('Jamie iPhone'), findsOneWidget);
    });

    testWidgets('revoking removes the bearer, not just the row', (
      tester,
    ) async {
      const bearer = 'peer-bearer';
      await store.add(
        clientId: 'c1',
        clientName: 'Jamie iPhone',
        bearerHash: PairingCrypto.sha256Hex(bearer),
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Jamie iPhone'), findsNothing);
      // The row going away is not the point: the peer's next request has to
      // fail authorization.
      expect(await store.verify(bearer), isFalse);
    });

    testWidgets('cancelling leaves the pairing alone', (tester) async {
      const bearer = 'peer-bearer';
      await store.add(
        clientId: 'c1',
        clientName: 'Jamie iPhone',
        bearerHash: PairingCrypto.sha256Hex(bearer),
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Jamie iPhone'), findsOneWidget);
      expect(await store.verify(bearer), isTrue);
    });
  });
}
