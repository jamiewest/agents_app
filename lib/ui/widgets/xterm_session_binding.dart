// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/core.dart';

/// Renders a [ChatTerminalSession]'s semantic event history into an xterm
/// [Terminal] buffer.
///
/// The session (from `agents_flutter`) records what happened — commands,
/// output chunks, results — and this binding owns how it looks: the prompt
/// marker, ANSI colors, CRLF conversion, and the status line. On attach it
/// replays [ChatTerminalSession.events], then follows
/// [ChatTerminalSession.onEvent] live. Notifies when the [terminal]
/// instance is replaced (a clear), so views can rebind.
class XtermSessionBinding extends ChangeNotifier {
  /// Creates a binding over [session], replaying its history immediately.
  XtermSessionBinding(this.session) {
    session.events.forEach(_render);
    _subscription = session.onEvent.listen(_onEvent);
  }

  /// The semantic session this binding renders.
  final ChatTerminalSession session;

  Terminal _terminal = _newTerminal();
  int _renderedCommands = 0;
  StreamSubscription<TerminalEvent>? _subscription;

  static Terminal _newTerminal() => Terminal(maxLines: 5000);

  /// The buffer a [TerminalView] renders. Replaced wholesale on clear, so
  /// bind widgets with a key on the instance.
  Terminal get terminal => _terminal;

  void _onEvent(TerminalEvent event) {
    if (event is TerminalCleared) {
      // Recreate rather than erase in place so the scrollback is truly gone.
      _terminal = _newTerminal();
      _renderedCommands = 0;
      notifyListeners();
      return;
    }
    _render(event);
  }

  void _render(TerminalEvent event) {
    switch (event) {
      case TerminalCommandStarted(:final command):
        if (_renderedCommands > 0) _terminal.write('\r\n');
        _terminal.write(
          '\x1b[1;32m\$\x1b[0m \x1b[1m${_crlf(command)}\x1b[0m\r\n',
        );
        _renderedCommands++;
      case TerminalOutput(:final text, :final isError):
        final body = _crlf(text);
        _terminal.write(isError ? '\x1b[31m$body\x1b[0m' : body);
      case TerminalCommandCompleted(:final result, :final outputStreamed):
        if (!outputStreamed) {
          if (result.stdout.isNotEmpty) _writeBlock(result.stdout);
          if (result.stderr.isNotEmpty) _writeBlock(result.stderr, sgr: '31');
          // The live stream carries every line; truncation only applies to
          // the buffered result the model sees.
          if (result.truncated) _writeBlock('[output truncated]', sgr: '2');
        }
        final ok = result.exitCode == 0;
        final status = [
          if (result.timedOut)
            'timed out · '
          else if (!ok)
            'exit ${result.exitCode} · ',
          _formatDuration(result.duration),
        ].join();
        _writeBlock(status, sgr: ok ? '2' : '31');
      case TerminalCommandFailed(:final error):
        _writeBlock(error, sgr: '31');
      case TerminalCleared():
        break;
    }
  }

  void _writeBlock(String text, {String? sgr}) {
    final body = _crlf(text.trimRight());
    _terminal.write(sgr == null ? '$body\r\n' : '\x1b[${sgr}m$body\x1b[0m\r\n');
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

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
