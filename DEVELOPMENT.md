# Yohaku Companion Development Guide

Yohaku Companion is a macOS menu-bar companion for Yohaku. Its central correctness boundary is the sanitized Presence snapshot: raw source data must pass through privacy policy before delivery, presentation, diagnostics, or persistence.

## Requirements

- Apple Silicon Mac (`arm64`); Intel build and release targets are intentionally unsupported.
- macOS 15.0 or later.
- Xcode 16.2 or later.
- Swift Package Manager dependencies resolved by Xcode.
- A signing identity for interactive Keychain and Accessibility testing.

Accessibility is optional at the product level and is required only for window-title capture. Application identity and media synchronization must remain usable without it.

## Build

The project, target, scheme, module, and source directory use `YohakuCompanion`. Debug builds use `dev.innei.YohakuCompanion.debug` and produce `YohakuCompanion_DEV.app`; Release builds use `dev.innei.YohakuCompanion` and produce `YohakuCompanion.app`. Credential storage derives its namespace from the active bundle identifier, so development builds cannot read or replace release credentials.

On a clean checkout, install the pinned Discord Game SDK input first. The script verifies the downloaded archive against the repository-pinned SHA-256 before copying the arm64 headers and dylib into the ignored `Vendor/Discord` directory.

```bash
bash scripts/setup_discord_sdk.sh

xcodebuild \
  -project YohakuCompanion.xcodeproj \
  -scheme YohakuCompanion \
  -configuration Debug \
  -derivedDataPath /tmp/YohakuCompanion-derived \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build
```

Run static analysis separately:

```bash
xcodebuild \
  -project YohakuCompanion.xcodeproj \
  -scheme YohakuCompanion \
  -configuration Debug \
  -derivedDataPath /tmp/YohakuCompanion-analyze \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  analyze
```

## Ownership boundaries

```text
YohakuCompanion/
├── Companion/
│   ├── Connection/            Non-secret metadata + protected Device Token adapter
│   ├── Domain/                Sanitized first-party Presence values
│   ├── LiveDesk/              Capability-gated heartbeat and lifecycle owner
│   ├── Protocol/              Versioned DTOs and the only seconds-to-ms mapper
│   └── Transport/             Authenticated HTTP and ordered device sequence
├── Core/
│   ├── Reporter/              Delivery orchestration and provider adapters
│   ├── Database/              SwiftData authority and value projections
│   ├── MediaInfoManager/      Media provider lifecycle
│   └── Utilities/             Monitoring, credentials, network, migrations
├── Presence/
│   ├── Assets/                S3-compatible icon hosting
│   ├── Capture/               AppKit capture adapters and pure sanitizers
│   ├── Domain/                UI and Sync Event value models
│   └── Policy/                Privacy rules and sanitized evaluation
├── Features/
│   ├── MenuBar/               Native status menu presentation
│   ├── Onboarding/            First-run Presence setup
│   └── Settings/              General, destinations, privacy, history, advanced
├── Preferences/DataModels/    Persisted compatibility models and relays
├── Windows/                   AppKit window ownership
└── AppDelegate.swift          Application lifecycle and bounded shutdown
```

AppKit owns the application, status item, native menu, and Settings window. SwiftUI owns Settings and onboarding content. Do not move lifecycle ownership into SwiftUI as part of a page-level change.

## Presence pipeline

```text
Source callbacks
    │
    ▼
Generation-scoped preparation
    │
    ▼
Privacy policy + legacy compatibility mapping
    │
    ▼
Sanitized ReportModel
    ├──> Menu-bar Current Presence
    ├──> Destination delivery
    └──> Versioned Sync Event envelope
```

The following invariants are mandatory:

1. A stale generation must not deliver or remain visible in History.
2. Offline recovery rebuilds a fresh snapshot; it does not replay a retained raw model.
3. Credential authority failure pauses sharing fail-closed.
4. S3 is an `AssetHostingService`, never a `ReporterExtension` or destination.
5. Provider payloads, endpoints, credentials, public asset URLs, and raw responses do not enter Sync History.
6. A destination output summary describes a successful final provider render only.
7. Companion Device Tokens exist only in protected credential memory and the Authorization header; they never enter a DTO, History, or diagnostics.
8. Every Companion v2 nullable key is encoded explicitly as JSON `null`; missing and cleared are not interchangeable.

## Companion Protocol v2 contract harness

The repository has no test target, so the pure Companion domain and transport boundary has a standalone behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Companion/Domain/CompanionMediaPlaybackURLPolicy.swift \
  YohakuCompanion/Companion/Domain/SanitizedPresenceSnapshot.swift \
  YohakuCompanion/Companion/Domain/CompanionMediaSessionTracker.swift \
  YohakuCompanion/Presence/Capture/CompanionMediaPresenceSanitizer.swift \
  YohakuCompanion/Companion/Protocol/CompanionProtocolV2.swift \
  YohakuCompanion/Companion/Protocol/CompanionMomentProtocol.swift \
  YohakuCompanion/Companion/Protocol/CompanionCapabilityNegotiator.swift \
  YohakuCompanion/Companion/Protocol/CompanionPresenceDTOMapper.swift \
  YohakuCompanion/Companion/Transport/CompanionHTTPClient.swift \
  YohakuCompanion/Companion/Transport/YohakuPresenceClient.swift \
  YohakuCompanion/Companion/LiveDesk/CompanionPresenceAuthority.swift \
  scripts/test_companion_protocol_v2.swift \
  -o /tmp/test_companion_protocol_v2

/tmp/test_companion_protocol_v2
```

The harness validates observable wire behavior: explicit nulls, Unicode normalization, media privacy and source-policy sanitization, paused playback semantics, millisecond conversion, position clamping, resource-host rejection, required nullable response keys, capability negotiation, response request-ID correlation, durable concurrent sequence allocation, Authorization-only credentials, the fixed Companion version header on clear and replace, exact-request retry after an ambiguous transport failure, a deliberately early wake remaining behind the bounded cleanup task, bounded clear returning before its deadline, and schema or feature rejection selecting capability refresh rather than a blind degraded heartbeat.

The supported-player playback-link resolver has a separate behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Core/MediaInfoManager/MediaInfo.swift \
  YohakuCompanion/Companion/Domain/CompanionMediaPlaybackURLPolicy.swift \
  YohakuCompanion/Presence/Capture/CompanionMediaPlaybackLinkResolver.swift \
  scripts/test_media_playback_links.swift \
  -o /tmp/test_media_playback_links

/tmp/test_media_playback_links
```

It verifies strict local queue matching for QQ Music and NetEase Cloud Music, fail-closed behavior for ambiguous tracks, canonical provider URL construction, and rejection of spoofed or tracking-bearing URLs.

The protected connection and explicit-null application capture boundary has a separate harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Companion/Domain/CompanionMediaPlaybackURLPolicy.swift \
  YohakuCompanion/Companion/Domain/SanitizedPresenceSnapshot.swift \
  YohakuCompanion/Companion/Protocol/CompanionProtocolV2.swift \
  YohakuCompanion/Companion/Protocol/CompanionCapabilityNegotiator.swift \
  YohakuCompanion/Companion/Protocol/CompanionPresenceDTOMapper.swift \
  YohakuCompanion/Companion/Transport/CompanionHTTPClient.swift \
  YohakuCompanion/Companion/Connection/CompanionConnectionStore.swift \
  YohakuCompanion/Companion/Connection/CompanionPairingClient.swift \
  YohakuCompanion/Presence/Capture/CompanionApplicationPresenceSanitizer.swift \
  scripts/test_companion_connection_capture.swift \
  -o /tmp/test_companion_connection_capture

/tmp/test_companion_connection_capture
```

It verifies that protected storage and capabilities are checked before the one-time pairing code is consumed; feature-off, unsupported-schema, and outdated-client responses stop before claim with fixed local states; the code stays in the POST body; the global pairing error envelope retains only an allowlisted fixed code; the minted Token crosses directly into protected storage; pairing remains publicly disabled; disabled startup does not resolve the Device Token; a concurrent disable wins over an in-flight credential resolution; non-secret metadata contains no credential-shaped field or token value; explicit opt-in resolves the protected connection; removal clears both authorities; privacy-hidden applications become an idle snapshot; hidden window titles encode as `null`; and an unavailable media source is encoded explicitly as `media: null`.

The restartable coordinator lifecycle gate has a focused behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Companion/Application/CompanionCoordinatorLifecycle.swift \
  scripts/test_companion_coordinator_lifecycle.swift \
  -o /tmp/test_companion_coordinator_lifecycle

/tmp/test_companion_coordinator_lifecycle
```

It verifies that an ordered stop owns one cleanup, concurrent stops join that cleanup, starts are rejected while cleanup is in flight, and the same coordinator can restart after shutdown without creating another heartbeat authority.

The Live Desk preview consent boundary has a standalone behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Companion/Domain/SanitizedPresenceSnapshot.swift \
  YohakuCompanion/Companion/Application/CompanionPreviewConsentGate.swift \
  scripts/test_companion_preview_consent_gate.swift \
  -o /tmp/test_companion_preview_consent_gate

/tmp/test_companion_preview_consent_gate
```

It verifies that an uncaptured or cleared preview cannot authorize sharing, a source/privacy revision invalidates earlier consent, recapture restores consent, and the current sanitized application/media projection must still match the reviewed preview. Capture time alone does not invalidate otherwise identical public content.

Media timing has a separate provider-level behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Core/MediaInfoManager/MediaInfo.swift \
  YohakuCompanion/Core/MediaInfoManager/MediaInfoProvider.swift \
  YohakuCompanion/Core/MediaInfoManager/AdaptiveMediaInfoProvider.swift \
  scripts/test_media_timing_semantics.swift \
  -o /tmp/test_media_timing_semantics

/tmp/test_media_timing_semantics
```

It verifies that unavailable timing remains `nil`, real zero remains `0`, enrichment fills only missing values, a known duration clamps an out-of-range position, supported-player playback state does not remain stale after a browser takes over the global session, and the authoritative global playback state wins over a contradictory player-specific fallback without discarding enriched metadata.

## Settings mutations

Integration saves, imports, reset, and erase operations share `SettingsMutationCoordinator`. New mutation paths must use this coordinator so that a stale editor cannot reintroduce data after maintenance completes.

The focused concurrency harness verifies serial admission, exclusive maintenance rejection, and the permanent termination boundary:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  YohakuCompanion/Core/Utilities/SettingsMutationCoordinator.swift \
  scripts/test_settings_mutation_coordinator.swift \
  -o /tmp/test_settings_mutation_coordinator

/tmp/test_settings_mutation_coordinator
```

Credentials are persisted through `CredentialStore` transaction helpers. Persisted configuration excludes secret values. Editors must:

- keep a local draft;
- never refill a stored secret into a control;
- represent secret intent as keep, replace, or remove;
- validate before mutating relays;
- update the runtime relay only after credential persistence succeeds.

Settings export intentionally excludes MixSpace, Slack, and S3 credentials. Import must parse and validate a complete staged snapshot before changing any live preference. Legacy plaintext credentials require explicit user consent and must be aggregated into one `CredentialStore.apply` transaction with their redacted integration preferences; do not persist each integration independently.

## Persistence

`DataStore` is the only component that should interact with SwiftData models. Cross-actor consumers receive value types such as `ReportValue`, `SyncEventValue`, and `IconValue`.

Sync Events are stored in a versioned Codable envelope within the existing report compatibility field. The decoder must continue to distinguish:

- modern structured events;
- legacy integration-name arrays;
- unreadable legacy payloads.

Do not fabricate failure details for legacy events. Do not change the SwiftData schema merely to change presentation.

## Adding a Presence destination

1. Add a stable `PresenceDestinationID` and user-facing metadata.
2. Implement `ReporterExtension` and return `ReporterOptions` with the correct asset capability.
3. Render the provider payload only from the sanitized `ReportModel`.
4. Return a normalized delivery result and a safe output summary for successful delivery.
5. Implement remote-state cleanup when the provider retains Presence.
6. Add a native destination draft editor with validation, test, save, credential replacement/removal, and dirty-navigation protection.
7. Add destination status to the menu bar and Sync History filters.
8. Verify partial success, total failure, cancellation, offline recovery, pause, sleep, and termination.

Do not add S3-compatible storage through this path. Asset hosting belongs under `Presence/Assets` and is resolved only when a destination advertises an icon URL capability.

## Verification

The project currently has no dedicated test target. Changes therefore require focused runtime and migration checks in addition to a strict build.

Prefer behavior-oriented tests when a test target is introduced. Avoid tests that merely restate constant tables, enum cases, or object literals.

Minimum validation for a material change:

| Change | Required evidence |
| --- | --- |
| Privacy or mapping | Sanitized preview and delivered snapshot agree; Hide overrides Alias |
| Destination | Draft test, successful delivery, normalized failure, and safe History output |
| Asset hosting | Optional and required capability paths; fallback remains destination-specific |
| Migration | Fresh install plus each prior schema boundary in isolated defaults |
| Credentials | Keychain success, unavailable authority, replacement, removal, and export exclusion |
| Lifecycle | Pause, sleep/wake, offline/recovery, and bounded termination cleanup |
| Settings UI | Minimum window size, keyboard navigation, VoiceOver labels, and dirty draft handling |

## Isolated runtime testing

Never smoke-test migrations against the installed application’s bundle identifier or Application Support directory. Build with a unique identifier and launch with an isolated home:

```bash
xcodebuild \
  -project YohakuCompanion.xcodeproj \
  -scheme YohakuCompanion \
  -configuration Debug \
  -derivedDataPath /tmp/YohakuCompanion-isolated \
  PRODUCT_BUNDLE_IDENTIFIER=dev.example.YohakuCompanion.smoketest \
  CODE_SIGNING_ALLOWED=NO \
  build

CFFIXED_USER_HOME=/tmp/yohaku-companion-smoketest-home \
  /tmp/YohakuCompanion-isolated/Build/Products/Debug/YohakuCompanion_DEV.app/Contents/MacOS/YohakuCompanion
```

Use a new identifier for every migration fixture when `cfprefsd` caching could invalidate the result.

## Release

Production publication requires signing, notarization, a valid Sparkle feed, and an EdDSA public key. Use the repository release procedure rather than ad hoc archive commands. A build without valid Sparkle metadata intentionally disables update checks.

The Yohaku Companion repository must be provisioned with its own Sparkle EdDSA key pair. Configure the repository-scoped `SPARKLE_PRIVATE_KEY` and `SPARKLE_PUBLIC_ED_KEY` secrets together; do not copy the ProcessReporter signing identity. The workflow verifies that the pair matches before publishing an appcast.

The release workflow runs `scripts/prepare_arm64_app.sh` after export. This removes Intel slices from precompiled dependencies such as Sparkle and re-signs nested code from the inside out before notarization or DMG creation. A plain Xcode arm64 build is not sufficient evidence that every embedded binary is arm64-only.

## Documentation

When behavior changes, update the closest user and architecture references:

- `PRESENCE_PRODUCT_UI_SPEC.md` for product decisions and acceptance criteria;
- `USER_GUIDE.md` for user workflows;
- `ARCHITECTURE.md` for runtime ownership and invariants;
- `API.md` for internal extension contracts;
- `readme.md` for the public product boundary.
