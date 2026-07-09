import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;

/// App-wide "is the app idle right now?" signal.
///
/// A background service consults [isIdle] to decide when it is safe to do
/// low-priority work, and listens to [onActivity] to abandon that work the
/// instant the user does something. Idle means the app is foregrounded, no
/// model generation is in flight, and no user input has arrived recently.
///
/// Fed from three places: the widget root reports pointer/keyboard input
/// through [reportUserActivity] and lifecycle changes through [reportLifecycle],
/// and the chat provider brackets each model turn with
/// [beginInference]/[endInference].
class AppActivityMonitor {
  final StreamController<void> _activity = StreamController<void>.broadcast();

  DateTime _lastActivityAt = DateTime.now();
  bool _foreground = true;
  int _inFlight = 0;

  /// Fires whenever the user acts or the app leaves the foreground — the cue
  /// for in-flight background work to cancel.
  Stream<void> get onActivity => _activity.stream;

  /// Whether a model turn is currently running.
  bool get isInferenceInFlight => _inFlight > 0;

  /// Whether the app is in the foreground.
  bool get isForeground => _foreground;

  /// Records user input (a pointer or key event) as happening now.
  void reportUserActivity() {
    _lastActivityAt = DateTime.now();
    _emit();
  }

  /// Tracks foreground state.
  ///
  /// A move out of [AppLifecycleState.resumed] also counts as activity so
  /// background work stops when the app is backgrounded.
  void reportLifecycle(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (!foreground) _emit();
    _foreground = foreground;
  }

  /// Marks the start of a model turn.
  void beginInference() => _inFlight++;

  /// Marks the end of a model turn.
  void endInference() {
    if (_inFlight > 0) _inFlight--;
  }

  /// Whether the app has been idle — foregrounded, nothing generating, and no
  /// user input — for at least [threshold].
  ///
  /// [now] is injectable for tests; it defaults to the wall clock.
  bool isIdle({required Duration threshold, DateTime? now}) {
    if (!_foreground || _inFlight > 0) return false;
    final elapsed = (now ?? DateTime.now()).difference(_lastActivityAt);
    return elapsed >= threshold;
  }

  void _emit() {
    if (!_activity.isClosed) _activity.add(null);
  }
}
