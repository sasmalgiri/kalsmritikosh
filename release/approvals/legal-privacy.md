# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: 06487e9560a140639c566a1e0cc63ceaf3e62295

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: this confirmation review covers 06487e95, which fixes the should-fixes LS19–LS22 from the e3ac8bf8 review (APPROVED). It adds no sending, consent, network or preference path.

- LS19 fixed: person erasure now deletes saved map views and saved searches whose name, filters, words or results name the person. It clears recorded states that name the person in their content or milestone name to stubs and replaces their names. It removes the before/after revisions naming the person. It reports the link reasons it keeps. Names match ignoring case, accents and width in any script. The updates stay within what the v173 triggers allow.
- LS20 fixed: DATA_FLOW_INVENTORY L3 and L12 now describe the current capture and DEVONthink defaults.
- LS21 fixed: DATA_FLOW, THREAT_MODEL T16, help and the manual disclose that a recorded state keeps the names and quotes of documents forgotten later, until a case, person or full erasure.
- LS22 fixed: the remaining module texts state the per-case AI permission instead of "previewed".

New items, none blocking:
- LS23 (should-fix): the erasure report's "still named in" count for studio drafts, answers, topics, conversation turns and documents still uses ASCII-only lower-casing. It can undercount for non-ASCII names.
- LN7 (note): checkpoint matching reads every checkpoint's content into memory.
- LN8 (note, existing behaviour): short aliases can over-match and cause over-erasure.
- LN4, LN6 and the owner steps LS6 and LS10 carry over.

If the uploaded commit is not 06487e95, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-06487e95-legal-privacy.md](../../docs/agent-reviews/candidate-review-06487e95-legal-privacy.md)
