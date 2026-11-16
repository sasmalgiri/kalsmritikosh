# Case-methods gap reconciliation (2026-11-16)

Plan: `docs/Kalsmritikosh_Case_Methods_Gap_Analysis_and_Implementation_Plan_2026-11-16.md` (baseline c157aaa6).
Checked against: `investigations-next` at **e4516f23**, two commits past the plan's baseline. Those commits are
the AI conflict review fixes A and B, which change none of the conclusions below. Method: code reading only, by
the agent. Nothing was built, run, walked in the UI or measured for this record.

Verdict vocabulary (plan §G1): **observed working**, **present but unverified**, **missing integration**,
**code defect**, **depends on owner/infrastructure**. In this record, "observed working" means the agent read
the code and confirmed the behaviour there. It does not mean a UI observation.

Tracker: `docs/SMART_MAP_COMPLETION_MATRIX.json`.
- It gains **29 rows** (spec ref `CM-2026-11-16`) for conditions no existing row covers.
- **17 existing rows** gain a cross-reference note (spec ref `CM-2026-11-16 (cross-ref)`).
- **2 rows are lowered**, because confirmed defects break their acceptance conditions:
  - OUTPUT-08: AUTOMATED_VERIFIED → IN_PROGRESS.
  - PERF-11: IMPLEMENTED → IN_PROGRESS.
- The work order is `docs/CASE_METHODS_IMPLEMENTATION_TODO_2026-11-16.md`.

## Confirmed code defects (fix first; each is small)

| # | Defect | Evidence | Row |
|---|---|---|---|
| D1 | Every root-cause report says the causes were traced to evidence and the root cause was confirmed by a human, whatever the evidence or review state. | `Investigate/RootCauseAnalysis.swift:288`. The same text reaches preview, Markdown export, copy, print/PDF, case output and stored snapshots. | REPORT-11 (OUTPUT-08 lowered) |
| D2 | The contradiction check compares only the first 400 documents, ordered by UUID. The cap is logged to OSLog only. The screen says "Compared 400 document(s)", and the AI coverage text says "The rules checked every document." | `App/AppState+CaseContradictions.swift:18-38`; `UI/CaseContradictionsSection.swift:264`; `+AIConflicts.swift:349` | SEARCH-13 (PERF-11 lowered) |
| D3 | An enrichment lookup with an empty page and more pages unread returns **noMatch** (reason "more pages were not read"). A partial lookup therefore reads as no match. | `Investigate/CaseFile/CaseEnrichment.swift:89` | ADAPT-07 / ADAPT-10 |
| D4 | Studio exports skip the source re-check: `exportNow`, `copyNow` and `printNow` call `storage.package` without `authorise`. | `UI/ReasoningStudioView.swift:740,747,757` | REPORT-11 |

## §A capabilities: verdict per gap

| Capability (plan §A) | Verdict | Evidence at e4516f23 | Rows |
|---|---|---|---|
| Start work on a point or disputed fact | **missing integration** | Commands exist for frame, report, point, allegation and task nodes. Case, transaction and passage nodes get only "Open as frame" (`UI/CaseMapWorkCommands.swift:120`). Neither "Investigate this discrepancy" nor "What haven't we considered?" exists. Back restores the node and view but not the presentation. | MAP-13 (new); MAP-01, MAP-07 |
| Check all 16 methods | **missing integration** | The 16 methods are registered in §B order (`Method/Catalog/ProfessionalMethodCatalog.swift:54-73`). There is no applicability record: a method exists only as a `MethodRun`, i.e. performed. `UI/` never references `ProfessionalMethod`. The only route is the persona `*.methods` job. | REASON-14 (new) |
| Use AI to reason through a case | **missing integration** | `CaseAITaskKind` has followUps, links, organize, summary and review only (`CaseAIAssist.swift:93-104`). Consent is already tied to destination, model and key (`CaseReadPermission.swift:121-133`): observed working. | AI-15 (new) |
| Choose the next action | **missing integration** | `CaseNextSteps.compute` uses a fixed order of kinds, with only `dueAt`/overdue for time. There is no expiry, discrimination, cost or override. `GapLeadFinder` sorts by UUID. | ACTION-15 (new); ACTION-07 |
| Trust the scope of a negative result | **code defect** (D2) + **missing integration** | Search has a receipt, a stable order with a tie-breaker and continuation (`Retrieval/CaseSearchService.swift`): present but unverified. Its continuation is not Codable, and the 20,000 cap gives none. Comparison has no receipt. Batches drop subjects past 6 and passages past 8 per subject with no record (`CaseContradictionFinder.swift:1297-1322`), and nothing is compared across batches. | SEARCH-13, SEARCH-14 (new); SEARCH-06, SEARCH-11, PERF-11 |
| Brainstorming, Five Whys, Ishikawa from the map | **code defect** (D1, D4) + **missing integration** | Why evidence is an optional String (`RootCauseAnalysis.swift:38`; `ReasoningStudioView.swift:394`). Ideas, causes and conclusions carry no references or assumptions. There is no inconclusive conclusion. Snapshots and frozen exports are kept (`StudioRecordRepository.swift:397-440`): present but unverified. | REPORT-11, REASON-13 (new); OUTPUT-08 |
| Cross-check a model claim without AI | **missing integration** | The query tree, receipt and saved searches exist. Nothing opens a pre-filled search from a node. There is no paired contrary result and no claim receipt. | SEARCH-15 (new) |
| Know which evidence challenges the leading theory | **missing integration** | Attribution, relations, `CaseDerivativeText` and `CaseSupportOrigins` exist and are tested (`CaseReasoning.swift`). `supportOrigins`, `dependenceReviews` and `alternatives` are called only from tests. The inspector shows copies but not assumptions or unassessed independence. | REASON-16 (new); REASON-05 |
| Obtain a missing record or technical opinion | **missing integration** + **code defect** (D3) | Itemized requests, due dates and statuses exist. The letter is drafted and copied only ("the app does not send it"). Requests do not use `case_external_effects`. `CaseEnrichmentResult` has no production caller. | ADAPT-10 (new); ADAPT-07 |
| Resume, revise and hand over | **present but unverified** (versioning) + **missing integration** | Briefs are versioned with stale-write refusal and open alternatives (`CaseBriefs.swift:350-381, 707-720`). The diff is per viewer, not per recipient. There are no reopening conditions and no "Inconclusive on the available evidence". The new kinds are absent from `CaseDerivedKind`. The late-contribution queue has no UI. | BRIEF-10, CHANGE-11 (new); BRIEF-04, CHANGE-07 |
| Operate across devices and providers | **depends on owner/infrastructure** | The relay host is `""` (`Routing/Providers/Online/AIIncludedRelay.swift:23`). v1 is solo (`SHIP_DECISIONS.md:21`). `TeamCase` is a signed shared-folder log, with no identity or sync. | SHIP-13, AI-16 (new); TEAM-*, ACCESS-* |
| Field evidence, performance, benefit | **missing integration** (capture); **depends on owner/infrastructure** (humans, hardware) | Capture accepts dropped files and pasted text only. The cold projection took 6,163 ms (`docs/evidence/case-map-perf-2026-11-13/case-map-perf-stress.md:28`); the 1.63 s stall is PERF-05/06. PROTOCOL.md criteria confirmed (≥ 4/5 pilot; ≥ 30 % median saving). | IN-13, IN-14, PERF-13, BENEFIT-09 (new); PERF-01, BENEFIT-02/07 |
| Money, needed by the §D.3 journey | **observed working** (engine, tested) + **missing integration** (UI) | The identity rule, returned figures and reconciliation are tested (`SmartMapS7Tests`). `drill()` and `decideMoneyIdentity` have no UI caller. | MONEY-13 (new); MONEY-04 |
| Child action → reviewed result → revised brief | **missing integration** | The map uses `CaseReports.recordResult`/`reviewAction`, which overwrite a single review state. The versioned `CaseActionWork` review has no UI caller. Nothing links a result to a brief. | ACTION-13 (new); ACTION-09 |

## Mapping of the plan's other identifiers

- **385-requirement plan and gap register:** not in the repository (BASE-10 waits for the owner's file).
- **52 reachability flags:** present as footnotes in the generated matrix; rechecked in QA-16.
- **Plan identifiers not in this tracker:**
  - QRY-01–40: closest are SEARCH-01…12; new SEARCH-13/14/15.
  - CAP-01–10: QA-18, written from the 385-row plan.
  - CAP-05/06/08: REASON-14, ACTION-14, ACTION-15.
  - IN-13–17: new IN-13, IN-14.
- **Already covered by existing rows (no new row):**
  - Multi-investigator work: ACCESS-01/07/08/10/11, TEAM-01/05/06/07/09, SEC-04, QA-07, RECOVERY-08.
  - Distribution: SHIP-01…12, QA-13, RECOVERY-04.
  - Restore without re-sending: RECOVERY-05.
  - Low storage: PERF-08.
  - Accessibility: QA-12.
