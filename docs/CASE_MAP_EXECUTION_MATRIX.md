# Living case map — execution matrix (M0–M10)

Plan: `docs/IME_Living_Case_Map_Implementation_Plan_2026-11-06.md` (§11 packages, §12 acceptance case, §13 tests).
Scope: `docs/IME_Core_and_Add_On_Scope_2026-11-06.md` (§2, §10).

Each column is a separate kind of evidence. "Automated" means model- and service-level tests in the XCTest host;
it is not a UI check. The plan (§13.2) says compilation, an accessibility tree, a screenshot or a model-level
test does not prove the journey works, so the UI, signed-build and human columns stay **NOT RUN** until each
is actually run and recorded. The map stays behind the opt-in "Case map (preview)" switch until M1–M9 pass
on the candidate, UI checks included.

Last automated run: 2026-11-07, working tree on `investigations-next` at 1c1ac37b plus the uncommitted M9
work, Debug test host, Apple M4 Mac16,12, macOS 27.0.1 (26A434), schema 173.

| Package | Implemented (commit) | Automated verification (suite: passed/run) | UI verification | Signed build | Human evaluation |
|---|---|---|---|---|---|
| M0 — baseline | a87f2c4d (matrix drift fixed via the Swift renderer, inventory drift test) | ScopeInventoryDriftTests 6/6, ScopePresetTests 3/3, ModuleScopeMigrationTests 3/3, ScopeRetiredSurfaceTests 5/5 (2026-11-07). The existing-workspace GUI journey was INCOMPLETE (screen locked, 68addaa4) | NOT RUN | NOT RUN | NOT RUN |
| M1 — case projection | 6132dab9; O(n) look-ups added in M9 (uncommitted) | CaseMapProjectionTests 9/9 (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M2 — workspace shell | 6132dab9 | CaseMapWorkspaceTests 5/5, CaseWorkspaceTests 7/7 (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M3 — spatial map and growth | 6132dab9; occupancy grid and owner pass made linear in M9 (uncommitted) | CaseMapWorkspaceTests 5/5 (stable growth, counts reconcile); harness smoke 1/1; stress run: 0 existing positions moved (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M4 — investigation actions | 6132dab9 | CaseMapLinkTests 2/2, ContradictionReviewInPlaceTests 5/5, EvidenceRequestFollowThroughTests 3/3 (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M5 — case search | a5b8c78b | CaseSearchTests 15/15 (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M6 — changes and impact | 1c1ac37b | CaseChangeFeedTests 4/4 (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M7 — history and maturity | 1c1ac37b | CaseHistoryTests 7/7 incl. the §12 multi-day replay (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M8 — privacy, export, recovery | 1c1ac37b | CaseMapRecoveryTests 9/9, CaseErasureTests 23/23, CaseOutputServiceTests 4/4 (2026-11-07) | NOT RUN | NOT RUN | NOT RUN |
| M9 — usability, help, performance | uncommitted on `investigations-next` (2026-11-07) | CaseMapAccessibilityTests 9/9; HelpRegistryTests 12/12 (manual and coverage matrix regenerated and matching); BaseCaseJourneyTests 1/1 with 1 known issue (below); BaseCaseMultiDayTests 1/1; BaseCaseLapsedBoundaryTests 2/2; CaseMapPerfHarnessTests smoke 1/1 + full normal 1/1 + full stress 1/1 (CASE_MAP_PERF only); regression: ScopeCoreTests 3/3, PackageBTests 9/9, PurchaseTests 11/11, EntitlementBoundaryTests 6/6, PurchaseStoreKitTests 16/16; `ci/guards/run-all.sh` clean | NOT RUN (no recording of keyboard/VoiceOver, narrow window, Reduce Motion or the tutorial on screen) | NOT RUN | NOT RUN |
| M10 — final candidate and measured benefit | not started | Full CI on a candidate: NOT RUN | NOT RUN | NOT RUN | NOT RUN (IME_Measurably_Easier_Test_Protocol_2026-11-04 comparison not run) |

## M9 detail

| Item (plan §10, §11 M9; scope §10) | Where | Automated evidence |
|---|---|---|
| Case map tutorial, manually stepped, sample case only: question → document → passage → review → request → new evidence → revised view → report | `HelpTutorial.caseMapSteps`, `TutorialPath.caseMap`; Help ▸ Replay the Case Map Tutorial; Guide | HelpRegistryTests.caseMapTutorialPath |
| First-use explanation (items, links, review state, what changed) | `CaseMapFirstUse` card above the map; topic `task-case-map-first-use` | CaseMapAccessibilityTests.firstUse, HelpRegistryTests.caseMapContextHelp |
| Context help for every link type, item state and review state | `HelpRegistry.caseMapLinkHelp/StatusHelp/ReviewHelp`, `caseMapContext` topics; shown as text in the inspector and legend | HelpRegistryTests.caseMapContextHelp |
| Legend always available | Footer "Legend" (explanations as text, keys) | HelpRegistryTests.caseMapContextHelp (source check) |
| Keyboard instructions from the Help menu | Help ▸ Case Map Keyboard Shortcuts → `task-case-map-keyboard` (`CaseMapKeyboard.lines`) | HelpRegistryTests.caseMapContextHelp, CaseMapAccessibilityTests.commandTable |
| Reset view resets geometry and filters only, never content | `CaseMapWorkspaceModel.resetView` | CaseMapAccessibilityTests.resetViewNeverChangesContent (records, links, saved views, decisions, six case tables unchanged) |
| Empty states name the next action; errors give one action and keep unsaved work | `CaseMapEmptyState`, `Retry` / "Try again" / "Dismiss" | CaseMapAccessibilityTests.emptyStates, .failedSaveKeepsWork |
| Nothing vital hover-only | Link/state help as text in inspector and legend; search panel "Mark as seen" and saved-search semantics as text | source checks only |
| Keyboard/list parity for every map command | `CaseMapCommand` table (list surface, controls, shortcut) | CaseMapAccessibilityTests.commandTable, .listPathRunsTheSameCommands |
| VoiceOver labels on items, links, counts, view strip | `CaseMapSpoken` used by canvas children, list rows, header counts, strip buttons | CaseMapAccessibilityTests.spokenText |
| Reduce Motion | `.transaction` disables animations; `CaseMapMotion` | CaseMapAccessibilityTests.motionAndNarrowLayout |
| Narrow layout: inspector becomes a drawer, sized from a GeometryReader | `CaseMapWorkspaceLayout` (drawer below 860 pt, ⌃⌘I) | CaseMapAccessibilityTests.motionAndNarrowLayout |
| List paging; every record reachable | `CaseMapListPaging` (500 per page, "Show more") | CaseMapAccessibilityTests.listPaging; stress run (86 pages, all reachable) |
| Performance harness (env-gated `CASE_MAP_PERF=1`) | `KalsmritikoshTests/CaseMapPerfHarnessTests.swift`, `scripts/case-map-perf-from-console.py` | `docs/evidence/case-map-perf-2026-11-07/` (normal + stress, JSON + markdown) |
| Base-case journey with optional packs and Online off | `KalsmritikoshTests/BaseCaseJourneyTests.swift` | BaseCaseJourneyTests, BaseCaseMultiDayTests (§12 days 3, 4, 6), BaseCaseLapsedBoundaryTests |

## Performance (2026-11-07, Debug test host, model level, not on-screen rendering)

| Measurement | normal (500 docs / 2,001 records / 3,000 links) | stress (5,000 docs / 50,001 records / 47,950 links) |
|---|---|---|
| Projection load cold | 232 ms (target ≤ 3 s: met) | 10,456 ms (no timing target) |
| Projection load warm p50 | 194 ms (target ≤ 1 s: met) | 9,330 ms |
| View switch p50 / p95 | 1.9 / 2.3 ms (≤ 150 ms: met) | 40.6 / 73.0 ms |
| Local filter p50 / p95 | 8.4 / 8.8 ms (≤ 150 ms: met) | 258 / 267 ms |
| Selection p95 | 0.3 ms (met) | 0.3 ms |
| Viewport cull p50 | 0.3 ms | 15.2 ms |
| Incremental 100 records, reload | 204 ms, 0 moved (≤ 2 s: met) | 9,456 ms, 0 moved |
| Case search (5 queries) | 85–95 ms | 850–932 ms |
| Peak resident memory | 316 MiB | 854 MiB |

## Open items found during M9 (not fixed here)

1. **Confirmed contradiction reported as provisional — FIXED.** `CaseReportItem.isAcceptedReview` now counts
   `confirmed` (only confirmed contradictions are carried by `JobResultHandoff+Review`), so the report lists it under
   "Reviewed results". BaseCaseJourneyTests asserts it directly (the known-issue wrapper is removed).
2. **Stress: "Fit all" showed an empty screen — FIXED.** When the bounds need more than the smallest zoom (0.15),
   `CaseMapLayout.fit` now shows the start of the map instead of centring on the empty middle; the off-screen count
   and the list disclose and reach the rest (CaseMapFitAllTests). Stress perf not re-measured after the fix.
3. **Stress: full reload takes about 9.5 s.** Each refresh, including the incremental one, reloads the whole
   projection. No stress timing target exists, and 25 times the records took 48 times the time.
   The known quadratic look-ups were made linear in M9, and no profiler run was made.
4. The UI, signed-build and human-evaluation columns above are all NOT RUN.
