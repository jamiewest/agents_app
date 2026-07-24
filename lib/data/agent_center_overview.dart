// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'agent_run_store.dart';
import 'usage_store.dart';

/// A window of operational history the Overview can show.
enum OverviewRange {
  /// The last 24 hours, bucketed by hour.
  day('24h', Duration(hours: 24), _Bucket.hour),

  /// The last 7 days, bucketed by day. The Overview's default.
  week('7d', Duration(days: 7), _Bucket.day),

  /// The last 30 days, bucketed by day.
  month('30d', Duration(days: 30), _Bucket.day),

  /// Everything on record, bucketed by day.
  all('All', null, _Bucket.day);

  const OverviewRange(this.label, this.span, this._bucket);

  /// Short control label.
  final String label;

  /// How far back the range reaches, or null for all of history.
  final Duration? span;

  final _Bucket _bucket;

  /// The earliest instant included for a window ending at [now].
  ///
  /// [all] still needs a floor to read usage rows against; the epoch keeps
  /// every record.
  DateTime since(DateTime now) => span == null
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : now.subtract(span!);
}

enum _Bucket { hour, day }

/// One time bucket's run and token counts.
///
/// [start] is the local instant the bucket opens on: the top of the hour for
/// a 24-hour range, midnight otherwise.
class OverviewBucket {
  /// Creates an [OverviewBucket].
  const OverviewBucket({
    required this.start,
    this.succeeded = 0,
    this.failed = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  /// The local instant the bucket covers from.
  final DateTime start;

  /// Runs that finished successfully in this bucket.
  final int succeeded;

  /// Runs that failed in this bucket.
  final int failed;

  /// Prompt tokens spent in this bucket.
  final int inputTokens;

  /// Completion tokens spent in this bucket.
  final int outputTokens;

  /// Successful plus failed runs. Running and interrupted runs are not
  /// counted — a bucket measures completed work.
  int get totalRuns => succeeded + failed;

  /// Prompt plus completion tokens.
  int get totalTokens => inputTokens + outputTokens;

  OverviewBucket _add({
    int succeeded = 0,
    int failed = 0,
    int inputTokens = 0,
    int outputTokens = 0,
  }) => OverviewBucket(
    start: start,
    succeeded: this.succeeded + succeeded,
    failed: this.failed + failed,
    inputTokens: this.inputTokens + inputTokens,
    outputTokens: this.outputTokens + outputTokens,
  );
}

/// One agent's share of the workload in a range.
class AgentWorkload {
  /// Creates an [AgentWorkload].
  const AgentWorkload({
    required this.agentId,
    required this.agentName,
    required this.runs,
  });

  /// The agent's id, or a synthetic key for the folded "Other" row.
  final String agentId;

  /// The agent's display name, snapshotted from its most recent run.
  final String agentName;

  /// Runs the agent accounts for in the range.
  final int runs;
}

/// A computed snapshot of the Agent Center Overview for one time range.
///
/// Pure data: [AgentCenterOverview.from] builds it from run records and token
/// points with no I/O, so every bucketing and rate decision is unit-testable
/// away from streams and widgets.
///
/// For a bounded range the KPIs and the buckets describe the same window, so
/// the bars always sum to [totalRuns]. The [OverviewRange.all] range is the
/// one exception: its KPIs count all of history while its chart shows only
/// the most recent 30 days, because an unbounded time axis cannot be
/// plotted. That divergence is intentional and confined to [OverviewRange.all].
class AgentCenterOverview {
  /// Creates an [AgentCenterOverview].
  const AgentCenterOverview({
    required this.range,
    required this.activeAgents,
    required this.totalRuns,
    required this.succeededRuns,
    required this.failedRuns,
    required this.runningRuns,
    required this.inputTokens,
    required this.outputTokens,
    required this.buckets,
    required this.workload,
    required this.recentRuns,
  });

  /// Beyond this many agents, the smallest are folded into one "Other" row
  /// so the workload chart stays legible.
  static const int maxWorkloadAgents = 8;

  /// The range this snapshot covers.
  final OverviewRange range;

  /// Distinct agents with at least one run in the range.
  final int activeAgents;

  /// Completed runs (succeeded plus failed) in the range.
  final int totalRuns;

  /// Runs that finished successfully.
  final int succeededRuns;

  /// Runs that failed.
  final int failedRuns;

  /// Runs still in flight, shown as live status rather than history.
  final int runningRuns;

  /// Prompt tokens spent in the range.
  final int inputTokens;

  /// Completion tokens spent in the range.
  final int outputTokens;

  /// The time series, oldest bucket first.
  final List<OverviewBucket> buckets;

  /// Per-agent run counts, largest first, with a trailing "Other" row when
  /// more than [maxWorkloadAgents] agents ran.
  final List<AgentWorkload> workload;

  /// The most recent runs, newest first.
  final List<AgentRunRecord> recentRuns;

  /// Prompt plus completion tokens.
  int get totalTokens => inputTokens + outputTokens;

  /// Successful runs as a fraction of completed runs, or null when nothing
  /// has completed.
  ///
  /// The denominator is succeeded plus failed only. A run the user cancelled
  /// counts as succeeded (per [AgentRunStatus]); a run left [running] has no
  /// outcome yet; an [AgentRunStatus.interrupted] run is a crash artifact,
  /// not a judgment on the agent — so neither belongs in a success rate.
  double? get successRate => totalRuns == 0 ? null : succeededRuns / totalRuns;

  /// Whether there is enough completed history to plot a time series rather
  /// than lead with the KPI cards alone.
  bool get hasTimeSeries => totalRuns >= _timeSeriesThreshold;

  /// Fewer completed runs than this and a time series is noise; the Overview
  /// shows KPIs and the recent-runs list instead.
  static const int _timeSeriesThreshold = 3;

  /// Builds an overview for [range] as of [now] from [runs] (any order) and
  /// [tokenPoints].
  factory AgentCenterOverview.from({
    required OverviewRange range,
    required DateTime now,
    required List<AgentRunRecord> runs,
    required List<UsageTokenPoint> tokenPoints,
    int recentLimit = 8,
  }) {
    final bucketStarts = _bucketStarts(range, now);
    final byStart = {
      for (final start in bucketStarts) start: OverviewBucket(start: start),
    };

    // The KPI window and the chart window must be the same window, or the
    // bars sum to less than the headline number beside them. For a bounded
    // range the effective floor is the first bucket's start (a calendar
    // boundary), so "last 7d" means exactly the 7 days plotted. The All
    // range still counts everything, and its 30-bucket chart is a recent
    // slice of that longer history (see the class doc).
    final since = range.span == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : bucketStarts.first;
    final inRange = [
      for (final run in runs)
        if (!run.startedAt.toLocal().isBefore(since)) run,
    ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    var succeeded = 0;
    var failed = 0;
    var running = 0;
    final agentRuns = <String, int>{};
    final agentNames = <String, String>{};
    for (final run in inRange) {
      switch (run.status) {
        case AgentRunStatus.succeeded:
          succeeded++;
        case AgentRunStatus.failed:
          failed++;
        case AgentRunStatus.running:
          running++;
        case AgentRunStatus.interrupted:
          break;
      }
      if (run.status == AgentRunStatus.succeeded ||
          run.status == AgentRunStatus.failed) {
        agentRuns.update(run.agentId, (value) => value + 1, ifAbsent: () => 1);
        agentNames[run.agentId] = run.agentName;
        final key = _bucketFor(range, run.startedAt.toLocal());
        final bucket = byStart[key];
        if (bucket != null) {
          byStart[key] = bucket._add(
            succeeded: run.status == AgentRunStatus.succeeded ? 1 : 0,
            failed: run.status == AgentRunStatus.failed ? 1 : 0,
          );
        }
      }
    }

    var inputTokens = 0;
    var outputTokens = 0;
    for (final point in tokenPoints) {
      if (point.at.isBefore(since)) continue;
      inputTokens += point.input;
      outputTokens += point.output;
      final key = _bucketFor(range, point.at);
      final bucket = byStart[key];
      if (bucket != null) {
        byStart[key] = bucket._add(
          inputTokens: point.input,
          outputTokens: point.output,
        );
      }
    }

    final workload = [
      for (final entry in agentRuns.entries)
        AgentWorkload(
          agentId: entry.key,
          agentName: agentNames[entry.key] ?? entry.key,
          runs: entry.value,
        ),
    ]..sort((a, b) => b.runs.compareTo(a.runs));

    return AgentCenterOverview(
      range: range,
      activeAgents: agentRuns.length,
      totalRuns: succeeded + failed,
      succeededRuns: succeeded,
      failedRuns: failed,
      runningRuns: running,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      buckets: [for (final start in bucketStarts) byStart[start]!],
      workload: _foldWorkload(workload),
      recentRuns: inRange.take(recentLimit).toList(),
    );
  }

  static List<AgentWorkload> _foldWorkload(List<AgentWorkload> sorted) {
    if (sorted.length <= maxWorkloadAgents) return sorted;
    final kept = sorted.take(maxWorkloadAgents - 1).toList();
    final rest = sorted.skip(maxWorkloadAgents - 1);
    final otherRuns = rest.fold<int>(0, (sum, w) => sum + w.runs);
    return [
      ...kept,
      AgentWorkload(agentId: _otherKey, agentName: 'Other', runs: otherRuns),
    ];
  }

  /// The synthetic id of the folded "Other" workload row.
  static const String _otherKey = '__other__';
}

/// The ordered local bucket-start instants covering [range] as of [now].
List<DateTime> _bucketStarts(OverviewRange range, DateTime now) {
  final local = now.toLocal();
  final starts = <DateTime>[];
  switch (range._bucket) {
    case _Bucket.hour:
      final top = DateTime(local.year, local.month, local.day, local.hour);
      for (var i = 23; i >= 0; i--) {
        starts.add(top.subtract(Duration(hours: i)));
      }
    case _Bucket.day:
      final count = switch (range) {
        OverviewRange.month => 30,
        OverviewRange.all => 30,
        _ => 7,
      };
      final midnight = DateTime(local.year, local.month, local.day);
      for (var i = count - 1; i >= 0; i--) {
        starts.add(midnight.subtract(Duration(days: i)));
      }
  }
  return starts;
}

/// The bucket-start [at] falls in, in local time.
DateTime _bucketFor(OverviewRange range, DateTime at) {
  final local = at.toLocal();
  return switch (range._bucket) {
    _Bucket.hour => DateTime(local.year, local.month, local.day, local.hour),
    _Bucket.day => DateTime(local.year, local.month, local.day),
  };
}
