// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:agents/agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions/ai.dart';
import 'package:extensions_flutter/extensions_flutter.dart';

import 'role_agent.dart';
import 'workflow_checkpoint_store.dart';
import 'workflow_run_controller.dart';
import 'workflow_spec.dart';

bool _wireConvertersRegistered = false;

/// Teaches the engine's checkpoint marshaller to round-trip the chat
/// message lists that flow between workflow stages; without this,
/// checkpointing a run whose pending deliveries hold [ChatMessage]s
/// fails at JSON encoding. Idempotent; the launcher calls it before
/// every run.
void registerWorkflowWireConverters() {
  if (_wireConvertersRegistered) return;
  _wireConvertersRegistered = true;
  WireMarshaller.valueConverters['List<ChatMessage>'] = WireValueConverter(
    toWire: (value) => [
      for (final message in value as List<ChatMessage>)
        ChatMessageCodec.encode(message),
    ],
    fromWire: (wire) => <ChatMessage>[
      for (final entry in wire as List)
        ?ChatMessageCodec.decode((entry as Map).cast<String, Object?>()),
    ],
  );
}

/// Compiles [spec] against the app's configured agents and wraps it in a
/// ready-to-start run controller.
///
/// Each agent node resolves its configured agent (falling back to the
/// first saved agent) and is cast into its role. Pass [checkpoints] to
/// resume into an existing checkpoint trail; otherwise the spec's
/// persisted trail is cleared and the run records a fresh one — a
/// checkpoint per superstep, kept in the app's record store so it
/// survives restarts. Throws [StateError] when no agents are configured
/// or the spec doesn't validate.
Future<WorkflowRunController> createSpecRunController(
  ServiceProvider services,
  WorkflowSpec spec, {
  CheckpointManagerImpl? checkpoints,
}) async {
  registerWorkflowWireConverters();
  final agents = await services
      .getRequiredService<ConfiguredAgentsManager>()
      .agents
      .listAgents();
  if (agents.isEmpty) {
    throw StateError('Workflows need a configured agent.');
  }
  final factory = services.getRequiredService<ConfiguredAgentFactory>();
  final compiled = await compileWorkflowSpec(
    spec,
    buildAgent: (node) async => RoleAgent(
      await factory.createAgentById(node.agentId ?? agents.first.id),
      role: node.label.trim(),
      roleInstructions: node.instructions,
    ),
  );
  var manager = checkpoints;
  if (manager == null) {
    final store = WorkflowCheckpointStore(
      services.getRequiredService<RecordStore>(),
    );
    await store.clearSession(spec.id);
    manager = store.managerFor(spec.id);
  }
  return WorkflowRunController(
    workflow: compiled.workflow,
    encodeResponse: compiled.encodeResponse,
    checkpoints: manager,
  );
}
