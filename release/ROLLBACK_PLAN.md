# Rollback plan (RC-6) — v1.1

What to do when a shipped build misbehaves. Ordered by severity; every step
is owner-executable without new code.

## 1. Bad answer quality on a user's archive (no crash)
- The deterministic kill-switch already ships: Settings → "Fully private
  (no AI)" forces evidence-only answers (rules + quotes; zero generative AI).
  Support reply: toggle it on, ask the question again — receipts stay intact.
- Collect the receipt ("Why this answer?") text; file against the gold wall.

## 2. Crash / data-integrity defect
- Expedited review: submit a 1.1.x patch from the release branch using the
  App Review "expedited" request (template below). Schema rule: patches may
  ADD migrations, never edit shipped ones (SAVEPOINT law) — user ledgers are
  forward-migrating and never lost.
- The app never deletes extracted data (tier-by-confidence law), so a bad
  producer is repaired by a versioned rewrite in the patch, not by re-ingest.

## 3. Pull from sale (last resort)
- App Store Connect → Pricing and Availability → remove from sale. Existing
  users keep the app; their data is local and remains readable — no server
  side exists to break.

## Expedited-review request template
> Kalsmritikosh 1.1.x fixes a defect that [one sentence]. The app is fully
> offline; the fix touches [subsystem] only. No new entitlements, no new
> data collection (PrivacyInfo unchanged). Please expedite.

## Post-rollback verification
- Re-run the release ritual on the patch: full suite, parity vs the latest
  sealed baseline (FULL-FIELD), grep + architecture guards, Step-5 proof.
