# Agent Center — reviewed plan

Reviewed against the repo at `f2ca6e4` on 2026-07-23. Verified against
`lib/navigation/app_router.dart`, `lib/ui/views/configured_agents/`,
`lib/data/usage_store.dart`, `lib/data/prompt_logging.dart`, and the four
`createAgent` call sites.

## Verdict

The navigation and information-architecture half of the plan is sound and
mostly buildable on what exists. The telemetry half needs rework: it
proposes a token ledger the app already has, and it assumes a run→usage
correlation key that does **not** exist today. Two UX assumptions should
also change before implementation.

Three things must be settled before any code is written; they are
Phase 0 below.

---

## 1. Do not build a second token ledger

`lib/data/usage_store.dart` already persists a durable, per-model-call
ledger in the `usage_records` collection with exactly the fields the plan
lists as new: `input`, `output`, `total`, `cached`, `reasoning`, plus
`modelId`, `sourceId`, `provider`, `timestamp`, `conversationId`,
`sessionId`. `UsageStore.totalsByModel` already aggregates it, and
`lib/ui/widgets/usage_stats_sheet.dart` already renders it.

The plan's `AgentRunRecord` restates all of those token fields. Two
ledgers accumulating the same tokens through different code paths will
silently diverge — and there is no way for a user to tell which is right.

**Change:** split the responsibilities.

- `usage_records` stays the single source of truth for **tokens**. Every
  token KPI and every token chart on the Overview reads from it. No token
  fields on `AgentRunRecord`.
- `AgentRunRecord` carries only what `usage_records` cannot express:
  stable run id, agent id + display-name snapshot, origin, status,
  start/end timestamps, duration, model-call count.
- Token totals per run/agent/model are a **join**, not an accumulation.

This deletes a large slice of the proposed work and removes the
divergence risk entirely.

## 2. The join key does not exist — but the seam for it does

`usage_records` has no `agentId` and no `runId`. It is keyed on
`AgentScope` = `{conversationId, sessionIdResolver, channelId, isPrivate}`
(`agent_scope.dart` in the `agents_flutter` git dependency). So **today
the app cannot attribute a single token to an agent** — precisely what
"workload by agent", "tokens by agent", and the per-agent detail charts
all require.

`sessionId` cannot stand in. Its own doc comment calls it a
"model-context epoch"; one session spans many turns, so it is coarser
than a run.

**Fix: subclass `AgentScope` in the app. No package change.**

`AgentScope` is a plain class — no `final`, `base`, or `sealed`
modifier — so the app can extend it:

```dart
// lib/data/agent_run_scope.dart
class AgentRunScope extends AgentScope {
  final String agentId;                   // fixed for the scope's life
  final String? Function() runIdResolver; // varies per turn
  @override
  AgentScope child(String discriminator) => AgentRunScope(...);
}
```

This was verified against the pinned package, and three properties make
it sound:

- **The package constructs `AgentScope` in exactly one place** —
  `AgentScope.child()` itself (`agent_scope.dart:38`). Nothing else
  rebuilds a scope, so the subtype is never silently downcast away.
- **`child()` is virtual and called from exactly one site** —
  `configured_agent_factory.dart:397`,
  `scope?.child('delegate-${delegateConfig.id}')`. Overriding it means
  **delegate agents inherit the initiating agent's id and run id for
  free**, satisfying the plan's delegation-attribution requirement with
  no extra mechanism.
- **The scope reaches app-owned code intact.** The factory passes it
  straight to `createChatClient` (`configured_agent_factory.dart:186-191`),
  which `LoggingConfiguredChatClientFactory` already overrides.

`agentId` is a plain field because it is fixed once the scope is built.
`runId` must be a **resolver**, mirroring the existing
`sessionIdResolver`, because a chat scope is built once when the pane
opens and then serves many turns. The precedent is load-bearing:
`UsageTrackingChatClient._record:205` already calls
`scope?.sessionIdResolver()` at record time, which proves lazy resolution
is correct on the streaming path — where a `Zone`-based ambient context
is genuinely at risk (`_runMessage` is an `async*` generator consumed
downstream through `.smoothed().map()`; do not assume zone identity
survives that).

One constraint this imposes: `ChatUsageRecord` is a package type with a
fixed field set, and `UsageTrackingChatClient` builds it itself, so the
new ids cannot ride along on it. They must be stamped by the **sink**.
`LoggingConfiguredChatClientFactory.createChatClient` already selects the
sink per client and already has the scope in hand
(`prompt_logging.dart:100-107`), so it wraps `UsageStore` in a
`RunAttributingUsageSink` that reads `scope.agentId` and
`scope.runIdResolver()` at `record()` time and writes them as two
additive fields on `usage_records`.

Do **not** fall back to correlating on
`(conversationId, sessionId, timestamp)` — concurrent runs in one
conversation make that unsound.

Also worth noting: the title summarizer and A2A hosting internals are
scope-less today and write anonymous usage records. Once agent-level
rollups exist, those rows need either a scope or an explicit exclusion,
or they will quietly skew totals.

## 3. Creation sites are not run boundaries

The plan names three invocation sites; there are four, and at **none of
them** does `createAgent` mark the run boundary. Wrapping runs around
`createAgent` would produce one run per conversation-open spanning many
turns — wrong granularity for the dominant case.

| Creation site | Scope | Actual run boundary |
| --- | --- | --- |
| `main.dart:1171` (chat open) | full | `AgentLlmProvider._appendResponseTo` |
| `main.dart:1292` (`_reloadAgent` hot-rebuild) | full | same provider |
| `task_scheduler_service.dart:200` | full | `_runWithAgent`, per execution |
| `a2a_host_service.dart:152` (once at `start()`) | **none** | per inbound request handler |

The chat boundary needs care. A run is **not** one `_runMessage` call:
the tool-approval middleware ends the run at the approval request, and
`sendToolApprovalStream` resumes it with a second `_runMessage`. The
provider already accounts for this — `turnStartedAt ??=` in
`_appendResponseTo:109` exists specifically to keep one start time across
an approval pause. The run boundary is `_appendResponseTo`'s
`try`/`finally`, which already computes `turnDuration` and already tracks
`isGenerating`. Hook the run wrapper there; much of what
`AgentRunRecord` needs is being computed at that site today.

Note also that `_runMessage:238` already surfaces `ai.UsageContent` per
model call via the `onUsage` callback (`llmMessage.addUsage`). That is a
ready-made model-call counter — and a cross-check against the
`usage_records` rows for the same turn.

The A2A case is the one to design for explicitly: because the agent is
built once at `start()`, the run wrapper must sit in the **request
handler**, not around `createAgent`. Give hosted agents a scope while you
are there.

Confirm whether the two `main.dart` chat sites are genuinely distinct
entry points before duplicating the wrapper — `_reloadAgent` may be able
to reuse the first.

## 4. Private chats and reset — reuse the existing patterns

The plan's private-chat rule already has a precedent:
`DiscardingUsageRecordSink` (`usage_store.dart`), selected via
`scope?.isPrivate` in `prompt_logging.dart:106`. Mirror it with a
discarding run sink rather than inventing a new suppression mechanism.

Two gaps the plan does not cover:

- **Retention.** "Keep records until app reset" means unbounded growth,
  and `usage_records` already grows without bound. A run ledger plus a
  usage ledger on a heavy user will get large. Add a documented trim
  (age- or count-bounded) rather than shipping unbounded and retrofitting.
- **App reset** turns out to be free: `RecordStore.clearAll()` deletes
  every record in every collection, and `resetAppData` already calls it.
  No change needed.

## 5. Define "success rate" before shipping a number

The plan puts success rate on KPI cards, agent cards, and model cards
without defining failure. A run where the user cancels mid-stream, a run
where a tool errored but the agent recovered, and a run where the model
call 500'd are three different things. Pick a definition, put it in the
record's doc comment, and show it in the UI tooltip. An undefined
percentage on a dashboard is worse than no percentage.

Similarly, **model latency has no capture path today**. Either derive it
from `duration / modelCallCount` and label it honestly as
"avg per model call", or drop it from v1.

---

## 6. UX: Agents should be the landing page, not Overview

This is the largest design risk in the plan, and `ui.md` calls it
directly: *"Design around activities, not feature lists"* and *"Do not
design from an internal feature checklist."*

Users open this screen to **add an agent, fix a broken agent, or change a
model**. They do not open it to look at charts. A user with two agents
and thirty runs lands on a dashboard of near-empty charts before reaching
the thing they came for.

**Change:** make **Agents** the default page at `/settings/agents`.
Overview becomes a sibling. Keep the featured Settings card, but have it
summarize *state* (agent count, anything needing setup) and deep-link to
Agents. Promote Overview to the default later only if usage shows people
actually go there.

Corollary: gate the Overview charts on having enough data. Under some
threshold, show the KPI cards and the "needs setup" list, and skip the
time-series entirely rather than rendering a two-point line.

## 7. Trim the chart scope for v1

There is **no chart code and no golden infrastructure** in this repo
today — one unrelated `CustomPainter` in `barcode_scanner_screen.dart`,
and zero `matchesGoldenFile` call sites anywhere in `test/`.

The plan asks for bar + area + sparkline painters with hover, focus, and
touch tooltips, keyboard access, themed gridlines, and semantic
summaries, plus light/dark goldens across multiple theme seeds. That is a
large body of net-new, fiddly work sitting on the critical path of a
navigation redesign.

**Change for v1:**

- Ship **bar and sparkline** only. Defer the stacked area chart; stacked
  success/failure reads fine as a grouped bar.
- Tap/click-to-reveal values plus a `Semantics` text summary. Defer
  hover-tracking tooltips and keyboard chart traversal.
- **Drop goldens from v1.** Standing up golden infra (font loading, CI
  render stability) is its own task. Cover charts with semantic and
  widget assertions instead, and add goldens as a follow-up once the
  layout has stopped moving.

## 8. Routing: avoid a third nested shell

`app_router.dart` already nests `StatefulShellRoute.indexedStack` inside
a `StatefulShellRoute.indexedStack` for Chats. A third level under
`/settings/agents` for the master-detail panes will be hard to reason
about and hard to test.

**Change:** use plain `GoRoute` children with the selected resource in
the path (`/settings/agents/agents/:id`), and let a single widget decide
whether to render that as a pushed page (compact) or an inline detail
pane (expanded) from `LayoutBuilder` constraints. One route table, two
renderings.

Two things must not break:

- `/settings/agents/add` — and note `AddAgentWizard` is **also** mounted
  at `/onboarding/add` (`app_router.dart:51`). Both mounts need coverage
  in `test/navigation/app_router_test.dart`.
- The onboarding `redirect` guard calls `bootstrap.hasUsableAgent()` on
  every navigation. Deep links into Agent Center pass through it.

## 9. Reuse is confirmed feasible

`ConfiguredAgentsController` (103 lines) is a plain `ChangeNotifier` over
`ConfiguredAgentsManager` with no widget or tab coupling. The editors —
`model_editor.dart` (983), `agent_editor.dart` (480),
`source_editor.dart` (209) — are separable from the
`DefaultTabController`/`TabBar` scaffolding, which lives only in
`configured_agents_view.dart:137-158`. "Retire the tab container, reuse
its controller and editors" works as written.

Two caveats. The editors are currently hosted in `AlertDialog`s at a
fixed `SizedBox(width: 420)` (`_showEditorDialog`); moving them into an
inline detail pane and a full-page compact route means they must become
width-flexible — budget for layout work inside `model_editor.dart` (983
lines), not just for its call sites. And `test/configured_agents_view_test.dart`
is 706 lines written against the tab UI; it gets rewritten, not ported.

The plan should also use `ConfiguredAgentsManager.agentChanges` (emits
the changed agent id) alongside `configurationChanges` — `ChatScreen`
already relies on it for hot-rebuild, and Agent Center cards want the
same granularity rather than reloading everything on every edit.

One detail to carry over: the web security notice in
`manage_agents_screen.dart:39` (keys fall back to browser storage on
web). It must land somewhere on the new Sources page, not get dropped in
the rewrite.

`configured_agents_view.dart` (587 lines) and `manage_agents_screen.dart`
are the two files that actually get retired. `test/configured_agents_view_test.dart`
will need rewriting rather than porting.

---

## Phasing

The original plan is one document describing roughly five changes. Land
them in this order; each is independently shippable.

**Phase 0 — decide (no UI work).**

0.1 ~~Decide the correlation mechanism.~~ **Settled:** `AgentRunScope
    extends AgentScope` in the app, plus a `RunAttributingUsageSink`.
    Verified against the pinned package; no upstream change. See §2.
0.2 Define "success rate" / failure taxonomy.
0.3 Decide the retention policy.
0.4 Identify the exact run boundary at each of the four sites (§3).

**Phase 1 — telemetry foundation. Largely landed.** See "Phase 1 status"
below. `AgentRunRecord` (run facts only),
`AgentRunTelemetryStore`, `runId`/`agentId` on `usage_records`, run
wrappers at all four sites, private-chat discarding sink, interrupted-run
recovery sweep on startup, app-reset integration. Fully unit-testable
with no UI. Ships invisibly.

**Phase 2 — navigation shell.** Agent Center routes, adaptive
compact/expanded layout, Agents / Models / Sources pages built on the
existing controller and editors, dirty-form protection, cascade delete
preserved, prerequisite empty states. Retire `ManageAgentsScreen` and
`ConfiguredAgentsView`. No charts yet — cards show configuration state
only. **This phase alone is a complete, shippable improvement.**

**Phase 3 — Overview and charts.** KPI cards, bar + sparkline painters,
current work / scheduled / recent runs lists, per-agent detail charts.

**Phase 4 — polish.** Golden coverage, hover tooltips, keyboard chart
traversal, area chart if still wanted.

## Phase 1 status

Landed, `dart analyze` clean, 365 tests passing:

- `lib/data/agent_run_scope.dart` — `AgentRunScope`, with `child()`
  overridden so delegates inherit the initiating agent and run.
- `lib/data/agent_run_store.dart` — `AgentRunRecord`, `AgentRunOrigin`,
  `AgentRunStatus`, `AgentRunHandle`, `AgentRunTelemetryStore`
  (`begin`/`succeed`/`fail`/`list`/`watch`/`recoverInterrupted`/
  `trimBefore`). No token fields.
- `lib/data/usage_store.dart` — additive `agentId`/`runId` fields,
  `attributedTo(scope)`, `totalsForRun(runId)`, `totalsByAgent({since})`,
  and a `TokenTotals` value type. Tokens are joined, never duplicated.
- `lib/data/prompt_logging.dart` — `_sinkFor` selects the discarding,
  attributing, or plain sink.
- `lib/main.dart` — service registration; both chat sites build an
  `AgentRunScope`; the provider gets the ledger (null for private chats)
  and a `_beginRun` that snapshots agent/model/source labels.
- `lib/ui/providers/implementations/agent_llm_provider.dart` — the run
  spans `_appendResponseTo`, is reused across a tool-approval pause, and
  counts model calls off the existing `onUsage` callback.
- `lib/data/task_scheduler_service.dart` — one run per execution.
- `lib/navigation/app_bootstrap.dart` — `recoverInterrupted()` runs
  before any new run can start.

Tests: `test/data/agent_run_store_test.dart` (14),
`test/data/agent_run_attribution_test.dart` (13, driving the real
factory), and a `run telemetry` group in
`test/agent_llm_provider_test.dart` (6).

A bug surfaced while wiring the chat boundary and is fixed: `yield*`
forwards a source stream's error straight to the output stream rather
than throwing it into the generator body, so a surrounding `catch` never
runs. Failure detection moved to `handleError`. Any future code in that
method that assumes `catch` sees streaming errors will be wrong the same
way.

### Known limitations

- **Delegation attribution only covers work inside the turn.**
  `runIdResolver` reads the provider's `currentRunId`, which is null once
  the turn's `finally` closes the run. A delegated model call that
  outlives the initiating turn therefore attributes to the agent but to
  no run. The original plan's "background-delegation work" wording
  overstates this; delegated work that is synchronous within the turn is
  covered, and nothing else is.
- **Two wired paths are not asserted end to end.** The scheduled-task
  run is written by `_runWithAgent`, which the scheduler tests bypass via
  the injectable `runner`; and delegation attribution is unit-tested at
  `AgentRunScope.child()` rather than driven through
  `ConfiguredAgentFactory`. Both should get one assertion each before
  Phase 3 depends on their numbers.

### Deliberately not done

- **A2A hosted-request telemetry.** Hosted agents are built once at
  `start()` and serve concurrent requests, so a single mutable
  "current run" field on the scope would cross-attribute between
  in-flight requests — the exact failure the design exists to prevent.
  Doing it properly needs either a per-request scope (which means
  restructuring `A2AHostService.start`) or a `Zone` around the request,
  whose reliability through `A2ADefaultRequestHandler`'s event bus is
  unverified. Left untouched rather than shipped wrong;
  `AgentRunOrigin.hostedRequest` and its round-trip test already exist
  for when it lands.
- **Giving hosted agents a scope** to de-anonymize their usage rows.
  Passing a scope also wires `configureHarnessForScope`, which would
  start persisting hosted conversations — a behavior change, not a
  telemetry one. Needs its own decision.
- **Retention.** `trimBefore` exists and is tested but nothing calls it;
  the policy (0.3) is still open. App reset is already covered —
  `RecordStore.clearAll()` wipes every collection, so no change to
  `app_reset.dart` was needed.

## Phase 2 status

Landed, `dart analyze` clean, 386 tests passing.

- `lib/ui/screens/agent_center_screen.dart` — one screen, three sections,
  built on `ConfiguredAgentsController` and the existing editors.
- `lib/navigation/app_router.dart` — section, create, and edit routes;
  `_agentCenterRoutes` is shared by all three sections.
- `lib/ui/screens/settings_home_screen.dart` — the Agent Center card,
  which summarizes state (agent count, how many need setup) and refreshes
  off `configurationChanges`.
- The three editors gained an optional `onDirty` callback. Coverage comes
  from two hooks rather than per-field wiring: `Form.onChanged` for text
  fields, and a `setState` override for every other control.
- Retired: `manage_agents_screen.dart`, `configured_agents_view.dart`,
  its barrel export, and `test/configured_agents_view_test.dart` (706
  lines), replaced by `test/agent_center_screen_test.dart` (23 tests).

Coverage is split deliberately across two harnesses, and the split
matters. `agent_center_screen_test.dart` hosts the screen directly, which
means it has no `GoRouter` — so it can only exercise the inline (wide)
path, because every compact interaction calls `context.go`. The compact
path is the primary one on a phone, so its interaction tests live in
`test/navigation/app_router_test.dart`, which wraps the real router:
selection, save, the `PopScope` discard guard, the untouched-form silent
close, and section switching. Any future compact-path test belongs there,
not in the screen test.

### Decisions taken during implementation

- **Selecting an item opens its editor, with no intermediate detail
  view.** In Phase 2 a detail view would be a read-only copy of the form
  with an Edit button next to it. Detail views arrive in Phase 3, when
  there is telemetry to put in them; the routes leave room for a
  `view/:id` sibling.
- **Lists, not card grids.** The plan's cards were justified by the
  per-item metrics they would carry. Without those a card is a ListTile
  with more padding, so the lists stay until Phase 3 fills them.
- **Two rendering mechanics, one per layout.** Below 1200dp the editor is
  a child route: system back works and `PopScope` guards unsaved edits.
  At or above it, selection is local state so a pane swap does not
  animate like a page push. The trade-off is that selection on a wide
  layout does not update the URL; deep links into an edit route still
  open with that item selected.
- **Both agent-create paths survive.** `AddAgentWizard` always builds a
  source, a model, and an agent, so it cannot serve "I already have
  models, add one more agent". The bare `AgentEditor` keeps that case;
  the wizard is what every prerequisite dead end offers.
- **The screen subscribes to `configurationChanges`.** The retired view
  loaded once, which was safe only because nothing could mutate
  configuration from inside it. Now the empty state routes to the wizard,
  so wizard → back → list is a live path.

### Known gaps

- `agentChanges` (the targeted per-agent stream) is not used yet; the
  screen reloads the whole catalog on any configuration change. Fine at
  these list sizes, worth revisiting if it gets slow.
- Medium-width "persistent secondary navigation" is a vertical button
  column, not a `NavigationRail`. It is persistent and always visible,
  but it is not the Material rail component.
- The agent form is long enough that Save sits below the fold in the
  editor pane. That matches the retired dialog's behavior, so it is not a
  regression — but a sticky action row would be an improvement.
- Selection on a wide layout does not update the URL (see the two-mechanic
  decision above). Deep links still work in the other direction.

### Bugs found by the new tests

- `setState(() => _summary = _load())` in the Settings card handed the
  framework a `Future` as the callback's return value. It only surfaced
  once the card was mounted inside the real router, which is exactly what
  the compact-path tests do.
- The `PopScope` dirty guard was originally wrapped only around the
  non-inline branch, so on a wide layout a browser or OS back during an
  edit discarded the form silently — the exact loss the guard exists to
  prevent. It is now unconditional, and covered by a wide-layout test.
- A cascade delete elsewhere could remove the item open in the inline
  pane; the editor would quietly become a create form, and saving would
  mint a new record under a different id. The `configurationChanges`
  handler now closes the pane when its item disappears.

## Phase 3 status

Landed, `dart analyze` clean, 419 tests passing.

- `lib/data/usage_store.dart` — `tokenPointsSince(DateTime)`, the missing
  time-ordered token slice the sparkline needed (the per-conversation and
  per-agent readers could not provide it). Excludes unattributed rows.
- `lib/data/agent_center_overview.dart` — the pure aggregation:
  `OverviewRange`, `OverviewBucket`, `AgentWorkload`, and
  `AgentCenterOverview.from(...)`. No I/O; buckets in local time via one
  shared helper so the runs and tokens series share an x-axis.
- `lib/ui/widgets/charts.dart` — `StackedBarChart` and `Sparkline`,
  theme-native `CustomPainter`s with no chart dependency. Tap-to-reveal on
  the bars; both carry a genuine `Semantics` data summary that is also the
  widget-test surface.
- `lib/ui/screens/agent_center_nav.dart` — `AgentCenterTab` and the shared
  `AgentCenterNav`, extracted from `AgentCenterScreen` so Overview and the
  catalogs navigate through one widget.
- `lib/ui/screens/agent_center_overview_screen.dart` — the dashboard:
  range control, KPI cards, needs-setup list, charts (gated on data),
  workload bars, recent runs. Watches the run ledger and
  `configurationChanges` for live updates.
- Route `/settings/agents/overview`, beside `models`/`sources`.

### Decisions taken

- **Overview is a tab, not the landing page.** It leads the nav switcher
  but a deep link to `/settings/agents` still arrives on Agents — the
  decision from Phase 2 stands.
- **Success rate = succeeded / (succeeded + failed).** Running and
  interrupted runs are excluded, matching the `AgentRunStatus` taxonomy
  (cancellation is a success; interrupted is a crash artifact, not an
  outcome). The denominator is shown on the KPI card so the number is not
  a mystery.
- **KPIs and bars share one window.** The effective floor is the first
  bucket's calendar boundary, so a bounded range's bars always sum to its
  run KPI. This was a bug first — the rolling KPI window and the calendar
  bucket window disagreed, so a run in the gap counted in the headline but
  landed in no bar, and the chart's own semantic summary then contradicted
  its bars. Fixed and regression-tested (`bars sum to the run KPI`).
- **`OverviewRange.all` is the one intentional window divergence.** Its
  KPIs count all history while its chart shows the last 30 days, because an
  unbounded axis cannot be plotted. Documented on the class.
- **No aggregate runs-by-origin split.** Per-row origin labels are
  accurate by construction, but an aggregate split would read as truth
  while A2A telemetry is unwired. The scheduled-task path is now asserted
  end to end (see below), so task runs really do appear; the origin split
  itself waits for A2A.
- **Two chart forms only.** Stacked bar (runs) and sparkline (tokens), per
  the revised plan. Hover tooltips, keyboard chart traversal, and goldens
  remain Phase 4.

### Closed from earlier phases

- **Scheduled-task telemetry is now asserted end to end.** A new test
  drives the scheduler's *default* runner through a real
  `ConfiguredAgentFactory` and asserts a `scheduledTask` run record is
  written — the Phase 1 gap the advisor flagged, now that the dashboard
  surfaces those numbers.

### Deferred, stated out loud

- **Per-item catalog metrics** (success rate, tokens, last activity on
  each agent/model card) are now computable but not wired onto the cards.
  Deferred to a follow-up; the lists stay plain for now.
- **The per-agent detail page** (an agent's own charts, delegations,
  conversations, tasks) is not built. It needs the detail-view surface
  Phase 2 deliberately deferred and is the natural next slice.
- **Live "current work"** (a running-run panel with links) is not built;
  the dashboard shows completed history plus a running count only.
- **Delegation attribution** is covered at the unit level
  (`AgentRunScope.child()` propagation plus the sink stamping) with the
  factory's single `child()` call site verified by source, not by a full
  delegated model call through the factory.

## Phase 4 status

Landed, `dart analyze` clean, 430 tests passing. Phase 4 turned out to be
the per-agent detail page, not chart polish — see "Scope correction".

- `lib/ui/widgets/agent_dashboard.dart` — the dashboard building blocks
  (`KpiCards`, `OverviewCharts`, `RecentRunsCard`, `DashboardCard`, the
  range control, formatters) extracted from the Overview screen so the
  detail page reuses one implementation. The Overview screen's tests
  passing unchanged after the extraction is the proof it was behavior-
  preserving.
- `lib/ui/screens/agent_detail_screen.dart` — a read-only page for one
  agent: identity (model/source, with a broken-config warning),
  per-agent KPIs and charts, instructions, enabled tools, delegates, and
  its own recent runs. Edit is an action in the app bar.
- `lib/data/usage_store.dart` — `tokenPointsSince` gained an `agentId`
  filter; without it a per-agent sparkline would sum in every agent's
  tokens. Tested with a two-agent fixture.
- Route `/settings/agents/view/:id`, beside `overview`.

### Scope correction

The original "Phase 4 = goldens + hover + keyboard + area chart" list did
not survive contact:

- **Goldens: not done, on purpose.** A golden locks in whatever the
  renderer currently produces. Generating them in an environment where the
  baseline cannot be visually verified blesses the current pixels sight
  unseen — including any bug, which the test then enshrines. With zero
  existing golden infrastructure and no human-verify loop, that is
  negative value. The chart `Semantics` summaries already give a
  table-equivalent regression surface. Goldens want a session where the
  baseline can actually be looked at.
- **Area chart: stays cut.** The revised plan replaced it with a stacked
  bar ("reads fine"); reintroducing it would reverse a settled decision.
- **Hover / keyboard chart traversal: deferred.** Minor enhancements to
  charts that already carry a semantic fallback; lower value than the
  detail page, which was the real outstanding slice.

So Phase 4 delivered the per-agent detail page instead.

### Decisions taken

- **Tapping an agent opens its detail page; Edit is inside** (the user's
  call). This inverts the Phase-2 "selecting opens the editor" line — but
  only for agents, which carry telemetry worth seeing before editing.
  Models and sources have none, so tapping one still opens its editor
  directly. The asymmetry is deliberate and documented on
  `AgentCenterScreen`.
- **Per-agent KPIs drop the fleet-only "Active agents" tile.** On a
  single-agent page that count is always one and says nothing. `KpiCards`
  takes a `fleet` flag; the detail page passes false, which also moves the
  live-run count onto the Runs tile so it is not lost. (This was a reuse-
  across-contexts trap — the shared widget rendered a fleet metric on a
  per-agent page; a "does not show Active agents" assertion now guards it.)
- **Delegate links push, not go**, so backing out of a delegate's detail
  returns to the agent that delegates to it rather than collapsing to the
  list.
- **The detail page is read-only.** Everything editable routes to the
  existing editor; the page never duplicates form state.

### Still deferred

- Per-item catalog card metrics (success rate / tokens / last activity on
  each row) remain unwired — the data exists, the cards are still plain.
- Live "current work" (a running-run panel) is still a count, not a list.
- A2A hosted-request telemetry is still unwired (Phase 1's documented
  gap); the origin split waits on it.
- Goldens, chart hover, and keyboard traversal, per the scope correction
  above.

## Test plan adjustments

Keep the original plan's unit and widget coverage, with these changes:

- Add a test that a run's token total, computed by joining
  `usage_records`, matches what `usage_stats_sheet` shows for the same
  conversation. This is the regression that catches the two-ledger
  divergence the split is meant to prevent.
- Add concurrent-run attribution: two runs live in one conversation must
  not cross-attribute tokens. This is the failure mode the timestamp
  fallback would have introduced.
- Add A2A hosted-request attribution explicitly — it is the site most
  likely to be missed, and `test/features/a2a_host_service_test.dart`
  already exists to extend.
- Add delegated-run attribution via the `parent#discriminator`
  conversation-id convention.
- Extend `test/app_reset_test.dart` for the new collection.
- Extend `test/navigation/app_router_test.dart` for both `AddAgentWizard`
  mounts and the new deep links.
- Drop golden tests to Phase 4.

## Unchanged from the original plan

These are correct as written and need no revision: preserving
`ModelSourceConfig` / `ModelConfig` / `SavedAgentConfig` /
`ConfiguredAgentsManager` / secret storage / local-model persistence
formats; no migration for existing records; readiness reflecting
configuration and local-file availability only (no implied network
health); snapshotted display names surviving resource deletion; cost and
pricing out of scope; the 600dp / 1200dp breakpoints measured from the
Agent Center's own constraints rather than screen size.
