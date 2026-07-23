/// Memory-aware context sizing for the resident local llama model.
///
/// The configured `llama.contextSize` is treated as the *maximum desired*
/// context; before a native load the planner reads the GGUF header, samples
/// device memory, and picks the largest context that actually fits, so a
/// model configured for 16K on a 64 GB desktop does not blindly allocate
/// 16K of KV cache on an 8 GB phone and get the app jetsammed.
///
/// This reuses the estimation and budgeting primitives that
/// `package:llama_cpp_flutter`'s orchestrator exports
/// ([llama.ModelMemoryEstimate], [llama.MemorySnapshot],
/// [llama.contextTokenGranularity]) without adopting the orchestrator
/// itself: the orchestrator's activation lock releases before a streamed
/// response finishes and its memory poll can resize (cancel + recreate) the
/// session mid-generation, so request lifetimes stay under this app's
/// [LocalLlamaModelHost] lease until the package grows a request-scoped
/// seam.
///
/// Planning is deliberately load-time only. Dynamic resizing recreates the
/// llama.cpp session and needs snapshot plumbing to not lose conversation
/// state; that stays out until the package can do it safely.
library;

import 'dart:math' as math;

import 'package:llama_cpp_flutter/orchestration.dart' as llama;

export 'local_llama_context_planner_stub.dart'
    if (dart.library.io) 'local_llama_context_planner_io.dart';

/// Fraction of available memory deliberately left unused when budgeting.
///
/// More conservative than the package's 0.15 default: the estimate cannot
/// see Metal working buffers or multimodal decode spikes, and on the
/// constrained devices this app targets an OS kill is strictly worse than a
/// smaller context.
const double defaultContextHeadroomFraction = 0.20;

/// The smallest context the app's harness can actually run.
///
/// The system prompt plus tool declarations already need ~5K tokens (see
/// the `llama.contextSize` default in the model editor), so anything
/// smaller technically fits memory but stalls before generating. When even
/// this does not fit the budget, the plan loads at this floor anyway and
/// flags [LocalLlamaContextPlan.memoryCritical] — refusing to load helps
/// nobody.
const int minUsefulContextTokens = 8192;

/// The context size chosen for a local model load.
class LocalLlamaContextPlan {
  /// Creates a plan.
  const LocalLlamaContextPlan({
    required this.contextTokens,
    required this.desiredContextTokens,
    required this.memoryCritical,
  });

  /// The context size to load with.
  final int contextTokens;

  /// The configured `llama.contextSize` the plan was capped by.
  final int desiredContextTokens;

  /// True when even the minimum useful context exceeded the memory budget;
  /// [contextTokens] is the floor and the load may still pressure the OS.
  final bool memoryCritical;

  /// Whether the plan shrank the context below the configured size.
  bool get isReduced => contextTokens < desiredContextTokens;
}

/// Plans the context size for an initial local model load.
///
/// The result is the largest context that fits
/// `availableBytes * (1 - headroomFraction)` per [estimate], rounded down
/// to [llama.contextTokenGranularity] and capped by [desiredContextTokens]
/// and the model's trained context. It never exceeds the configured size —
/// growth beyond what the user asked for is not this planner's call.
///
/// When the budget cannot fit [minContextTokens] (itself capped by the
/// desired size, so a deliberately small configuration is respected), the
/// plan returns that floor with [LocalLlamaContextPlan.memoryCritical] set
/// rather than refusing.
LocalLlamaContextPlan planLocalLlamaContext({
  required llama.ModelMemoryEstimate estimate,
  required llama.MemorySnapshot memory,
  required int desiredContextTokens,
  double headroomFraction = defaultContextHeadroomFraction,
  int minContextTokens = minUsefulContextTokens,
}) {
  var cap = desiredContextTokens;
  final trained = estimate.trainedContextTokens;
  if (trained != null && trained > 0) cap = math.min(cap, trained);
  final floor = math.min(minContextTokens, cap);

  final budget = (memory.availableBytes * (1 - headroomFraction)).floor();
  var target = math.min(estimate.maxContextForBudget(budget), cap);
  target -= target % llama.contextTokenGranularity;

  if (target < floor) {
    return LocalLlamaContextPlan(
      contextTokens: floor,
      desiredContextTokens: desiredContextTokens,
      memoryCritical: true,
    );
  }
  return LocalLlamaContextPlan(
    contextTokens: target,
    desiredContextTokens: desiredContextTokens,
    memoryCritical: false,
  );
}
