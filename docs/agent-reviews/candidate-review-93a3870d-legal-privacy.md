# AGENT REVIEW — legal / privacy confirmation review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: 93a3870ddd0a6020559b038af4baf9560b51a294

This is an agent review, not a lawyer's opinion or sign-off. It is read-only. I read `git show 93a3870d` and the files it
touches (plus the call sites they depend on). I did not build, run tests or use the app.

- **Candidate:** `93a3870d` on `investigations-next`. The working tree differs only in Xcode-extracted `InfoPlist.xcstrings`
  and user metadata.
- **Baseline:** `candidate-review-54ed48b9-legal-privacy.md` (APPROVED; should-fix LS24; note LN9; carried LN4, LN6, LN8,
  LS6, LS10).
- **Diff reviewed:** 12 files: schema v174 (`SchemaMigrations.swift`), `ConversationsRepository.swift`,
  `AnswerLedgerRepository.swift`, `AppState.swift`, `AppState+Erasure.swift`, `CaseErasure.swift`, `AskView.swift`,
  `HelpRegistry.swift`, `DATA_FLOW_INVENTORY.md`, `USER_MANUAL.md`, `CaseAskConversationTests.swift`,
  `MigrationMatrixTests.swift`.

**Verdict: APPROVED. LS24 is fixed.** No blocker and no new should-fix. The diff adds no network call, send path, consent
change or new preference. Two new notes (LN10, LN11).

## LS24 — case scoping

| Check | Result | Evidence |
|---|---|---|
| Schema | OK | v174 is a new migration: `ALTER TABLE conversations ADD COLUMN case_id TEXT` plus an index. No shipped migration was edited. Existing rows get `NULL`, so they stay library conversations. The test `migrationKeepsOldConversationsInLibrary` covers a v173 → v174 upgrade. |
| Opening Ask | OK | `loadOrCreateConversation` → `resumeOrCreate(caseID: caseScope?.caseID)` → `recent(limit: 1, caseID:)`, which filters `WHERE case_id IS ?`. With a case, only that case's conversations match. With no case, `IS NULL` matches only library ones. Otherwise a new conversation bound to the same scope is created. `.task(id: caseScope?.caseID)` reloads on a case switch and clears the cached answers, passages and general-knowledge blocks. |
| History list, new conversation | OK | `loadHistory` and `startNewConversation` pass the same `caseScope?.caseID`. |
| Writes | OK | `submit` captures `convID` before the async work, and `caseScope` is a `let` on the view value captured by the task. Turns go to the conversation the question was asked in. The saved answer is stamped `origin_scope_id = case` through `recordAnswer(…, originScopeID:)`. The case answering path (`InvestigationAnswerService`) already stamped its own answer with the case id (since v118). Both stamps use the same `.uuid` binding as the erasure query. |
| Other conversation callers | OK | `AskView` is the only user of `ConversationsRepository`. No other code enumerates `case_id` tables, so adding the column does not pull conversations into any export or share path. The only such enumeration is case erasure. |

## LS24 — erasure

- **Order.** The hold and hold-notice check (step 1) runs first and throws `Refused` before anything is written.
  `eraseCaseAsk` runs in step 3 inside the same erasure transaction as the rest. Any thrown error rolls everything back
  ("Nothing was deleted"). The test `holdRefusesCaseAskErasure` checks that a held case keeps its conversation, all
  6 turns and its answers.
- **What goes.**
  - The case's answers: rows with `answers.origin_scope_id = case`, plus any answer linked from a turn of the case's
    conversations. This covers refused and not-found answers and answers citing shared documents.
  - Each answer's children, through `eraseAnswers`: `conversation_turns.answer_ledger_id`, `answer_revision_events`,
    `answer_revisions`, `answer_claims`, then `answers`. These tables also have `ON DELETE CASCADE` to `answers`, and
    `foreign_keys=ON`.
  - All turns of the case's conversations.
  - The conversation rows. Now that `conversations` has a `case_id` column, it is in `caseTables`, so the generic
    case-table pass removes them.
- **Count-back.** The generic pass recounts `conversations WHERE case_id = ?`. `askLeft` recounts the case's turns and
  answer ids. Any row left throws and rolls back.
- **What is kept.** The deletes are keyed only on this case's id, on its conversation ids, or on answer ids found from
  them. Library conversations (`case_id IS NULL`) and other cases' conversations are not selected. One answer row is
  linked from one turn, so deleting by `answer_ledger_id` cannot reach a library turn. The test
  `caseErasureRemovesCaseAsk` checks this: after erasure, the library conversation, the library answer and case B's
  conversation and answer are still there. The pre-existing removal of library answers that quote exclusive documents
  ("remove documents only this case used") is unchanged and was already disclosed.
- **Report.** `answersRemoved` is now the case's Ask answers plus the existing derived-prose count. The removed turns
  are counted in `rowsErased["conversation_turns"]`, and the erasure record holds counts, not text (the test checks that
  the record JSON has no answer text).

## Wording

- **Erasure report** ("saved answer(s) asked in this case or quoting the erased documents were removed"): accurate. The
  count covers both sources.
- **Help and user manual** ("erasing a case also removes the questions asked in it and every answer given there …
  Questions asked across the whole library or in another case are kept"): accurate for every question asked in a case
  from v174 on. See LN10 for questions asked before.
- **DATA_FLOW**: accurate, and it states the pre-v174 rule explicitly ("every conversation saved before v174" is a
  library conversation).
- **Privacy policy, terms and store listing:** no update needed. Retention is now shorter, not longer, and there is no
  new data type, recipient or send path.

## New items (none blocking)

- **LN10 (note): questions asked in a case before v174 are not treated as case questions.**
  - **What survives.** Conversations saved before v174 become library conversations. Their turns survive case erasure,
    and so does any answer saved by Ask's own save path, which did not stamp the case before this commit. The help
    sentence says this without qualification. DATA_FLOW states it.
  - **Why it is only a note.** Ask inside a case arrived with the unreleased navigation merge (54ed48b9), and no build
    has shipped. Only test ledgers can hold such rows. If a released ledger ever predates v174, add "from this version
    on" to the help sentence.
- **LN11 (note): a case answer still in progress when its case is erased.**
  - **What can happen.** Suppose the case is erased while a case answer is being written (a slow AI reader). The turn
    append and link then fail, because the conversation is gone and foreign keys are on. These errors are swallowed by
    `try?`. But `recordAnswer` and the case answering service could still save an answer stamped with the erased case
    id, after the erasure. It would sit in the whole-library answers list.
  - **Why it is only a note.** This is narrow and on-device. A later "erase everything" removes it.
  - **Optional fix.** Skip saving the answer when the case no longer exists.
- LN9 (journal digest), LN4, LN6, LN8 and the owner steps LS6 and LS10 carry over unchanged.

If the uploaded commit is not 93a3870d, re-point the gate record after a confirmation review.
