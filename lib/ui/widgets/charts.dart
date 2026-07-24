// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

/// One column of a [StackedBarChart]: a good/bad split over one time bucket.
class BarDatum {
  /// Creates a [BarDatum].
  const BarDatum({required this.label, required this.good, required this.bad});

  /// Accessible label for the bucket (e.g. a date or hour).
  final String label;

  /// The lower, "good" segment's value (succeeded runs).
  final int good;

  /// The upper, "bad" segment's value (failed runs).
  final int bad;

  /// The stacked height.
  int get total => good + bad;
}

/// A stacked bar chart drawn with a [CustomPainter] — no chart dependency.
///
/// Each bar splits into a lower "good" segment and an upper "bad" one, the
/// shape the Overview's succeeded/failed-over-time series takes. Bars are
/// baseline-anchored with rounded tops and a hairline gap between the two
/// segments. Tapping a bar reveals its counts; the whole chart also carries
/// a [Semantics] summary, so the data is reachable without sight and is the
/// surface the widget tests assert on.
class StackedBarChart extends StatefulWidget {
  /// Creates a [StackedBarChart].
  const StackedBarChart({
    required this.data,
    required this.semanticSummary,
    this.height = 160,
    super.key,
  });

  /// The bars, oldest first.
  final List<BarDatum> data;

  /// A plain-language summary of the whole series, read by screen readers
  /// and asserted by tests. For example, "7 days: 42 runs, 5 failed".
  final String semanticSummary;

  /// The chart's drawing height, excluding the reveal caption.
  final double height;

  @override
  State<StackedBarChart> createState() => _StackedBarChartState();
}

class _StackedBarChartState extends State<StackedBarChart> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxTotal = widget.data.fold<int>(
      0,
      (m, d) => d.total > m ? d.total : m,
    );
    final selected = _selected;
    final caption = selected == null || selected >= widget.data.length
        ? null
        : widget.data[selected];

    return Semantics(
      label: widget.semanticSummary,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 16,
              child: caption == null
                  ? null
                  : Text(
                      '${caption.label}: ${caption.good} ok'
                      '${caption.bad > 0 ? ', ${caption.bad} failed' : ''}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: widget.height,
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  // A bare CustomPaint does not claim hits, so without an
                  // opaque behavior taps over empty chart area never fire.
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _selectAt(details.localPosition.dx, constraints.maxWidth),
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, widget.height),
                    painter: _StackedBarPainter(
                      data: widget.data,
                      maxTotal: maxTotal,
                      selected: selected,
                      goodColor: scheme.primary,
                      badColor: scheme.error,
                      gridColor: scheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectAt(double dx, double width) {
    if (widget.data.isEmpty) return;
    final index = (dx / width * widget.data.length).floor().clamp(
      0,
      widget.data.length - 1,
    );
    setState(() => _selected = index == _selected ? null : index);
  }
}

class _StackedBarPainter extends CustomPainter {
  _StackedBarPainter({
    required this.data,
    required this.maxTotal,
    required this.selected,
    required this.goodColor,
    required this.badColor,
    required this.gridColor,
  });

  final List<BarDatum> data;
  final int maxTotal;
  final int? selected;
  final Color goodColor;
  final Color badColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    // A baseline is drawn even when empty, so the panel never looks broken.
    final baseline = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      baseline,
    );
    if (data.isEmpty || maxTotal == 0) return;

    final slot = size.width / data.length;
    // Bars occupy most of their slot with a small gutter; a lone bar is
    // capped so a single data point does not become a full-width block.
    final barWidth = (slot * 0.6).clamp(2.0, 40.0);
    final scale = size.height / maxTotal;

    for (var i = 0; i < data.length; i++) {
      final datum = data[i];
      if (datum.total == 0) continue;
      final centerX = slot * i + slot / 2;
      final left = centerX - barWidth / 2;
      final dim = selected != null && selected != i;

      final goodHeight = datum.good * scale;
      final badHeight = datum.bad * scale;
      var top = size.height;

      if (datum.good > 0) {
        final rect = Rect.fromLTWH(
          left,
          top - goodHeight,
          barWidth,
          goodHeight,
        );
        _bar(canvas, rect, goodColor.withValues(alpha: dim ? 0.35 : 1), true);
        top -= goodHeight;
      }
      if (datum.bad > 0) {
        // A 2px surface gap separates the two segments.
        top -= datum.good > 0 ? 2 : 0;
        final rect = Rect.fromLTWH(left, top - badHeight, barWidth, badHeight);
        _bar(canvas, rect, badColor.withValues(alpha: dim ? 0.35 : 1), true);
      }
    }
  }

  void _bar(Canvas canvas, Rect rect, Color color, bool roundTop) {
    final paint = Paint()..color = color;
    final radius = Radius.circular(rect.width < 8 ? rect.width / 2 : 4);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: roundTop ? radius : Radius.zero,
        topRight: roundTop ? radius : Radius.zero,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_StackedBarPainter old) =>
      old.data != data ||
      old.maxTotal != maxTotal ||
      old.selected != selected ||
      old.goodColor != goodColor;
}

/// A filled sparkline for a single time series — the Overview's tokens line.
///
/// One hue, no legend: the surrounding title names the series. Renders safely
/// for zero points (an empty panel), one point (a dot), and many. Carries a
/// [Semantics] summary for the same reasons as [StackedBarChart].
class Sparkline extends StatelessWidget {
  /// Creates a [Sparkline].
  const Sparkline({
    required this.values,
    required this.semanticSummary,
    this.height = 72,
    super.key,
  });

  /// The series, oldest first.
  final List<double> values;

  /// A plain-language summary read by screen readers and asserted by tests.
  final String semanticSummary;

  /// Drawing height.
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticSummary,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparklinePainter(
              values: values,
              lineColor: scheme.primary,
              fillColor: scheme.primary.withValues(alpha: 0.12),
              gridColor: scheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
  });

  final List<double> values;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      baseline,
    );
    if (values.isEmpty) return;

    final maxValue = values.fold<double>(0, (m, v) => v > m ? v : m);
    // A flat all-zero series still draws along the baseline rather than
    // dividing by zero.
    final scale = maxValue == 0 ? 0.0 : (size.height - 4) / maxValue;

    double x(int i) => values.length == 1
        ? size.width / 2
        : size.width * i / (values.length - 1);
    double y(double v) => size.height - 4 - v * scale;

    if (values.length == 1) {
      canvas.drawCircle(
        Offset(x(0), y(values.first)),
        3,
        Paint()..color = lineColor,
      );
      return;
    }

    final line = Path()..moveTo(x(0), y(values.first));
    for (var i = 1; i < values.length; i++) {
      line.lineTo(x(i), y(values[i]));
    }
    final fill = Path.from(line)
      ..lineTo(x(values.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = fillColor);
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.lineColor != lineColor;
}
