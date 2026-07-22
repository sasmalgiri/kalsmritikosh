# Kalsmritikosh — Support

_Draft for the owner to host at the App Store "Support URL". Covers the §8 support-operations
checklist. Last reviewed 2026-07-22._

## Contact

_Owner to insert a public support email or page before submission._

## What Kalsmritikosh is

A private, on-device workspace that turns your own documents and email into a searchable,
evidence-cited knowledge base — fully on your Mac, with no account and no data leaving the device.

## FAQ

**Does my data go to the cloud?** No. The release build has no network provider; everything runs
on your Mac. See the Privacy Policy.

**Do I need an account or subscription?** No account. The App is a one-time purchase; there are no
hidden in-app purchases.

**Why does an answer say "not found in the documents searched"?** The App only answers from
evidence it can cite. If the fact isn't in your ingested files (or hasn't finished processing), it
tells you honestly instead of guessing.

**Why is a file listed as "couldn't be processed"?** Some formats are supported with limits, some
are preserved-only, and audio/video aren't transcribed in this version. The Sources screen shows
exactly which files didn't make it and why. See the Supported Formats page.

**Why are answers deterministic-only on my Mac?** Rich AI answers use Apple's on-device Foundation
Models, available on macOS 26 hardware that supports Apple Intelligence. Where they're unavailable,
the App still works fully in deterministic mode (search, timelines, matrices, contradictions, gaps,
and cited reports).

**How big an archive can it handle?** The App is tested to the size stated on the store page. Very
large corpora may take longer to fully process; search becomes available before deep enrichment
finishes (the Sources screen shows both dimensions).

## Reporting a bug (privacy-safe)

1. In the App, reproduce the issue.
2. Export a diagnostic report from Settings (this contains app logs and counts — **review it and
   remove anything sensitive before sending**; it never includes your document contents by default).
3. Send it to the support contact with a short description and your macOS version.

The App never uploads diagnostics automatically — you choose what to share.

## Backup & restore

Your knowledge base lives in the App's Application Support container on your Mac. To back it up,
include your user Library in your normal Mac backup (e.g. Time Machine). To restore, restore that
container before launching. Re-ingesting your original folders also rebuilds the knowledge base
(processing is idempotent — unchanged files are skipped).

## Known limitations (v1)

- Audio/video are recognized but **not transcribed** (deferred).
- Some legacy/office formats are extracted with disclosed limits; a few are preserved-only.
- Advertised scale is the **tested figure** on the store page — not an unlimited claim.
- Optional downloaded local models are **not** in v1.

## Release notes & rollback

Release notes ship with each version. If an update misbehaves, you can reinstall the prior version
from your purchase history; your local database is preserved across app reinstalls.
