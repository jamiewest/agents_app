import 'package:agents/agents.dart'
    show ShellOutputChannel, ShellOutputChunk, ShellResult;
import 'package:agents_app/ui/widgets/xterm_session_binding.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

ShellOutputChunk chunk(
  String text, {
  ShellOutputChannel channel = ShellOutputChannel.stdout,
}) => ShellOutputChunk(
  commandId: 1,
  command: 'cmd',
  channel: channel,
  text: text,
);

void main() {
  group('XtermSessionBinding', () {
    test('renders command echo, buffered output, and status', () {
      final session = ChatTerminalSession();
      final binding = XtermSessionBinding(session);

      session.beginCommand('echo hello');
      session.completeCommand(
        const ShellResult(
          stdout: 'hello\nworld',
          stderr: '',
          exitCode: 0,
          duration: Duration(milliseconds: 1200),
        ),
      );

      final text = binding.terminal.buffer.getText();
      expect(text, contains('\$ echo hello'));
      expect(text, contains('hello'));
      expect(text, contains('world'));
      expect(text, contains('1.2s'));
      binding.dispose();
      session.dispose();
    });

    test('replays history recorded before the binding attached', () {
      final session = ChatTerminalSession();
      session.beginCommand('ls /nope');
      session.completeCommand(
        const ShellResult(
          stdout: '',
          stderr: 'no such file',
          exitCode: 2,
          duration: Duration(milliseconds: 40),
        ),
      );

      final binding = XtermSessionBinding(session);

      final text = binding.terminal.buffer.getText();
      expect(text, contains('\$ ls /nope'));
      expect(text, contains('no such file'));
      expect(text, contains('exit 2'));
      binding.dispose();
      session.dispose();
    });

    test('streamed output renders live and is not echoed twice', () {
      final session = ChatTerminalSession();
      final binding = XtermSessionBinding(session);

      session.beginCommand('make');
      session.writeChunk(chunk('building...\n'));
      final midCommand = binding.terminal.buffer.getText();
      session.writeChunk(chunk('done\n'));
      session.completeCommand(
        const ShellResult(
          stdout: 'building...\ndone',
          stderr: '',
          exitCode: 0,
          duration: Duration(milliseconds: 250),
        ),
        outputStreamed: true,
      );

      expect(midCommand, contains('building...'));
      final text = binding.terminal.buffer.getText();
      expect('done'.allMatches(text), hasLength(1));
    });

    test('renders truncation marker and failures', () {
      final session = ChatTerminalSession();
      final binding = XtermSessionBinding(session);

      session.beginCommand('cat big');
      session.completeCommand(
        const ShellResult(
          stdout: 'partial',
          stderr: '',
          exitCode: 0,
          duration: Duration(milliseconds: 40),
          truncated: true,
        ),
      );
      session.beginCommand('rm -rf /');
      session.failCommand(StateError('rejected by policy'));

      final text = binding.terminal.buffer.getText();
      expect(text, contains('[output truncated]'));
      expect(text, contains('rejected by policy'));
    });

    test('clear swaps in a fresh terminal and notifies', () {
      final session = ChatTerminalSession();
      final binding = XtermSessionBinding(session);
      session.beginCommand('echo hi');
      final before = binding.terminal;
      var notified = false;
      binding.addListener(() => notified = true);

      session.clear();

      expect(identical(binding.terminal, before), isFalse);
      expect(notified, isTrue);
      expect(binding.terminal.buffer.getText().trim(), isEmpty);
    });
  });
}
