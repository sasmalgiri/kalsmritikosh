# Output routes — inventory and protection (App Store completion §4)

Date: 2026-10-30, updated 2026-11-02 (routes 20, 39–41; print gap). Source tree on `investigations-next`; 2026-11-07 (routes 42–46, case map export); 2026-11-12 (S11: routes 12–14 through CaseOutputService, routes 47–51 reviewed case products, manifests and read-back reconciliation, approvals at a revision).

Every route by which case content can leave the app, the service that authorises and protects it,
what that service does, and the test that proves it. "Protected" means: content frozen, cited
sources revalidated against the case's access policy immediately before release, protected source
identities scrubbed and verified gone, bytes written atomically and read back, release recorded with
the digest of what actually left. A cancelled dialog writes and records nothing.

## Services

| Service | Used by | Freeze | Revalidate | Protect | Record |
|---|---|---|---|---|---|
| `CaseOutputService` (Investigate/CaseFile/CaseOutputService.swift) | case file documents, ACH, Data Lab datasets, Work Center reports, studio briefings | re-verifies every link/carried item, renders once | every cited version must be eligible under the export policy now; refuses otherwise | `ProtectedIdentities.scrub` on the whole text (binary documents: on every input text before rendering) + leak check | `case_document_outputs` + case log; pending JSON beside the ledger when the record fails; resumed at launch |
| `AppState.exportJobResult` (B2) — since S11 inside `CaseOutputService` (kind `jobResult`: role, case, protection, write, read-back and record in `case_document_outputs`), then its own record | job-result Markdown export | current revision only | every cited source re-checked (`jobResultExportCheck`) | scrub + leak check | `job_result_exports` after read-back |
| `StudioStorage.package` / `exported` (R2, K5) — since S11 a CASE draft is prepared and authorised by `CaseOutputService` (kind `studioReport`, `authorizeExternalRelease` immediately before the bytes leave) and recorded there after (`recordExternalRelease`, the file read back) | the six persona studios: copy, print, export | pending writes flushed, draft frozen at its payload digest | `StudioEvidenceResolver.unresolved` under the export policy | scrub + leak check | studio export record after read-back |
| `InvestigationFindings` + `findingsExportCheck` (K5) + `FindingsExporter` redaction policy — since S11 the file is released by `CaseOutputService.prepareData(.findingsReport)` + `write` | the findings report (Work product hand-off) | built findings | cited sources re-checked before write | redaction policy applied at write | hand-off model outcome |

## Routes

| # | Surface | Action | Content | Route | Service | Status |
|---|---|---|---|---|---|---|
| 1 | CaseFileView › Log | Case file report… | case snapshot report | file | CaseOutputService.prepare(.caseFileReport) — DRAFT banner | protected |
| 2 | CaseFileView › Log | Case log… | action log CSV | file | CaseOutputService.prepare(.caseLog) | protected |
| 3 | CaseFileView › Log, Evidence | Exhibit list… | exhibits CSV | file | CaseOutputService.prepare(.exhibitList) | protected |
| 4 | CaseFileView › Log, Evidence | Custody report… | custody report | file | CaseOutputService.prepare(.custodyReport) — refused when custody is unreadable | protected |
| 5 | CaseFileView › Log | Personal data export… | one person's record | file | CaseOutputService.prepare(.personDataExport) | protected |
| 6 | CaseFileView › People | Export statement for signature… | interview statement | file | CaseOutputService.prepare(.statement) | protected |
| 7 | CaseFileView › Evidence | Save notice to send… | preservation notice (free text) | file | CaseOutputService.prepareText(.holdNotice) | protected |
| 8 | CaseFileView › Evidence | Export redaction log… | redaction log CSV | file | CaseOutputService.prepare(.redactionLog) | protected |
| 9 | ACHMatrixView | Export / Export Markdown | ACH report | file | CaseOutputService.prepareText(.achReport) with the analysis's citations | protected |
| 10 | ACHMatrixView | Copy report | ACH report | clipboard | same; `released` records the text digest | protected |
| 11 | ACHMatrixView | Print | ACH report | print | same; recorded only when the print dialog ran | protected |
| 12 | JobResultView | Export… | job result Markdown | file | AppState.exportJobResult → CaseOutputService.prepareText(.jobResult) → write | protected (B2; S11 recorded in the case's outputs) |
| 13 | Persona studios (Journalist, Workplace, SIU, Privilege log, Forensic, Reasoning) | Copy / Export / Print | studio report | clipboard, file, print | StudioStorage.package + exported; a case draft through CaseOutputService (studioReport: authorizeExternalRelease before, recordExternalRelease after) | protected (R2/K5; S11 recorded in the case's outputs) |
| 14 | WorkProductHandoffView | Export findings | findings report | file | findingsExportCheck + FindingsExporter(redaction) → CaseOutputService.prepareData(.findingsReport) → write | protected (K5; S11 recorded in the case's outputs) |
| 15 | WorkProductHandoffView | Copy sealed conformance certificate; Export verification bundle | conformance certificate / bundle (rules, seals; no document text) | clipboard, file | ConformanceSeal / ConformanceBundle | not case document content; sealed |
| 16 | DataLabView | Export CSV / XLSX / DOCX / PDF | dataset (workspace-scoped) | file | CaseOutputService.prepareText / protectedText + prepareData | protected (no case record: datasets have no case) |
| 17 | WorkCenterView | Copy Report / Print; Summary copy/print | work-center run report | clipboard, print | CaseOutputService.prepareText(.workCenterReport) | protected (no case record) |
| 18 | StudioOutputsView | Export… | briefing / FAQ / mind map (archive-level) | file | CaseOutputService.prepareText(.studioBriefing) | protected (no case record) |
| 19 | ExportCenterView | Export table | ledger tables with a signed receipt (recovery/support export, §4 item 8) | file | LedgerExportRenderer + VerifiableReceipt | recovery export; not case-scoped; privacy controls = the ledger's own labels; unchanged |
| 20 | AskView | Copy answer | an answer's text, plain, with its sources by file name (archive Q&A, no case) | clipboard | ProtectedExport.prepare (scrub + leak check, fails closed) — since the re-review 2026-11-02; same route as 37 | protected |
| 21 | ConvertView | Copy / Save output | a converted document's text | clipboard, file | — | archive-level document conversion; the person already has the document; unchanged |
| 22 | QueryView / HighlightsView / RedactionView | fileExporter | query results / highlights / redacted document | file | — (RedactionView writes the REDACTED document) | archive-level; unchanged |
| 23 | CitationBuilderView, FundFlowView, ComplianceBoardView, SavedQueriesView, DeepLink, MoveToNewMac, Settings | Copy | a citation string, fact/document ids, SOP handbook, a saved query, a link, a secret (concealed) | clipboard | — | no document text (ids/handbook/secret); unchanged |
| 24 | DiagnosticsSendButton | Compose e-mail | diagnostics bundle | share | existing redaction of diagnostics | unchanged |
| 25 | TranscriptsView | Export quotes… | quote book with Speaker column | file | AppState.protectedExportText (scrub + leak check, fails closed) — added 2026-11-02 after the agent practitioner review | protected |
| 26 | AskView (answer menu) | Export verifiable receipt… | answer receipt JSON (question, answer, passages) | file | ProtectedExport.prepare(refuseIfPresent) — a sealed receipt is never altered after sealing; one holding a protected identity is refused (re-review 2026-11-02) | protected |
| 27 | IssueChronologyView | Export chronology | issue chronology Markdown | file | AppState.protectedExportText — added 2026-11-02 | protected |
| 28 | CaseStoryView | Save case story | case story Markdown / HTML | file | AppState.protectedExportText — added 2026-11-02 | protected |
| 29 | CaseSliceView | Save slice | signed case slice JSON | file | ProtectedExport.prepare(refuseIfPresent) — a signed slice holding a protected identity is refused — added 2026-11-02 after the agent re-review | protected |
| 30 | CrossDocumentMatrixView | Export Markdown | matrix Markdown | file | ProtectedExport.prepare (scrub + leak check) — added 2026-11-02 after the agent re-review | protected |
| 31 | CrossDocumentMatrixView | Export receipt | sealed receipt JSON | file | ProtectedExport.prepare(refuseIfPresent) — added 2026-11-02 after the agent re-review | protected |
| 32 | KnowledgeView | Save dossier | entity dossier Markdown | file | ProtectedExport.prepare — added 2026-11-02 after the agent re-review | protected |
| 33 | NotebookView | Save investigation report | investigation report Markdown | file | ProtectedExport.prepare — added 2026-11-02 after the agent re-review | protected |
| 34 | StructuredComparisonView | Export comparison brief | comparison brief Markdown | file | ProtectedExport.prepare — added 2026-11-02 after the agent re-review | protected |
| 35 | WorkspacesView | Export report | work-product report | file | ProtectedExport.prepare — added 2026-11-02 after the agent re-review | protected |
| 36 | WorkspacesView | Export receipt | sealed receipt JSON | file | ProtectedExport.prepare(refuseIfPresent) — added 2026-11-02 after the agent re-review | protected |
| 37 | AskView (answer menu) | Copy answer | answer text | clipboard | clipboard — ProtectedExport.prepare — added 2026-11-02 after the agent re-review | protected |
| 39 | AskView (answer header and menu) | Save / Save answer as text… | question, plain answer and sources by file name (.txt) | file | ProtectedExport.prepare — added 2026-11-02 (user evaluation M2) | protected |
| 40 | AskView (answer menu) | Send to DEVONthink | answer note Markdown with passage links, handed to DEVONthink (or shown in Finder) | file (another app) | ProtectedExport.prepare in AppState.sendToDevonthink — added 2026-11-02 (candidate re-review P-B1); a refusal sends nothing | protected |
| 41 | AskView (AI review sheet) | Copy | an Online-AI review / draft paragraph | clipboard | ProtectedExport.prepare — added 2026-11-02 (candidate re-review P-B1) | protected |
| 38 | AskView (answer menu) | Export proof bundle… | signed proof bundle | file | ProtectedExport.prepare(refuseIfPresent) on question, answer, passages and file names — added 2026-11-02 after the agent re-review | protected |
| 42 | CaseMapWorkspaceView › Export | Export map as PDF (with its relationship table)… | the shown map items and links drawn on page one, then the relationship and evidence table; header names the case, view, moment or recorded state, scope fingerprint, selection, current legal holds | file | CaseOutputService.prepareMap(.pdf) → write (UI: CaseMapExportRoutes) — added 2026-11-07 (Living Case Map M8) | protected |
| 43 | CaseMapWorkspaceView › Export | Export map as PNG and the table as CSV… | the map image, then (second save panel) its relationship and evidence table CSV; a skipped table is reported | file | CaseOutputService.prepareMap(.png) + prepareMap(.csv) → write — added 2026-11-07 (M8) | protected |
| 44 | CaseMapWorkspaceView › Export | Export the relationship table (CSV)… | relationship and evidence table | file | CaseOutputService.prepareMap(.csv) → write — added 2026-11-07 (M8) | protected |
| 45 | CaseMapWorkspaceView › Export | Copy the relationship table | relationship and evidence table text | clipboard | CaseOutputService.prepareMap(.csv, .clipboard) → release — added 2026-11-07 (M8) | protected |
| 46 | CaseMapWorkspaceView › Export | Print the relationship table | relationship and evidence table text | print | CaseOutputService.prepareMap(.csv, .print) → release via the print preview — added 2026-11-07 (M8) | protected |
| 47 | CaseMapWorkspaceView › Export | Export the case package (read-only, whole case)… | one static HTML file: status (revision, approval or DRAFT), legend (Supplied / Inferred / Reviewed / Unresolved), items, relationships and their evidence, evidence (document, location, quoted words, source version), findings and decisions, open work, money report, briefing steps, what is not included (by count; restricted by count only), manifest | file | CaseOutputService.preparePackage(.wholeCase) → write (UI: CaseMapExportRoutes.exportPackage) — frozen between two equal revision fences, protected item by item, active-content check before and after writing, read back and reconciled row by row with its manifest — S11 | protected |
| 48 | CaseMapWorkspaceView › Export | Export the selected branch as a package… | the same package for a frame and what is placed in it, or an item and its neighbours, plus what they rest on (each marked "Included because …") | file | CaseOutputService.preparePackage(.branch) → write — S11 | protected |
| 49 | CaseMapWorkspaceView › Export | Export the money report… | the case's money report (the same text as the report and the package) | file | CaseOutputService.prepareMoneyReport → write; every cited statement re-checked — S11 | protected |
| 50 | CaseMapWorkspaceView › Export | Export this case's review record… | a review case's own findings, authorship and chronology | file | CaseOutputService.prepareReviewRecord → write (the release check: role, references re-read and re-checked, protected names) — S11 | protected |
| 51 | CaseMapBriefPanel | Export this briefing… | a briefing's steps (as frozen, or as the case is now with what changed) | file | CaseOutputService.prepareBriefing → write — S11 | protected |

The Export menu's "Approve the reports and the package at this revision" records an approval (CaseOutputService.approve, a review decision); it releases nothing.

## Removed

`CaseFileSave` (CasesView.swift) — the save helper several buttons called directly. Deleted; no
direct `NSSavePanel` + `write` path remains in the case file screen.

## Known gaps (recorded, not hidden)

- Routes 42–46 (case map, M8): a map export freezes the view as shown, revalidates every cited source against the export
  policy now (a historical export too — its label names the recorded state and says it is not the current case), scrubs
  protected identities from every text before drawing, states the case's legal holds as they are now, and is recorded in
  `case_document_outputs` as kind `caseMap`. The map screens have no screenshot, image, copy or print command of their own;
  `CaseMapHistoryTests.noCanvasBypass` checks the sources. A PNG and its CSV are two releases (two records); the person may
  decline the CSV, and the receipt says the image alone does not show the sources.

- Routes 12–14 (S11): job results, persona-studio case drafts and the findings report now leave through CaseOutputService
  and are recorded in `case_document_outputs`. A studio draft not yet assigned to a case has no case to record in; it keeps
  its own studio export record (as before). A studio's file is written by the SwiftUI file exporter, so the door
  authorises immediately before the panel and reads the file back after; a file that does not hold the released bytes is
  recorded as failed.
- Routes 47–51 (S11): every product that presents conclusions states the case revision it was read at and either the
  approval of exactly that revision or DRAFT; a change to the case after it was prepared, or an approval withdrawn since,
  refuses the release. Each output's manifest (revision fence, selection, counts, pinned revisions, source versions,
  what was left out) is stored with its record. The package carries no originals; it says so.
- Print (routes 11, 13, 17): owner decision 2026-11-02 — no `com.apple.security.print` entitlement. Every Print
  button opens a **print preview** (AppPrinting): the same released text laid out as PDF pages drawn in the app,
  with "Save as PDF…"; only a saved PDF is recorded as a release, closing the preview records nothing. The person
  prints the PDF from any app.
- Print and clipboard routes record the digest of the released text; the app never sees the
  printer's or the recipient's bytes, and the record says so.

## Tests

- `SmartMapS11Tests` (S11) — freeze under a concurrent edit (re-read, then refused); the package read by a fresh reader with
  nothing but its bytes; selection and dependencies; read-back reconciliation (a missing row, a short CSV, a damaged PDF or
  PNG is not an export); approvals at a revision; money report, briefing and review record through the door; studio and
  job-result writers through the door (an altered file is failed, a person without a role refused).

- `CaseOutputServiceTests` — file export recorded with the on-disk digest; protected name in a
  free-text note scrubbed; preview alone records nothing (cancellation); source labelled privileged
  or removed from the case after the preview refuses the release, refusal recorded; ACH citation
  outside the case refused; custody unreadable refuses the custody report and marks prose
  INCOMPLETE; altered file is not an export; record failure keeps a pending record and resumes;
  binary document protected before rendering, a surviving name refuses.
- `CaseErasureTests/caseReportExportReauthorised` (K5), `JobResultIntegrityTests/exportAuthorisedAtWrite`
  (B2), `JobDeliverableTests/protectedIdentityKeptOut` — the other services.
