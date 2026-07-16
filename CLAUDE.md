# Yohaku Companion Repository Guidance

## Project Overview

Yohaku Companion is the native macOS companion for Yohaku. The current first-party Live Desk client publishes privacy-sanitized foreground application context after one-time pairing, preview, and explicit consent. MixSpace, Slack, and Discord remain optional Bridges; S3-compatible storage is optional icon-hosting infrastructure rather than a destination.

The Xcode project, target, scheme, and source directory temporarily retain the internal `ProcessReporter` name. Do not treat that implementation name as the product identity or persistence namespace.

## Build and Verification

```bash
bash scripts/setup_discord_sdk.sh

xcodebuild \
  -project ProcessReporter.xcodeproj \
  -scheme ProcessReporter \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build
```

The app requires Apple Silicon, Xcode 16.2 or later, and macOS 15 or later. Run the behavior harnesses and isolated runtime procedure documented in `DEVELOPMENT.md` for changes to Companion protocol, connection storage, media timing, settings transactions, privacy, or lifecycle behavior.

## Product and Runtime Boundaries

1. `YohakuCompanionService` owns the one process-wide `CompanionConnectionStore` and `CompanionLiveDeskCoordinator`.
2. Pairing installs protected credentials and non-secret metadata with Live Desk disabled. Pairing alone must never publish.
3. Preview and delivery use the same sanitized application-only capture. Do not add media to Live Desk until the client and negotiated server capability support it.
4. Live Desk mutations use Companion Protocol v2 directly against Core. Do not restore the removed cloud-function payload/cache/broadcast path.
5. Bridge delivery continues through `Reporter` and its extensions. The Bridge sharing switch does not implicitly control Live Desk.
6. Raw application or media data must pass source controls, privacy policy, and mapping before network delivery or local history persistence.
7. Reset, erase, pairing, consent, and credential changes must use `SettingsMutationCoordinator` so destructive maintenance cannot race a stale editor.

## Identity and Credentials

- Release bundle: `dev.innei.YohakuCompanion`
- Debug bundle: `dev.innei.YohakuCompanion.debug`
- Release product: `YohakuCompanion.app`
- Debug product: `YohakuCompanion_DEV.app`

Application Support and protected credential service names derive from the active bundle identifier. Yohaku Companion must not inspect, copy, import, or delete ProcessReporter preferences, databases, Application Support data, or Keychain services. The two applications may coexist, and Yohaku Companion requires a new Yohaku device pairing.

Never store a Device Token or Bridge credential in plain UserDefaults, logs, diagnostics, exported settings, previews, or view state. Views consume only non-secret connection summaries and fixed error descriptions.

## Important Locations

- `ProcessReporter/Companion/`: pairing, connection persistence, Protocol v2, transport, and Live Desk lifecycle.
- `ProcessReporter/Presence/`: capture, privacy policy, mappings, and sanitized domain models.
- `ProcessReporter/Core/Reporter/`: optional Bridge delivery engine.
- `ProcessReporter/Features/Settings/Yohaku/`: first-party pairing, preview consent, pause, and removal UI.
- `ProcessReporter/Core/Utilities/SettingsMutationCoordinator.swift`: cross-settings transaction ordering.
- `YOHAKU_COMPANION_PRODUCT_SPEC.md`: accepted product and cross-repository protocol baseline.

Preserve behavior-oriented tests. Do not add tests that merely snapshot static enum cases, constant tables, or object literals.
