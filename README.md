# agents_app

The Flutter app built on `agents_flutter`: multi-agent chat with cloud and
fully local models, scheduled agent tasks, LAN agent sharing (A2A), and an
optional capture wearable.

## Setup

```sh
flutter pub get
flutter run            # pick a device: macOS, iOS, Android, or Chrome
```

Committed dependencies use immutable Git revisions. To develop against sibling
checkouts, copy `pubspec_overrides.yaml.example` to `pubspec_overrides.yaml`.

Before the first iOS or macOS build, install the checksummed llama.cpp
framework release:

```sh
dart run tool/bootstrap_llama.dart
```

On first launch the onboarding flow walks through adding an agent — either an
API-backed provider (OpenAI-compatible, Anthropic) or a local GGUF model that
runs on-device via llama.cpp.

## Supported platforms

| Platform | Notes |
|---|---|
| macOS / iOS / Android | Full feature set. |
| Web (Chrome) | Chat and providers work (local inference uses wllama and needs cross-origin isolation). No LAN hosting, no wearable — both need sockets/BLE the browser doesn't expose. |

Typography (Outfit 400/500/600/700) is bundled under `assets/google_fonts/`,
so startup looks identical offline; runtime font fetching is disabled in
`main()`.

## Providers and local models

- **Model sources** (Settings → Agents & providers) hold endpoints and API
  keys; keys live in the platform secret store, never in records.
- **Local models** download into the app's support directory under
  `local_models/<id>/`; edits to files outside that copy do not take effect.
- **Agents** pair a model with instructions, tool access, and optional
  delegations to other agents.

## Tasks (foreground only)

Tasks (the Tasks tab) run agent prompts on a schedule **while the app is
open** — there is no OS-level background execution. Each run executes in a
dedicated conversation you can inspect from Chats.

- Recurring tasks that fail retry automatically on their next cycle (the
  status shows `failed` until the retry starts).
- Failed one-shot tasks are not retried automatically; use **Run now**.
- Runs interrupted by quitting the app are marked failed on the next launch;
  recurring ones become due again immediately.

## Sharing agents on the network (A2A)

Settings → Share agents serves selected agents to paired devices over the
LAN using the A2A protocol.

**Security model:** pairing uses a single-use, two-minute QR/paste token;
paired clients hold a bearer credential (only its hash is stored on the
host). Traffic is plain HTTP on the local network — share only on networks
you trust. Inbound runs queue one at a time so a busy host serves peers in
order.

## Wearable (native only)

Settings → Wearable device pairs the XIAO ESP32S3 capture wearable over BLE
and syncs audio/images into agent memory. The entry is hidden on web, where
BLE is unavailable. See `docs/WEARABLE_PLAN.md` for the device plan.

## Privacy

- **Prompt logs** (Settings → Logs & diagnostics) record every request sent
  to a model — including message content — to help debug. They stay on
  device; avoid sharing them verbatim.
- **Private chats** skip persistence: no transcript, no usage ledger rows,
  no titles.
- Usage (token) records are kept per model call in the local usage ledger.

## Development

```sh
flutter test                    # run all tests
flutter test test/<file>.dart  # one file
flutter test --platform chrome test/settings_wearable_visibility_test.dart
flutter analyze                 # static analysis
dart format lib test            # format
```

The reusable framework packages are maintained in
[`jamiewest/agents`](https://github.com/jamiewest/agents), while local GGUF
inference is maintained in
[`jamiewest/agents_llama`](https://github.com/jamiewest/agents_llama).
