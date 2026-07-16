# Yohaku Companion Repository Instructions

## Product boundary

- The public product name is **Yohaku Companion**.
- The Xcode project, target, scheme, module, and source directory use `YohakuCompanion`. Legacy `ProcessReporter` identifiers may remain only where changing them would alter a compatibility contract.
- Release and Debug persistence must remain isolated under `dev.innei.YohakuCompanion` and `dev.innei.YohakuCompanion.debug`. Never read, copy, migrate, or delete the separately installed ProcessReporter application's data or credentials.
- Pairing alone must not publish Presence. Live Desk requires a current sanitized preview and explicit user consent.
- Live Desk uses Companion Protocol v2 directly against Yohaku Core. Do not restore the removed cloud-function transport.

## Build and verification

On a clean checkout, run the checksum-pinned Discord SDK installer before Xcode builds:

```bash
bash scripts/setup_discord_sdk.sh
xcodebuild \
  -project YohakuCompanion.xcodeproj \
  -scheme YohakuCompanion \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build
```

Use behavior-oriented harnesses from `scripts/` for protocol, connection, lifecycle, consent, media-timing, settings-transaction, or Discord changes. Do not add tests that merely snapshot constant tables or internal representation.

## Implementation constraints

- `YohakuCompanionService` is the one process-wide owner of pairing metadata, protected credentials, preview consent, and the Live Desk coordinator.
- Raw application, window-title, and media values must pass source controls and privacy policy before delivery, diagnostics, UI preview, or local history.
- Reset, erase, pairing, consent, and credential changes must retain `SettingsMutationCoordinator` ordering and fail-closed behavior.
- Preserve unrelated work and never use destructive Git restore/reset commands against user-owned changes.

## Release

Use `.agents/skills/release-yohaku-companion/SKILL.md`. Releases require the repository-specific Sparkle key pair; Apple Developer ID credentials are optional until the project explicitly requires notarized distribution.
