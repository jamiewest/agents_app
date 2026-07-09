/// Describes wearable camera stills through an agent run, so the local
/// multimodal path (Gemma + mmproj) — or any vision-capable configured
/// model — turns photos into searchable memory text.
library;

import 'dart:io';

import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart' as ai;
import 'package:path/path.dart' as p;

import 'capture_processor.dart';
import 'distillation_service.dart';

/// Thrown when no describer agent is configured — the processor leaves the
/// image pending (no retry burned) until one is selected.
class DescriberUnavailableException implements Exception {
  /// Creates a [DescriberUnavailableException].
  const DescriberUnavailableException();
}

/// Runs the describer agent over [message]; returns its response text.
typedef DescriberRunner =
    Future<String> Function(SavedAgentConfig config, ai.ChatMessage message);

/// [ImageDescriber] that reuses the wearable distiller agent for vision.
///
/// One agent powers both distillation and description; point the wearable
/// "distiller agent" at a multimodal model (e.g. a local Gemma preset with
/// its mmproj) and photos become memory. A non-vision model will fail the
/// describe run, and the capture retries within its normal budget.
class AgentImageDescriber implements ImageDescriber {
  /// Creates an [AgentImageDescriber].
  ///
  /// [runner] is injectable for tests (making [factory] optional).
  AgentImageDescriber({
    required this._agents,
    required this._settings,
    ConfiguredAgentFactory? factory,
    DescriberRunner? runner,
  }) : assert(
         runner != null || factory != null,
         'provide a factory or a runner',
       ),
       _runner = runner ?? _agentRunner(factory!);

  final AgentConfigurationStore _agents;
  final KeyValueStore _settings;
  final DescriberRunner _runner;

  static const String _prompt =
      'This photo was taken by a wearable camera from the wearer\'s point '
      'of view. Describe what it shows in two or three sentences for later '
      'recall: people, place, activity, and any readable text. Respond with '
      'the description only.';

  static DescriberRunner _agentRunner(ConfiguredAgentFactory factory) =>
      (config, message) async {
        final agent = await factory.createAgent(
          config,
          scope: AgentScope(
            conversationId: 'wearable-describe',
            sessionIdResolver: () => 'wearable-describe',
            isPrivate: true,
          ),
        );
        final session = await agent.createSession();
        final response = await agent.run(session, null, messages: [message]);
        return response.text;
      };

  @override
  Future<String> describe(String path) async {
    final id = await _settings.read(DistillationService.distillerAgentIdKey);
    final config = (id == null || id.isEmpty)
        ? null
        : await _agents.getAgent(id);
    if (config == null) {
      throw const DescriberUnavailableException();
    }
    final bytes = await File(path).readAsBytes();
    final message = ai.ChatMessage(
      role: ai.ChatRole.user,
      contents: [
        ai.TextContent(_prompt),
        ai.DataContent(bytes, mediaType: 'image/jpeg', name: p.basename(path)),
      ],
    );
    final description = (await _runner(config, message)).trim();
    if (description.isEmpty) {
      throw StateError('describer returned no text');
    }
    return description;
  }
}
