// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/ui/widgets/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  group('StackedBarChart', () {
    testWidgets('exposes its summary to the semantics tree', (tester) async {
      await pump(
        tester,
        const StackedBarChart(
          data: [
            BarDatum(label: 'Mon', good: 4, bad: 1),
            BarDatum(label: 'Tue', good: 3, bad: 0),
          ],
          semanticSummary: '7 days: 8 runs, 1 failed.',
        ),
      );

      expect(
        find.bySemanticsLabel('7 days: 8 runs, 1 failed.'),
        findsOneWidget,
      );
    });

    testWidgets('renders with zero data', (tester) async {
      await pump(
        tester,
        const StackedBarChart(data: [], semanticSummary: 'No runs yet.'),
      );

      expect(find.bySemanticsLabel('No runs yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders a single bucket safely', (tester) async {
      await pump(
        tester,
        const StackedBarChart(
          data: [BarDatum(label: 'Mon', good: 1, bad: 0)],
          semanticSummary: '1 run.',
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a bar reveals its counts', (tester) async {
      await pump(
        tester,
        const SizedBox(
          width: 300,
          child: StackedBarChart(
            data: [
              BarDatum(label: 'Mon', good: 4, bad: 2),
              BarDatum(label: 'Tue', good: 3, bad: 0),
            ],
            semanticSummary: 'summary',
          ),
        ),
      );

      // Tap low in the left quarter of the plotting area — inside the
      // first bar, which is baseline-anchored.
      final rect = tester.getRect(
        find.descendant(
          of: find.byType(StackedBarChart),
          matching: find.byType(CustomPaint),
        ),
      );
      await tester.tapAt(
        Offset(rect.left + rect.width * 0.25, rect.bottom - 8),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('4 ok'), findsOneWidget);
    });
  });

  group('Sparkline', () {
    testWidgets('exposes its summary to the semantics tree', (tester) async {
      await pump(
        tester,
        const Sparkline(
          values: [1, 4, 2, 8],
          semanticSummary: '7 days: 1.2k tokens.',
        ),
      );

      expect(find.bySemanticsLabel('7 days: 1.2k tokens.'), findsOneWidget);
    });

    testWidgets('renders zero, single, and flat series safely', (tester) async {
      for (final values in [
        const <double>[],
        const [5.0],
        const [0.0, 0.0, 0.0],
      ]) {
        await pump(tester, Sparkline(values: values, semanticSummary: 's'));
        expect(tester.takeException(), isNull);
      }
    });
  });
}
