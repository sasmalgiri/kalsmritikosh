# Privacy Data Flow — Kalsmritikosh (App Review + PrivacyInfo basis)

Engineering-truth companion to the Privacy Policy. It states exactly what data exists,
where it lives, and every network egress — so `PrivacyInfo.xcprivacy`, the App Store
privacy nutrition labels, and the App Review notes match the shipped binary (P11/P14).

## Data at rest (all on-device)
| Data | Location | Leaves device? |
|---|---|---|
| User source files | where the user put them (read in place via security-scoped bookmarks) | No |
| Evidence blocks, chunks, entities, events, relationships, assertions, embeddings, summaries, answers, custody | single SQLite DB in the app's Application Support container | No |
| Settings / bookmarks | UserDefaults + Keychain (bookmarks) | No |
| Exports (answers/reports/diagnostics) | user-chosen or app-private folder, on explicit action | Only if the user shares them |

## Network egress (exhaustive)
| Call | When | Payload | Endpoint |
|---|---|---|---|
| Optional model download | user taps "download larger model" | none of the user's content — only the model file request | [MODEL HOST URL] |

There is **no** other network path in the release build:
- No cloud reasoning/embedding (cloud provider is NOT registered in release — enforced by test, P8.1).
- No analytics, telemetry, crash reporting, or ads SDKs.
- No account/auth service.

## PrivacyInfo.xcprivacy — required declarations
- **Data collected:** none linked to identity; no tracking.
- **API "reasons":** file timestamp / disk space / UserDefaults reasons as applicable
  to the frameworks used (fill exact reason codes at P14.8).
- **Tracking:** NSPrivacyTracking = false.

## App Review notes (draft)
> Kalsmritikosh is fully on-device. Reviewers can test offline. The only network use
> is an optional, user-initiated download of a larger local AI model from [HOST];
> no document content is transmitted. There is no login. To test: add a folder of
> sample documents, wait for "queryable", ask a question, open a citation.

---
Last updated: 2026-07-13. Reconcile against the final binary before submission; if any
new egress is added, it MUST appear here and in PrivacyInfo first.
