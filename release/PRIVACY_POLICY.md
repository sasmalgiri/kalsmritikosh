> **SUPERSEDED (D-4, 2026-08-27)** — the canonical public text is
> `docs/privacy.html` / `docs/terms.html` / `docs/support.html`
> (matching `LegalNotice.termsVersion` 1.5, 2026-08-27). This draft is
> retained for history only; do not link or submit it.

# Kalsmritikosh — Privacy Policy

_Draft for the owner to review and host at the App Store "Privacy URL". Last reviewed 2026-07-22.
Copy is written to match the locked product contract in `SHIP_DECISIONS.md`; if any product
claim changes, update this document in the same change (GOV rule)._

## Summary (plain language)

Kalsmritikosh is a **local, on-device** knowledge workspace for your own documents and email.
**We do not collect, transmit, sell, or share any of your data.** Your files, the text extracted
from them, the questions you ask, and the answers you receive **never leave your Mac** in the
release build. There is **no account, no sign-in, no analytics, and no telemetry.**

## What data the app handles — and where it stays

| Data | Where it lives | Leaves your device? |
|---|---|---|
| Documents/email you point the app at | In place, plus the app's local database in your Mac's Application Support container | **No** |
| Extracted text, entities, events, facts, embeddings | Local SQLite database on your Mac | **No** |
| Your questions and the generated answers | Computed on-device; stored locally in your history | **No** |
| Optional "managed evidence vault" copies | A local, content-addressed folder on your Mac (only if you turn it on) | **No** |
| Crash logs / diagnostics | Only what **you** choose to export and send; nothing is sent automatically | **Only if you export & send** |

## No network in the release build

The shipping app contains **no network provider**. Cloud reasoning/OCR code paths exist only in
internal developer builds and are compiled out or made unreachable for release by the app's
`PrivacyGate`. Reasoning uses **Apple's on-device Foundation Models** where available; where they
are unavailable the app runs in a fully deterministic, no-model mode. The text-embedding model
(BGE-small) is **bundled** and runs on-device. There is no background uploader and no model
downloader in v1.

## Data collection (App Store "nutrition label")

**Data Not Collected.** The app collects no data. It requires no account and performs no tracking.
The only files it reads are the ones you explicitly select, under macOS's standard security-scoped
permission prompts, which you can revoke at any time in System Settings.

## Your control

- **Access:** all your data is in local files you own; you can inspect or copy the database directly.
- **Deletion:** removing a folder from the app, or deleting the app's Application Support container,
  removes the corresponding data. Redaction and "forget" actions are explicit and audited in-app.
- **Portability:** answers and work products export to standard files you keep.

## Children

The app is not directed at children and collects no personal data from anyone.

## Changes

Material changes to this policy will be published here and reflected in the app's version notes.

## Contact

_Owner to insert a public support/privacy contact address before submission (see `SUPPORT.md`)._
