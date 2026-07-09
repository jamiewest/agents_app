# Wearable Capture — Plan

Integration of a Seeed Studio XIAO ESP32S3 Sense wearable (camera + PDM mic +
microSD) into `agents_app`. The device captures continuously on its own,
buffers to SD, and offloads to the app opportunistically; the app processes
captures into a time-addressable memory store, and exposes the device to
agents as tools — the agent's "eyes and ears".

## Locked decisions (2026-07-09)

- **Platforms:** macOS + iOS only. macOS is the phase-1 bring-up host.
- **Firmware:** new sibling repo `~/Developer/capture_firmware` (PlatformIO,
  XIAO ESP32S3 Sense). Its `docs/PROTOCOL.md` is the **authoritative**
  protocol contract — GATT UUIDs, HTTP endpoints, manifest/file formats.
  Neither side diverges from it silently; propose a spec change instead.
- **Transport:** hybrid. BLE = control plane (status, time_sync, capture-now,
  policy, WiFi provisioning, check-in) and *discovery for the data plane*:
  the device publishes its HTTP `ip:port + token` over a GATT characteristic,
  so there is **no mDNS dependency**. HTTP (device-hosted) = bulk plane:
  manifest pull, CRC-verified file download, explicit ack before the device
  frees SD space. BLE chunked transfer is the slow fallback for audio when
  WiFi is unreachable.
- **STT:** `TranscriptionEngine` interface with `AppleSpeechEngine`
  (on-device SFSpeechRecognizer/SpeechAnalyzer) first; whisper.cpp is a
  future engine behind the same interface (would require approved
  `llama_flutter` work).
  - *Revised 2026-07-09:* the second engine is `AgentTranscriptionEngine`
    (local Gemma 4 audio-in through the distiller agent — its mmproj
    carries an audio encoder, and the existing mtmd path accepts WAV
    `DataContent`), not whisper.cpp. No `llama_flutter` changes were
    needed. Engine selection is the `wearable.transcription_engine`
    setting (`apple` | `local` | unset = auto, which prefers the local
    model once a distiller agent is configured and falls back to Apple
    Speech otherwise). Audio *output* (Gemma 4 speech generation) is not
    buildable on the vendored llama.cpp runtime — mtmd is input-only —
    so it stays out of scope.
- **Image analysis:** existing local multimodal path (Gemma + mmproj presets
  via `agents_llama`). No new vision stack.
- **Repo bounds:** all Flutter-side code lives in `packages/agents_app/`
  (including the Apple Speech Swift bridge in `ios/`/`macos/` Runner). The
  `agents`, `agents_flutter`, `agents_llama`, and `llama_flutter` packages
  are used through their public APIs only.
- **New dependency:** `flutter_blue_plus` (macOS + iOS). The only new Dart
  dependency in the plan.

## App-side layout

```
packages/agents_app/lib/wearable/
  protocol/    Pure Dart: status/manifest/control models, framing, CRC,
               time-sync math. Zero Flutter/BLE imports. All unit tests
               live here, against byte/JSON fixtures.
  transport/   BLE via flutter_blue_plus + HTTP offload client (existing
               `http` dep). Exposed behind a DeviceTransport interface so
               the pipeline is testable with a FakeDeviceTransport.
  pipeline/    Offload orchestrator, capture archive (sqflite), processing
               job queue, TranscriptionEngine + AppleSpeechEngine,
               image-describe + distillation runners.
  tools/       CaptureDeviceProvider extends AIContextProvider (same shape
               as FileMemoryProvider/TodoProvider: static tool-name
               constants, rehydratable ProviderSessionState).
  ui/          Device page: pairing, battery/buffer status, recording
               consent toggle, manual capture, sync progress.
```

## Device behavior (firmware)

- PDM mic → 16 kHz / 16-bit mono WAV segments (~60 s) to microSD,
  continuous while recording is enabled.
- On-device silence gate (protocol v0.2, 2026-07-09): segments that never
  exceed the `silence_rms` policy threshold (default -45 dBFS, matching the
  app-side `SilenceGate`) for ≥300 ms are deleted at rotation — dead air
  never reaches SD backlog, sync, or transcription. Manifest id gaps are
  normal. Tunable via `set_policy {silence_rms}`; 0 disables.
- OV2640 → JPEG still every N minutes (policy-set) to SD.
- Append-only manifest journal on SD:
  `{id, type, start_epoch_ms, duration_ms, size, crc32}`.
  Pre-time-sync segments carry epoch 0; the app stamps them with
  sync-receipt time and flags them approximate.
- Check-in: buffer threshold crossed + bonded central in range → notify.

## Pipeline

```
check-in / manual sync:
  BLE connect → time_sync → read WiFi endpoint characteristic
  → HTTP pull manifest → download files → verify CRC
  → write to archive dir + sqflite rows            ← DURABLE POINT
  → POST /ack (device frees SD)
  → enqueue jobs: transcribe(wav) | describe(jpeg)
  → workers drain queue → on batch complete: distillation agent run
```

Rules:

- The durable point is the archive write. Before it, retries resume from the
  device (files persist until acked); after it, from persisted job state.
  Every step must survive being killed and resumed.
- `start_epoch_ms` flows end-to-end untouched — it is what makes memory
  time-addressable.
- Archive: sqflite (existing app dep), store shaped like
  `lib/data/chat_transcript_store.dart`:
  `captures(id, device_id, kind, start_epoch_ms, duration_ms, file_path,
  crc, status, transcript_or_description, processed_at)` + a `jobs` table
  with retry/backoff state.
- Distillation is an agent run in the existing framework (a user-selected
  "distiller" configured agent, run in a private scope), fed the batch of
  `{timestamp, transcript|description}`. Its output lands in a **dedicated
  `wearable_memory` vector collection** (`WearableMemoryStore` over
  `RecordStoreVectorStore` + app embedding settings) rather than any
  agent's chat memory — chat memory is scoped per agent + session, but
  wearable observations must be recallable by every agent via the phase-3
  device tools. Entries carry start/end epoch ranges for time-window
  recall. Without a configured distiller, or when the run fails, raw
  transcripts/descriptions are stored verbatim — observations are never
  lost.

## Agent tools

- `device_status` — cached last-seen/battery/buffer; never blocks on radio.
- `device_capture_image` / `device_capture_audio_clip` — live BLE; fail fast
  with `device_unreachable` + last-seen info.
- `device_force_sync` — kicks the pipeline.
- Recall goes through the existing memory/search tools — agents read memory,
  never the device.
- Recording consent is app-level user state checked in the service layer;
  no tool path can enable capture when the user has it off.

## Phases

1. **Prove the pipe (macOS).** Firmware records WAV segments + JPEGs to SD,
   advertises, serves HTTP. App: connect, time_sync, pull, archive, play
   back WAV, view JPEG.
2. **Processing.** Apple Speech bridge, multimodal describe, job queue,
   distillation → memory store.
3. **Tools + UI.** CaptureDeviceProvider, device page, consent, manual
   capture.
4. **iOS + background.** Native CoreBluetooth restoration, opportunistic
   sync, retention/cleanup. The SD buffer means a missed wake costs
   nothing — never design for real-time delivery on iOS.

Within a phase: smallest vertical slice first.

## Known risks

- **Battery** is the dominant physics problem (continuous PDM + SD writes +
  camera). Measure in phase 1; duty-cycling/energy gating is the lever.
- **iOS background BLE** is deliberately quarantined in phase 4 behind a
  working foreground product.
