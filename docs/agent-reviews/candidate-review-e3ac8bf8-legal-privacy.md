# AGENT REVIEW — legal / privacy re-review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: e3ac8bf83b2d5367ada83014e29a6c6b964c09a4

This is an agent review, not a lawyer's opinion or sign-off. It is read-only. I read the code and the documents. I did not
build, run tests or use the app.

- **Candidate:** `e3ac8bf8` on `investigations-next`. The working tree differs only in Xcode-extracted `InfoPlist.xcstrings`
  and user metadata.
- **Baseline:** `candidate-review-06e4b3a9-legal-privacy.md` (APPROVED; should-fix LS17, LS18; carried LN4, LN6, LS6).
- **Diff reviewed:** `git diff 06e4b3a9..e3ac8bf8` (124 files, 6 commits). It contains:
  - `68addaa4` LS17/LS18;
  - `a87f2c4d` scope package S;
  - `6132dab9`, `a5b8c78b`, `1c1ac37b`, `e3ac8bf8`: Living Case Map M1–M9, schema v171–v173.
- **Method:**
  - Read the migrations v171–v173, `CaseErasure.swift` (case, person and source erasure), the full-erase path in
    `AppState.swift`, `CaseOutputService.prepareMap`, `CaseMapExportRoutes.swift`, `CaseHistoryRepository.swift` (the checkpoint
    payload, rebuild and write), `CaseWorkspace.swift`, `ModuleScopeMigration`/`ModulePreset`, the Share-capture change, and
    the reworded trust and priority surfaces.
  - Grepped every added line in the product for `UserDefaults`/`AppDefaults`, logging, `URLSession`, pasteboard, print,
    save panels and `Task.detached`.
  - Scanned the added help, manual, listing and module copy for accuracy, culpability, "100 %", "never leave" and preview
    claims.
  - Read the DATA_FLOW_INVENTORY v5, OUTPUT_ROUTES_INVENTORY routes 42–46 and THREAT_MODEL T16 changes.

**Verdict: APPROVED.** I found no blocker. The diff adds no network, sending or consent path.

- **Ledger only.** Every new kind of case content is in the encrypted ledger: saved map views and their search words, map
  links and their reasons, saved searches, before/after revisions, checkpoints and the seen position. The preference
  addition holds only identifiers and geometry, under the existing per-case key that both erasures already clear.
- **Erasure.** Case and full erasure reach every new table generically, by its `case_id` column or by table enumeration.
  Person erasure covers the new tables by explicit steps.
- **Checkpoints.** Their triggers allow a delete only during a case or full erase, and an update only to clear content
  during a person erase. A late write checks again that the case still exists.
- **Map export.** Every map export goes through `CaseOutputService.prepareMap` → `prepareData` (revalidate, scrub, leak
  check, record).
- **Defaults.** No preset, pack, migration or the preview switch turns on Online, Spotlight, sync or monitors.
- **Copy.** The reworded copy removes claims rather than adding them.
- **Should-fix.** Four new items, none blocking (LS19–LS22).

## LS17 / LS18 (from the 06e4b3a9 review) — fixed

| # | Status | Evidence |
|---|---|---|
| LS17 | **Fixed** | `docs/sop-register.html:63` now says "Online mode is opt-in, no case document goes to the AI until you allow it for that case, and every send is logged" (the mirrored register text was changed with it). |
| LS18 | **Fixed** | The `ProductModule` `onlineAnswers` detail now says "No case document is sent until you allow AI for that case (questions inside an allowed case go without a further prompt), every send is logged …". |

## Privacy checks

| Check | Result | Evidence |
|---|---|---|
| New case content only in the encrypted ledger | **Yes** | v171 `case_map_views` (name, `filters_json` with search words), `case_map_layout`, `case_map_links` (rationale); v172 `case_saved_searches` (`query_text`, `result_json`); v173 `case_record_revisions`, `case_checkpoints`, `case_change_seen`, `case_history_install` (one time, no content) — `Storage/Schema/SchemaMigrations.swift`. |
| Nothing new in UserDefaults that holds content | **Yes** | `CaseMapWorkspaceMemory` (`Investigate/CaseFile/CaseWorkspace.swift`) holds the view id, list/map flag, `CaseMapNodeID` (case UUID + kind + record id), link digest id, viewports (scale/origin), and hidden/collapsed ids. It has no names, quotes, view names or search words, and it sits under the existing `kalsmritikosh.case.workspace.<case id>` key that case and full erasure already clear. The other new keys are `kalsmritikosh.caseMap.preview` (bool), the case-map first-use flag (bool), the tutorial path (enum raw value) and `kalsmritikosh.product.scopeRevision` (int). `CaseSearchModel` and `CaseSearchPanel` write nothing to preferences. |
| Nothing new in logs that holds content | **Yes** | Every new log line is a fixed message plus `error.localizedDescription`, a count or a fixed refusal reason. No query text, view name, link reason or checkpoint name is logged. `CaseSearchLive.swift:86` logs the `unresolvedReference` reason as public. That reason concerns a source reference, which L14 already discloses (file names are logged as public). |
| Case erasure covers the new tables | **Yes** | `CaseEraser.eraseCase` deletes every table with a `case_id` column, apart from the erasure records (`CaseErasure.swift:168-206`), and checks afterwards that nothing is left (`:228`). All v171–v173 content tables carry `case_id`. The delete triggers stand aside for `ledger_case_erase` of that case. A legal hold refuses the erasure before anything is removed. Tests: `CaseErasureTests.caseEraseCoversMap`, `.caseEraseCoversSavedSearches`, `CaseMapHistoryTests.caseErasure`. |
| Full erasure covers the new tables | **Yes** | The full erase enumerates every table (`AppState.swift:4381`) under `ledger_full_erase`, which every new trigger honours. The workspace preference prefix is cleared as before. Tests: `fullEraseCoversMap`, `fullEraseCoversSavedSearches`, `CaseMapHistoryTests.fullErasure`. |
| Person erasure covers the new tables | **Yes, with a gap (LS19)** | `CaseErasure.swift:357-403`: checkpoints whose payload names the person, an alias or their case-person row id are cleared to a stub. Revisions of their case-person rows, and revisions naming them, are deleted. Map layout and links on their rows are deleted, and so are saved searches whose words or results name them. Not covered: saved map views, link reasons on other records and milestone names (LS19). |
| Checkpoints cannot bring back erased content | **Yes for case, person and full erasure** | The checkpoint `BEFORE UPDATE` trigger allows only the person-erase clearing (`erased_at` set once, never unset). `BEFORE DELETE` allows only a case or full erase. A write checks again that the case exists ("late work cannot recreate an erased case's history", `CaseHistoryRepository.swift:434`), tested by `CaseMapHistoryTests.eraseDuringLoad`. History is read-only and has no "restore to this state" path. A retained version that is no longer in the ledger is shown as unavailable, never replaced (`:133-151`). One residue is not covered by erasure: content of documents that were later forgotten (LS21). |
| Backup | **Covered** | The new tables travel as part of the ledger. `CompleteBackupTests.caseMapStateRoundTrip` and `.savedCaseSearchRoundTrip`, and `CaseMapHistoryTests.restoreToNewLedger`, check the round trip. The diff does not change backup or restore semantics. |
| Map export, copy and print go through the output service | **Yes** | `UI/CaseMapExportRoutes.swift` is the only route. Each entry calls `prepareMap` → `prepareData`, which revalidates citations against today's export policy, scrubs protected identities, re-checks for leaks and states the current holds (`CaseOutputService.swift:276-330`). Release goes through `outputs.write` / `outputs.release`, and is recorded as `caseMap` in `case_document_outputs`. A cancelled panel records nothing. A historical export is labelled as such. The PNG goes with a second CSV package, and when the person declines the CSV the result says so. `CaseMapHistoryTests.noCanvasBypass` scans the sources. Routes 42–46 are added to `OUTPUT_ROUTES_INVENTORY.md`. |
| Preview switch and module-default migration never turn on Online/Spotlight/sync/monitors | **Yes** | `CaseMapPreview` is a single bool that defaults to off. `ProductModule.neverSwitchedOnAutomatically = [.onlineAnswers, .spotlightIndex, .folderSync, .questionMonitors]` (`ProductModule.swift:636`). `ModuleScopeMigration.run` skips these even when it restores an old default (`:764`), and changes only DEVONthink import/send, the coverage badge and the notes defaults, for unset keys on earlier installs. `ModulePreset.modules` and `standalone` filter the same set out (`:810`, `:847`). `ModuleInvariant.presetsOnlySwitchOn` and `perCaseAIConsent` are stated as non-switchable. |
| Share-menu capture now core | **Acceptable; inventory stale (LS20)** | `shareMenuCaptureAvailable = explicitChoice(.captureExtensions) ?? true` (`ProductModule.swift:725`). Capture is a local action the person starts in another app. It does not use the network, and `privacy.html:155` already describes it without an "off by default" claim. `DATA_FLOW_INVENTORY.md:46` still says "off by default". |

## Claims checks

| Check | Result | Evidence |
|---|---|---|
| Review priority: no accuracy or culpability claim | **Yes** | `RiskScoring.swift` is documents only. The UI shows "Review priority: <signals>" and never a number. The module text says "It orders reading only; it never scores or ranks people and says nothing about anyone's conduct." The help lists it as "Order by review priority" for documents. |
| Source counts: no accuracy claim | **Yes** | `CorroborationMeter.swift`: "N documents cited · M distinct origins after copies". The dependence note says "Distinct origins are not proven independent…". The review state says "Not assessed by you yet — open each source and judge it". The green "corroborated" colour and icon are removed (`AnswerTrustPanel.swift`). |
| Archive self-score not user-facing | **Yes** | The `calibratedNote` line under answers is removed (`AnswerTrustPanel.swift`). It remains only as a diagnostic in Settings ▸ Advanced, as module `.internal`, with the text "a consistency check, not a measure of real-world accuracy; nothing is shown with answers" (`SettingsView.swift:544-565`). |
| "Filter by document date": no replay claim | **Yes** | "Documents dated on or before". The text adds "A file date is not when anyone learned of it." A refusal reads "No document dated on or before that day supports an answer." |
| No "100 % correct"-style claims; Private-mode qualifiers kept | **Yes** | The added help, manual, module and listing lines contain no accuracy, guarantee, "court-ready" or unqualified "never leave" wording. The listing keeps "Without AI, nothing leaves your Mac … With an AI plan or your own Anthropic key, the documents of a case you allow go to Anthropic". The new map help says "reads this Mac's ledger only: nothing is sent anywhere", which is true: the map code has no network path. |
| Listing / SHIP_DECISIONS: no entitlement revoked, no paywall | **Yes** | `SHIP_DECISIONS.md` §5 2026-11-06 says "no entitlement revoked, no new paywall, no price or plan changed". `ModuleEntitlement` is `.none` for everything except `onlineAnswers` (`ProductModule.swift:591`, unchanged in effect). The diff does not touch purchase, StoreKit or paywall files. The listing's Workbench line widens ("the whole investigation workflow, every optional tool and all personas"). Retired surfaces keep saved work reachable. |
| App Review 2.1 / 2.3 / 3.1.1 / 3.1.2 / 5.1.2(i) | **Consistent** | 2.1: the map is an opt-in preview switch, off by default, and the tabbed view is unchanged; no hidden or dead feature is advertised. 2.3: the listing describes the core workflow and names the specialist tools that exist (Bates, email forensics, watchlists), and the job count was dropped. 3.1.1 / 3.1.2: no IAP, price or subscription change. 5.1.2(i): no new collection or sharing; all new data stays on the device. |

## Data documents

| Document | Result |
|---|---|
| `docs/DATA_FLOW_INVENTORY.md` | **Updated** (v5): v171/v172/v173 paragraphs, map export, person erasure, and the L15 map preference fields ("No item names, quotes, view names or search words"). Stale in L3/L12 (LS20). Missing the forgotten-document residue (LS21). |
| `docs/OUTPUT_ROUTES_INVENTORY.md` | **Updated**: routes 42–46, plus a known-gaps note on PNG/CSV and the bypass scan. |
| `docs/THREAT_MODEL.md` | **Updated**: T16, including the residual that a recorded state keeps the display text of later-edited investigator records. |
| `release/APP_PRIVACY_LABEL.md` | **No change needed.** Every new data type stays on the device in the encrypted ledger and is not collected under Apple's definition. Nothing new is sent off the device. The existing declaration (content sent to AI collected, not linked, not tracking, App Functionality) is unaffected. |

## Should-fix (none blocking)

| # | Finding | Evidence |
|---|---|---|
| LS19 | Person erasure misses three new free-text fields that can name the person: a saved map view's `name` and `filters_json` (which holds search words); `case_map_links.rationale` on links that do not touch their case-person row; and a milestone checkpoint's `name` (the clearing matches `payload_json` only and leaves `name`). None of these is erased, and none is listed in the "still names them" inventory (`stillNamedIn`), which reports only studio drafts, answers, topics and turns. This is the same class as older case free text (allegation and note text, also not inventoried), so it is not a new kind of failure. But the v172 saved-search fix shows the intended standard. Fix: apply the same name/alias `instr` match to `case_map_views.name`/`filters_json` (delete, or clear the words) and to `case_checkpoints.name`, and add `case_map_links` rationale (and preferably the older case text tables) to the inventory. The name match uses SQLite `lower()`, which folds ASCII only, so a non-ASCII name in a different case is missed. Consider matching on the `alias_normalized` form as well. | `Kalsmritikosh/Personas/Investigator/CaseErasure.swift:395-403` (steps), `:368-373` (checkpoint clearing), `:430-438` (inventory) |
| LS20 | The data-flow inventory is stale after package S. L3 says capture is "`captureExtensions` off by default", but Share-menu capture is now core and on unless the person switched it off. L12 says DEVONthink hand-off is "module on by default", but new installs now have it off and earlier installs keep their old value. Neither is a new risk, but this file is "the one source for privacy statements". | `docs/DATA_FLOW_INVENTORY.md:46`, `:55`; `ProductModule.swift:725`, `:742-745` |
| LS21 | A checkpoint keeps the document names and quoted passages of the sources it cited (`CaseCheckpointPayload.Source.documentName/quote`). When a document later leaves the ledger by another route ("Stop and forget" a folder), the history view hides the words and names the version "Retained version no longer available". The text itself stays in `payload_json`, and in backups, until a case, person or full erasure. Existing case records (report items, entries) already keep quotes the same way, so this is disclosure, not a regression. Fix: say so in the DATA_FLOW v173 paragraph and in T16's residual column. T16 currently names only "later-edited investigator records". | `Kalsmritikosh/Investigate/CaseFile/CaseHistoryRepository.swift:52`, `:133-151`; `docs/THREAT_MODEL.md` T16; `docs/DATA_FLOW_INVENTORY.md:102` |
| LS22 | Two module texts in Settings ▸ Modules still say sends are previewed. "Send the least data" off: "still previewed and logged". "Mask personal details" off: "Passages are sent unmasked, still previewed first." Inside an allowed case there is no further preview (same class as LS18). Both texts predate this diff. Suggest "… logged; outside an allowed case, previewed first". | `Kalsmritikosh/App/Modules/ProductModule.swift:178`, `:359` |
| LN4, LN6 | Carried over, unchanged. | `CaseErasure.swift` legacy full-copy match; `OnlineCloudProvider.swift` untagged fallback |
| LS6, LS10 | Owner steps, carried over: confirm the Anthropic and Google retention figures on submission day, and name the uploaded commit in `docs/RELEASE_CANDIDATE.md`. | `docs/privacy.html`; `docs/RELEASE_CANDIDATE.md` |

## Notes (no action required)

- **Export.** A historical map export revalidates today's policy. A source that has since been set aside or marked
  privileged refuses the export. In-app history still shows what was recorded, by design (T16).
- **Share-capture default.** Earlier installs that never touched `captureExtensions` now get Share-menu capture. The
  person has to start each capture in another app, and the text tells them how to switch it off.
- **Not run.** The GUI walk, the signed build and the export dialogs were not exercised (`docs/CASE_MAP_EXECUTION_MATRIX.md`
  says NOT RUN). This review does not depend on them.

## Conditions

- **Commit.** This approval names `e3ac8bf8`. `scripts/release_check.py` passes the `legal-privacy` gate only when the
  candidate commit equals the `Commit:` field.
- **Later commits.** If a later commit is uploaded, the record must be re-pointed to it. That includes a commit that only
  adds these review files or the LS19–LS22 fixes. A copy-only or docs-only change needs only a one-line confirmation. An
  LS19 code fix needs a short confirmation of the person-erasure path.
- **Full re-review.** Re-run this review in full if a later commit changes sending, consent, erasure, preferences that hold
  case content, the output service, or the public privacy text.
