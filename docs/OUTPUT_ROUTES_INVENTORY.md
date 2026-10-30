# Output routes — inventory and protection (App Store completion §4)

Date: 2026-10-30. Source tree after the §4 commit on `investigations-next`.

Every route by which case content can leave the app, the service that authorises and protects it,
what that service does, and the test that proves it. "Protected" means: content frozen, cited
sources revalidated against the case's access policy immediately before release, protected source
identities scrubbed and verified gone, bytes written atomically and read back, release recorded with
the digest of what actually left. A cancelled dialog writes and records nothing.

## Services

| Service | Used by | Freeze | Revalidate | Protect | Record |
|---|---|---|---|---|---|
| `CaseOutputService` (Investigate/CaseFile/CaseOutputService.swift) | case file documents, ACH, Data Lab datasets, Work Center reports, studio briefings | re-verifies every link/carried item, renders once | every cited version must be eligible under the export policy now; refuses otherwise | `ProtectedIdentities.scrub` on the whole text (binary documents: on every input text before rendering) + leak check | `case_document_outputs` + case log; pending JSON beside the ledger when the record fails; resumed at launch |
| `AppState.exportJobResult` (B2) | job-result Markdown export | current revision only | every cited source re-checked (`jobResultExportCheck`) | scrub + leak check | `job_result_exports` after read-back |
| `StudioStorage.package` / `exported` (R2, K5) | the six persona studios: copy, print, export | pending writes flushed, draft frozen at its payload digest | `StudioEvidenceResolver.unresolved` under the export policy | scrub + leak check | studio export record after read-back |
| `InvestigationFindings` + `findingsExportCheck` (K5) + `FindingsExporter` redaction policy | the findings report (Work product hand-off) | built findings | cited sources re-checked before write | redaction policy applied at write | hand-off model outcome |

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
| 12 | JobResultView | Export… | job result Markdown | file | AppState.exportJobResult | protected (B2) |
| 13 | Persona studios (Journalist, Workplace, SIU, Privilege log, Forensic, Reasoning) | Copy / Export / Print | studio report | clipboard, file, print | StudioStorage.package + exported | protected (R2/K5) |
| 14 | WorkProductHandoffView | Export findings | findings report | file | findingsExportCheck + FindingsExporter(redaction) | protected (K5); not yet routed through the case output record |
| 15 | WorkProductHandoffView | Copy sealed conformance certificate; Export verification bundle | conformance certificate / bundle (rules, seals; no document text) | clipboard, file | ConformanceSeal / ConformanceBundle | not case document content; sealed |
| 16 | DataLabView | Export CSV / XLSX / DOCX / PDF | dataset (workspace-scoped) | file | CaseOutputService.prepareText / protectedText + prepareData | protected (no case record: datasets have no case) |
| 17 | WorkCenterView | Copy Report / Print; Summary copy/print | work-center run report | clipboard, print | CaseOutputService.prepareText(.workCenterReport) | protected (no case record) |
| 18 | StudioOutputsView | Export… | briefing / FAQ / mind map (archive-level) | file | CaseOutputService.prepareText(.studioBriefing) | protected (no case record) |
| 19 | ExportCenterView | Export table | ledger tables with a signed receipt (recovery/support export, §4 item 8) | file | LedgerExportRenderer + VerifiableReceipt | recovery export; not case-scoped; privacy controls = the ledger's own labels; unchanged |
| 20 | AskView | Copy answer | an answer's text (archive Q&A, no case) | clipboard | — | archive-level; protected names: not scrubbed (gap, see below) |
| 21 | ConvertView | Copy / Save output | a converted document's text | clipboard, file | — | archive-level document conversion; the person already has the document; unchanged |
| 22 | QueryView / HighlightsView / RedactionView | fileExporter | query results / highlights / redacted document | file | — (RedactionView writes the REDACTED document) | archive-level; unchanged |
| 23 | CitationBuilderView, FundFlowView, ComplianceBoardView, SavedQueriesView, DeepLink, MoveToNewMac, Settings | Copy | a citation string, fact/document ids, SOP handbook, a saved query, a link, a secret (concealed) | clipboard | — | no document text (ids/handbook/secret); unchanged |
| 24 | DiagnosticsSendButton | Compose e-mail | diagnostics bundle | share | existing redaction of diagnostics | unchanged |

## Removed

`CaseFileSave` (CasesView.swift) — the save helper several buttons called directly. Deleted; no
direct `NSSavePanel` + `write` path remains in the case file screen.

## Known gaps (recorded, not hidden)

- Route 14: the findings export is protected by its own check and redaction policy but is not yet
  recorded in `case_document_outputs`; its hand-off model records the outcome.
- Route 20: an archive-level answer copied from Ask is not scrubbed of protected source identities.
  The protected-identity register is a case artefact (`jrn.source-vault`); Ask runs outside cases.
  Decision needed: scrub globally (cheap, may surprise) or leave archive Q&A outside the policy.
- Print and clipboard routes record the digest of the released text; the app never sees the
  printer's or the recipient's bytes, and the record says so.

## Tests

- `CaseOutputServiceTests` — file export recorded with the on-disk digest; protected name in a
  free-text note scrubbed; preview alone records nothing (cancellation); source labelled privileged
  or removed from the case after the preview refuses the release, refusal recorded; ACH citation
  outside the case refused; custody unreadable refuses the custody report and marks prose
  INCOMPLETE; altered file is not an export; record failure keeps a pending record and resumes;
  binary document protected before rendering, a surviving name refuses.
- `CaseErasureTests/caseReportExportReauthorised` (K5), `JobResultIntegrityTests/exportAuthorisedAtWrite`
  (B2), `JobDeliverableTests/protectedIdentityKeptOut` — the other services.
