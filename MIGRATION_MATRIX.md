# MIGRATION_MATRIX

**Status: CURRENT.** MIG-001A (2026-07-25). Inventory of the representative schema-migration
fixtures and the invariants each proves. Authority: `WHOLE_PROJECT_COMPLETION_PROGRAM.md` Stage 1.

Schema head is **v68** (`SchemaMigrations.latestVersion`); v67 added nullable `scope_kind` /
`scope_id` to `claims`; **v68 (OPS-001)** adds the professional Issue Engine tables
(`professional_issues`, `professional_issue_links`, `professional_issue_reviews`). Every fixture
row's "Expected end" means the CURRENT latest (now 68). Migrations are append-only, each applied inside a per-version SAVEPOINT
(`applyOne`), with a stale-`user_version` self-heal on the full-migrate path.

## How the fixtures are built (no committed binaries)

Synthetic historical databases are **reproduced at test time** by replaying the committed
migration list to a target version: `SchemaMigrations.migrate(db, through: N)`
(`MigrationFixtureBuilder.database(atVersion:)`). Seeding is **column-aware** — a row is written
only when its table and every target column already exist at that version
(`MigrationFixtureBuilder.seedPreservationRows`), so the one seed set degrades correctly on old
schemas without a hand-maintained per-version matrix. Committed DB binaries are reserved for a
sanitized real archive (MIG-001B) and anything not reproducible from history.

## Representative milestones (material schema boundaries)

| Fixture ID | Start | Constructed by | Seeded object types (era-limited) | Expected end | Preservation assertions | Integrity | Test | State | Limitations |
|---|---:|---|---|---:|---|---|---|---|---|
| FRESH-0 | 0 | fresh DB, no migrate | — | 67 | list gap-free; user_version 67; v67 markers | integrity_check ok; fk_check 0 | `MigrationMatrixTests.freshDatabaseReachesLatest` | Unit verified | — |
| MS-1 | 1 | migrate through 1 | files (+KO/workspace if present) | 67 | seeded rows survive; reopen survives | ok / 0 | `milestoneMigratesToLatest[1]` | Unit verified | few tables exist at v1 |
| MS-36 | 36 | migrate through 36 | pre-evidence-ledger tables | 67 | seeded rows survive; reopen | ok / 0 | `milestoneMigratesToLatest[36]` | Unit verified | pre structural evidence ledger |
| MS-54 | 54 | migrate through 54 | files, KO, workspaces, workspace_sources | 67 | seeded rows survive; reopen | ok / 0 | `milestoneMigratesToLatest[54]` | Unit verified | before Workbench/durable-ingest tables |
| MS-61 | 61 | migrate through 61 | files, KO, workspaces, workspace_sources | 67 | seeded rows survive; reopen | ok / 0 | `milestoneMigratesToLatest[61]` | Unit verified | before evidence dimensions |
| MS-62 | 62 | migrate through 62 | files, KO, workspaces, workspace_sources | 67 | seeded rows survive; reopen | ok / 0 | `milestoneMigratesToLatest[62]` | Unit verified | before canonical Claim engine |
| MS-63 | 63 | migrate through 63 | + claims, claim_evidence_ref (no ordinal), reviews, usage | 67 | claim/evidence/review/usage survive the v64 table rebuild; reopen | ok / 0 | `milestoneMigratesToLatest[63]` | Unit verified | ordinal assigned by v64 |
| MS-64 | 64 | migrate through 64 | + claim_evidence_ref with ordinal | 67 | seeded rows survive; reopen | ok / 0 | `milestoneMigratesToLatest[64]` | Unit verified | before durable projection |
| MS-65 | 65 | migrate through 65 | + claim_projection_progress | 67 | seeded rows survive; reopen | ok / 0 | `milestoneMigratesToLatest[65]` | Unit verified | before block→KO ownership |
| MS-66 | 66 | migrate through 66 | claims era, no scope columns | 67 | claim/evidence/review/usage survive; scope added NULL | ok / 0 | `milestoneMigratesToLatest[66]` + `v66ToV67AddsNullScope` | Unit verified | — |
| MS-67 | 67 | migrate through 67 (reopened) | full claims-era set | 67 | idempotent reopen; rows survive | ok / 0 | `milestoneMigratesToLatest[67]` | Unit verified | — |
| REPEAT-67 | 67 | reopen+migrate ×3 | full set | 67 | no dup / no regression / no loss | ok / 0 | `repeatedMigrationIsStable` | Unit verified | — |
| STALE-67 | 67 (counter→2) | full schema, lowered user_version | full set | 67 | self-heals to 67; rows retained; no destructive replay | markers present | `staleUserVersionSelfHeals` | Unit verified | — |
| REAL-ARCHIVE | real | sanitized owner archive copy | real corpus | 67 | count + reopenability preserved; original untouched | ok / 0 | (MIG-001B) | Planned | deferred to MIG-001B |

## Existing tests referenced (NOT duplicated here)

- `EvidenceDimensionMigrationTests` — genuine **v61→v62** migration, preservation of legacy rows +
  evidence, interrupted v62 SAVEPOINT rollback, and successful retry after the injected failure.
  MIG-001A adds generalized milestone coverage and does not re-implement these.

## MIG-001B — fault atomicity (delivered)

Failure injection uses a test-only hook threaded explicitly into
`SchemaMigrations.migrate(_:through:fault:)` / `applyOne(_:version:sql:fault:)` (production passes
`nil`; no shipping behaviour change). Genuine SQLite failures (missing-table query, `SQLITE_FULL`)
are used where possible instead of injected throws.

| Case | Scenario | Invariant proven | Test |
|---|---|---|---|
| A | fault before SAVEPOINT | no schema/data change; version unchanged; second launch recovers | `faultAtBoundaryRollsBack[.beforeSavepoint]` |
| B | fault after SAVEPOINT | rollback; version unchanged; recover | `[.afterSavepoint]` |
| E | fault after SQL, before version stamp | DDL rolled back; version unchanged; recover | `[.afterSQLBeforeVersionStamp]` |
| F | fault after version stamp, before RELEASE | **version stamp AND DDL roll back together** (they share the SAVEPOINT — confirmed: SQLite rolls `PRAGMA user_version` back); recover | `[.afterVersionStampBeforeRelease]` |
| C | genuine failure during DDL (valid DDL + trailing invalid statement) | earlier table+index rolled back; version unchanged; retry succeeds | `ddlFailureRollsBack` |
| D | genuine failure during backfill (UPDATE + trailing invalid statement) | updated values roll back to originals; no partial backfill; retry applies once | `backfillFailureRollsBack` |
| WRITE | genuine `SQLITE_FULL` via `max_page_count` (DELETE journal) | no partial schema; old version + rows retained; integrity ok; retry after lifting the cap succeeds | `writeSpaceFailureRollsBack` |

## MIG-001B — malformed partial schemas (fail-closed)

Expected behaviour: never falsely stamp latest; never delete user data; fail with an explicit
error; retain a diagnosable state.

| Case | Malformation | Behaviour | Test |
|---|---|---|---|
| MP1 | partial v67 (one scope column dropped) | migrate fails closed (duplicate-column on v67 re-run); not stamped 67; columns/rows retained | `partialV67FailsClosed` |
| MP3 | required v66 table (`evidence_block_objects`) missing, counter behind | self-heal correctly returns false (does NOT stamp 67); pending v67 fails closed; rows retained | `selfHealRejectsMissingMarker` |
| MP2 | `user_version` AHEAD of the physical schema | **KNOWN LIMITATION:** migrate() trusts the counter → no-op; it never corrupts or deletes data, but does NOT detect/repair the mismatch. Detection is a documented follow-up (a startup schema-shape verifier). Test pins the safe part. | `versionAheadOfSchemaIsNonDestructive` |

## MIG-001B — real-archive methodology (delivered synthetic; sanitized real archive Planned)

Correct hash semantics (a real migration REWRITES the file, so original ≠ migrated):
- original hash before == after (original never touched);
- working copy == original before migration;
- working copy ≠ original after migration;
plus count/stable-id preservation, `integrity_check ok`, `foreign_key_check` empty, no-op repeat,
fresh-instance reopen. Proven on a genuine v66→v67 on-disk archive by
`RealArchiveMigrationTests.archiveMigrationPreservesAndRehashes`.

A sanitized REAL owner archive is **not committed** (no private data). Running this methodology
against such a fixture is an owner step (`ci/migrations/verify-real-archive.sh`, which SKIPS when
no fixture is present) and is marked **Planned / Real-data verified only after that run**.

## MIG-001C — external-archive acceptance capability (delivered)

The repository can now FULLY validate an owner-supplied sanitized archive (previously the script
only copied/hashed and the tests only used synthetic archives):

- `OwnerArchiveMigrationAcceptanceTests.ownerArchiveMigrationAcceptance` — env-gated
  (`KALS_OWNER_ARCHIVE` / `_MANIFEST` / `_REPORT`; SKIPPED in normal/CI runs — a skip is never
  verification). Runs the REAL `SchemaMigrations.migrate` on the working copy and verifies:
  manifest hash pins the exact bytes; start/end versions; `integrity_check ok` +
  `foreign_key_check` empty; pre==post counts for all known tables + manifest expectedCounts;
  stable-ID samples survive; Claim evidence/reviews/usage counts; workspace membership; at least
  one exact reopening (source version + content hash via EvidenceStore, or file); second
  migration no-op; fresh-instance reopen; and writes a non-sensitive acceptance report
  (counts/versions/hashes only). The after-hash is checkpointed so it reflects the migrated file.
- `generateSyntheticArchive` — env-gated self-test generator producing an owner-like v66 archive
  + a schema-conformant manifest (documents the exact format an owner must supply).
- `ci/migrations/real-archive-manifest.schema.json` — the manifest contract
  (containsPersonalData MUST be false; SHA-256 pin; expectedCounts; representative anchor).
- `ci/migrations/verify-real-archive.sh` — validate manifest → preserve original hash →
  disposable working copy (+wal/shm) → run the acceptance test via `TEST_RUNNER_` env forwarding
  (single worker) → prove the .xcresult EXECUTED and passed (≥1 passed, 0 failed — a skip fails
  the script) → original hash unchanged → retain the acceptance report.

**End-to-end self-test PASSED** (2026-07-25) against a generated synthetic owner-like archive:
v66→v67, counts + 5 stable IDs preserved, representative source version reopened with its exact
content hash, second-migration no-op, fresh reopen, original untouched; report at
`ci/migrations/fixtures/synthetic-selftest-001-acceptance-report.json`. The REAL owner archive
run remains an owner step (Planned).

## Documented gaps / follow-ups (honest)

- **Ahead-of-schema `user_version`** is not auto-detected by `migrate()` (MP2). Candidate: a
  startup schema-shape verifier that compares `user_version` against the physical shape and
  fails closed on mismatch.
- IF-NOT-EXISTS masking of a same-named conflicting table on a far-behind counter is not
  exercised here (re-running early non-idempotent migrations like v64 on a v67 DB is itself
  unsafe); the realistic malformed cases above use a counter one step behind so only v67 re-runs.
