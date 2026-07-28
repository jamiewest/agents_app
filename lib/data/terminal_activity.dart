import 'dart:async';

import 'package:agents/agents.dart'
    show ShellExecutor, ShellOutputChannel, ShellOutputChunk, ShellResult;
import 'package:extensions/system.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/core.dart';

/// Registry of per-conversation chat terminal sessions.
///
/// Each session carries an xterm [Terminal] that mirrors the shell commands a
/// conversation's agent executes — the command line as it starts, then its
/// output and exit status as it completes. [TerminalMirroringShellExecutor]
/// feeds a session from inside the tool pipeline; the chat UI renders it in a
/// terminal panel docked under the transcript. Keying by conversation keeps
/// concurrent runs (a background task next to the foreground chat) from
/// bleeding output into each other's terminals.
class TerminalActivity {
  final Map<String, ChatTerminalSession> _sessions = {};
  final Map<String, int> _refCounts = {};

  /// Normalizes delegate/child scopes (`parent#delegate`) onto the parent
  /// conversation's session, so a delegate's shell commands surface in the
  /// foreground chat's terminal.
  static String _rootOf(String conversationId) =>
      conversationId.split('#').first;

  /// Acquires the session for [conversationId]; pair with [release].
  ChatTerminalSession listen(String conversationId) {
    final key = _rootOf(conversationId);
    _refCounts[key] = (_refCounts[key] ?? 0) + 1;
    return _sessions.putIfAbsent(key, ChatTerminalSession.new);
  }

  /// Releases one [listen] ref; the session is disposed at zero.
  void release(String conversationId) {
    final key = _rootOf(conversationId);
    final count = (_refCounts[key] ?? 1) - 1;
    if (count > 0) {
      _refCounts[key] = count;
      return;
    }
    _refCounts.remove(key);
    _sessions.remove(key)?.dispose();
  }

  /// The session for [conversationId]'s conversation, or null when no chat
  /// holds it — so background runs cost nothing and buffer nothing.
  ChatTerminalSession? sessionFor(String conversationId) =>
      _sessions[_rootOf(conversationId)];
}

/// One conversation's live terminal: an xterm buffer of every shell command
/// the agent has run, plus the panel-facing state around it.
///
/// Notifies when panel-relevant state changes — a command starting or
/// finishing, or the buffer being cleared. Per-cell paints are driven by the
/// [terminal] itself, which [TerminalView] listens to directly.
class ChatTerminalSession extends ChangeNotifier {
  Terminal _terminal = _newTerminal();

  int _commandCount = 0;
  String? _runningCommand;

  static Terminal _newTerminal() => Terminal(maxLines: 5000);

  /// The buffer the panel renders. Replaced wholesale by [clear], so bind
  /// widgets with a key on the instance.
  Terminal get terminal => _terminal;

  /// Whether any command has been echoed since the last [clear]; the panel
  /// stays hidden until this turns true.
  bool get hasOutput => _commandCount > 0;

  /// The command currently executing, or null between commands.
  String? get runningCommand => _runningCommand;

  /// Commands echoed since the last [clear].
  int get commandCount => _commandCount;

  /// Echoes [command] behind a prompt marker as it starts executing.
  void beginCommand(String command) {
    if (_commandCount > 0) _terminal.write('\r\n');
    _terminal.write('\x1b[1;32m\$\x1b[0m \x1b[1m${_crlf(command)}\x1b[0m\r\n');
    _commandCount++;
    _runningCommand = command;
    notifyListeners();
  }

  /// Writes one live output line from the running command.
  ///
  /// No listener notification: panel-level state is unchanged, and the
  /// [terminal] repaints its own cells through its own listenable.
  void writeChunk(ShellOutputChunk chunk) {
    final text = _crlf(chunk.text);
    _terminal.write(
      chunk.channel == ShellOutputChannel.stderr
          ? '\x1b[31m$text\x1b[0m'
          : text,
    );
  }

  /// Writes a finished command's exit status — and, when the executor could
  /// not stream it live ([outputStreamed] false), the buffered output first.
  void completeCommand(ShellResult result, {bool outputStreamed = false}) {
    if (!outputStreamed) {
      if (result.stdout.isNotEmpty) _writeBlock(result.stdout);
      if (result.stderr.isNotEmpty) _writeBlock(result.stderr, sgr: '31');
      // The live stream carries every line; truncation only applies to the
      // buffered result the model sees.
      if (result.truncated) _writeBlock('[output truncated]', sgr: '2');
    }
    final ok = result.exitCode == 0;
    final status = [
      if (result.timedOut) 'timed out · ' else if (!ok) 'exit ${result.exitCode} · ',
      _formatDuration(result.duration),
    ].join();
    _writeBlock(status, sgr: ok ? '2' : '31');
    _runningCommand = null;
    notifyListeners();
  }

  /// Writes a command failure (rejection, executor error) in error color.
  void failCommand(Object error) {
    _writeBlock('$error', sgr: '31');
    _runningCommand = null;
    notifyListeners();
  }

  /// Drops the buffer and hides the panel until the next command.
  ///
  /// Recreates the [Terminal] rather than erasing in place so the scrollback
  /// is truly gone.
  void clear() {
    _terminal = _newTerminal();
    _commandCount = 0;
    _runningCommand = null;
    notifyListeners();
  }

  void _writeBlock(String text, {String? sgr}) {
    final body = _crlf(text.trimRight());
    _terminal.write(
      sgr == null ? '$body\r\n' : '\x1b[${sgr}m$body\x1b[0m\r\n',
    );
  }

  /// Terminals need CRLF line endings; tool output uses LF.
  static String _crlf(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

  static String _formatDuration(Duration duration) {
    if (duration.inMinutes >= 1) {
      final seconds = duration.inSeconds % 60;
      return '${duration.inMinutes}m ${seconds.toString().padLeft(2, '0')}s';
    }
    if (duration.inSeconds >= 10) return '${duration.inSeconds}s';
    return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
}

/// A [ShellExecutor] decorator that mirrors every command into a
/// [TerminalActivity] session.
///
/// Wraps whichever executor the harness was configured with (local shell
/// today; ssh or container backends the same way tomorrow), so the chat
/// terminal shows commands the moment they start executing and each output
/// line as the process emits it, via the inner executor's
/// [ShellExecutor.outputEvents]. Executors that don't implement the stream
/// (its default is empty) fall back to echoing the buffered result when the
/// command completes.
class TerminalMirroringShellExecutor extends ShellExecutor {
  /// Wraps [inner], mirroring commands to [registry] under [conversationId].
  TerminalMirroringShellExecutor(
    this._inner, {
    required this.registry,
    required this.conversationId,
  });

  final ShellExecutor _inner;

  /// The registry holding the conversation's terminal session.
  final TerminalActivity registry;

  /// The conversation whose terminal this executor writes into.
  final String conversationId;

  @override
  Stream<ShellOutputChunk> get outputEvents => _inner.outputEvents;

  @override
  Future<void> initializeAsync({CancellationToken? cancellationToken}) =>
      _inner.initializeAsync(cancellationToken: cancellationToken);

  @override
  Future<ShellResult> runAsync(
    String command, {
    CancellationToken? cancellationToken,
  }) async {
    // Resolved per call, not at construction: the chat UI may open (or
    // close) its session at any point in the executor's life.
    final session = registry.sessionFor(conversationId);
    session?.beginCommand(command);
    // Built-in executors emit synchronously per line, so every chunk of this
    // command is delivered before runAsync returns. Filtering by command
    // keeps concurrent tool calls from cross-writing each other's output
    // (identical concurrent commands would interleave, which a shared
    // terminal shows anyway).
    var streamed = false;
    StreamSubscription<ShellOutputChunk>? subscription;
    if (session != null) {
      subscription = _inner.outputEvents
          .where((chunk) => chunk.command == command)
          .listen((chunk) {
            streamed = true;
            session.writeChunk(chunk);
          });
    }
    try {
      final result = await _inner.runAsync(
        command,
        cancellationToken: cancellationToken,
      );
      session?.completeCommand(result, outputStreamed: streamed);
      return result;
    } catch (error) {
      session?.failCommand(error);
      rethrow;
    } finally {
      unawaited(subscription?.cancel());
    }
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
