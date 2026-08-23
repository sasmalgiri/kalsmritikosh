# Constitutional Governance — how changes are handled (2026-08-23)

Three layers of "law" govern the app; each has its own change process, and each
change is versioned, prospective, and provable.

## 1. Architecture invariants (the unamendable core)
One ledger, capability discipline, privacy enforced by PrivacyGate, evidence
gate, formats die at ingestion. Changed only by the owner editing CLAUDE.md;
enforced every session by the grep guard + build ritual + tests. These do not
version — they are the identity of the app.

## 2. SOPs / disciplines (the Sūtras)
- Every discipline is a machine-readable `Sutra` with `id`, `version`, phases,
  obligations, reserved human decisions, prohibited conclusions.
- **Change process:** `sutra.amended(on:summary:)` is the ONLY sanctioned path —
  it bumps the version, appends a `SutraAmendment` (version, date, why) to the
  history, and never rewrites the past. The original value is untouched.
- **Compliance proof:** `SutraConformance.verify(run:against:)` checks a run's
  recorded facts against its constitution; the certificate now NAMES the exact
  constitution and version (`Title vN · sutra.id`), so a report sealed under v1
  remains provably a v1 report after the SOP moves to v2.
- Old records decode unchanged (`amendments` optional) — history is never lost
  to a schema change.

## 3. Policies / legal notices
- `LegalNotice.termsVersion` (now 1.2, dated) shown in Settings.
- `changesStatement`: material changes are versioned, announced in-app, take
  effect prospectively only, and privacy commitments are never reduced
  retroactively for already-ingested data.
- `subscriptionStatement`: written to survive the free→subscription transition
  unchanged — Apple handles all billing, prices change prospectively with
  notice, and a lapsed subscription never locks a user out of their own data.

Verified: build green; SutraGovernanceTests (amend/version/citation/legacy-decode)
+ all Sūtra suites, 24/24.
