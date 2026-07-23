# Local llama memory-aware orchestration plan

Reviewed against `llama_cpp_flutter` 0.5.0 (pub) and the local
`~/Developer/llama_flutter` checkout at 0.6.0, 2026-07-23.

## Review verdict on adopting `LlamaOrchestrator`

Full adoption is **blocked on package seams that do not exist yet**, in
0.5.0 or in the 0.6.0 checkout. All four gaps were verified in source:

1. **No request-lifetime lease.** `sessionFor()` serializes *activation*
   only; the task queue releases before generation finishes. A queued
   `checkMemory()` resize then calls `session.cancel()` and disposes the
   session mid-response (`orchestrator.dart`, `_resizeLocked`). The app's
   `LocalLlamaModelHost.lease` holds exclusivity across the whole streamed
   response; the orchestrator has no equivalent. Upstream ask:
   `runWithAgent<T>(String agentId, Future<T> Function(LlamaSession) op)`
   holding the queue until `op` completes or its stream cancels.
2. **No transient owners.** Title generation must not earn a KV stash or
   disk snapshot (the app passes `retainKvState: false` today). Upstream
   ask: a retention mode on registration or activation.
3. **Polling cannot be disabled.** `loadModel` always starts a
   `Timer.periodic(policy.pollInterval)`. A huge `pollInterval` is a
   workaround, but resize safety still depends on gap 1. Upstream ask:
   `pollInterval: null` disables the timer; hosts call `checkMemory()`
   at safe points (idle via `AppActivityMonitor`, between requests, on OS
   pressure notifications).
4. **Estimator and stash-cap details.** `estimateModelMemory` counts model
   and draft bytes but not the mmproj projector (~0.8–1 GB undercount on
   multimodal presets), and `_enforceStashCap` always keeps the newest
   stash even when that single stash exceeds `maxStashBytes` (the app's
   host drops oversized stashes instead, the safer behavior here).

One correction to the original plan: 0.6.0 removed the orchestrator's
`agents` dependency and `AgentHandle.agent`, so the feared conflict with
this app's agent configuration/delegation/history layer is already gone.
The remaining gaps are the four above.

## Phase 1 — implemented (this repo, no package changes)

Memory-aware **initial** context sizing, using only what 0.5.0 already
exports (`ModelMemoryEstimate`, `planContextBudget` primitives,
`createSystemMemoryMonitor`, GGUF metadata readers):

- `lib/data/local_llama_context_planner.dart` — pure planner. The
  configured `llama.contextSize` is the *desired maximum*; the plan picks
  the largest context fitting `available * (1 - 0.20 headroom)`, rounded
  to the 256-token granularity, capped by the trained context, floored at
  8192 tokens (the harness prompt alone needs ~5K). When even the floor
  does not fit, it loads at the floor and flags `memoryCritical` — the
  package's 2048-token default would "fit" but stall the harness.
- `..._io.dart` / `..._stub.dart` — native estimate reader; folds the
  mmproj file size into weight bytes (fixes gap 4's undercount app-side).
  Web returns null (wllama; no honest browser memory numbers).
- `lib/main.dart` — the loader plans before `runtime.loadModel` on both
  native paths, skips planning when measurements are estimated (non-Apple
  fallback numbers), records shrunk sizes per load key, passes
  `contextSizeOverride` to `createLlamaChatClient` so prompt budgeting
  targets the real allocation, logs decisions under `local_llama.memory`,
  and appends the sized context to the ready status message.
- Request serialization, KV stashing, prompt inspector, thinking toggle,
  GGUF format detection: unchanged (`LocalLlamaModelHost` +
  `LeasedLocalLlamaChatClient` stay in place).

## Later phases (in order, each gated on the upstream seams)

2. **Between-request / idle memory checks** — needs seam 3 (or the huge
   `pollInterval` workaround) plus an app hook calling `checkMemory()`
   from `AppActivityMonitor` idle transitions.
3. **Orchestrator adoption for conversations** — needs seams 1–2. Map
   `conversation:<id>` owners to `AgentProfile`s, wrap activation in the
   existing host gate during migration, translate orchestrator events
   into the prompt log / UI.
4. **Dynamic resize + disk snapshots** — snapshots under Application
   Support, wired into app reset and conversation deletion. Accept that a
   shrunk context cannot restore more tokens than it holds (trim or
   recall older history).
5. **Multi-sequence residency** — only after measuring real switching
   costs; slots divide the context, grow KV, and disable speculative
   decoding (the Gemma preset uses a draft model), while local generation
   is serialized anyway.

Suggested starting policy when phase 3 lands: `headroomFraction: 0.20`,
`minContextTokens: 8192`, `maxContextTokens: 32768`,
`maxStashBytes: 512 MiB`, `unloadOnCritical: true`, `sequenceSlots: 1`.
