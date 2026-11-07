# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: 93a3870ddd0a6020559b038af4baf9560b51a294

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: this confirmation review covers 54ed48b9..93a3870d, the LS24 fix. It adds schema v174 (`conversations.case_id`), case-scoped Ask conversations and the removal of a case's Ask questions and answers when the case is erased. It adds no network, sending, consent or content-holding preference path. No privacy policy, terms or listing text change is needed; retention is shorter, not longer.

- LS24 fixed: Ask in a case resumes, lists and creates only that case's conversations, and library Ask only unbound ones (every pre-v174 conversation stays a library conversation). Answers made in a case are stamped with the case.
- Erasure: the case's turns are removed, and so is every answer made in the case, whether stamped with the case or linked from one of its turns. This includes refused and not-found answers and answers citing shared documents. The conversations then go with the case tables. All of this runs after the legal-hold refusal and inside the erasure's rollback, and it is counted back before commit. Library and other cases' conversations and answers are untouched.
- The erasure report, help, user manual and DATA_FLOW wording match the code.

New items, none blocking:
- LN10 (note): case questions asked before v174 stay library conversations. This applies only to unreleased test ledgers. If a released ledger ever predates v174, the help sentence should say "from this version on".
- LN11 (note): suppose a case is erased while one of its answers is still being written. That answer could be saved after the erasure, stamped with the erased case. The optional fix is to skip saving when the case no longer exists.
- LN4, LN6, LN8, LN9 and the owner steps LS6 and LS10 carry over.

If the uploaded commit is not 93a3870d, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-93a3870d-legal-privacy.md](../../docs/agent-reviews/candidate-review-93a3870d-legal-privacy.md)
