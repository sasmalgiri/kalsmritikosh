# AGENT REVIEW — legal / privacy confirmation review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: 06487e9560a140639c566a1e0cc63ceaf3e62295

This is an agent review, not a lawyer's opinion or sign-off. It is read-only. I read the code and the documents. I did not
build, run tests or use the app.

- **Candidate:** `06487e95` on `investigations-next`. The working tree differs only in Xcode-extracted `InfoPlist.xcstrings`
  and user metadata.
- **Baseline:** `candidate-review-e3ac8bf8-legal-privacy.md` (APPROVED; should-fix LS19–LS22; carried LN4, LN6, LS6, LS10).
- **Diff reviewed:** `git show 06487e95` (13 files). Code: `CaseErasure.swift` (person erasure), two module texts in
  `ProductModule.swift`, one in `KnowledgeModule.swift`, one help note in `HelpRegistry.swift`. Tests: `CaseErasureTests`
  (two new tests), `CaseMapHistoryTests` (flaky check fixed). Documents: DATA_FLOW_INVENTORY, THREAT_MODEL T16, USER_MANUAL,
  MODULE_MATRIX, CAPABILITY_INVENTORY, the e3ac8bf8 review and the gate record.
- **Method:** read the person-erasure function in full against the v171–v173 schema and triggers
  (`SchemaMigrations.swift` v171–v173), the new tests, and every changed document line.

**Verdict: APPROVED.** No blocker. The commit adds no network, sending, consent or preference path. It only widens
person erasure and corrects text.

## Should-fix items from e3ac8bf8

| Item | Status | Evidence |
|---|---|---|
| LS19 person erasure misses map free text | **Fixed** | See the code check below. |
| LS20 L3/L12 defaults out of date | **Fixed** | DATA_FLOW L3 now says Share/Services capture is core and on unless switched off, with Continuity Camera behind `captureExtensions` (off). L12 now says `sendToDevonthink` is off on new installs, and that older installs which never chose keep "on" through `ModuleScopeMigration`. |
| LS21 checkpoint residue of forgotten documents | **Fixed** | Disclosed in DATA_FLOW v173 ("Residue of forgotten documents"), THREAT_MODEL T16 residual risk, the history help note and USER_MANUAL. All four say the text stays in `payload_json` and in backups until a case, person or full erasure. |
| LS22 "previewed" module texts | **Fixed** | `leastDataOnline.whenOff`, `onlinePIIMasking.whenOff` and `onlineRecordReading` now state the per-case permission. They say sends are logged, and that sends outside an allowed case are previewed. No "previewed" claim is left in either module file. MODULE_MATRIX and CAPABILITY_INVENTORY were regenerated. |

## LS19 code check (`Personas/Investigator/CaseErasure.swift`, `erasePerson`)

- **Terms.** `nameTerms` holds the name plus every `alias_normalized`, trimmed, with terms of one character or less dropped.
  `personIDs` holds the lower-cased `case_people` ids. Both are read before the aliases and case-person rows are deleted
  further down, so the order is correct. `historyTerms` is `nameTerms` plus `personIDs`. It is used only for the history
  tables, which is right: the ids appear only in recorded content.
- **Matching.** `names(_:_:)` uses `range(of:options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`.
  Foundation compares canonically equivalent strings as equal, so composed and decomposed forms match. This fixes the
  ASCII-only `lower()` gap for these tables. The test covers accents, case, decomposed forms and Cyrillic, and checks that a
  different name does not match.
- **Checkpoints.** Rows that are not yet erased and whose `name`, `payload_json` or `manifest_json` name the person become
  stubs:
  - the content is cleared;
  - the digest becomes `erased`;
  - a non-null name is replaced with "Recorded state (content erased)", which keeps the milestone `CHECK` on a non-empty
    name true;
  - `erased_at` and `erased_reason` are set.

  The `case_checkpoints_fixed` trigger allows this update only while the `ledger_person_erase` marker exists, only on a
  row not yet erased, and only when `id`, `case_id`, `kind`, `fence`, `recorded_at` and `recorded_by` stay the same. The
  update keeps all six, so it matches what the trigger allows. Checkpoints are never deleted, which is consistent with
  `case_checkpoints_kept`.
- **Revisions.** Rows whose before/after JSON names the person are deleted, together with every `record_kind = 'person'`
  row for their case-person ids. This is done while the marker exists (`case_record_revisions_kept`). The marker is then
  removed, and a test confirms it is gone. If the erasure throws, the savepoint rolls back the marker with everything else.
- **Saved views and searches.** `case_map_views` rows are deleted whole when `name` or `filters_json` names the person.
  `case_saved_searches` rows are deleted whole when `name`, `query_text` or `result_json` names the person. This includes
  frozen receipts: the receipt trigger blocks only UPDATE, not DELETE. The only consumer of `case_map_views` is
  `CaseMapRepository`, which lists views by case. A stale view id left in preferences then simply finds no row.
- **Kept and reported.** Link `rationale` and `withdrawn_reason` on links between other records are kept (the
  `case_map_links_fixed` trigger forbids edits), and so are the names of stubs erased earlier. Both are counted into
  `stillNamedIn`. This runs after the deletions, so links on the person's own rows are already gone and are not counted. A
  read failure is logged through `KalsmritikoshLog` and the report is still returned.
- **Bindings.** Ids are read back as text and bound again in chunks of 400. The test confirms that `.uuid`-written ids
  round-trip. Table and column names are literals, not user input.

## New items (none blocking)

- **LS23 (should-fix):** the A5 "still named in" inventory still matches with SQLite `lower()`, which folds ASCII only. This
  covers studio drafts, saved answers, topics, conversation turns and `documentsStillNaming`. For a non-ASCII name written
  in another case or without its accents, the report can undercount what is kept. Nothing is wrongly erased. DATA_FLOW
  correctly limits the any-script claim to the case-map, saved-search and history tables. Use `names(_:_:)` there too, or
  state the limit in the erasure report text.
- **LN7 (note):** `matchingIDs` reads `payload_json` and `manifest_json` for every unerased checkpoint, in all cases, in
  one query inside the savepoint. On a large ledger this costs memory and time, but it is not a privacy problem.
- **LN8 (note, existing behaviour):** a two-character alias matched as a substring can over-match. It can stub unrelated
  checkpoints or delete unrelated saved views or searches. This is over-erasure, it is counted in the report, and the old
  `instr` path did the same.
- LN4, LN6 and the owner steps LS6 and LS10 carry over unchanged.

If the uploaded commit is not 06487e95, re-point the gate record after a confirmation review.
