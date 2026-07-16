# Yohaku Companion User Guide

Yohaku Companion is Yohaku’s native macOS companion. It publishes a privacy-sanitized snapshot of the foreground application and eligible media playback to your Yohaku Live Desk after you pair this Mac, review the public preview, and explicitly enable sharing. It is not a productivity tracker and does not calculate work time, rankings, or focus scores.

Media timeline delivery is capability-negotiated. When Core advertises `mediaTimeline`, Yohaku Companion publishes sanitized media identity and playback anchors; otherwise it continues with application Presence and explicitly sends `media: null`.

## Product Model

| Concept | Meaning |
| --- | --- |
| Yohaku Connection | A revocable device pairing between this Mac and one Yohaku server |
| Live Desk | The latest sanitized, short-lived public projection; it is not an activity timeline |
| Sanitized Preview | The exact application and media context eligible for first-party delivery after local privacy rules |
| Bridge | An optional Slack, Discord, or legacy MixSpace delivery path |
| Sync Event | A bounded local audit record of one sanitized Bridge delivery |
| Application Icon Hosting | Optional S3-compatible storage for public icon URLs used by supported Bridges |

S3 is not a Presence destination. It is used on demand only when an enabled Bridge can benefit from a public application icon URL.

## System Requirements

- Apple Silicon Mac (`arm64`). Intel Macs are not supported.
- macOS 15.0 or later.
- Yohaku Companion version `1.7.3`. This version is retained to satisfy the Core minimum-client contract.
- A Yohaku server with the Companion Live Desk capability enabled.

## Independent Installation

Yohaku Companion is a new, independently installed application. It does not replace the earlier ProcessReporter application.

| Boundary | Behavior |
| --- | --- |
| Installation | Both applications may remain installed and run independently |
| Preferences and history | Yohaku Companion starts with its own settings, database, and Application Support directory |
| Credentials | Yohaku Companion uses its own bundle-scoped Keychain service and protected local credential store |
| Migration | No ProcessReporter settings, history, cache, or credential is read, copied, or silently imported |
| Pairing | Generate a new one-time code in Yohaku Admin and pair Yohaku Companion as a new device |

Removing the earlier application is optional. Installing Yohaku Companion never enables Live Desk automatically.

## First Launch

The onboarding flow has three stages:

1. **Welcome** explains current Presence, privacy-before-delivery, and the absence of productivity analysis.
2. **Sources & Privacy** selects Applications, Window Titles, and Media Playback.
3. **Yohaku** opens the first-party pairing page. Completing onboarding leaves sharing paused.

Pairing requires a one-time code generated in Yohaku Admin. The code expires after 10 minutes and can be used only once.

Accessibility permission is used only for **Window Titles**. Yohaku Companion does not read the current window title while Window Titles is disabled. After the user enables Window Titles, the application requests Accessibility access only through the explicit permission action. Foreground application identity remains available without this permission.

## Pairing and Live Desk Consent

Open **Settings > Yohaku**, then provide:

- The public URL of the Yohaku server.
- A device name shown in Yohaku Admin.
- The one-time pairing code.

Pairing stores the device token in Yohaku Companion’s protected credential namespace and leaves Live Desk disabled. Review **Current Sanitized Preview**, then explicitly enable Live Desk. The pairing itself never publishes desktop activity.

When Live Desk is enabled:

- Application changes and negotiated heartbeats publish a complete sanitized snapshot.
- Sleep, screen lock, pause, removal, and application termination clear the public projection on a best-effort ordered path; the server lease provides final expiry.
- **Pause Live Desk** stops new updates and makes a best-effort clear request while retaining the pairing; an unreachable server falls back to lease expiry.
- **Remove Pairing…** stops new updates, attempts the same remote clear, and removes the local connection. Revoke the device in Yohaku Admin when server-side revocation is required or the app warns that an inaccessible Keychain copy may remain.

## Menu Bar

Select the menu bar icon to open the native Presence menu.

| Menu area | Purpose |
| --- | --- |
| Global status | Shows setup required, paused, syncing, ready, degraded, or failed |
| Current Presence | Shows the sanitized application and media currently eligible for configured delivery paths |
| Connections and Bridges | Shows the latest first-party or optional Bridge state |
| Recovery commands | Opens the relevant Settings page for connection, credential, or icon-hosting failures |

Current application and media items are read-only. Use **Add Rule for _Application_…** or **Edit Rule for _Application_…** to open **Privacy & Rules** for the named application. The menu also contains Settings, update checks, and Quit.

## Settings

### Yohaku

The Yohaku page owns first-party pairing, sanitized preview, Live Desk consent, pause, and device removal. Slack and Discord failures do not invalidate a healthy Yohaku Connection.

### General

Sources are independent:

- **Applications** makes foreground application identity eligible for sanitization and delivery.
- **Window Titles** allows Yohaku Companion to read the active title only while this switch is enabled. Accessibility permission and the privacy policy must also allow it. The switch is off by default on new installations.
- **Media Playback** makes current title, artist, media application, and capability-negotiated playback timeline available to Live Desk and supported Bridges.

General also reports Accessibility, media-provider, credential-storage, and Launch at Login state.

### Bridges and Assets

Optional delivery paths are separate from the Yohaku Connection.

| Bridge or resource | Required configuration | Notes |
| --- | --- | --- |
| Slack | Slack API token | Publishes a rendered profile status and supports conditional emoji rules |
| Discord | Discord Application ID | Publishes local Rich Presence through the Discord client |
| Legacy MixSpace | HTTP(S) endpoint and API token | Compatibility path; it is not the Yohaku device pairing |
| Application Icon Hosting | S3-compatible storage | Optional asset infrastructure, not a destination |

Each detail page keeps an unsaved draft. **Test** uses that draft without saving it, and external-write tests require confirmation. Leaving a modified page offers Save, Discard, and Cancel.

Credentials are stored outside exported settings. Saved credentials are never displayed in plaintext; use **Replace** or **Remove** to change them.

### Privacy & Rules

Global defaults control whether Application Name, Window Title, and Media are shared or hidden. Application rules can override each field and may define a display alias.

Policy precedence is:

```text
General source off
    > Hide rule
    > Legacy mapping
    > Explicit display alias
```

Consequences:

- A disabled source cannot be re-enabled by an application rule.
- Hide always wins over an alias.
- Existing legacy Filter entries remain fail-closed Hide projections within Yohaku Companion’s own data store.
- Legacy Mappings remain available under **Advanced** and are not silently rewritten.

### Sync History

Sync History is a local delivery audit, not an activity-analysis view. Each event can include the sanitized application, allowed window title, media fields, per-Bridge result, safe output summary, normalized error, asset result, event ID, timestamp, and trigger reason.

Yohaku Companion retains at most 5,000 Sync Events and removes the oldest first. Legacy record formats remain readable. A legacy `S3` success is shown as an asset result, never as a destination. History does not contain credentials, authorization headers, endpoints, full provider responses, icons, artwork, or raw capture objects.

### Advanced

Advanced includes engine controls, legacy mappings, local history and cache maintenance, credential-free settings export, validated import, application updates, sanitized diagnostics, **Reset Settings**, and **Erase All App Data**.

Backup and restore operate only on Yohaku Companion data. They are not a ProcessReporter migration mechanism. Export excludes credentials; an import is validated before mutation, and historical plaintext credential fields require an explicit restore, omit, or cancel decision.

## Privacy and Security

Yohaku Companion does not capture screenshots, record keystrokes, read file contents, or persist raw provider payloads. Window titles and media metadata may be sensitive. Keep Window Titles disabled unless required, review the sanitized preview, and add application-specific Hide rules where appropriate.

The Device Token is placed only in the HTTP Authorization header. It is not written to request bodies, URLs, UserDefaults, Sync History, logs, or diagnostics.

## Troubleshooting

### Window titles are unavailable

1. Enable **General > Window Titles**. Until this switch is enabled, Yohaku Companion does not read the current window title.
2. Select **Request Accessibility Access…** or **Open System Settings…**.
3. Enable **Yohaku Companion** in **Privacy & Security > Accessibility**.
4. Return to Yohaku Companion; capability state refreshes when the window becomes active.

Application names continue to work without Accessibility permission.

### Pairing is unavailable

Confirm that the server advertises the Companion Live Desk capability, Yohaku Companion is version `1.7.3` or newer than the server minimum, protected credential storage is available, and the one-time code has not expired or already been consumed.

### Live Desk is not publishing

Confirm that pairing completed, the sanitized preview was reviewed, Live Desk was explicitly enabled, at least one application or media field remains visible after privacy rules, and the server capability is still available. Pairing alone is intentionally insufficient.

### Status says Waiting for Network

The menu retains the local sanitized presentation without queuing a stale report. After connectivity returns, Yohaku Companion captures and sanitizes the latest state before delivery.

### A Bridge fails

Open the event in **Sync History**. The Inspector displays a normalized, non-sensitive error code and safe summary. A Bridge failure does not revoke the Yohaku pairing.
