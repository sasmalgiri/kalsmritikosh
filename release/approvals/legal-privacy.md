# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: 54ed48b94811dd7a4d46d71da1b441b1572e54f4

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: this confirmation review covers 06487e95..54ed48b9: the CI script, the contradiction-finder determinism fix, the history time rounding, the regenerated verifier, LS23 erasure-report matching and paging, case-map speed (fence query, journal cache, projection memo, smaller snapshot) and the navigation merge (Cases / Evidence / Search / Outputs, Ask and Search in the active case). It adds no network, sending, consent or content-holding preference path. No privacy policy, terms or listing text change is needed.

- LS23 fixed: the "still named in" counts (documents, studio drafts, saved answers, topics, conversation turns) use the same Unicode matcher as the erasure itself, paged 256 rows at a time; a failed count is logged.
- LN7 fixed: checkpoint and other name matching is paged by rowid; only matching ids are held.
- Journal cache and projection memo: memory only, one case, created per map view; an erased case clears both on the next read, and a case switch replaces them. Every in-place journal write (verification, removal) changes the digest, so no stale journal text survives.
- Ask in a case uses the case's answering service (fail-closed case scope, the case's AI permission and send marker); the closest-passage and general-knowledge lanes run only without a case. Help and onboarding copy matches.

New items, none blocking:
- LS24 (should-fix): Ask in a case resumes and writes to the shared Ask conversation history and the global answers ledger. This has two effects. Earlier questions from another case or the library can show under "This case". Case questions and answers, including refused ones and ones citing shared documents, also survive case erasure, and this is not disclosed. The fix is a per-case conversation erased with the case, or at least a fresh conversation for a case, or disclosure in DATA_FLOW, help and the erasure report.
- LN9 (note): the journal digest omits text, quote and event date; it is safe while no path edits those columns or deletes single rows. It must be extended if one ever does.
- LN4, LN6, LN8 and the owner steps LS6 and LS10 carry over.

If the uploaded commit is not 54ed48b9, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-54ed48b9-legal-privacy.md](../../docs/agent-reviews/candidate-review-54ed48b9-legal-privacy.md)
