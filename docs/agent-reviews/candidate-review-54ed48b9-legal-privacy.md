# AGENT REVIEW — legal / privacy confirmation review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: 54ed48b94811dd7a4d46d71da1b441b1572e54f4

This is an agent review, not a lawyer's opinion or sign-off. It is read-only. I read the diff and the files it touches.
I did not build, run tests or use the app.

- **Candidate:** `54ed48b9` on `investigations-next`. The working tree differs only in Xcode-extracted `InfoPlist.xcstrings`,
  user metadata and an untracked UI-walk evidence folder.
- **Baseline:** `candidate-review-06487e95-legal-privacy.md` (APPROVED; should-fix LS23; notes LN7, LN8; carried LN4, LN6,
  LS6, LS10).
- **Diff reviewed:** `git diff 06487e95..54ed48b9` (48 files): CI script (`-parallel-testing-enabled NO`), contradiction-finder
  determinism, history time rounding, the regenerated verifier, LS23/LN7 in `CaseErasure.swift`, map speed
  (`CaseFileRepository.journalSince`, `CaseMapJournalCache`, `CaseMapProjectionMemo`, the `forMap` snapshot, the fence and
  change-feed queries), and the navigation merge (`NavigationAreas.swift`, `NavigationMap.swift`, `RootView.swift`,
  `AskView.swift`, `CaseSearchPanel.swift`, `CasesView.swift`, `CaseFileView.swift`, help, onboarding, manual, DATA_FLOW).

**Verdict: APPROVED.** No blocker. The diff adds no network call, no new send path, no consent change and no new
preference that holds content. One new should-fix (LS24) on where questions asked in a case are kept.

## Items from 06487e95

| Item | Status | Evidence |
|---|---|---|
| LS23 "still named in" counts ASCII-only | **Fixed** | `erasePerson` now counts documents (`knowledge_objects.content`), studio drafts, saved answers, topics and conversation turns with `matchingCount` → `scanNaming` → `names(_:_:)` (case-, diacritic- and width-insensitive). No SQL `lower()` prefilter is left. An inventory read failure is now logged through `KalsmritikoshLog` instead of being swallowed by `try?`; the documents count still throws and rolls the erasure back, as before. DATA_FLOW now extends the any-script claim to these counts, which matches the code. The test covers accents, upper case, decomposed forms, a near-miss name and a page boundary. |
| LN7 checkpoint matching reads everything into memory | **Fixed** | `scanNaming` pages by rowid, 256 rows at a time, with the filter ANDed in; only matching ids are kept. Every table it scans is an ordinary rowid table (the schema's three `WITHOUT ROWID` tables are vector/posting tables, not scanned here). |
| LN8 short aliases over-match | Unchanged (note) | Same matcher; over-erasure, counted in the report. |
| LN4, LN6, LS6, LS10 | Carried | Unchanged by this diff. |

## Erasure paths and the new caches

- **Journal cache (`CaseMapJournalCache`).** It holds one case's journal. Every map read first reads the case header;
  a missing header (an erased case) calls `forget` and returns "not in the ledger". Opening another case runs
  `forget(old)` before the full read, so only one case is held. Reused rows are kept only while the digest of rows up to
  the last rowid is unchanged. The digest covers count, rowid sum, verification, its detail and time, `removed_at`, review
  state, citations and origin digest. It does not cover `text`, `quote` or `event_date`. I checked every writer of
  `case_journal`: the only UPDATEs set verification fields (`CaseFileRepository.swift:273`) or `removed_at` (`:479`), both
  in the digest. The only deletion is case erasure, which the header check catches. Person erasure does not touch
  `case_journal`. So no erasure or removal path can leave stale journal text in the map today. If a later change edits
  journal text in place or deletes single journal rows, the digest must cover it (see LN9).
- **Projection memo (`CaseMapProjectionMemo`).** It is in memory only and never stored, and holds no record the projection
  does not already hold. It is reused only for the same case id, and only when the documents list is equal and the entry,
  its attestations and its superseded flag are equal. An erased case clears it (`CaseMapService` sets `memo = nil` when
  the snapshot returns nil). A different case replaces it.
- **Lifetime.** The service and both caches are created per map workspace (`CaseMapServiceFactory.map`, used by
  `CaseMapWorkspaceView`), not app-wide. When the view goes, they go. While the view lives, they hold what the view model
  already held as `liveProjection`. Nothing new survives a case switch or an erasure beyond the next read.
- **Smaller snapshot.** `forMap` omits contacts, credibility, holds, redactions, review batches, conflict checks and the
  action log. This is less data in memory, not more.
- **Fence and change-feed queries.** The same pairs are rewritten as a primary-key lookup. Scope is unchanged:
  `s.case_id = ? AND s.in_scope = 1` is kept in both.
- **History time rounding.** `knownAt` allows 1 ms and `record()` returns the stored time. This is display and selection
  only. Erased checkpoints are still filtered by `erasedAt == nil`.

## Ask in a case: no outside lanes, no wider sends

- `AskView(caseScope:)` is built only once the stored case is known to be readable (`NavigationAreas.swift:296–301`).
  Otherwise the view shows a spinner or falls back to the library, and the label names that scope.
- A case question goes to `AppState.answerInCase` → `InvestigationAnswerService.answer(caseID:question:access:)`. This is
  the same path as a case's Ask job. It uses the fail-closed `SourceScopedRetriever` over the case's scope and the case's
  cloud scope (`setCloudScope`), and has the case's per-case AI permission, offline search results and
  `CaseSendScope` marker (so case erasure removes the sent text). The access is the workspace-bound `SensitiveScope`,
  with privileged material off.
- The two lanes that read outside the case are gated by `AskCaseScope.extraLanesAllowed(caseScope)`, which is true only
  with no case. These are the closest passage from whole-library FTS, and the general-knowledge block.
- A failure returns a refused, not-found answer ("Nothing was guessed"). It does not fall back to the global brain.
- Case search in the Search area is `CaseSearchPanel` (local `CaseSearchService`). A header or menu-bar query is handed to
  it as a case search. Nothing new is sent.

## Help, onboarding and listing copy

- The new copy ("With a case open, the question is asked in that case only"; "Search looks only in that case's
  documents"; "Nothing widens by itself"; "Case analysis views … read the whole library"; "The lists are the whole
  library") matches the code paths above. One edge case is labelled rather than silent: if the stored case is gone or
  unreadable, Search falls back to the library and its detail line says so (`NavigationAreas.swift:268–273`).
- Copy otherwise only renames places (Sources → Evidence ▸ Sources, Ask → Search ▸ Ask a question, Insights and Convert →
  More tools). No claim about data, AI, cost or privacy changed.
- **No privacy policy, terms or store-listing update is needed.** There is no new data type, network path, recipient,
  retention period or purchase flow. The new preferences (`kalsmritikosh.nav.evidenceSection`,
  `kalsmritikosh.nav.outputsSection`) hold section names only. The active case uses the existing
  `kalsmritikosh.cases.lastOpen` id. Listing screenshots and text that show the old sidebar should follow the new names
  when they are next refreshed. That is an owner/listing task, not a legal one.

## New items

- **LS24 (should-fix): questions asked in a case are kept in the whole-library Ask history.**
  - **Where it happens.** `AskView` with a case scope uses the same conversation store as library Ask. On open,
    `loadOrCreateConversation` (`AskView.swift:960–972`) resumes the most recent conversation, whichever case or library
    question it came from. The question and the answer are then appended to it (`AskView.swift:1062`, `:1120`) and recorded
    in the global `answers` ledger (`AskView.swift:1134`). None of these rows carries the case id.
  - **What the user sees.** Ask on case B can show case A's earlier questions and answers, or library ones, under the
    "This case" label. The answer itself stays case-only.
  - **What case erasure misses.** The case-scoped deletion does not reach these rows. `eraseDerivedProse` removes answers
    citing the case's documents only when "remove documents only this case used" is chosen and those documents are
    exclusive. The user's question turns, refused or not-found answers, and answers citing shared documents stay after
    the case is erased. DATA_FLOW's case-erasure paragraph does not say so.
  - **Fix.** Pick one:
    1. Give case Ask its own conversation per case and remove those turns and answers with the case.
    2. At least, start a fresh conversation when the scope is a case.
    3. Disclose in DATA_FLOW, the case-erasure help and the erasure report that questions asked in a case stay in Ask
       history until deleted there.
  - **Why not blocking.** Everything is on-device, nothing is sent, and the answers stay case-scoped. Library Ask already
    kept Q&A about case documents in the same way before this change. The person-erasure inventory already counts
    conversation turns and saved answers that name a person.
- **LN9 (note): the journal digest omits `text`, `quote` and `event_date`.** This is safe today, because no code path
  edits those columns in place or deletes single journal rows. A future in-place redaction or row deletion of the journal
  must extend `journalDigest` (`CaseFileRepository.swift`), or the open map could keep showing the old text until it
  reloads in full.
- LN4, LN6, LN8 and the owner steps LS6 and LS10 carry over.

If the uploaded commit is not 54ed48b9, re-point the gate record after a confirmation review.
