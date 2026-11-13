# Smart map defect log (slices S13–S18)

QA-15: every defect found and fixed while the smart-map M6 work was done, with how it showed, what was changed and the
regression test that now fails if it comes back. Sources: the S13–S18 commit messages (`c15a06e3`, `81caee89`,
`bcf643e9`, `0d9b27a3`, `de7c6c43`, `e63df8f8`, `d2d17eb8`, `5ec23184`, S18) and the completion matrix rows
(`docs/SMART_MAP_COMPLETION_MATRIX.json`). "Recheck" says which wider suites were re-run for the fix. Open items, misses
and paths not observed are listed at the end; they stay visible in the matrix.

Every regression test named here ran for real in the slice that fixed it (console log checked for "hung before").
None of these fixes has been observed in the running app on screen (that needs the GUI walk).

## S13 (`c15a06e3`)

| # | Defect (how it showed) | Fix | Regression test | Recheck |
|---|---|---|---|---|
| D13-1 | Money records placed in a branch did not appear in that branch's frame (the journey's money branch was empty). | The frame projection includes placed money records. | `SmartMapAcceptanceJourneyTests.decisiveJourney` (money branch step) | 244 referencing tests |
| D13-2 | The whole-case HTML export re-read the full package to look for active content (~89 s at the stress size; 2.9 s normal). | The active-content check reads the written sections once. Normal prepare 2,889 → 2,067 ms. | `CaseMapPerfHarnessTests.smoke`, `SmartMapAcceptanceJourneyTests.decisiveJourney` (export step) | perf harness normal + stress |
| D13-3 | A failed scan held by the app could not be admitted to the case, so the case search receipt could not name it (finding, fixed in S14). | See D14-1. | — | — |

## S14 (`81caee89`, `bcf643e9`, `0d9b27a3`, `cfa64732`)

| # | Defect | Fix | Regression test | Recheck |
|---|---|---|---|---|
| D14-1 | A file the app holds but could not read (failed scan, unsupported attachment) was neither offered nor admitted to the workspace and case; the receipt, coverage, map and brief could not name it. | Admitted as NOT READ with its reason; never projected or counted as read. | `SmartMapS14Tests.notReadAdmission`, `SmartMapS14Tests.notReadReasonWording` | 84 referencing suites |
| D14-2 | Suites switched module flags in the shared preference store and restored them while other suites ran: `BaseCaseJourney`/`BaseCaseLapsedBoundary` saw flags flip mid-run (failed beside others, passed alone). | Debug-only per-task `ProductModuleFlags.TestOverride`. | `SmartMapS14bTests.moduleOverrideIsPerTask` | 200 concurrent store flips; base journeys beside other suites |
| D14-3 | The strict findings-approval path wrote approvals and withdrawals without a role check. | Role check on both paths; independent-review policy refuses the builder. | `SmartMapS14bTests.strictPathChecksRole`, `SmartMapS14bTests.independentReviewRequiredForFindings` | ~310 referencing suites |
| D14-4 | A bank statement with an impossible date (2026-13-01) was refused only after the rows before it were saved. | Every row is checked before anything is written. | `SmartMapS14cTests.statementWithImpossibleDayRefusedWhole` | 69 referencing suites |
| D14-5 | The new production clean-up could delete a folder that existed before the run. | Only what the run created is removed. | `SmartMapS14cTests.productionStoppedPartWayLeavesNothingHalfWritten` | same |
| D14-6 | Spreadsheet formula injection in map and case-file CSVs (`=`, `+`, `-`, `@`, tab, CR, full-width look-alikes). | `CSVFormulaGuard` on every CSV writer. | `SmartMapS14Tests.csvFormulaInjection`, `SmartMapS14bTests.remainingCSVWritersGuarded` | — |
| D14-7 | The HelpRegistry control-name union timed out the CI type checker (every test job failed to compile). | Split into smaller expressions. | `HelpRegistryTests` (compiles on CI) | HelpRegistry 13/13 |

## S15 (`de7c6c43`, `e63df8f8`)

| # | Defect | Fix | Regression test | Recheck |
|---|---|---|---|---|
| D15-1 | Automation checked authority before the engine ran and applied the result without re-checking: a case closed, an input made stale or the policy switched to manual during the run still took the result. | Re-checked inside the applying write; the engine's action is archived (`unapplied_task_id`). | `SmartMapS15Tests.applyTimeRecheck`, `SmartMapS15Tests.erasedDuringRun` | 62 referencing suites |
| D15-2 | Routing and assignment changed a task's owner with no before/after copy. | Before/after revisions in the same unit. | `SmartMapS15Tests.assignmentRevisions` | same |
| D15-3 | The map export printed every event date as a GMT day: an IST day became the previous day; a month-precision date got an invented day. | Each date at its own precision, in its own zone. | `SmartMapS15Tests.explicitUnknownsAcrossSerialization` | same |
| D15-4 | Recorded map states dropped date precision and money amounts. | Kept in the checkpoint payload. | `SmartMapS15Tests.explicitUnknownsAcrossSerialization` | same |
| D15-5 | The DATA-10 test itself built an IST date without a zone; on UTC CI runners the March month became 28 February. | Entries carry `timeZoneID`. | `SmartMapS15Tests.explicitUnknownsAcrossSerialization` (CI) | SmartMapS15 11/11 |

## S16 (`d2d17eb8`)

| # | Defect | Fix | Regression test |
|---|---|---|---|
| D16-1 | A document marked privileged on its file or record, or coded privileged in review, after an output was prepared was still released (only version labels were read); a citation naming only the record was not checked. | `CaseProtectionNow` reads the whole lineage at release. | `SmartMapS16Tests.protectionChangeAfterPrepareStopsRelease` |
| D16-2 | A Data Lab dataset made from a case (and its rows) survived the case erasure. | Erased by origin, counted back, inventoried. | `SmartMapS16Tests.erasureReachesOriginTablesAndCountsBack` |
| D16-3 | The erasure/inventory filter `LIKE '%_fts%'` was unescaped: any table with "fts" after its first letter escaped erasure. | Escaped. | `SmartMapS16Tests.erasureReachesOriginTablesAndCountsBack` |
| D16-4 | Opened plaintext originals and the DEVONthink hand-off file were never removed. | Launch sweep of the app's own temporary plaintext. | `SmartMapS16Tests.temporarySweep` |
| D16-5 | A ledger move copied opened plaintext copies of sealed originals. | Excluded from moves. | `SmartMapS16Tests.storageInventory` |
| D16-6 | Crash reports kept exception messages, arguments and home paths. | Sanitised before save and send. | `SmartMapS16Tests.diagnosticsCarryNoContent` |
| D16-7 | File names from case text could start with a dot or hold control/bidi characters. | One safe component. | `SmartMapS16Tests.fuzzFileNames` |
| D16-8 | File names were logged as public text. | Private; guarded by a source scan. | `SmartMapS16Tests.noPublicFileNamesInLogs` |

Recheck: 101 referencing suites in four batches.

## S17 (`5ec23184`)

| # | Defect | Fix | Regression test |
|---|---|---|---|
| D17-1 | Ingestion ran on the main thread (undeclared types are main-actor in the app target): a 120-page PDF held it 1.8 s; a 200-file intake took 538 s. | Parsers, loaders and pipeline helpers `nonisolated`; 57 s. | `SmartMapS17Tests.parseRunsOffTheMainThread`, `SmartMapS17Tests.navigationAnswersDuringIntake` |
| D17-2 | Caused by D17-1: off the main thread a URL's cached size/date is not refreshed, so a rewritten file was refused as "changed during capture". | Fresh resource values in byte capture and SQLite acquisition. | `CanonicalSourceIntakeRepositoryTests.changedBytesNewVersion`, `DurableReadinessIngestTests.oldVersionCoverageUnchanged` |
| D17-3 | A report's rule reader and a point's source-sentence check stopped silently at 20,000 passages. | Read every passage; caps inventoried. | `SmartMapS17Tests.longReportReadInFull`, `SmartMapS17Tests.truncationPointsAreInventoried` |

Recheck: 176 referencing suites (1,327 tests).

## S18 (this slice)

| # | Defect (how it showed) | Fix | Regression test |
|---|---|---|---|
| D18-1 | A spreadsheet citation's "cited place not shown" note named the wrong cell: locator rows are 0-based (CSV, XLSX, ODS, XLS readers) but the note printed them as A1 rows, so row index 4 column B read "cell B4" for spreadsheet cell B5. | Rows printed +1; a spreadsheet the viewer reads now opens AT the cell instead (no note). | `SmartMapS14Tests.unsupportedLocatorLabelled` (now "cell B5", "cell C10"), `SmartMapS18Tests.sheetCellAndSlidePlaces` |
| D18-2 | The full erase ("Delete all my data") listed its tables with the same unescaped `NOT LIKE '%_fts%'` as D16-3: any table holding "fts" after its first letter (a "…drafts…" or "…shifts…" store) was neither emptied nor counted back. | `AppState.fullEraseTablesSQL`, escaped. | `SmartMapS18Tests.fullEraseReach` |
| D18-3 | A full erase left this app's Spotlight items, and a configured sync folder would refill the emptied ledger from the other devices' changes at the next sync. | The full erase removes the app's Spotlight items, stops syncing on this Mac and names the folder as kept (its batches are sealed and signed per device). | `SmartMapS18Tests.fullEraseReach`, `DiagnosticEndToEndTests.eraseIsVerified` |
| D18-4 | Case and person erasure left the erased rows' values in the sync side tables (`sync_field_clocks.synced_value`, `sync_conflicts`, `sync_dirty`) and a person's name in waiting incoming changes (`sync_pending.op_json`). | `CaseEraser.scrubSyncSideTables` inside the erasure savepoint: the clock stays (an older copy still loses), the value goes. | `SmartMapS18Tests.syncSideTablesScrubbed` |
| D18-5 | Rows an erasure removed stayed in this Mac's earlier batches in the sync folder, so a device that had not yet read them received the erased text. | `SyncEngine.redactErasedFromOwnBatches`: own batches re-sealed and re-signed without them (`SyncStore.replace`). | `SmartMapS18Tests.ownBatchesRedacted` |
| D18-6 | The issue-chronology and case-slice save panels checked protected names before the panel and wrote without a second check: a source protected while the panel was open still left in the file. | `ProtectedExport.writeRechecked` reads the register again at write (replaced; a signed slice refused; unreadable register → nothing written). | `SmartMapS18Tests.secondCheckAtWrite` |
| D18-7 | The test host IS the app (same sandbox container): notes, capture intake, diagnostics, import receipts, AI transcriptions and the diagnostic reports (`Documents/EvalBaselines`, e.g. `fixed-point-check.md` written by `DiagnosticEndToEndTests`) resolved to the owner's real folders. | `TestHost.applicationSupport()` / `TestHost.documentsDirectory(create:)` give the test host its own folder; a guard scans every product file using those folders. | `SmartMapS18Tests.testHostStoresAreItsOwn` |
| D18-8 | The result-bundle check counted SKIPPED tests toward the executed floor (an all-skipped run could pass) and accepted a bundle older than the commit it vouched for; the group check counted a suite whose tests were all skipped as "ran". | Floor counts passed + failed + expected failures; a bundle that started before HEAD's commit time is refused (`XCRESULT_ALLOW_STALE=1` to skip only that); skipped test cases do not mark a suite as run. | `SmartMapS18Tests.resultBundleChecksAreHonest`; run by hand on a real bundle: fresh → OK, `XCRESULT_NOT_BEFORE=now` → "stale result bundle", exit 4 |

Recheck (S18): see the S18 commit message (every suite referencing a changed type, four batches).

## Still open, missed or not observed (kept visible in the matrix)

- PERF-06: one 1.63 s main-thread hold during the S17 intake was not reproduced or traced (S18 did not trace it either).
- `DiagnosticEndToEndTests.fixedPointCheckRuns` fails when run beside other suites (a background writer adds rows to
  `claim_projection_progress` or `embedding_cache` between its runs) and passes alone (S18: 2 batch failures, 2 solo passes).
  Not fixed; the check's isolation from other suites' background work is the suspected cause.
- `ManagedFileProtectionTests.sealedCache` fails while the screen is locked (NSFileProtectionComplete); code untouched.
- Owner-archive suites (`RealArchivePipelineTests`, `FactCorrectnessTests`, `MboxAccountingTests`) cannot run without the owner's archive.
- No fix above has been observed in the running app (GUI walk), and none has a fresh CI run until the owner pushes.
