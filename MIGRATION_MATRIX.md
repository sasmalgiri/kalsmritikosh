# MIGRATION_MATRIX

**Status: CURRENT.** MIG-001A (2026-07-25). Inventory of the representative schema-migration
fixtures and the invariants each proves. Authority: `WHOLE_PROJECT_COMPLETION_PROGRAM.md` Stage 1.

Schema head is **v67** (`SchemaMigrations.latestVersion`); v67 adds nullable `scope_kind` /
`scope_id` to `claims`. Migrations are append-only, each applied inside a per-version SAVEPOINT
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

## Deferred to MIG-001B (documented, NOT claimed complete here)

low-disk / write-failure; failure before transaction; failure during DDL; failure during
backfill; failure before the version stamp; failure after writes but before commit; malformed
partial schemas; migration of a real archived user database; hash comparison of the original vs
migrated archive copy (on a disposable copy, original retained).
