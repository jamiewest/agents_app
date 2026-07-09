import 'package:agents_app/data/app_activity_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppActivityMonitor.isIdle', () {
    test('is not idle immediately after user activity', () {
      final monitor = AppActivityMonitor()..reportUserActivity();
      expect(monitor.isIdle(threshold: const Duration(hours: 1)), isFalse);
    });

    test('is idle once the threshold has elapsed', () {
      final monitor = AppActivityMonitor()..reportUserActivity();
      expect(
        monitor.isIdle(
          threshold: const Duration(seconds: 30),
          now: DateTime.now().add(const Duration(minutes: 5)),
        ),
        isTrue,
      );
    });

    test('is not idle while a generation is in flight', () {
      final monitor = AppActivityMonitor()..beginInference();
      final future = DateTime.now().add(const Duration(minutes: 5));
      expect(monitor.isIdle(threshold: Duration.zero, now: future), isFalse);
      monitor.endInference();
      expect(monitor.isIdle(threshold: Duration.zero, now: future), isTrue);
    });

    test('is not idle while backgrounded, idle again once resumed', () {
      final monitor = AppActivityMonitor();
      final future = DateTime.now().add(const Duration(minutes: 5));
      monitor.reportLifecycle(AppLifecycleState.paused);
      expect(monitor.isIdle(threshold: Duration.zero, now: future), isFalse);
      monitor.reportLifecycle(AppLifecycleState.resumed);
      expect(monitor.isIdle(threshold: Duration.zero, now: future), isTrue);
    });
  });

  group('AppActivityMonitor inference counter', () {
    test('nests begin/end and never goes negative', () {
      final monitor = AppActivityMonitor()
        ..beginInference()
        ..beginInference();
      expect(monitor.isInferenceInFlight, isTrue);
      monitor.endInference();
      expect(monitor.isInferenceInFlight, isTrue);
      monitor
        ..endInference()
        ..endInference();
      expect(monitor.isInferenceInFlight, isFalse);
    });
  });

  test('onActivity fires on user input and on backgrounding, not resume', () async {
    final monitor = AppActivityMonitor();
    final events = <void>[];
    final sub = monitor.onActivity.listen(events.add);

    monitor.reportUserActivity();
    monitor.reportLifecycle(AppLifecycleState.resumed); // no event
    monitor.reportLifecycle(AppLifecycleState.paused); // event
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(events.length, 2);
  });
}
