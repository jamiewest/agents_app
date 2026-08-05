# App Store and Mac App Store readiness

A review of this app against Apple's App Review Guidelines as of August 2026,
covering both the iOS App Store and the Mac App Store, plus the changes made in
response and the decisions still outstanding.

Scope note: the app is currently named "Agents App". A rename (OnionChat) is
planned but deliberately not part of this pass — the bundle identifier
`dev.jamiewest.agentsApp` can stay unchanged through any rename, so nothing here
depends on the final name.

## Summary

Nothing in the app's design is disqualifying on either store. The features that
*sound* alarming turn out to be the defensible ones, and the real problems were
mundane configuration: missing usage strings, an undeclared capability, absent
privacy manifests, and a build number that never incremented.

The two substantive product changes are that iOS is now a Tor **client** only,
and that paired peers can be revoked.

| Area | Before | Now |
| --- | --- | --- |
| Tor on iOS | Client + onion hosting | Client only (dial, pair) |
| Tor on macOS | Client + hosting | Unchanged |
| `run_shell` | macOS only, no policy | macOS only, deny-list policy, gate enforced in the factory |
| Local model presets | Every preset on every device | Filtered by platform and physical RAM |
| Paired peers | Bearer valid forever | Listed and revocable in Settings |
| Tor keys/guard state on iOS | Synced to iCloud backup | Excluded from backup |

## What the app does, in review terms

Useful framing for anything written to App Review:

- It is a **client for AI agents**. Users bring their own provider account
  (Anthropic, Google, or any OpenAI-compatible endpoint) and their own API key,
  or run a local GGUF model on-device via llama.cpp. The app sells nothing, has
  no accounts, and collects no data.
- Agents can use **tools**: web search, a scratch file store, device facts
  (time, connectivity, battery, location), notifications, an inventory
  database, and — on desktop only — a shell.
- Devices can **pair** with each other to share agents, over the local network
  or over Tor.

## Findings and what changed

### Resolved: submission blockers

**Undeclared background mode.** `ios/Runner/Info.plist` declared
`UIBackgroundModes: [bluetooth-central]` while the app contains no Bluetooth
code and no Bluetooth usage string. An unused background mode is a routine
2.5.4 rejection. Removed.

**Missing purpose strings for linked frameworks.** `geolocator_apple` and
`geocoding_darwin` are linked on both platforms and the agent editor exposes a
Location toggle, but neither Info.plist had a location purpose string — a
guaranteed crash the first time permission is requested, and a review flag even
before that. On macOS the microphone was worse than missing a string: the audio
recorder is live in the chat input and `record_macos` is linked, but there was
neither `NSMicrophoneUsageDescription` nor the `device.audio-input` sandbox
entitlement, so recording could not have worked in a sandboxed build at all.
Both platforms now carry accurate strings, and macOS has the matching
entitlements. The iOS microphone string was also corrected — it described
"recording video attachments", which is not what the feature does.

**Contacts access with no consumer.** macOS carried
`com.apple.security.personal-information.addressbook` and
`NSContactsUsageDescription`, justified only as AppKit text-field autofill.
Nothing in the app touches Contacts. For an AI chat app this reads as
contact-list harvesting and invites a question with no good answer. Removed
from both entitlements files and the plist.

**No privacy manifests.** Neither Runner target had a `PrivacyInfo.xcprivacy`.
Most plugins ship their own, but `llama_cpp_flutter`, `tor_flutter_arti`, and
`camera_macos` do not, and their required-reason API use is attributable to the
app. Added to both targets and registered as bundle resources, declaring no
tracking and no collected data, with reason codes for file timestamps
(`C617.1`), disk space (`E174.1`), system boot time (`35F9.1`), and user
defaults (`CA92.1`).

If a TestFlight upload still returns an ITMS-91053 warning naming
`llama.framework` specifically, the fallback is a Podfile `post_install` step
that copies the same manifest into the framework bundle. Don't do this
pre-emptively.

**Build number never incremented.** `version: 0.0.1` with no `+build` meant
`CFBundleVersion` resolved to `0.0.1` on every build, and App Store Connect
rejects a duplicate build number on re-upload. Now `0.1.0+1`.

> **Process rule:** bump the `+N` suffix in `pubspec.yaml` on every TestFlight
> or App Store upload. One bump covers both platforms — they read the same
> pubspec. In CI, `--build-number=$(git rev-list --count HEAD)` automates it.

**iOS had no entitlements file at all.** This mattered in two places. Without
`com.apple.developer.kernel.increased-memory-limit`, loading a multi-gigabyte
GGUF on an 8 GB iPhone risks a jetsam kill rather than merely slow
performance — the single most likely way a reviewer crashes the app. Without
`com.apple.developer.networking.wifi-info`, the `get_current_network_info` tool
silently returns nothing on iOS. Added `ios/Runner/Runner.entitlements` with
both, wired into all three build configurations.

> Both capabilities must be enabled on the App ID. Automatic signing normally
> handles this, but if a build starts failing to sign, that is the first thing
> to check.

### Resolved: iOS feature gating

**Tor hosting is now macOS-only.** iOS carries the same Arti runtime, and the
switch was reachable on iPhone — but a backgrounded iOS app is suspended, so an
onion address published from a phone is unreachable most of the time. The
`tor_flutter` README concedes this directly. Shipping it would be advertising a
feature that does not work (guideline 2.1) on top of inviting the hardest
questions in the review.

Gated in two places: `TorSharingSettings` is only registered on macOS in
`lib/main.dart`, and `TorSharingSettings.isSupported` independently requires
macOS, so a future caller constructing it directly cannot re-open the hole.
The `/settings/tor` screen no longer points iOS users at a per-agent switch
that isn't there.

**iOS keeps the entire client half** — reaching a peer's `.onion`, redeeming a
pairing code, and chatting with a remote agent all work unchanged. This is also
the posture with the clearest App Store precedent.

**Model presets are filtered to the device.** `availableLocalModelPresets`
filtered only on web, so an iPhone was offered a preset documented as needing
16 GB of RAM and roughly 6 GB of downloads, and `minMemoryMb` was recorded but
never enforced anywhere. Replaced with `presetsFor({totalMemoryMb})`, which
hides desktop-only presets on phones and enforces `minMemoryMb` against
physical memory sampled from the llama.cpp memory monitor (exact on Apple
platforms via `sysctl hw.memsize`). Unknown or estimated memory skips the
memory filter rather than emptying the list.

**Local models on iOS come from the built-in list or a file the user picks.**
The model editor had free-text GGUF URL fields validated only as "is this an
absolute URI" — any host, any scheme. That weakens the 2.5.2 answer below
(curated weights from a known host is a much better sentence than "the user
types any URL and we download it"), and it is a 2.1 quality risk in its own
right: an unvetted GGUF can be the wrong architecture, wrong quantization, or
simply too large, and it crashes on the reviewer's device. iOS now shows a
read-only summary of where a preset's weights came from instead of the URL
fields, and a model that has no URL yet starts on the file picker. Importing a
file through the system picker stays available — a file the user explicitly
chose is exactly the sanctioned model. macOS keeps URL entry.

**Preset model URLs are pinned to commit SHAs**, not `resolve/main`. A shipped
build cannot be re-pointed, so a mutable ref means an upstream rename breaks
the download for everyone already on that version. This was not hypothetical:
the Gemma 4 E4B preset's MTP drafter URL already 404s against `main` today
because upstream renamed the file, so that preset has been shipping a broken
artifact. Fixed along with the pinning, and a test now fails any preset URL
that is not pinned to a 40-character commit.

**Web search keeps custom endpoints on iOS but not custom user agents.**
Configurable user agents violate no App Store rule — Safari's own "Request
Desktop Site" is user-agent switching — but an arbitrary UA sitting next to
JavaScript rendering and free-text query parameters reads as bot-detection
evasion tooling, and it earns a phone almost nothing. The user-agent profile
editor and browsing-UA override are hidden on iOS; clients there send the
platform default. Choosing the search endpoint, which is the part people
actually want (a self-hosted SearXNG is privacy-positive), stays.

Search endpoints saved or edited from now on must use **https** unless the host
is on the local network — loopback, RFC 1918, link-local, or a `.local` /
`localhost` name. A self-hosted SearXNG on a LAN rarely has a certificate and
its traffic never leaves the network, so blocking it outright would have
removed the very use case that justified keeping custom endpoints on iOS.
Anything routable must be https: a search query is the user's own text, and
over http it crosses the internet in the clear.

Two limits worth knowing. The rule runs in `saveClient`, so a cleartext client
saved by an earlier build keeps working until someone edits it — nothing
re-validates on load. And a local cleartext client with **Render JavaScript**
enabled still goes through the platform WebView, where App Transport Security
governs the request; that combination can fail even though the plain-HTTP
search path works.

Note what this does *not* change: `open_web_page` loads arbitrary URLs in a
headless WebKit view with JavaScript enabled, and it is registered
independently of search configuration. That is the app's unrestricted web
access, and it is the thing the age-rating answer has to reflect — hiding
search settings would not have removed it.

**Shell access can no longer be wired on mobile.** The editor offered the
toggle only on desktop, but `ConfiguredAgentFactory` gated only on `!kIsWeb` —
so a config arriving with the flag already set (imported from a paired peer,
restored from a desktop backup) would have wired a shell executor on a phone.
The factory now requires a desktop platform too, with a regression test
covering iOS and Android.

### Resolved: hardening

**Paired peers can be revoked.** `AuthorizedClientsStore` had `add` and
`verify` and no way to remove, so a bearer issued once was valid forever and
the only escape was destroying the onion identity — which breaks *every* peer.
The store now has `list()` and `remove()`, and Settings has a **Paired devices**
screen listing each device with a confirm-then-revoke action. Verification
re-reads the store per request, so revocation takes effect on the peer's next
call with no restart. In-flight streams finish.

**Tor state no longer rides along in iCloud backups.** The Tor data directory
holds Arti's guard state and consensus cache, and on a host its own copy of the
onion service key. A small method channel in `AppDelegate.swift` sets
`isExcludedFromBackup` on that directory at every launch (the flag lives on the
directory, so recreating the tree drops it). macOS needs nothing — Application
Support is not part of a device backup.

**`run_shell` now runs under a policy.** A deny-list only, deliberately short:
`sudo`, `rm -rf` aimed at a filesystem or home root, `mkfs` / `diskutil erase` /
`dd of=/dev/`, `shutdown` / `reboot`, `launchctl bootout`, the classic fork
bomb, pipe-a-download-into-a-shell, and keychain dumping. Patterns are anchored
to command position, so `grep "rm -rf" notes.md` passes untouched. This is a UX
guardrail, not a security boundary — the real controls are the approval prompt
and the sandbox.

## Not problems — do not "fix" these

Each of these looks like a finding and isn't. They are listed so a future pass
doesn't create a problem by tidying them.

- **No `NSAppTransportSecurity` exception is needed, and adding one would hurt.**
  The plain-HTTP pairing and onion traffic goes through Dart's `HttpClient` over
  raw sockets, which never touches NSURLSession, so ATS does not apply. Adding
  `NSAllowsArbitraryLoads` would invite a review question where none exists.
- **No `NetworkExtension` or VPN entitlement.** Tor runs in-process. Guideline
  5.4 (VPN apps) is not implicated.
- **`com.apple.security.cs.allow-jit` is correctly absent from macOS Release.**
  Flutter release builds are AOT.
- **macOS Release signing with "Apple Development" is correct at rest.** The
  Mac App Store distribution identity is applied by Xcode at archive-export
  time. Hardcoding a distribution identity into the Release configuration would
  break every local `flutter run --release` on a machine without that
  certificate.

## Open decisions

### 1. The macOS Release build does not link for Intel

**Found during this pass; pre-existing and unrelated to the changes above.**
A universal `flutter build macos --release` fails at the link step:

```
ld: symbol(s) not found for architecture x86_64
tor_flutter_arti: clang: error: linker command failed
```

`TorFlutterArti.xcframework` ships three slices — `ios-arm64`,
`ios-arm64-simulator`, `macos-arm64` — and no `macos-x86_64`. macOS Release
builds every standard architecture, so the Intel half has no Arti to link
against. Confirmed by building the same configuration arm64-only, which
succeeds:

```bash
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

Two ways out, and this is a product decision:

- **Add an `x86_64` (or universal) macOS slice to the Arti xcframework** in
  `tor_flutter`. Correct if the app should run on Intel Macs — the deployment
  target is 13.3, which still includes them.
- **Ship Apple silicon only**, by setting `EXCLUDED_ARCHS[sdk=macosx*] =
  x86_64` (or pinning `ARCHS = arm64`). The Mac App Store accepts an
  arm64-only app; it simply will not be offered to Intel users.

Nothing else is blocked on this, but the Mac App Store archive cannot be
produced until one of them is done.

### 2. Export compliance — must be settled before the first upload

**Status: deliberately unanswered in code.** Neither Info.plist declares
`ITSAppUsesNonExemptEncryption`, so App Store Connect will ask on every upload.
That is the correct state until the classification is decided, because the key
is a formal export declaration and a wrong one is worse than an extra prompt.

The app embeds **Arti** (Tor, via `tor_flutter_arti`), which brings its own TLS
stack (rustls/ring) rather than relying on Apple's. That means the common "uses
only encryption provided by the operating system" exemption does **not** apply,
and answering `false` would be inaccurate.

The plausible path is License Exception **TSU** for publicly available
encryption source code — Arti and its crypto dependencies are open source — which
carries a **one-time** notification to BIS and the NSA rather than an annual
report. Note this is *not* the same as mass-market self-classification under
EAR 740.17(b)(1), which does involve annual reporting; the two are easy to
conflate.

**Action:** confirm which exemption applies (worth a lawyer's eye, since it is a
regulatory filing and not an engineering call), file the one-time notification
if that is the route, then set the plist key to match the answer so uploads stop
prompting.

### 3. Age rating

The new questionnaire (13+/16+/18+, mandatory since 31 January 2026) has to be
completed before any submission. The driver here is **unrestricted web access**:
agents can run web searches against a user-supplied endpoint, load arbitrary
pages in a headless web view, and model responses can contain tappable links
that open in the browser. Answer that question honestly; expect 16+ or higher.

The questionnaire now also asks about social-media capabilities. Device pairing
is closer to personal device sync than to a social network — there are no
profiles, no discovery, no public content, and a paired peer talks to *your
agent*, not to you — but the pairing feature should be described accurately
rather than denied.

### 4. Third-party AI disclosure

Apple's November 2025 clarification requires clear disclosure and consent before
sharing personal data with third-party AI services. The app's posture is already
strong — the user chooses the provider explicitly and supplies their own key,
and nothing is sent anywhere until they do. Worth a plain sentence in onboarding
and in the privacy policy naming what leaves the device: conversation content
goes to the provider the user configured, and nowhere else.

Separately, the app should make clear that agents are AI, not people. Given the
app is explicitly about configuring AI agents this is unlikely to be contested,
but it is now an explicit guideline.

## Draft App Review notes

Paste into App Review Notes, trimmed per platform. Every claim is verifiable in
the source.

> Agents App is a client for AI agents. Users supply their own AI provider
> account and API key, or run an open-weights model entirely on-device. The app
> has no accounts, no purchases, no advertising, and collects no data. There is
> no demo account to provide; a reviewer can add any provider key, or download
> an on-device model with no key at all.
>
> **On-device models.** The app downloads GGUF model weights from Hugging Face
> at the user's request. These are data files consumed by the llama.cpp
> inference engine compiled into the app — not code, not scripts, and not
> plug-ins. The app never downloads or loads executable code at runtime; it uses
> no JIT and calls `dlopen` on nothing outside its own bundle. The model list is
> filtered to what the device's physical memory can hold.
>
> **Tor.** The app can reach agents shared by another device at a `.onion`
> address. Tor runs in-process as a compiled Rust library (Arti); no separate
> process is spawned and no VPN or NetworkExtension API is used. This transport
> carries one thing: agent-to-agent messages between devices the user has
> explicitly paired. It is not a general-purpose onion browser — the web tools
> resolve hosts through the system resolver, so `.onion` addresses are rejected
> there. On iOS, the app is a Tor *client* only; publishing an onion service is
> available on macOS alone.
>
> **Pairing.** Devices pair out-of-band by scanning or pasting a single-use code
> that expires in two minutes. There is no discovery, no directory, and no
> user-to-user messaging. Every request after pairing requires a bearer
> credential; only its hash is stored. Users can list and revoke paired devices
> in Settings → Paired devices.
>
> **Shell tool (Mac App Store only).** An agent can be granted a shell tool,
> off by default and available only on desktop. Commands require explicit user
> approval before running, a policy rejects obviously destructive ones, and —
> most importantly — the app is sandboxed, so any process it spawns inherits
> that sandbox and reaches only the app container and files the user has
> explicitly selected. It cannot read the user's home directory.
>
> **Agent file tools** operate on a private virtual store inside the app's own
> database, not the real filesystem.

## Archiving and signing

**Precondition: push the `agents` package changes first.** Peer revocation
(`AuthorizedClientsStore.list`/`remove`, `PairedClient`), the default shell
policy, and the desktop-only shell gate live in `~/Developer/agents`, and
`pubspec.yaml` resolves `agents` and `agents_flutter` from git at `ref: main`.
Local builds only work because the gitignored `pubspec_overrides.yaml` points at
the local checkout — so `lib/ui/screens/paired_devices_screen.dart` will not
compile on CI, on a fresh clone, or on any machine without that override until
those changes are committed and **pushed** to `main` on
`github.com/jamiewest/agents`. Since the two repos are committed separately,
the realistic failure is agents_app landing without its package half.

While there: `ref: main` is unpinned on `agents`, `agents_flutter`, and
`tor_flutter`, so an upstream push silently changes what ships and the binary is
not reproducible from the referenced source. Pin the refs before submitting.

Nothing in the project needs changing for distribution; the identity is applied
at export.

1. `flutter build ipa` (iOS) or `flutter build macos --release` (macOS), or open
   the workspace directly.
2. Xcode → Product → Archive.
3. Organizer → **Validate App** first. This is what actually exercises privacy
   manifest scanning, re-signing of the embedded `llama.framework`, entitlement
   and provisioning-profile matching, and build-number checks. Fix anything it
   reports before distributing.
4. Organizer → Distribute App → App Store Connect.

## Verification performed

- `flutter analyze` clean in `agents_app` and `agents_flutter`.
- Test suites: 834 pass in `agents_flutter`; in `agents_app` 423 pass and 2
  fail, both in `test/tasks_screen_test.dart` and both unrelated to this work —
  that test still exercises the task-template feature that a concurrent change
  removed from `tasks_screen.dart`. New coverage here spans the preset filter,
  preset URL pinning, the shell policy deny-list, the desktop-only shell gate
  on iOS and Android, paired-device revocation, Tor hosting staying hidden on
  iOS, search-endpoint scheme rules, the iOS user-agent gate, and the iOS model
  editor — including that a preset's download URL survives a save with the
  field hidden.

> **Check what `agents_flutter` actually resolved to before trusting a run.**
> `pubspec.yaml` overrides `agents`/`agents_flutter` to git at `ref: main`, and
> the gitignored `pubspec_overrides.yaml` overrides that again to the local
> checkout. If the local override is missing or `pub get` has not re-run,
> everything still compiles — against the *git cache copy*, silently ignoring
> local package edits. Confirm with:
>
> ```bash
> python3 -c "import json;print([p['rootUri'] for p in json.load(open('.dart_tool/package_config.json'))['packages'] if p['name']=='agents_flutter'])"
> ```
>
> A `.pub-cache/git/...` path there means package changes are not being tested.
> Note also that running `pub get` with the override present rewrites
> `pubspec.lock` to local paths; that rewrite should not be committed.
- `flutter build ios --release` succeeds **with signing**, so both new
  entitlements provision against the App ID. Verified in the signed binary:
  `com.apple.developer.kernel.increased-memory-limit` and
  `com.apple.developer.networking.wifi-info` are present,
  `PrivacyInfo.xcprivacy` ships in the bundle, `UIBackgroundModes` is gone, and
  the location and microphone strings read correctly at
  `CFBundleShortVersionString` 0.1.0 / `CFBundleVersion` 1.
- `flutter build web` succeeds (the only target CI builds).
- macOS Release **builds and signs arm64-only**; the universal build fails to
  link for Intel — see open decision 1, which is a pre-existing packaging gap
  rather than a regression. The signed arm64 app was inspected directly and
  carries the expected entitlements (`device.audio-input`,
  `personal-information.location`, `app-sandbox`; no `addressbook`), ships
  `PrivacyInfo.xcprivacy` in `Contents/Resources`, and reports
  `CFBundleShortVersionString` 0.1.0 / `CFBundleVersion` 1.

Still worth doing on real hardware before submitting:

- macOS: record an audio message (proves the new microphone entitlement and
  string), confirm text fields still behave after the Contacts entitlement was
  removed, and check Console for sandbox denials.
- iOS device: confirm the Tor data directory carries the excluded-from-backup
  flag after Tor has run once.
- Both: an Organizer **Validate App** pass, per above.
