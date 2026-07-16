# Yohaku Companion

[![macOS](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Yohaku Companion is the native macOS companion for Yohaku. The current client publishes a privacy-sanitized snapshot of the foreground application to Yohaku Live Desk. Optional Bridges can also use application and media Presence when configured.

It is not a productivity tracker: it does not calculate work time, rankings, focus scores, or behavioral analytics.

## Product model

```text
Application Source ──> Privacy Rules ──> Sanitized Application ──> Yohaku Live Desk
                                               │
                                               ▼
Media Source ───────> Bridge Sanitizer ──> Optional Bridge Snapshot
                                               ├──> MixSpace
                                               ├──> Slack
                                               └──> Discord
            │
            ▼
Optional public application icon URL
            │
            ▼
S3-compatible Application Icon Hosting
```

S3-compatible storage is asset infrastructure, not a Presence destination. A hosting failure may degrade an icon enhancement, but it must not block destinations that can receive Presence without a public icon URL.

## Features

- Menu-bar-first Current Presence and destination health.
- Application and optional window-title sources for Live Desk; media remains Bridge-only in the current client.
- Global privacy defaults plus per-application Share, Hide, and Alias rules.
- First-party Yohaku connection and Live Desk publishing.
- Optional Slack and Discord Presence bridges.
- Optional S3-compatible application icon hosting with a local URL cache.
- Local Sync History containing sanitized snapshots and normalized delivery results.
- Protected destination credentials with explicit replacement and removal: Keychain for stable signed builds, or a permissions-restricted local journal for ad-hoc builds.
- Versioned settings migration and credential-free settings backup.

## Requirements

- Apple Silicon Mac (`arm64`). Intel Macs are not supported.
- macOS 15.0 or later.
- Accessibility permission only when window titles are enabled.
- The optional media helper when a supported Bridge uses media Presence.
- A paired Yohaku connection for Live Desk, or at least one configured Bridge for Bridge delivery.

## Installation

1. Download the latest build from [Releases](https://github.com/Innei/YohakuCompanion/releases).
2. Open the disk image and move Yohaku Companion to Applications.
3. Launch Yohaku Companion and complete the privacy and Yohaku setup flow.
4. Pair this Mac with Yohaku, then review the sanitized preview before enabling Live Desk. Optional Bridges can be configured separately.

## Settings

| Section | Purpose |
| --- | --- |
| General | Bridge sharing, shared source controls, permissions, media helper, and launch behavior |
| Yohaku | First-party pairing, sanitized preview, and Live Desk controls |
| Destinations | MixSpace, Slack, Discord, and optional Application Icon Hosting |
| Privacy & Rules | Global privacy defaults and application-specific behavior |
| Sync History | Local audit of sanitized delivery attempts |
| Advanced | Reporting engine, mappings, storage, backup, updates, and diagnostics |

The native menu bar menu is the primary operational interface. Settings is intended for configuration and audit rather than continuous activity browsing.

## Development

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

The project, target, and scheme retain their internal `ProcessReporter` names during the staged migration. Debug uses the isolated `dev.innei.YohakuCompanion.debug` bundle and produces `YohakuCompanion_DEV.app`; Release uses `dev.innei.YohakuCompanion` and produces `YohakuCompanion.app`.

See [ARCHITECTURE.md](ARCHITECTURE.md), [DEVELOPMENT.md](DEVELOPMENT.md), and [USER_GUIDE.md](USER_GUIDE.md) for additional detail.

## License

2025 © Innei. Released under the [MIT License](LICENSE).

[Personal website](https://innei.in/) · GitHub [@Innei](https://github.com/innei/)
