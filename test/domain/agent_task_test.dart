// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents_app/domain/agent_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IntervalSchedule', () {
    test('runs a fixed offset after the previous run', () {
      const schedule = IntervalSchedule(30);
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 7, 2, 10)),
        DateTime.utc(2026, 7, 2, 10, 30),
      );
    });
  });

  group('WeeklySchedule', () {
    // 2 Jul 2026 is a Thursday.
    final thursday = DateTime.utc(2026, 7, 2, 10);

    test('picks the matching day later in the same week', () {
      const schedule = WeeklySchedule(weekday: DateTime.saturday);
      expect(schedule.nextRunAfter(thursday), DateTime.utc(2026, 7, 4, 9));
    });

    test('wraps to next week when the day has passed', () {
      const schedule = WeeklySchedule(weekday: DateTime.tuesday);
      expect(schedule.nextRunAfter(thursday), DateTime.utc(2026, 7, 7, 9));
    });

    test('a run on the scheduled day moves to the following week', () {
      const schedule = WeeklySchedule(
        weekday: DateTime.thursday,
        hour: 10,
        minute: 0,
      );
      expect(schedule.nextRunAfter(thursday), DateTime.utc(2026, 7, 9, 10));
    });
  });

  group('MonthlyDaySchedule', () {
    test('picks the day later in the same month', () {
      const schedule = MonthlyDaySchedule(day: 15);
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 7, 2, 10)),
        DateTime.utc(2026, 7, 15, 9),
      );
    });

    test('wraps to next month when the day has passed', () {
      const schedule = MonthlyDaySchedule(day: 1);
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 7, 2, 10)),
        DateTime.utc(2026, 8, 1, 9),
      );
    });

    test('wraps across a year boundary', () {
      const schedule = MonthlyDaySchedule(day: 5);
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 12, 20)),
        DateTime.utc(2027, 1, 5, 9),
      );
    });

    test('the 31st clamps to the last day of shorter months', () {
      const schedule = MonthlyDaySchedule(day: 31);
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 2, 1)),
        DateTime.utc(2026, 2, 28, 9),
      );
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 4, 1)),
        DateTime.utc(2026, 4, 30, 9),
      );
    });
  });

  group('MonthlyWeekdaySchedule', () {
    test('finds the first Tuesday of the month', () {
      const schedule = MonthlyWeekdaySchedule(
        week: 1,
        weekday: DateTime.tuesday,
      );
      // 1 Jul 2026 is a Wednesday, so the first Tuesday is the 7th.
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 7, 2, 10)),
        DateTime.utc(2026, 7, 7, 9),
      );
    });

    test('wraps to next month once the occurrence has passed', () {
      const schedule = MonthlyWeekdaySchedule(
        week: 1,
        weekday: DateTime.wednesday,
      );
      // The first Wednesday of July 2026 is the 1st; 3 Aug 2026 is a
      // Monday, so August's first Wednesday is the 5th.
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 7, 2, 10)),
        DateTime.utc(2026, 8, 5, 9),
      );
    });

    test('finds the last Friday of the month', () {
      const schedule = MonthlyWeekdaySchedule(
        week: MonthlyWeekdaySchedule.lastWeek,
        weekday: DateTime.friday,
      );
      // 31 Jul 2026 is a Friday.
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 7, 2, 10)),
        DateTime.utc(2026, 7, 31, 9),
      );
    });
  });

  group('schedule persistence', () {
    AgentTask taskWith(TaskSchedule? schedule) => AgentTask(
      id: 't1',
      title: 'T',
      prompt: 'P',
      agentId: 'a1',
      schedule: schedule,
      status: AgentTaskStatus.scheduled,
      createdAt: DateTime.utc(2026, 7, 1),
    );

    test('every schedule kind round-trips through its record', () {
      const schedules = [
        null,
        IntervalSchedule(1440),
        WeeklySchedule(weekday: DateTime.friday, hour: 17, minute: 30),
        MonthlyDaySchedule(day: 15, hour: 8, minute: 15),
        MonthlyWeekdaySchedule(
          week: MonthlyWeekdaySchedule.lastWeek,
          weekday: DateTime.monday,
          hour: 7,
          minute: 45,
        ),
      ];
      for (final schedule in schedules) {
        final record = taskWith(schedule).toRecord();
        expect(
          AgentTask.fromRecord('t1', record).schedule,
          schedule,
          reason: 'round-trip of $schedule',
        );
      }
    });

    test('interval schedules keep writing the legacy field', () {
      final record = taskWith(const IntervalSchedule(60)).toRecord();
      expect(record['intervalMinutes'], 60);
      expect(record.containsKey('schedule'), isFalse);
    });

    test('legacy records with intervalMinutes still load', () {
      final task = AgentTask.fromRecord('t1', {
        'title': 'T',
        'prompt': 'P',
        'agentId': 'a1',
        'intervalMinutes': 10080,
        'status': 'scheduled',
        'createdAt': '2026-07-01T00:00:00.000Z',
      });
      expect(task.schedule, const IntervalSchedule(10080));
    });
  });
}
