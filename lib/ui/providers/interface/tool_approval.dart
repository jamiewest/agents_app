// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'llm_provider.dart';

/// A tool call awaiting the user's approval decision.
///
/// This is a UI-facing view of the underlying framework approval request:
/// just enough to describe the call to the user without exposing
/// agent-framework types to the chat widgets.
class ToolApprovalRequest {
  /// Creates a [ToolApprovalRequest].
  const ToolApprovalRequest({required this.toolName, this.arguments});

  /// The name of the tool the agent wants to invoke.
  final String toolName;

  /// The decoded arguments of the pending call, when available.
  final Map<String, Object?>? arguments;
}

/// The user's decision for a pending [ToolApprovalRequest].
enum ToolApprovalDecision {
  /// Reject this call; the agent is told the user denied it.
  deny,

  /// Approve this call only.
  allowOnce,

  /// Approve this call and record a standing rule that auto-approves all
  /// future calls to the same tool.
  alwaysAllow,
}

/// An [LlmProvider] that can surface user-in-the-loop tool approvals.
///
/// When a run stops because the agent needs permission to execute a tool,
/// [pendingToolApproval] becomes non-null. The chat UI presents the request
/// and resumes the run by streaming [sendToolApprovalStream] with the user's
/// decision.
abstract interface class ToolApprovalSupport implements LlmProvider {
  /// The unresolved approval request, if the last run stopped on one.
  ToolApprovalRequest? get pendingToolApproval;

  /// Answers [pendingToolApproval] with [decision] and resumes the run,
  /// streaming the continuation of the response text.
  Stream<String> sendToolApprovalStream(ToolApprovalDecision decision);
}
