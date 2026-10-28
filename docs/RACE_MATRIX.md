# Race matrix (final completion instructions §6, T1)

The eight races the instructions name, the outcome required, and the test that proves it on the real
service and database path. "By construction" means the check runs inside the same savepoint as the
write, on the one `Database` actor, so the two operations cannot interleave; the test drives both
orders.

| # | Race | Required outcome | Proof | Status |
|---|---|---|---|---|
| 1 | Case switch during a question | The answer belongs to the case it was asked in and is never shown or saved under another case | `InvestigationAnswer.context` carries the asking case's scope; an `ask` job's result is persisted to the asking case (`PersonaJobService.askLaunch`) | **partial** — service binding proven; the Ask screen discarding a late answer after a switch is checked in the F3/F8 journeys |
| 2 | Close during a studio write | A write that lands after the case closed is refused and stays pending (reported), never silently lost | `StudioRecordRepositoryTests.parentCaseAndApproval` (parent case must be open to edit, checked inside the savepoint) + `failedSaveRetried` (a refused save stays pending) | done (by construction + test) |
| 3 | Sensitivity or scope change during export | Nothing is output when a cited source became privileged or left the case after Export was pressed | `StudioRecordRepositoryTests.exportReauthorised`; `CaseErasureTests.caseReportExportReauthorised` (case reports) | done |
| 4 | Legal hold during erasure | A hold placed while an erase starts rolls the erase back; nothing is deleted | `DiagnosticEndToEndTests.eraseFailsClosedOnHolds` (full erase re-checks inside the destructive savepoint); `CaseErasureTests.holdRefuses` (case erase checks holds inside its savepoint) | done (by construction + test) |
| 5 | Edit during approval | An approval of content that changed after review is refused | `StudioRecordRepositoryTests.parentCaseAndApproval` (approval bound to the approved payload hash); `InvestigationFindingsServiceTests.approvalPolicyAndCurrency` (stale scope / tampered receipt refused) | done |
| 6 | Pending studio write during backup | A backup does not start while a studio write is unsaved | `StudioRecordRepositoryTests.failedSaveRetried` (the backup flush refuses while unsaved) | done |
| 7 | Provider confirmation, key or mode change during consent | A change to Online mode, provider, key, model or document terms while the consent dialog is open voids the consent; nothing is sent | `OnlineProviderFailureTests.changeDuringConsent` (`SendSettings` is snapshotted before the dialog and compared after it, inside `OnlineCloudProvider.send`) | done (unit; the dialog itself is driven in F8) |
| 8 | Old background result arriving after full erasure | A result that finishes after its data was erased writes nothing | `DiagnosticEndToEndTests.eraseFilesPreferencesAndWriters` (a studio save after the erase writes nothing); `ChronologyExecutorTests.resultsKept` (a job result for an erased or unknown case is refused inside its savepoint) | done |

Found and fixed while building this matrix: race 7 (the send went out with the settings captured before
the dialog) and race 8 for job results (a late executor result would recreate rows for an erased case).
