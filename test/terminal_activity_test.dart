import 'dart:async';

import 'package:agents/agents.dart'
    show ShellExecutor, ShellOutputChannel, ShellOutputChunk, ShellResult;
import 'package:agents_app/data/terminal_activity.dart';
import 'package:extensions/system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TerminalMirroringShellExecutor', () {
    test('streams live output lines while the command runs', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final inner = _StreamingShellExecutor();
      final executor = TerminalMirroringShellExecutor(
        inner,
        registry: registry,
        conversationId: 'conv-a',
      );
      String? textMidCommand;
      inner.onRun = (command) {
        inner.emit(command, 'building...\n');
        textMidCommand = session.terminal.buffer.getText().trim();
        inner.emit(command, 'warning: slow\n', channel: ShellOutputChannel.stderr);
        inner.emit(command, 'done\n');
      };

      await executor.runAsync('make');

      // The first line was on screen before the command finished.
      expect(textMidCommand, contains('building...'));
      final text = session.terminal.buffer.getText();
      expect(text, contains('warning: slow'));
      expect(text, contains('done'));
      // Streamed output is not echoed a second time from the buffered
      // result: one occurrence per line.
      expect('done'.allMatches(text), hasLength(1));
    });

    test('ignores chunks from other commands', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final inner = _StreamingShellExecutor();
      final executor = TerminalMirroringShellExecutor(
        inner,
        registry: registry,
        conversationId: 'conv-a',
      );
      inner.onRun = (command) {
        inner.emit('other-command', 'foreign line\n');
        inner.emit(command, 'own line\n');
      };

      await executor.runAsync('make');

      final text = session.terminal.buffer.getText();
      expect(text, contains('own line'));
      expect(text, isNot(contains('foreign line')));
    });

    test('echoes the command, output, and status into the session', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final executor = TerminalMirroringShellExecutor(
        _ScriptedShellExecutor([
          const ShellResult(
            stdout: 'hello\nworld',
            stderr: '',
            exitCode: 0,
            duration: Duration(milliseconds: 1200),
          ),
        ]),
        registry: registry,
        conversationId: 'conv-a',
      );

      final result = await executor.runAsync('echo hello');

      // The decorator is a pure observer: the result passes through intact.
      expect(result.stdout, 'hello\nworld');
      expect(session.hasOutput, isTrue);
      expect(session.commandCount, 1);
      expect(session.runningCommand, isNull);
      final text = session.terminal.buffer.getText();
      expect(text, contains('\$ echo hello'));
      expect(text, contains('hello'));
      expect(text, contains('world'));
      expect(text, contains('1.2s'));
    });

    test('marks the command as running while it executes', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final inner = _ScriptedShellExecutor([
        const ShellResult(
          stdout: '',
          stderr: '',
          exitCode: 0,
          duration: Duration(milliseconds: 100),
        ),
      ]);
      final executor = TerminalMirroringShellExecutor(
        inner,
        registry: registry,
        conversationId: 'conv-a',
      );
      String? observedWhileRunning;
      inner.onRun = () => observedWhileRunning = session.runningCommand;

      await executor.runAsync('sleep 1');

      expect(observedWhileRunning, 'sleep 1');
      expect(session.runningCommand, isNull);
    });

    test('shows stderr and a non-zero exit status', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final executor = TerminalMirroringShellExecutor(
        _ScriptedShellExecutor([
          const ShellResult(
            stdout: '',
            stderr: 'no such file',
            exitCode: 2,
            duration: Duration(milliseconds: 40),
          ),
        ]),
        registry: registry,
        conversationId: 'conv-a',
      );

      await executor.runAsync('ls /nope');

      final text = session.terminal.buffer.getText();
      expect(text, contains('no such file'));
      expect(text, contains('exit 2'));
    });

    test('an executor failure lands in the terminal and rethrows', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final executor = TerminalMirroringShellExecutor(
        _ScriptedShellExecutor([], error: StateError('rejected by policy')),
        registry: registry,
        conversationId: 'conv-a',
      );

      await expectLater(executor.runAsync('rm -rf /'), throwsStateError);

      expect(session.runningCommand, isNull);
      expect(
        session.terminal.buffer.getText(),
        contains('rejected by policy'),
      );
    });

    test('runs without a session (background task) touch nothing', () async {
      final registry = TerminalActivity();
      final executor = TerminalMirroringShellExecutor(
        _ScriptedShellExecutor([
          const ShellResult(
            stdout: 'ok',
            stderr: '',
            exitCode: 0,
            duration: Duration(milliseconds: 10),
          ),
        ]),
        registry: registry,
        conversationId: 'background-task',
      );

      // No chat holds the session: nothing to observe, nothing thrown.
      final result = await executor.runAsync('true');
      expect(result.stdout, 'ok');
    });

    test('delegate scopes write into the parent conversation', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      final executor = TerminalMirroringShellExecutor(
        _ScriptedShellExecutor([
          const ShellResult(
            stdout: '',
            stderr: '',
            exitCode: 0,
            duration: Duration(milliseconds: 10),
          ),
        ]),
        registry: registry,
        conversationId: 'conv-a#delegate-1',
      );

      await executor.runAsync('pwd');

      expect(session.commandCount, 1);
      expect(session.terminal.buffer.getText(), contains('\$ pwd'));
    });
  });

  group('ChatTerminalSession', () {
    test('clear drops the buffer and hides the panel', () async {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      session.beginCommand('echo hi');
      final before = session.terminal;

      session.clear();

      expect(session.hasOutput, isFalse);
      expect(session.commandCount, 0);
      expect(session.runningCommand, isNull);
      expect(identical(session.terminal, before), isFalse);
    });

    test('notifies on command begin and completion', () {
      final registry = TerminalActivity();
      final session = registry.listen('conv-a');
      var notifications = 0;
      session.addListener(() => notifications++);

      session.beginCommand('echo hi');
      session.completeCommand(
        const ShellResult(
          stdout: 'hi',
          stderr: '',
          exitCode: 0,
          duration: Duration(milliseconds: 5),
        ),
      );

      expect(notifications, 2);
    });
  });

  group('TerminalActivity registry', () {
    test('refcounted release keeps the session until the last ref', () {
      final registry = TerminalActivity();
      final first = registry.listen('conv-a');
      final second = registry.listen('conv-a');
      expect(identical(first, second), isTrue);

      registry.release('conv-a');
      // Still alive: the second ref holds it.
      expect(identical(registry.sessionFor('conv-a'), first), isTrue);

      registry.release('conv-a');
      // Disposed: background runs find no session to buffer into.
      expect(registry.sessionFor('conv-a'), isNull);
      final fresh = registry.listen('conv-a');
      expect(identical(fresh, first), isFalse);
    });

    test('sessions are isolated per conversation', () {
      final registry = TerminalActivity();
      final a = registry.listen('conv-a');
      final b = registry.listen('conv-b');
      expect(identical(a, b), isFalse);
      expect(identical(registry.sessionFor('conv-b'), b), isTrue);
    });
  });
}

/// A fake executor with the built-in executors' streaming shape: a sync
/// broadcast [outputEvents] stream fed while [runAsync] is in flight.
final class _StreamingShellExecutor extends ShellExecutor {
  final StreamController<ShellOutputChunk> _output =
      StreamController<ShellOutputChunk>.broadcast(sync: true);
  int _commandId = 0;

  /// Invoked inside [runAsync] with the command, so tests can [emit] chunks
  /// mid-command.
  void Function(String command)? onRun;

  @override
  Stream<ShellOutputChunk> get outputEvents => _output.stream;

  void emit(
    String command,
    String text, {
    ShellOutputChannel channel = ShellOutputChannel.stdout,
  }) {
    _output.add(
      ShellOutputChunk(
        commandId: _commandId,
        command: command,
        channel: channel,
        text: text,
      ),
    );
  }

  @override
  Future<ShellResult> runAsync(
    String command, {
    CancellationToken? cancellationToken,
  }) async {
    _commandId++;
    onRun?.call(command);
    return const ShellResult(
      // The buffered result carries the same output the stream delivered;
      // the mirror must not echo it twice.
      stdout: 'building...\ndone',
      stderr: 'warning: slow',
      exitCode: 0,
      duration: Duration(milliseconds: 250),
    );
  }

  @override
  Future<void> dispose() async {
    await _output.close();
  }
}

final class _ScriptedShellExecutor extends ShellExecutor {
  _ScriptedShellExecutor(this._results, {this.error});

  final List<ShellResult> _results;

  /// Thrown from [runAsync] instead of returning a result, when set.
  final Object? error;
  int _call = 0;

  /// Invoked inside [runAsync], letting a test observe mid-command state.
  void Function()? onRun;

  @override
  Future<ShellResult> runAsync(
    String command, {
    CancellationToken? cancellationToken,
  }) async {
    onRun?.call();
    final error = this.error;
    if (error != null) throw error;
    return _results[_call++];
  }

  @override
  Future<void> dispose() async {}
}
