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

## GUI walk 2026-11-13 on c179485f (`docs/evidence/gui-walk-2026-11-13/README.md`)

Found on screen by the agent walk; fixed in the "GUI walk defects D1-D5" commit. Every fix is checked by unit and
off-screen layout tests only. **None has been confirmed on screen yet**: no row moves to UI_VERIFIED until a walk sees it.

| # | Defect (how it showed) | Cause | Fix | Regression test |
|---|---|---|---|---|
| GW-D1 (high) | File ▸ New Window re-ran the app's boot: under `--acceptance-case` the ledger was deleted and re-created, so the open case read "not in the ledger" and Cases said "No cases yet". The first launch had opened no window. | The boot `.task` sits on the window content (one run per window) and `AppState.boot` had no once-only guard; the fixture wiped its ledger before booting. | `AppState.boot` is idempotent per AppState (a concurrent call awaits the running boot; a call on an open ledger returns; a boot stopped for a recovery key, failed or shut down may run again). The launch sequence moved into `KalsmritikoshApp.launch`, run through `AppState.startOnce` (a later window attaches). The fixture never wipes an open ledger. `.defaultLaunchBehavior(.presented)` presents the window even when restored state holds none. | `GUIWalkBootOnceTests` (`bootTwiceRunsOnce`, `concurrentBootRunsOnce`, `startOnceRunsStartupOnce`, `acceptanceFixtureNotRecreated`) |
| GW-D2 (high) | With Case map (preview) on, the content was laid out ~2,800 pt tall in an 845-pt window (header, strip, toolbar, sidebar, inspector off-screen); the Evidence screen likewise. | The split view sizes its detail with narrow probes; the map workspace has no scroll view of its own, so its wrapping header text reported a tall size (measured: 572×1069 pt at a 210-pt probe). | `ViewportPinned` (the Ask fix as one helper): the map workspace (`CaseMapWorkspaceView.pinned`, clipped), the Cases screen and the Evidence area are hard-framed to the real viewport. | `GUIWalkLayoutTests` (`caseMapFitsWindow`, `caseColumnFits`, `evidenceFitsWindow`: NSHostingController probes 1200×845, 850, 210, 0 and an off-screen NSHostingView at 1200×845) |
| GW-D3 (medium) | The intake receipt said "not reached 10" when nothing was missed. | The folder was registered twice (the second boot re-registered it; `BookmarkStore.register` never de-duplicated), so the run planned 20 for 10 selected. | `register` keeps one row per standardized path; twins left by earlier builds merge on load (bookmark rows only; the ledger keys files by path, nothing is deleted); `ingestAllRoots` / `autoReingestEmptyRoots` read each folder once (twins and nested folders dropped), so the plan counts each file once. | `GUIWalkFolderTests` (`registerTwiceKeepsOneRow`, `mergeKeepsFirstRow`, `distinctFoldersCountOnce`, `receiptWithoutPhantomNotReached`) |
| GW-D4 (low) | A contradiction's source highlight ended mid-word ("Invoice INV-2041 Dal"). | `CitedPassageLocator.locate` fell back to a 20-character prefix and marked exactly that. | The match continues while quote and source agree, then widens to whole words (start and end). | `GUIWalkHighlightTests` (`statementHighlightsWholeWords`, `widenedToWords`) |
| GW-D5 (low) | One unreadable scan read "stage: parser — loaderFailure …" on Evidence and "reading failed (metadataExtraction failed)" in Add sources. | Two sources of words: the raw attempt record and an internal readiness step name. | `UnreadSourceReason.failureReason` / `failureDetail(dimension:)`: both screens and the intake list say "reading failed (no text could be read from it)"; the technical stage and detail are a tooltip. | `GUIWalkUnreadReasonTests` (`sameReasonBothScreens`, `otherFailures`) |
| GW-O1 | The sidebar showed "93 new files added" with 9 documents in the ledger. | It counted every FSEvents notification (create/modify/rename of the re-created fixture files, twice for the twin root). | It counts documents the watcher took in as new (`newLogicalSource`), once per path. | `GUIWalkNewFilesBadgeTests.newFilesCountedOnce` |

Also changed: `SmartMapS18Tests.testHostStoresAreItsOwn` accepts `AcceptanceCaseGUIFixture.boot(` (it opens only its
temporary ledger, and nothing when one is open). Recheck: see the commit message.

## Deep dive 2026-11-14 batch 1 (startup, concurrency, isolation)

From a read-only review; each item was confirmed in the code before it was changed. Tests in
`KalsmritikoshTests/DeepDiveBatch1Tests.swift`. Tests 1, 5 and 6 were also run with the fix taken out and failed (5 of 5).

| # | Defect (reproduction) | Fix | Regression test |
|---|---|---|---|
| DD1-1 (CI root cause) | `CapabilityRegistry.register` ran `PerformanceBenchmark.benchmark`, which called `provider.generate` directly (no resolve, no privacy gate, no availability check). With a cold `benchmarks.json` (first launch, CI's fresh container) the Online provider wrote a "blocked / sources not cleared" outbound row and an Online failure at boot, even in Fully private mode; `SmartMapAcceptanceJourneyTests` then saw `outbound_log` = 1. | Registration no longer generates (ranking uses measurements already cached). `benchmark(_:)` itself never measures a cloud provider, an unavailable one, or anything while Fully private is on. The cache lives in `TestHost.applicationSupport()` (the test host's own folder), and `Routing/PerformanceBenchmark.swift` left the S18 reviewed list. Recording speed from real calls was not added: it would change provider ranking (out of scope). | `registrationGeneratesNothing`, `freshBootRecordsNothing`; `SmartMapS18Tests.testHostStoresAreItsOwn` |
| DD1-2 | `OnlineCloudProvider.generate` / `generateFromDocuments` / `readPageImages` / `transcribeRecording` wrote a "blocked" row (and a failure) before checking that Online was set up at all. | Each route first refuses with `notAvailable` when the provider is not set up, writing nothing; a refused send of a set-up provider is still recorded as blocked. `VerifiedRecordExtractorTests.generalRouteIsADocumentSend` now uses explicit settings. | `notSetUpRecordsNothing`, `setUpStillRecordsBlocked` |
| DD1-3 | Nine tests set `offlineNoLLM` (or the connectivity mode) in the process-wide argument domain / `UserDefaults.standard` and put it back afterwards, undoing each other's switch in parallel runs; `CaseBenchRunner` never put it back. | DEBUG-only task-local `PrivacyGate.TestOverride.offlineNoLLM` and `ConnectivityMode.TestOverride.stored` (the `ProductModuleFlags.TestOverride` pattern); the tests use them; `CaseBenchRunner` restores the argument domain it still sets for module switches; the boot prewarm honours the override. Release reads exactly as before. | `overridesArePerTask`, `convertedSuitesUseOverrides` |
| DD1-4 | `CaseReadBudgetTests` read `OnlineStatus.shared.lastFailureOffers`, which a concurrent failure elsewhere can overwrite. | `OnlineCloudProvider.Seams.status` (default: the shared status); the test reads its own. | `statusSinkIsPerProvider`; `CaseReadBudgetTests.providerUsesPreCheck` |
| DD1-5 | `EvidenceVault.storeStreaming` (an actor, off the main thread since S17) read the source's size and date through cached URL resource values: a rewrite during the copy was not seen and the free-space check used a stale size. | Each read clears a fresh URL copy's cache first (as `SourceByteCapture`). | `vaultSeesRewriteDuringCopy`, `vaultSizesFromFreshValues` |
| DD1-6 | `CaseAIAssist` applied an effect in one savepoint and marked the proposal in another: a recheck failing in between (execute) or a failed decision record (accept) left the effect in the case with the proposal still "proposed" (accepting again would apply it twice). | The two writes go through different services, so one savepoint is not possible without a refactor; the effect is compensated instead — the link or placement withdrawn with the reason, the new action cancelled — and the error rethrown. | `executeCompensatesFailedMark`, `acceptCompensatesFailedDecision` |
| DD1-7 | `OOXMLBlockDelegate`, `OOXMLStructuredDelegate` and `XMLTextCollector` were main-actor by default but created and driven off the main thread by nonisolated parsers. | Marked `nonisolated`; the other two `XMLParserDelegate` types already were. | `xmlDelegatesAreNonisolated` (source check + DOCX and XML parsed in detached tasks) |
| DD1-8 | A boot failing after the ledger opened left `database` set and the ledger open; `startupTask` was never cleared, so no retry was possible and a later boot opened a second Database. A concurrent boot of a different ledger was silently handed the first. | On failure the watcher and question queue stop and the ledger is closed and cleared (with the coordinator); a launch ending `.failed` clears `startupTask`; "Try again" on the failed screen runs the launch again (`retryStartup`); a concurrent boot of another ledger is refused with a log. | `failedBootClosesAndRetries`, `failedLaunchCanBeRetried`, `concurrentBootOfAnotherLedgerIsRefused`; `GUIWalkBootOnceTests` |
| DD1-9 | `DiskSpaceCheck.requireScratch` let parallel parses each see the same free space and together overfill the disk. | A process-wide reservation (`ScratchPool`, a lock): `reserveScratch` checks and reserves together, held for each scratch write by the seven structural parsers, the archive expansion and each container member; `requireScratch` counts reservations in progress. | `scratchReservationsShareTheDisk` |

Not done here: no GUI walk (the "Try again" button is not seen on screen yet); no CI run (not pushed).

## Deep dive 2026-11-14 batch 2 (erasure, restore, sync integrity)

From a read-only review; each item was confirmed in the code before it was changed. Tests in
`KalsmritikoshTests/DeepDiveBatch2Tests.swift` (12 tests). Tests 1, 3, 7, 11 and 12 were also run with the fix taken out
(CaseErasure.swift and SyncEngine.swift at 911c0f0b) and failed (5 of 5); the others need the new code paths to compile,
so their failing state was shown by reading the old code. No schema change (latest stays v191).

| # | Defect (reproduction) | Fix | Regression test |
|---|---|---|---|
| DD2-1 | A person erasure matched the name and every alias longer than one character as a plain substring in every case: an alias "ed", "al" or "ian" matched "created_at", "allegation" or "Brian", so revisions, recorded states, saved views and searches and sync values of unrelated cases were deleted or cleared. | `CaseEraser.names` matches whole words only (no letter just before or after; still case-, diacritic- and width-insensitive). An alias counts from 3 characters; the full name always counts. The full name and the person's case-person ids reach every case; an alias reaches only the person's own cases in the history, map-view and saved-search steps. | `personEraseWholeWordsAndScope` |
| DD2-2 | A complete restore deleted the replaced files before its completion steps (register merge, opening the ledger, relinking sources, pausing outbound work); a failure there said "Your ledger was not changed" while the restored files stayed and the work was half done. | `restorePromoted` keeps the replaced files aside until the completion steps succeed; a failure rolls the files and the register back. If the undo itself fails it is tried again from the journal; anything still not put back is said plainly (`RestoreNotUndone`) and finished at the next launch. | `restoreRollsBackAfterSwap` |
| DD2-3 | A person erasure took only entities merged directly into the person (`merged_into = id`); a chain C → B → A left C (and the erase failed on the reference). | A recursive query follows the chain, bounded at 8 levels as `resolveCanonical`. | `personEraseFollowsMergeChain` |
| DD2-4 | A crash between the ledger commit and the erasure-register write left the erasure off the register for good (a restored older backup would then bring it back). | The plan written before the erase says it goes on the register (with its time); a person erasure now writes a plan too. At the next launch a plan whose erase committed is added to the register; a plan for a person still in the ledger is dropped. | `resumeWritesTheRegister` |
| DD2-5 | The "Before restore" copy of the ledger was not in the list of backups: an erasure receipt did not name it and "Delete backups made before this erasure" left it. | Recorded as kind `beforeRestore`, with a marker inside (time and file sizes); deleted only while the folder still matches its marker. | `beforeRestoreCopiesListed` |
| DD2-6 | With the ledger moved to another disk, the erasure register was written beside the open copy only; opening the other copy later brought erased cases back. | Register entries are written beside the other copy too, and at open the other copy's register is merged in (a union). Both copies' backup lists are read for the receipt and the deletion. The receipt names the other copy. | `otherLedgerCopyFollowsErasures` |
| DD2-7 | Sync redaction moved `erasure_redacted_through` past a batch it could not read, so that batch was never redacted. | The cursor stays where it was while any batch is unreadable; the next sync redacts again (redacting twice changes nothing). | `unreadableBatchRetried` |
| DD2-8 | The register pass at open stopped at the first entry that failed. | Each entry is caught, logged and reported; the rest are still erased again. | `registerPassContinuesPastAFailure` |
| DD2-9 | At open, the resume step ran before the register pass and dropped an unfinished plan's vault list when a restored backup had brought the case back. | The register pass runs first; a re-erasure joins the earlier plan's vault list. | `oldPlanVaultJoined` |
| DD2-10 | A backup was stamped after its snapshot, and an erasure's register time after its file steps, so a backup made in between could be misdated against the erasure. | Backups are stamped before the snapshot (Settings, Move to a new Mac); the erasure's time is the date the ledger records for it. | `timestampsTakenFirst` |
| DD2-11 | The count-back checks after a case or document erase used subqueries on parent rows already deleted, so a child row left behind was never found. | Parent ids are read first and the count-back uses them. | `countBackFindsLeftovers` |
| DD2-12 | The shared-document check compared `source_ref` as exact text; another case naming the document in lower case did not count, so the document was erased with the first case. | Compared with `upper()` on both sides. | `sharedCheckIgnoresLetterCase` |

Limits: the sync side tables (no case column) are still scrubbed for the full name and aliases of 3+ characters in every
case, now by whole word. A crash during the restore's completion steps is undone at the next launch, but a register
merge that already happened stays (a union only adds erasures). No GUI walk; no CI run (not pushed).

## Deep dive 2026-11-14 batch 3 (money, dates, CSV, locators)

From a read-only review; each item was confirmed in the code before it was changed. Tests in
`KalsmritikoshTests/DeepDiveBatch3Tests.swift` (13 tests, dates built in explicit zones, Asia/Kolkata and
America/New_York where a zone matters). Most tests need new or widened entry points to compile (a zone parameter, a
currency context, a per-line escaper), so their failing state was shown by reading the old code against each test's
inputs; none was run against the old build. No schema change (latest stays v191).

| # | Defect (reproduction) | Fix | Regression test |
|---|---|---|---|
| DD3-1 | The exchange export wrote a zone-less chronology day in UTC, though addJournal had cut it at local midnight: in IST the file said the day before. A minute lost its time; a month or year was written as an invented day. | `CaseExchange.dateText` writes each date at its own precision in its recorded zone, else the reader's (`exchangeDocument(timeZone:)`), the same text as the map export (`CaseMapExportRenderer.dateText`, shared). `CaseExchange.placed` reads back decade, year, quarter, month, day, minute with offset and RFC 3339 at that precision. | `exchangeDatesAtPrecision` |
| DD3-2 | CSV writers quoted only cells holding "\n" (or replaced "\r\n"/"\n" only): a lone CR, or a CRLF (one Swift Character), broke the row, and the text after it could start a line with a formula. `CSVFormulaGuard.triggers` lacked "\r\n". | One escaper, `CSVFormulaGuard.csvField`: guards the cell and the text after every line break, quotes on a comma, quote, CR or LF scalar. Map export, privilege log, ledger tables (and batch screening), work-product CSV, Data Lab, Query, Convert and case-document CSV go through it. CRLF and LF added to the triggers. | `csvRowBreaksQuoted` |
| DD3-3 | A shared reference made two records one payment before the day and same-statement checks: two instalments of one invoice reference on different days, or two statement rows both saying "NEFT", were merged. | Different days and rows of one statement are checked first; then the same reference (same amount and currency) is the same payment. A reference with a day missing on one side stays the same payment (the documented statement-row-and-report case of the INV-104 fixture), not a candidate — see limits. | `sharedReferenceDifferentDays` |
| DD3-4 | Records were bucketed by exact payer/payee before the reference rule: "Kestrel Supplies" vs "Kestrel Supplies Pvt Ltd", or a missing payer, with the same reference counted twice; a person's "same transaction" decision never joined records across buckets. | Before bucketing, records sharing a normalised reference, kind, currency and amount, and records a person decided are one, are joined (union-find); look-alikes without a reference stay candidates only within their own parties. | `sameReferenceAcrossPartyNames` |
| DD3-5 | `FAMoney.value`: "83.125" and "1.500" were unreadable (a three-decimal rate was refused as badRate); "0,125" read as 125 and "1,085" as 1085. | One separator before exactly three digits is read only when the context decides it: a stated or written currency (three-decimal KWD/BHD/OMR/JOD/TND/LYD/IQD → decimals; any other known currency or a sign → a group) or a rate (one dot is the decimal point). "0,125" is a decimal. Otherwise it is not read. Callers pass their context: money records and statements their currency, schedule rows and reconciliations theirs, rates `rate: true`; the evidence check compares a bare "1,085" under both readings. | `famoneySeparators` |
| DD3-6 | Money days were parsed with a lenient DateFormatter: "2026-3-5" and "26-03-05" (year 26) were accepted and the raw text stored. | `CaseMoneyLedger.date` requires `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` and a round trip to the same text (records, statements, rates, the Case tools money field). | `strictMoneyDays` |
| DD3-7 | Money nodes had a UTC-midnight date with no zone, so the label showed the day before west of UTC; the timeline buckets were computed in UTC while chronology labels were local (east of UTC an entry fell in the day before). | Money nodes carry `dateTimeZone = "UTC"`; `CaseMapDistribution.byDate` buckets each record in its recorded zone, else the reader's (`timeZone:`), and labels the day bucket in that zone. | `moneyDayAndBuckets` |
| DD3-8 | An onward hop needed a strictly earlier receipt: a same-day onward payment, or one after an undated receipt, was added to gross paid again. | Such a payment is a possible onward hop: in the onward figure (not gross), listed in `possibleOnward`, with a warning to check it. Money coming back from the payee is not a hop. | `possibleOnwardHops` |
| DD3-9 | Statement import: a CRLF file parsed 0 rows and reported success; "0.00" or "-" in the unused column made a 0 payment and lost the credit; opening/closing/total rows were imported; quoted CSV was split naively; each row was its own savepoint. | Lines split on CRLF, CR or LF; comma lines read as RFC 4180; a zero, dash or blank cell is no amount; a row with both a debit and a credit, a balance or total line, or a row with no date is refused (nothing written); every row is written in one savepoint (one action). | `statementImport` |
| DD3-10 | Statement support and the studio evidence check used NSDataDetector, which read 05/03/2026 as US month/day: it supported a 3 May field. | A numeric date whose day and month are both 1–12 and differ is not read (neither support nor contradiction); ISO and written-month dates are unchanged. | `ambiguousNumericDates` |
| DD3-11 | `.xls` rows carried no cells array (text joined by tabs, empties dropped), so a cited column was never highlighted although the citation said the place is shown. | The XLS parser adds `cells` by column with empties kept, as XLSX and ODS do; the row text is unchanged. | `xlsRowCells` |
| DD3-12 | ODS collapsed a run of repeated empty rows to one and numbered rows by position, so row numbers after the run drifted from LibreOffice's. | `ODSStructuralParser.indexedRows`: the row number moves past the full repeat count while only capped copies are kept; row blocks carry that number. | `odsRowNumbers` |
| DD3-13 | Ownership `validFrom`/`validTo` (Dates) were compared with a UTC-midnight day, so a period recorded with a time of day did not hold on its first day. Day arithmetic for statement gaps and month bounds used this Mac's zone (a day moved across a daylight-saving change). | Compared as UTC day strings (`holds(onDay:)`); gap and month arithmetic in a UTC calendar. No migration (converted at read time). | `ownershipDays` |

Limits: item 3 keeps "same reference, one record undated" as the same payment (the review suggested a candidate; that
contradicts the module's documented rule and the INV-104 acceptance key, which records undated report payments with the
statement's references), so two instalments under one reference where one is undated are still merged. A bare "1,085"
with no currency anywhere is now unreadable where it used to read as 1085 (stated, never guessed). A possible onward hop
on the same day is not counted in gross even when the two payments are unrelated (it is flagged). No GUI walk; no CI run
(not pushed).

## Deep dive 2026-11-14 batch 4 (privacy, exports, relay money path)

From a read-only review; each item was confirmed in the code before it was changed. App tests in
`KalsmritikoshTests/DeepDiveBatch4Tests.swift` (10 tests), the parity check in `CaseReadBudgetTests.refusalWordsMatchRelay`
and the log audit in `SmartMapS16Tests.noPublicFileNamesInLogs`; relay tests in `relay/test/relay.test.ts` (5 new, `npm test`
offline). No schema change (latest stays v191). The relay is not deployed.

| # | Defect (reproduction) | Fix | Regression test |
|---|---|---|---|
| DD4-1 | Relay: the verified JWS's productId was never checked and the account was keyed by its originalTransactionId. A subscriber could send a credit pack's signed transaction (a consumable has no expiry and its own number) or a Workbench one and get a fresh monthly allowance per transaction, since Apple's status call answers for the whole customer. | `jws.ts` refuses a transaction whose productId is not an AI subscription (`TIER_OF_PRODUCT`, own property) or that has no expiry; `planStatus` counts only statuses whose `originalTransactionId` is the credential's. App side confirmed consistent: `Entitlement.aiSignedTransaction` picks only AI subscription records (no change). | relay "a credit pack's or a Workbench signed transaction is no credential", "only the subscription the credential names counts"; app `credentialIsTheAISubscription` |
| DD4-2 | Relay: a `document` block was counted as one image (1,600 tokens) and skipped the size cap, and the charge is capped at the reservation, so a large PDF was under-reserved and under-charged. Other block types were sized by their JSON. | Only `text` and `image` content blocks are forwarded (what the app's request builders send); anything else is refused as `bad-request` ("text and images only"), before any reservation. | relay "only text and image content blocks are forwarded"; app `relayRefusalsRead` |
| DD4-3 | App: the protected-name check ran before the save panel but not at write in Timeline, Watchlist, Workspaces (report and receipt), Knowledge, Notebook, Structured comparison, Cross-document matrix (both), Ask (answer text, receipt, proof bundle), and also Transcripts, Case story and Send to DEVONthink. A source protected while the panel was open still reached the file. | Every write goes through `ProtectedExport.writeRechecked(…, names: { try await appState.protectedNamesNow() })`; the proof-bundle folder through the new `ProtectedExport.recheck` before it is written. Clipboard copies (no panel) are unchanged. | `protectedAtWrite`, `everyProtectedExportRechecksAtWrite` (source audit) |
| DD4-4 | Relay: Sandbox (TestFlight, App Review) transactions are accepted in production and each sandbox renewal (minutes apart) opened a new allowance month. | `SANDBOX_DAILY_CREDITS` (default 100; `0` = none; documented in wrangler.toml and the README): a Sandbox account's allowance period is the UTC day, with that ceiling as allowance and daily limit. Production unchanged. | relay "Sandbox subscriptions get one allowance per UTC day…" |
| DD4-5 | App: the AI `money` tool held figures only for money records whose source was not sent; a record with no source passed, and accounts, holder assertions and statements were not checked. | `CaseMoneyLedger.heldFromAssistant`: an active record, account, holder or statement whose source version was not sent holds the tool; a carried money record (job result, exchange import) with no source is held; an investigator's own entry with no source is not. Exchange rates have no source version (a named publisher), so none is held. | `moneyToolHoldsAccountsHoldersStatements`, `moneyToolHoldsCarriedWithoutSource` |
| DD4-6 | Relay: a provider failure after the hand-over was reported as `store-unavailable` ("…Nothing was sent"), which is false. | New `provider-unavailable` (502): "The AI service did not answer. Your request may have reached it; no credits were charged for it. Try again in a minute." (`metered` gives every reserved credit back in that case.) Added to the app's refusal codes (`AIIncludedRelay.refusalCodes`) and words (`AIPricing.providerUnavailableMessage`). | relay "a provider that does not answer is provider-unavailable"; `refusalWordsMatchRelay` (words and code sets) |
| DD4-7 | App: LegalProduction and other file operations logged FileManager error descriptions (which name files and folders) as public. | Every log line within four lines of a file operation in Export/, Investigate/ and App/ now logs the error privately (61 lines; `writeRechecked` logs domain and code publicly). | `fileErrorsLoggedPrivately`; `noPublicFileNamesInLogs` extended |
| DD4-8 | App: the diagnostics path cleaner stopped at the first space ("/Users/a/Client Files/Meera Iyer.pdf" kept " Files/Meera Iyer.pdf") and kept /Volumes paths. | `DiagnosticsSanitizer.clean` cuts /Users, /Volumes, ~/, /private/var/folders and /var/folders paths to the closing quote (', ", “, ‘) or to the end of the string value. | `diagnosticsPathsCutWhole` |
| DD4-9 | App: masking ignored accents and line breaks — a protected "José Núñez" written "Jose Nunez" was sent, and "Jane\nDoe" was not masked; the redaction check also missed the unaccented spelling. | `OnlinePIIMasker` finds names on a case- and accent-folded copy of the text (with a UTF-16 map back), `\s+` between name parts, longest first, no overlaps; the original spelling is what is restored. `RedactionVerifier` adds a `diacriticFolded` channel (every earlier channel kept, so it is only stricter). | `maskerFoldsAccentsAndBreaks`, `verifierFoldsAccents` |

Limits: the relay tests import the new constant, so against the old source they fail at import rather than per test;
the app tests use new entry points (`recheck`, `heldFromAssistant`, `refusalCodes`) for the same reason. The relay still
releases the global-cap reservation when the provider does not answer (the owner's real cost of such a call is not
counted). User-facing text changed: the relay's provider-unavailable and bad-request words, the Sandbox ceiling, and the
existing at-write refusal words now also appear on the views listed in DD4-3. No privacy.html change. No GUI walk; no CI
run (not pushed).

## Still open, missed or not observed (kept visible in the matrix)

- PERF-06: one 1.63 s main-thread hold during the S17 intake was not reproduced or traced (S18 did not trace it either).
- `DiagnosticEndToEndTests.fixedPointCheckRuns` fails when run beside other suites (a background writer adds rows to
  `claim_projection_progress` or `embedding_cache` between its runs) and passes alone (S18: 2 batch failures, 2 solo passes).
  Not fixed; the check's isolation from other suites' background work is the suspected cause.
- `ManagedFileProtectionTests.sealedCache` fails while the screen is locked (NSFileProtectionComplete); code untouched.
- Owner-archive suites (`RealArchivePipelineTests`, `FactCorrectnessTests`, `MboxAccountingTests`) cannot run without the owner's archive.
- No fix above has been observed in the running app (GUI walk), and none has a fresh CI run until the owner pushes.
