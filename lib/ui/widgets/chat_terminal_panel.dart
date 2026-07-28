import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

import '../../data/terminal_activity.dart';
import '../app_theme.dart';

/// A live terminal docked in the chat, mirroring the shell commands the
/// agent runs.
///
/// Hidden until the conversation's [ChatTerminalSession] echoes its first
/// command; from then on it shows each command and its output as they
/// execute. The header collapses the output pane to a one-line status strip
/// and can clear the buffer, which hides the panel again.
class ChatTerminalPanel extends StatefulWidget {
  /// Creates a [ChatTerminalPanel] over [session].
  const ChatTerminalPanel({required this.session, super.key});

  /// The conversation's terminal session.
  final ChatTerminalSession session;

  @override
  State<ChatTerminalPanel> createState() => _ChatTerminalPanelState();
}

class _ChatTerminalPanelState extends State<ChatTerminalPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      if (!session.hasOutput) return const SizedBox.shrink();

      final scheme = Theme.of(context).colorScheme;
      final terminalTheme = chatTerminalThemeFor(scheme);
      return Container(
        margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: terminalTheme.background,
          borderRadius: BorderRadius.circular(AppShape.inner),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TerminalHeader(
              session: session,
              expanded: _expanded,
              onToggle: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded)
              SizedBox(
                height: 220,
                child: TerminalView(
                  session.terminal,
                  // The session swaps in a fresh Terminal on clear; the key
                  // rebinds the view to the new buffer.
                  key: ObjectKey(session.terminal),
                  theme: terminalTheme,
                  textStyle: const TerminalStyle(fontSize: 12),
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  // Display surface only: the agent owns the underlying
                  // process, so keystrokes have nowhere meaningful to go.
                  readOnly: true,
                  hardwareKeyboardOnly: true,
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// The panel's header strip: title, live status, clear and collapse controls.
class _TerminalHeader extends StatelessWidget {
  const _TerminalHeader({
    required this.session,
    required this.expanded,
    required this.onToggle,
  });

  final ChatTerminalSession session;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = session.runningCommand;
    final status = running ?? _commandCountLabel(session.commandCount);
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        child: Row(
          children: [
            Icon(
              LucideIcons.squareTerminal300,
              size: 16,
              color: running != null ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Text('Terminal', style: theme.textTheme.labelLarge),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: running != null ? FontStyle.italic : null,
                ),
              ),
            ),
            if (running != null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            IconButton(
              tooltip: 'Clear terminal',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(LucideIcons.eraser300),
              onPressed: session.clear,
            ),
            IconButton(
              tooltip: expanded ? 'Collapse terminal' : 'Expand terminal',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: Icon(
                expanded
                    ? LucideIcons.chevronDown300
                    : LucideIcons.chevronUp300,
              ),
              onPressed: onToggle,
            ),
          ],
        ),
      ),
    );
  }

  static String _commandCountLabel(int count) =>
      count == 1 ? '1 command' : '$count commands';
}

/// Maps the app's Material 3 [ColorScheme] onto an xterm [TerminalTheme].
///
/// Frame roles (background, foreground, cursor, selection) come straight
/// from the scheme so the panel sits on the same surface system as the rest
/// of the chat; the sixteen ANSI slots use fixed palettes per brightness,
/// tuned to stay legible against those surfaces.
TerminalTheme chatTerminalThemeFor(ColorScheme scheme) {
  final ansi = scheme.brightness == Brightness.dark ? _darkAnsi : _lightAnsi;
  return TerminalTheme(
    cursor: scheme.primary,
    selection: scheme.primary.withValues(alpha: 0.35),
    foreground: scheme.onSurface,
    background: scheme.surfaceContainerLowest,
    black: ansi[0],
    red: ansi[1],
    green: ansi[2],
    yellow: ansi[3],
    blue: ansi[4],
    magenta: ansi[5],
    cyan: ansi[6],
    white: ansi[7],
    brightBlack: ansi[8],
    brightRed: ansi[9],
    brightGreen: ansi[10],
    brightYellow: ansi[11],
    brightBlue: ansi[12],
    brightMagenta: ansi[13],
    brightCyan: ansi[14],
    brightWhite: ansi[15],
    searchHitBackground: scheme.tertiaryContainer,
    searchHitBackgroundCurrent: scheme.tertiary,
    searchHitForeground: scheme.onTertiaryContainer,
  );
}

/// ANSI palette for light surfaces: darkened tones that hold WCAG-ish
/// contrast on a near-white terminal background.
const List<Color> _lightAnsi = [
  Color(0xFF1D1B20), // black
  Color(0xFFB3261E), // red
  Color(0xFF2E7D32), // green
  Color(0xFF9A6700), // yellow
  Color(0xFF1565C0), // blue
  Color(0xFF7B1FA2), // magenta
  Color(0xFF00838F), // cyan
  Color(0xFF79747E), // white
  Color(0xFF49454F), // bright black
  Color(0xFFDC362E), // bright red
  Color(0xFF388E3C), // bright green
  Color(0xFFB26A00), // bright yellow
  Color(0xFF1E88E5), // bright blue
  Color(0xFF8E24AA), // bright magenta
  Color(0xFF0097A7), // bright cyan
  Color(0xFF1D1B20), // bright white (kept dark: it's ink on light bg)
];

/// ANSI palette for dark surfaces: soft mid-tones in the Material dark-theme
/// register, vivid enough to read as terminal colors.
const List<Color> _darkAnsi = [
  Color(0xFF2B2930), // black
  Color(0xFFF2726B), // red
  Color(0xFF81C995), // green
  Color(0xFFFDD663), // yellow
  Color(0xFF8AB4F8), // blue
  Color(0xFFC58AF9), // magenta
  Color(0xFF78D9EC), // cyan
  Color(0xFFE6E1E5), // white
  Color(0xFF938F99), // bright black
  Color(0xFFF28B82), // bright red
  Color(0xFFA8DAB5), // bright green
  Color(0xFFFDE293), // bright yellow
  Color(0xFFAECBFA), // bright blue
  Color(0xFFD7AEFB), // bright magenta
  Color(0xFFA1E4F2), // bright cyan
  Color(0xFFFFFFFF), // bright white
];
