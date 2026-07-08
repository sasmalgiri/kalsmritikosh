# App Store / Distribution Readiness — Phase L

This document captures the App Store / notarization checklist and the
runtime decisions made in Phase L to satisfy Apple's review criteria
without amputating capabilities.

## Distribution targets

Kalsmritikosh is designed to ship via two paths:

1. **Mac App Store** — strict sandbox, no Full Disk Access. Optional
   loaders (iMessage, browser history) work only when the user
   manually copies the source SQLite file into an Kalsmritikosh-watched
   folder.
2. **Developer ID + notarization** — same binary, same flags,
   distributed outside the App Store. With Full Disk Access granted
   by the user in System Settings, the optional loaders can read the
   original container paths directly.

The two builds use the **same code**. The only difference is the
distribution path. No `#if APPSTORE` compile flag needed.

## Sandbox + entitlements

`Kalsmritikosh.entitlements` declares:

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required for Mac App Store |
| `com.apple.security.files.user-selected.read-write` | `true` | NSOpenPanel folder picks |
| `com.apple.security.files.bookmarks.app-scope` | `true` | Persisted security-scoped bookmarks |
| `com.apple.security.network.client` | `true` | Local Ollama HTTP + user-configured cloud LLM endpoints |
| `com.apple.security.device.audio-input` | `false` | We don't capture mic audio (we ingest pre-recorded files only) |
| `com.apple.security.automation.apple-events` | `false` | We don't script other apps |
| `com.apple.security.cs.allow-unsigned-executable-memory` | `false` | No JIT / runtime code load |
| `com.apple.security.cs.disable-library-validation` | `false` | All loaded libs are signed |
| `com.apple.security.cs.allow-jit` | `false` | Foundation Models / MLX models are AOT-loaded |

## Privacy manifest

`Kalsmritikosh/PrivacyInfo.xcprivacy` declares:

- `NSPrivacyTracking = false` — zero tracking
- `NSPrivacyTrackingDomains = []`
- `NSPrivacyCollectedDataTypes` — only `OtherUserContent`, linked to
  the user's identity, with purpose `AppFunctionality`. Collection
  is conditional: only when the user explicitly configures a cloud
  LLM endpoint AND issues a query.
- `NSPrivacyAccessedAPITypes` — required-reason declarations:
  - `FileTimestamp` → reason `C617.1` (inside app/group container)
  - `SystemBootTime` → reason `35F9.1` (measure time spent in app)
  - `DiskSpace` → reason `E174.1` (display free space)
  - `UserDefaults` → reason `CA92.1` (read/write same app group)

## Info.plist additions required (in the Xcode build settings)

The project uses Xcode's auto-generated Info.plist. Add these keys
in **Project → Info → Custom macOS Application Target Properties**:

| Key | String value |
|---|---|
| `NSLocalNetworkUsageDescription` | `Kalsmritikosh connects to your local Ollama daemon (http://localhost:11434) for on-device LLM generation when configured.` |
| `NSDocumentsFolderUsageDescription` | `To ingest emails, documents, PDFs, and other files into your private knowledge ledger.` |
| `NSDownloadsFolderUsageDescription` | `Same as Documents — to ingest files you've placed there.` |
| `NSDesktopFolderUsageDescription` | `Same as Documents.` |
| `NSAppleEventsUsageDescription` | (not needed; entitlement is `false`) |
| `LSApplicationCategoryType` | `public.app-category.productivity` |
| `NSHumanReadableCopyright` | `© 2026 Shirshendu Sasmal Giri. All rights reserved.` |

## Optional loaders (Phase L feature flags)

`App/FeatureFlags.swift` exposes three flags, all UserDefaults-backed:

| Flag | Default | What it gates |
|---|---|---|
| `iMessageLoaderEnabled` | OFF | `IMessageLoader` (reads chat.db via ExternalSQLiteSource) |
| `browserHistoryLoaderEnabled` | OFF | `BrowserHistoryLoader` (Safari + Chromium) |
| `chatExportLoaderEnabled` | ON | `ChatExportLoader` (WhatsApp/Signal/Slack TXT — file-system only) |

Settings → **Optional ingest** lets the user toggle each. Takes
effect on next app launch (the LoaderRegistry is built once at
`AppState.boot()`).

## Demo data for App Review

The current build does not ship a bundled demo archive. Reviewers
need to verify the app works without ingesting their own data.

**Recommended addition before submission**:

```
Resources/Fixtures/AppReviewDemo/
  ├── README.txt
  ├── emails/
  │   ├── project-kickoff-2024-01-15.eml
  │   ├── contract-signed-2024-02-03.eml
  │   ├── invoice-001-2024-02-15.eml
  │   └── delivery-confirmation-2024-03-01.eml
  ├── docs/
  │   ├── Project_Kalsmritikosh_Brief.pdf
  │   └── Contract_v2.pdf
  └── images/
      └── meeting-whiteboard.png
```

Plus an Onboarding action: **"Try the demo archive"** that bookmarks
`Resources/Fixtures/AppReviewDemo` and kicks off an ingest. Lets
reviewers see ingest → answer → causal chain → narrative chapter
within ~30 seconds of first launch.

## Network calls — auditable list

All network egress lives under `Routing/Providers/`. No other
directory may contain a `URLSession` call. Auditable via:

```bash
grep -rE "URLSession|URLRequest" Kalsmritikosh/ \
  | grep -v Routing/Providers \
  | grep -v Tests
```

Should return zero hits. (PrivacyGate filters cloud providers out of
capability resolution when the user disables them.)

## Pre-submission test suite (TODO)

These don't exist yet but should before TestFlight:

- `KalsmritikoshTests/EventVersionsRepositoryTests.swift`
- `KalsmritikoshTests/ContradictionFinderTests.swift`
- `KalsmritikoshTests/CounterfactualSimulatorTests.swift`
- `KalsmritikoshTests/EvidenceRankerTests.swift`
- `KalsmritikoshTests/QueryCategoryClassifierTests.swift`
- `KalsmritikoshTests/IMessageLoaderTests.swift` (with a synthetic chat.db fixture)
- `KalsmritikoshTests/ChatExportLoaderTests.swift` (WhatsApp + Signal + Slack samples)
- `KalsmritikoshTests/SchemaMigrationsTests.swift` (v1 → v27 round-trip)
- `KalsmritikoshUITests/GoldenPath.swift` (cold boot → ingest demo → ask question → see answer)

Plus an eval-gate CI workflow that fails the build when:

- `EvalKit` lookup precision < 0.85
- `EvalKit` multi-hop recall < 0.55
- `NarrativeEvalKit` confidence RMSE > 0.20
- `GroundTruthEvalKit` Entity F1 < 0.80 or Event F1 < 0.70

## Review-time gotchas

1. **Local network usage prompt**: macOS will show a one-time
   permission dialog when Ollama is first contacted. The
   `NSLocalNetworkUsageDescription` string above is what appears.
2. **Folder pickers**: NSOpenPanel prompts the user per-folder. The
   first ingest after install will trigger one prompt per root.
3. **Background ingest**: Kalsmritikosh does NOT use BGTaskScheduler or
   continuous capture. All work runs only while the app is open.
4. **Crash logs**: enable symbolication uploads in the Organizer
   so App Store reviewers can attach trace data.
