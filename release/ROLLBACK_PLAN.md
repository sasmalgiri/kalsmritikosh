# Rollback plan (RC-6) — v1.1

What to do when a shipped build misbehaves. Ordered by severity; every step
is owner-executable without new code.

## 1. Bad answer quality on a user's archive (no crash)
- The deterministic kill-switch already ships: Settings → "Fully private
  (no AI)" forces evidence-only answers (rules + quotes; zero generative AI).
  Support reply: toggle it on, ask the question again — receipts stay intact.
- Collect the receipt line plus the "Technical details" disclosure (answer ID, build, source ids); file against the gold wall.

## 2. Crash / data-integrity defect
- Expedited review: submit a 1.1.x patch from the release branch using the
  App Review "expedited" request (template below). Schema rule: patches may
  ADD migrations, never edit shipped ones (SAVEPOINT law) — user ledgers are
  forward-migrating and never lost.
- The app never deletes extracted data (tier-by-confidence law), so a bad
  producer is repaired by a versioned rewrite in the patch, not by re-ingest.

## 3. Pull from sale (last resort)
- App Store Connect → Pricing and Availability → remove from sale. Existing
  users keep the app; their data is local and remains readable. The one server
  (the AI relay, §5) holds no case data; pausing it stops AI Included / AI Pro
  requests only — every case, search, map and export keeps working offline.

## 4. App version and ledger schema compatibility (S14, SHIP-10)
- **Forward only.** The ledger schema only increases (release/VERSION_RULE.md). A new build migrates
  an older ledger inside SAVEPOINTs; a failed migration step rolls back to the ledger as it was and the
  app reports it — it never resets a case (MigrationFaultInjectionTests, MigrationMatrixTests).
- **No destructive downgrade.** An older build opening a newer ledger (schema ahead of the code) does
  not migrate, rewrite or drop anything (MigrationFaultInjectionTests.versionAheadOfSchemaIsNonDestructive).
  Rolling a user back therefore means: install the fixed NEWER patch, never ask them to reinstall an
  older build over a migrated ledger.
- **Before a schema-changing release**, the release check confirms: a complete backup verifies and
  restores into a fresh folder on the candidate (CompleteBackupTests, the smart-map acceptance journey),
  and the migration matrix passes from every milestone ledger.
- **A bad migration in a shipped build** is repaired by the NEXT migration (additive, re-runnable),
  never by editing the shipped one; users' current cases stay where they are.

## 5. The AI relay (Cloudflare Worker `relay/`): rollout, rollback, forward recovery
What it holds: counts and credits only (relay/schema.sql) — no question, passage or answer.
- **Rollout.** Deploy a new Worker version with `wrangler deploy` only after `npm test` passes in
  `relay/`; keep the previous version's id (`wrangler deployments list`). Schema changes to D1 are
  additive `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ADD COLUMN` only; never drop or rename a column
  a running Worker reads.
- **Rollback.** `wrangler rollback <previous-version-id>` restores the previous code at once. Because
  D1 changes are additive, the previous code still reads the tables. Credits reserved by in-flight
  requests are returned by the relay's own failure path (a provider failure gives everything back).
- **Forward recovery** when a release corrupted metering rows: stop charging by setting
  `GLOBAL_CAP_USD` to `0` (every request is refused `capacity-paused`; nothing is charged; own-key users
  are unaffected), export the D1 tables (`wrangler d1 export kals-relay`), repair with a reviewed SQL
  script against the export, re-import, restore the cap. Never delete `topups` rows — a pack's
  remaining credits are the customer's.
- **Key compromise.** Rotate the provider key in the Worker's secrets (`wrangler secret put`), then
  revoke the old key at the provider. The app holds no publisher key, so no app update is needed.

## 6. Incident response (any severity)
1. **Contain**: pull the relay (cap to 0) or the build (remove from sale / pause phased release)
   — whichever is implicated; never both by reflex.
2. **Record**: open an incident note in `docs/incidents/YYYY-MM-DD-<slug>.md` (what, first seen,
   builds/schema affected, user impact, data at risk: none / counts / case data on the user's Mac).
3. **Communicate**: in-app notices cannot be pushed (no server channel to the app); use the App Store
   release notes of the fix and the support page. Never ask a user to send their ledger.
4. **Fix forward** (§2, §4, §5), re-run the release ritual on the fix, then close the note with the
   cause, the fix commit and the evidence.

## Expedited-review request template
> Kalsmritikosh 1.1.x fixes a defect that [one sentence]. The app keeps every
> case on the Mac (optional AI goes through our relay or the user's own key); the fix touches [subsystem] only. No new entitlements, no new
> data collection (PrivacyInfo unchanged). Please expedite.

## Post-rollback verification
- Re-run the release ritual on the patch: full suite, parity vs the latest
  sealed baseline (FULL-FIELD), grep + architecture guards, Step-5 proof.
