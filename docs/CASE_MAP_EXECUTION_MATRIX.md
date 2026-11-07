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
| M1 — case projection | 6132dab9; O(n) look-ups added in M9; reload speed (fence, link ids, incremental journal + memo) uncommitted on 2108ca5f | CaseMapProjectionTests 12/12 (2026-11-07, incl. 3 new M9 reload tests) | NOT RUN | NOT RUN | NOT RUN |
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

Before: build 1c1ac37b (`docs/evidence/case-map-perf-2026-11-07/case-map-perf-*-before.*`). After: the uncommitted
reload-speed change on top of 2108ca5f (`case-map-perf-normal.*`, `case-map-perf-stress.*`; the files' `build_sha` names
2108ca5f, the base of the uncommitted tree). Same Apple M4 Mac. The after run shared the machine with other work: the
timings the change did not touch (view switch, local filter, case search) read about 1.5–2× slower than in the before run,
so the after numbers are if anything pessimistic.

| Measurement | normal before | normal after | stress before | stress after |
|---|---|---|---|---|
| Projection load cold | 232 ms | 338 ms (≤ 3 s: met) | 10,456 ms | 3,558 ms |
| Projection load warm p50 (same service) | 194 ms | 154 ms (≤ 1 s: met) | 9,330 ms | 956 ms |
| Projection load warm p50, new service (nothing remembered) | — | 209 ms | — | 1,969 ms |
| Incremental 100 records, reload | 204 ms, 0 moved | 169 ms, 0 moved (≤ 2 s: met) | 9,456 ms, 0 moved | 1,177 ms, 0 moved |
| View switch p50 / p95 | 1.9 / 2.3 ms | 5.0 / 8.2 ms (met) | 40.6 / 73.0 ms | 45.2 / 106.2 ms |
| Local filter p50 / p95 | 8.4 / 8.8 ms | 17.9 / 19.8 ms (met) | 258 / 267 ms | 319 / 361 ms |
| Selection p95 | 0.3 ms | 1.4 ms (met) | 0.3 ms | 0.5 ms |
| Viewport cull p50 | 0.3 ms | 1.0 ms | 15.2 ms | 20.7 ms |
| Case search (5 queries) | 85–95 ms | 182–239 ms (machine load; search not changed) | 850–932 ms | 1,414–1,709 ms |
| Peak resident memory | 316 MiB | 260 MiB | 854 MiB | 646 MiB |

Growth now: a fresh warm load at 25× the records takes 9.4× the time (was 48×). An earlier mid-size profiling run
(1,500 documents, ~15,000 records, quiet machine) measured warm 1,590 ms before and 292 ms after.

What was slow and what changed (profiled per stage with `CaseMapPerfHarnessTests.stages`, now part of the harness output):
1. **The revision fence was quadratic.** Its "versions of the case's documents" part joined `source_versions` to the
   case's sources with `s.source_ref IN (v.id, upper(v.id), lower(v.id))`, which SQLite runs as a scan of every version
   per case source (query plan `SCAN v`): 422 ms per fence at 1,500 documents, about 4.5 s at 5,000, read twice per
   load — nearly all of the 9.3 s. It now drives from the case's sources into `source_versions` by primary key
   (`v.id IN (s.source_ref, upper(s.source_ref), lower(s.source_ref))`, plan `SEARCH v USING INDEX`); the same pairs
   match. 422 → 6 ms (mid-size), 17 ms at stress. The case change feed had the same subquery and was changed the same way.
2. **Link ids were formatted one byte at a time with `String(format:)`.** Same lower-case hex, built from a table
   (`CaseMapProjectionTests.linkIDEncodingUnchanged` pins the old encoding).
3. **Refresh reads only what changed in the journal and reuses what did not change.** `CaseMapJournalCache` (live
   sources) re-reads only chronology rows written since the last read, after checking in one savepoint that the earlier
   rows' digest (number, verification and its time and detail, removal, review state, citations) is unchanged; any
   difference reads the journal whole. The projector reuses each unchanged entry's item and links
   (`CaseMapProjectionMemo`: same entry, same verification marks, same superseded state, same case documents), keeps the
   previous order for items still present and merges only new ones in, and groups in one pass. The map's snapshot no
   longer reads the action log, contacts, credibility notes, holds, redactions, batches or conflict checks (the map shows
   none of them). The result is identical to a read from scratch: the harness and
   `CaseMapProjectionTests.incrementalRefreshMatchesFullRead` / `documentChangeRebuildsEntries` compare nodes, links and
   groups with a fresh service's load.

Still not proportional to the change at stress size: a refresh with 100 new records takes about 1.2 s, because the
rest of the case (documents, grid rows, people) is read and projected again, the stored layout is read whole (95 ms) and
the projection's indexes and groups are rebuilt over all 50,000 items. A cold load (3.6 s) stores 50,000 positions one
row at a time. These are linear costs, not quadratic ones. No stress timing target exists. Release-build and on-screen
timings are NOT RUN.

## Open items found during M9 (not fixed here)

1. **Confirmed contradiction reported as provisional — FIXED.** `CaseReportItem.isAcceptedReview` now counts
   `confirmed` (only confirmed contradictions are carried by `JobResultHandoff+Review`), so the report lists it under
   "Reviewed results". BaseCaseJourneyTests asserts it directly (the known-issue wrapper is removed).
2. **Stress: "Fit all" showed an empty screen — FIXED.** When the bounds need more than the smallest zoom (0.15),
   `CaseMapLayout.fit` now shows the start of the map instead of centring on the empty middle; the off-screen count
   and the list disclose and reach the rest (CaseMapFitAllTests). Stress perf not re-measured after the fix.
3. **Stress: full reload took about 9.5 s — FIXED (see Performance).** The cause was the quadratic revision-fence
   query, read twice per load. Warm reload at stress is now 956 ms (same service) / 1,969 ms (new service), the
   incremental 100-record refresh 1,177 ms. A refresh is still linear in the case size, not proportional to the change.
4. The UI, signed-build and human-evaluation columns above are all NOT RUN.
