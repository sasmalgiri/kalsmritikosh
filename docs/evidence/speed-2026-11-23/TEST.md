# Speed program test phase (PERF-21 … PERF-33), 2026-11-23

Scope: the commits after 139be177 (PERF-21 … PERF-32), plus the after-benchmark for PERF-33. There was no network and no
live AI. Providers and the network helper were scripted, and every ledger was throwaway. The owner's ledger was never
opened. All tests ran through the Xcode runner (`RunSomeTests`, plan `Kalsmritikosh`). Every console log was checked:
none had "hung before connection".

## Existing suites

The suites were chosen like this:
- every test file that names a type changed since 139be177 (types named in 12 or fewer test files);
- plus the requested suites: SmartMapS16 (log privacy), SmartMapS17 (truncation/LIMIT inventory), RawSavepointRatchet, the erasure suites, Data Lab, backup/restore, the network helper and online provider, and case reading.

| Run | Suites | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|---|
| New suites (first run) | 12 | 24 | 22 | 2 | 0 |
| S16/S17/S18 + ingest/vector suites | 13 | 109 | 104 | 2 | 3 |
| Parsers, retrieval gold, diagnostics, team, topics | 57 | 349 | 348 | 1 | 0 |
| Diagnostics rerun, StoreKit, parsers, online tools, planning | 34 | 337 | 334 | 3 | 0 |
| Case reading, team folder, backup expansion, sync, unified path | 40 | 330 | 329 (+1 expected failure) | 0 | 0 |
| Smart map S5–S15, release sims, scan rescue, SQLite, RawSavepointRatchet, real archive | 50 | 333 | 323 | 10 | 0 |
| Ledger drain, jobs, investigation, legal packs, export, email, containers, complete backup | 57 | 503 | 503 | 0 | 0 |
| Claims, cited sources, case search/output/erasure/drafts, contradictions, screening, AI, MigrationMatrix, backup, Data Lab, credits | 40 | 442 | 440 | 0 | 2 |
| Reruns (ProgressiveIngest, S18 fuzz) and the final new-suite run | 2 + 14 | 17 + 26 | 17 + 25 | 0 | 1 |

About 285 suites and 2,032 distinct tests ran.

### Failures and their outcomes

| Test | Outcome |
|---|---|
| `DiagnosticEndToEndTests/eraseFailsClosedOnHolds` | **Code defect (PERF-32), fixed.** See below. |
| `SmartMapS17Tests/truncationPointsAreInventoried` | **Intentional change.** The one-pass SubjectSpine reads chunks in keyset pages (`LIMIT 2000`, and the walk continues). An inventory entry was added: "Updated for PERF-27 (owner 2026-11-23)". |
| `SpeedStatementCacheTests` (first run) | The test itself was wrong: a 1,500-placeholder IN list is under 4 KB. It now uses 2,500. |
| `SpeedVectorTests/hnswResume`, `ManagedFileProtectionTests/sealedCache` | **Environment.** The Mac was locked, and NSFileProtectionComplete refuses the write (Cocoa 513). hnswResume is now `.enabled(if:)` a protected write works, so it is skipped here and runs on CI or on an unlocked Mac. |
| `SmartMapS18Tests/fuzzBinaryReaders` | Timing bound (2 s / 5 s) under load averages of 30–110. It passed alone. |
| `ProgressiveIngestIntegrationTests/supervisedDrainerCompletesWork` | 10 s budget under heavy load. It passed alone. |
| `RealArchivePipelineTests` ×6, `MboxAccountingTests` ×2, `FactCorrectnessTests` | **Environment.** `~/Downloads/Mail` now holds only `Fixtures*` folders, and the owner's real archive is gone. These were not run here. |
| `PersonaJobCoverageMeasuredTests/measured` | **Environment.** The sandboxed test host cannot write the repo's CSV. |
| `PurchaseStoreKitTests/billingRetryWithGraceKeepsAccessUntilGraceEnds` | StoreKit test-session timing. Not in the speed program's files. |

No privacy, consent or erasure assertion was weakened.

## New suite: `KalsmritikoshTests/SpeedProgramTests.swift`

It is Swift Testing with no long `.timeLimit`. It has 26 tests: 25 run here and 1 is skipped while the Mac is locked.

| Suite | PERF row | What it proves |
|---|---|---|
| SpeedAdaptiveConcurrencyTests (5) | 22 | The limit rises by 1 per window while throughput rises, and does not rise when throughput falls. It halves on an overload, down to the floor, and grows again afterwards. Retry-After is honoured. The limit never exceeds the WorkerBudget cap (aiCap ≤ 8). Errors are classified correctly. A global overload halves a live limiter. |
| SpeedWorkStealingTests (3) | 25/26 | Stealing takes the back half of the largest segment. Every index is claimed exactly once under contention. perform/map/mapSync keep index order and stop on the first error. |
| SpeedStreamingCopyTests (2) | 25 | A one-pass digest equals the file's digest, and the copy is byte-identical. The resume log reuses files, re-copies changed files and survives a restart. |
| SpeedKeysetPagerTests (2) | 23 | Events by (date, id) and object ids by (created_at, id) come back in the OFFSET order. The data has many equal dates and lower-case stored ids. |
| SpeedStatementCacheTests (1) | 32 | Each statement is prepared once and reused. Long SQL is not kept. Close finalizes everything. A dropped table still throws. |
| SpeedCasePartTests (3) | 21/22 | On retry, only the failed part is re-sent. Case and person erasure clear kept replies. A 6-part read makes 1 helper launch and 1 connection. |
| SpeedMboxTests (1) | 26 | 700 messages across 3 parallel windows give exactly the serial reference records. |
| SpeedZIPTests (2) | 24/30 | Same-named members stay distinct, each hashed while extracted. The streamed writer's output equals the in-memory writer's. zlib crc32 is correct. |
| SpeedVectorTests (3) | 28 | Parallel k-means assignment equals serial. An IVF rebuild indexes all 1,300 vectors. HNSW checkpoint resume is skipped while the Mac is locked. |
| SpeedDataLabTests (1) | 31 | The projection and cell map are built once per change. Values equal the scan. A 100,000-cell redraw is fast. |
| SpeedContradictionTests (1) | 29 | Findings with 8 workers equal findings with 1. |
| SpeedRetrieverTests (1) | 29 | Layers run in the fixed order, and the merged result is identical on every run. |

## Defects found and fixed (commit ccf63e28)

| Where | Failure | Cause | Fix |
|---|---|---|---|
| `Database.runBinding` (PERF-32 statement cache) | A full erase went ahead when the legal-hold table could not be read. The test reads a dropped `legal_hold_items` table; the hold check came back empty, so it looked like "no hold". | A cached statement re-prepares itself at its first step. When that fails, the read path only logs the error and returns rows-so-far (none). Before the cache, the same SQL failed at prepare and threw. | When a cached statement's first step fails with SQLITE_ERROR or SQLITE_SCHEMA, the statement is finalized and the SQL prepared fresh. A vanished table therefore throws, as it did before the cache. Tested by `SpeedStatementCacheTests` and `eraseFailsClosedOnHolds`. |
| `KeysetCursor` (PERF-23) | When ids are stored in lower case, rows within one sort value came back again. If a whole page shared one date, the walk never ended. | The tiebreak re-bound `id.uuidString`, which is upper case. | The cursor now binds the id exactly as stored. Tested by `SpeedKeysetPagerTests/eventsKeyset`. |
| `WorkbenchScenarioProjection.baseValue` (PERF-31) | A Data Lab redraw stayed O(cells²) even with the projection memoised. The baseline measured 6.75 ms per cell. | `projectedValue` scanned every base cell for every read. | Reads now use a lazily built "row\|field" index, where the first cell wins (the same result as the scan). The memo moved into `DataLabMemo`, which has build counters. Per-cell time is now 0.017 ms. |
| `AdaptiveConcurrency` start (PERF-22 tuning) | A 6-part read never had more than 3 requests in flight, against a cap of 8. | The limit started at 2. | The start is now 4 (`defaultStart`). One bench re-run confirmed it. |

Three DEBUG-only test seams were added; the app is unchanged:
- `WorkStealingQueue.TestOverride.cpuWidth`;
- `HNSWVectorIndex.debugStopBuild(afterCheckpoints:)` and `lastResumedVectors`;
- `Database.cachedStatementCount`.

## After-benchmark

See `after.md` and `after.json` for the baseline-vs-after table and its limits. In short, for run B:

| Phase | Baseline | After |
|---|---|---|
| import | 295.7 s | 109.2 s |
| HNSW + IVF indexes | 76.0 s | 1.5 s |
| contradictions | 27.6 s | 6.7 s |
| retrieval | 231 s | 131 s |
| Data Lab redraw | 674 s | 1.75 s |
| AI read | 3.87 s, 12 launches and 12 connections | 2.76 s, 1 launch and 1 connection |

Run B's load was lighter than the baseline's, and run A (heavier load) is shown beside it. Run A's IVF rebuild indexed 0 vectors; this was not reproduced, and it is tracked on PERF-28. The generated corpus was removed by the run, and the trigger file was deleted.

## Tracker

These rows are AUTOMATED_VERIFIED: PERF-21, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32 and 33.

PERF-28 stays IMPLEMENTED for two reasons:
- the HNSW resume test has not run, because the Mac was locked;
- the IVF 0-vector run is unexplained.

Each row keeps its remaining limits: untested screens on PERF-31, the stand-in helper link on PERF-21, and id-only pagers on PERF-23.
