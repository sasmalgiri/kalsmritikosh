# AGENT REVIEW — legal / privacy confirmation review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-08
Commit: 4af12048004f95f394d1cf8613ee04e2f17d4c3d

This is an agent review, not a lawyer's opinion or sign-off. It is read-only. I read `git diff 93a3870d..4af12048 --
Kalsmritikosh` and the code it depends on: `ContradictionsRepository`, `CaseContradictionFinder`, `CaseErasure`,
`AppState+Erasure`, the full erase in `AppState`, the v98/v99 decision tables and `DATA_FLOW_INVENTORY.md`. I did not
build, run tests or use the app.

- **Candidate:** `4af12048` on `investigations-next`. The working tree differs only in Xcode-extracted
  `InfoPlist.xcstrings` and user metadata.
- **Baseline:** `candidate-review-93a3870d-legal-privacy.md` (APPROVED; notes LN10, LN11; carried LN4, LN6, LN8, LN9,
  LS6, LS10).
- **Diff reviewed:** 4 files across commits e2d7b20e, 2379084e, 4d35b4c3 and 4af12048:
  - `Core/Models/Contradiction.swift`: `stableIdentities`.
  - `App/AppState.swift`: one line, `scanForContradictions` inserts stable ids.
  - `Investigate/CaseFile/CaseMapLayout.swift`: `groupCardPoint`.
  - `UI/CaseMapCanvas.swift`: `groupCards`.

**Verdict: APPROVED.** The diff adds no network call, send path, consent change, preference, log of content or schema
change. It has no blocker and no new should-fix. One should-fix found while checking erasure (LS25) is older than this
diff: this diff does not cause it and does not make it worse. One new note (LN12).

## Stable contradiction ids

| Check | Result | Evidence |
|---|---|---|
| New store of content | None | The id is the first 16 bytes of SHA-256 over `archive-scan`, kind, description, the sorted document ids and the sorted claim text (lower-cased, whitespace collapsed), with UUID version and variant bits set. It is held only in memory while computed. What is saved is the same `contradictions` row as before (`INSERT OR IGNORE`, the same columns), with this id instead of a random one. That row already held `claim_a` / `claim_b` in plain text, so the hash reveals nothing the row does not. Nothing new is written to preferences, files or logs: the scan's log line prints counts only (`privacy: .public` on an integer). |
| Where the id goes | Unchanged places | The same places that took the random id: `contradictions.id`, the case decision tables (`investigation_desk_reviews`, `investigation_review_decisions`, `item_id`), case map rows, the change feed, and the per-case workspace preference (as an identifier, DATA_FLOW L15). Each is case-scoped or is the contradictions row itself. The only rows kept after case erasure (`case_erasures`, `studio_erasures`) hold counts and digests, not item ids. |
| Link surviving erasure | No | The hash input includes the two knowledge-object ids. Erasing a document deletes its knowledge objects, and a re-import creates new ids. So a re-imported document produces a different id, and no decision left elsewhere can re-attach to it. Inverting the hash would need the object ids and the exact claim text, which are both in the same encrypted ledger. A 128-bit id from SHA-256 is not a practical way to recover content. |
| Collisions | No privacy effect | The `archive-scan|` prefix keeps these ids apart from the case check's own stable ids (`CaseContradictionFinder.stableID`, kept across rescans). An exact duplicate within one scan is stored once. That means fewer rows, not more. |

## Erasure

- **Full erase.** Unchanged and complete. It deletes every user table, `contradictions` and both decision tables
  included, inside the savepoint, then counts back to zero.
- **Case erasure: decisions.** `investigation_desk_reviews` and `investigation_review_decisions` have `case_id`. They
  are in `caseTables`, so they are deleted with the case and counted back. The append-only trigger on
  `investigation_review_decisions` stands aside only while `ledger_case_erase` holds this case. Because ids are now
  stable, a decision keeps matching its finding across rescans while the case exists. Once the case is erased, no
  decision is left to match. The decision behaviour under erasure is unchanged.
- **Person erasure.** Unchanged by this diff. Decisions are not person rows. A decision note the person wrote is free
  text in a case table, as before.
- **The `contradictions` rows themselves.** No erasure path removed them before this diff, and none does now. See
  LS25. A rescan still deletes every archive-scan row before inserting (`clearKeepingCaseChecks`). An erased document
  produces no finding, so its archive-scan rows still go at the next rescan, exactly as before.

## Case map group cards

`groupCardPoint` and `groupCards` only compute layout. The point is calculated at draw time from the positions already
shown. It is not saved: the canvas property is computed and nothing is written to `case_map_layout` or preferences.
There is no privacy effect.

## Wording

No help, manual, DATA_FLOW, privacy policy, terms or listing text changes, and none is needed for this diff.

## Findings

- **LS25 (should-fix, older than this diff; not caused or worsened by it): contradiction rows outlive the documents
  they quote.** `contradictions` stores both quotes verbatim (`claim_a`, `claim_b`) and the two knowledge-object ids
  (`evidence_a`, `evidence_b`). The table has no `case_id`. Its document columns are not in the list `eraseSources`
  deletes by (`source_version_id`, `logical_source_id`, `file_id`, `source_object_id`, `knowledge_object_id`,
  `object_id`, `source_ko_id`). No trigger or foreign key removes these rows either.
  - **Case erasure with "remove documents only this case used".** Archive-scan rows quoting the erased documents stay
    until the next archive rescan (idle maintenance or Insights). The case check's own rows (`(case check · …)`) are
    kept by every rescan by design, so their verbatim quotes of the erased documents stay indefinitely. They are shown
    in Insights through `open()`. DATA_FLOW says this path removes "every row derived from them", which is not true for
    these rows.
  - **Person erasure.** Its "still named in" inventory does not list contradiction quotes naming the person. Keeping
    them is consistent with "documents are not edited", but the report undercounts.
  - **Fix.** (a) In the exclusive-source step, delete `contradictions` where `evidence_a` or `evidence_b` is one of the
    erased objects, and include that in the count-back. (b) Add `contradictions` `claim_a` / `claim_b` (and the
    description) to the person-erasure inventory. (c) Add a test.
  - **Why not a blocker.** The data stays on the device in the encrypted ledger, and "Delete all my data" removes it. It
    is an existing gap that earlier reviews did not catch, not a regression in this candidate.
- **LN12 (note): rescans now keep decisions attached.** This is intended. A confirm, dismiss or defer recorded in a
  case now stays attached to the same archive finding across rescans, where before it was silently orphaned. A finding
  whose claim text changes gets a new id and has to be reviewed again. Decisions orphaned by earlier rescans stay in
  their case's tables. Those rows are removed by case erasure and full erase, but nothing displays them any more. They
  exist only in unreleased test ledgers.
- LN4, LN6, LN8, LN9, LN10 and LN11, and the owner steps LS6 and LS10, carry over unchanged.

If the uploaded commit is not 4af12048, re-point the gate record after a confirmation review.
