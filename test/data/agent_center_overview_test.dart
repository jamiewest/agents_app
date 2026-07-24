// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/data/agent_center_overview.dart';
import 'package:agents_app/data/agent_run_store.dart';
import 'package:agents_app/data/usage_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fixed "now" so bucket boundaries are deterministic. Local time — the
  // aggregation buckets in local time, and so must the fixtures.
  final now = DateTime(2026, 7, 23, 12);

  AgentRunRecord run({
    required String id,
    required AgentRunStatus status,
    required DateTime startedAt,
    String agentId = 'agent-1',
    String agentName = 'Researcher',
  }) => AgentRunRecord(
    id: id,
    agentId: agentId,
    agentName: agentName,
    origin: AgentRunOrigin.chat,
    status: status,
    startedAt: startedAt,
    endedAt: status == AgentRunStatus.running ? null : startedAt,
  );

  UsageTokenPoint token(DateTime at, {int input = 10, int output = 4}) =>
      UsageTokenPoint(at: at, input: input, output: output);

  AgentCenterOverview build({
    OverviewRange range = OverviewRange.week,
    List<AgentRunRecord> runs = const [],
    List<UsageTokenPoint> tokens = const [],
  }) => AgentCenterOverview.from(
    range: range,
    now: now,
    runs: runs,
    tokenPoints: tokens,
  );

  group('KPIs', () {
    test('counts active agents, runs, and outcomes in range', () {
      final overview = build(
        runs: [
          run(
            id: 'r1',
            status: AgentRunStatus.succeeded,
            startedAt: now.subtract(const Duration(hours: 1)),
          ),
          run(
            id: 'r2',
            status: AgentRunStatus.failed,
            startedAt: now.subtract(const Duration(hours: 2)),
            agentId: 'agent-2',
            agentName: 'Writer',
          ),
          run(
            id: 'r3',
            status: AgentRunStatus.running,
            startedAt: now.subtract(const Duration(minutes: 5)),
          ),
        ],
      );

      expect(overview.totalRuns, 2);
      expect(overview.succeededRuns, 1);
      expect(overview.failedRuns, 1);
      expect(overview.runningRuns, 1);
      // Running runs are live status, not completed work, so the agent that
      // only has a running run does not count as active.
      expect(overview.activeAgents, 2);
    });

    test('success rate excludes running and interrupted runs', () {
      final overview = build(
        runs: [
          run(id: 'r1', status: AgentRunStatus.succeeded, startedAt: now),
          run(id: 'r2', status: AgentRunStatus.succeeded, startedAt: now),
          run(id: 'r3', status: AgentRunStatus.failed, startedAt: now),
          run(id: 'r4', status: AgentRunStatus.running, startedAt: now),
          run(id: 'r5', status: AgentRunStatus.interrupted, startedAt: now),
        ],
      );

      // 2 of (2 succeeded + 1 failed) — the running and interrupted runs are
      // not in the denominator.
      expect(overview.successRate, closeTo(2 / 3, 1e-9));
    });

    test('success rate is null with no completed runs', () {
      final overview = build(
        runs: [run(id: 'r1', status: AgentRunStatus.running, startedAt: now)],
      );

      expect(overview.successRate, isNull);
      expect(overview.totalRuns, 0);
    });

    test('sums input and output tokens in range', () {
      final overview = build(
        tokens: [
          token(now.subtract(const Duration(hours: 1)), input: 10, output: 4),
          token(now.subtract(const Duration(hours: 2)), input: 20, output: 6),
        ],
      );

      expect(overview.inputTokens, 30);
      expect(overview.outputTokens, 10);
      expect(overview.totalTokens, 40);
    });
  });

  group('range filtering', () {
    test('a 24h range excludes older runs', () {
      final overview = build(
        range: OverviewRange.day,
        runs: [
          run(
            id: 'in',
            status: AgentRunStatus.succeeded,
            startedAt: now.subtract(const Duration(hours: 3)),
          ),
          run(
            id: 'out',
            status: AgentRunStatus.succeeded,
            startedAt: now.subtract(const Duration(hours: 30)),
          ),
        ],
      );

      expect(overview.totalRuns, 1);
      expect(overview.recentRuns.single.id, 'in');
    });

    test('the All range keeps very old runs', () {
      final overview = build(
        range: OverviewRange.all,
        runs: [
          run(
            id: 'ancient',
            status: AgentRunStatus.succeeded,
            startedAt: now.subtract(const Duration(days: 400)),
          ),
        ],
      );

      expect(overview.totalRuns, 1);
    });
  });

  group('buckets', () {
    test('a 24h range has 24 hourly buckets, oldest first', () {
      final overview = build(range: OverviewRange.day);

      expect(overview.buckets, hasLength(24));
      final starts = overview.buckets.map((b) => b.start).toList();
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i].isAfter(starts[i - 1]), isTrue);
      }
      // Hourly boundaries.
      expect(overview.buckets.every((b) => b.start.minute == 0), isTrue);
    });

    test('a 7d range has 7 daily buckets on midnight boundaries', () {
      final overview = build(range: OverviewRange.week);

      expect(overview.buckets, hasLength(7));
      expect(
        overview.buckets.every((b) => b.start.hour == 0 && b.start.minute == 0),
        isTrue,
      );
    });

    test('runs and tokens land in the same bucket by local time', () {
      final at = now.subtract(const Duration(hours: 5));
      final overview = build(
        range: OverviewRange.day,
        runs: [run(id: 'r1', status: AgentRunStatus.succeeded, startedAt: at)],
        tokens: [token(at, input: 12, output: 3)],
      );

      final bucket = overview.buckets.firstWhere(
        (b) => b.succeeded > 0,
        orElse: () => throw StateError('no bucket got the run'),
      );
      expect(bucket.inputTokens, 12);
      expect(bucket.outputTokens, 3);
      expect(bucket.totalRuns, 1);
    });

    test('a single data point renders without error', () {
      final overview = build(
        runs: [run(id: 'r1', status: AgentRunStatus.succeeded, startedAt: now)],
      );

      expect(overview.buckets.where((b) => b.totalRuns > 0), hasLength(1));
    });

    test('bars sum to the run KPI — same window for both', () {
      // A run near the old edge of the rolling window but before the first
      // calendar bucket must not be counted in the KPI while missing from
      // every bar. KPIs and buckets share one window.
      final overview = build(
        range: OverviewRange.week,
        runs: [
          for (var i = 0; i < 3; i++)
            run(
              id: 'now$i',
              status: AgentRunStatus.succeeded,
              startedAt: now.subtract(Duration(hours: i)),
            ),
          run(
            id: 'edge',
            status: AgentRunStatus.succeeded,
            startedAt: now.subtract(const Duration(days: 6, hours: 18)),
          ),
        ],
      );

      final barTotal = overview.buckets.fold<int>(
        0,
        (sum, b) => sum + b.totalRuns,
      );
      expect(barTotal, overview.totalRuns);
    });

    test('an empty range yields empty buckets, no time series', () {
      final overview = build();

      expect(overview.buckets.every((b) => b.totalRuns == 0), isTrue);
      expect(overview.hasTimeSeries, isFalse);
      expect(overview.successRate, isNull);
    });

    test('hasTimeSeries turns on past the threshold', () {
      final overview = build(
        runs: [
          for (var i = 0; i < 3; i++)
            run(
              id: 'r$i',
              status: AgentRunStatus.succeeded,
              startedAt: now.subtract(Duration(hours: i)),
            ),
        ],
      );

      expect(overview.hasTimeSeries, isTrue);
    });
  });

  group('workload', () {
    test('counts completed runs per agent, largest first', () {
      final overview = build(
        runs: [
          for (var i = 0; i < 3; i++)
            run(
              id: 'a$i',
              status: AgentRunStatus.succeeded,
              startedAt: now,
              agentId: 'agent-1',
              agentName: 'Busy',
            ),
          run(
            id: 'b1',
            status: AgentRunStatus.succeeded,
            startedAt: now,
            agentId: 'agent-2',
            agentName: 'Quiet',
          ),
        ],
      );

      expect(overview.workload.map((w) => w.agentName), ['Busy', 'Quiet']);
      expect(overview.workload.first.runs, 3);
    });

    test('folds agents beyond the cap into an Other row', () {
      final overview = build(
        runs: [
          for (var i = 0; i < 12; i++)
            run(
              id: 'r$i',
              status: AgentRunStatus.succeeded,
              startedAt: now,
              agentId: 'agent-$i',
              agentName: 'Agent $i',
            ),
        ],
      );

      expect(
        overview.workload,
        hasLength(AgentCenterOverview.maxWorkloadAgents),
      );
      expect(overview.workload.last.agentName, 'Other');
      // Every agent's run is accounted for once, folding included.
      final total = overview.workload.fold<int>(0, (sum, w) => sum + w.runs);
      expect(total, 12);
    });
  });

  group('recent runs', () {
    test('are newest first and capped', () {
      final overview = AgentCenterOverview.from(
        range: OverviewRange.week,
        now: now,
        runs: [
          for (var i = 0; i < 10; i++)
            run(
              id: 'r$i',
              status: AgentRunStatus.succeeded,
              startedAt: now.subtract(Duration(minutes: i)),
            ),
        ],
        tokenPoints: const [],
        recentLimit: 5,
      );

      expect(overview.recentRuns, hasLength(5));
      expect(overview.recentRuns.first.id, 'r0');
      expect(overview.recentRuns.last.id, 'r4');
    });
  });
}
