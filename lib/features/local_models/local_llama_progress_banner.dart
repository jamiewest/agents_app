import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'local_llama_agent_factory.dart';

/// Download/load progress for the resident local model, shown above the chat.
class LocalLlamaProgressBanner extends StatelessWidget {
  const LocalLlamaProgressBanner({required this.modelId, super.key});

  final String modelId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: localLlamaProgress,
    builder: (context, child) {
      final status = localLlamaProgress.statusFor(modelId);
      if (!status.isVisible) return const SizedBox.shrink();

      final colorScheme = Theme.of(context).colorScheme;
      final progress = status.progress;
      final isBusy =
          status.phase == LocalLlamaPhase.downloading ||
          status.phase == LocalLlamaPhase.loading;

      return Material(
        color: status.phase == LocalLlamaPhase.error
            ? colorScheme.errorContainer
            : colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isBusy) ...[
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: status.phase == LocalLlamaPhase.downloading
                            ? progress
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ] else
                    Icon(
                      status.phase == LocalLlamaPhase.error
                          ? LucideIcons.circleAlert300
                          : LucideIcons.circleCheck300,
                      size: 18,
                      color: status.phase == LocalLlamaPhase.error
                          ? colorScheme.onErrorContainer
                          : colorScheme.primary,
                    ),
                  if (!isBusy) const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusText(status),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: status.phase == LocalLlamaPhase.error
                            ? colorScheme.onErrorContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (status.phase == LocalLlamaPhase.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress),
              ],
            ],
          ),
        ),
      );
    },
  );

  String _statusText(LocalLlamaStatus status) {
    final progress = status.progress;
    if (status.phase == LocalLlamaPhase.downloading && progress != null) {
      return '${status.message} ${(progress * 100).toStringAsFixed(0)}%';
    }
    return status.message;
  }
}
