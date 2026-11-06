# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-04
Commit: 9da8a81d2357f78ba73da91e9240cb31b588e1f1

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: Both earlier blockers are fixed. LB1: erasing a case now replaces the text it sent in "What was sent" with an erasure line that keeps the time, destination, size and SHA-256, and withdraws the case's AI permission. LB2: the Marketing URL no longer says "100% on your Mac / no uploads" without the Online AI qualifier. Practitioner PB1 and should-fix items LS1–LS5 and LS7–LS9 are also fixed. LS6 is partly fixed: the owner must confirm Anthropic's retention figure at submission. LS10 is not fixed: the candidate packet still names c30d2191. New should-fix items, none blocking:
- LN1: question-only sends made in a case (the cloud interpreter and rewriter) carry no case marker, so the question text survives case erasure.
- LN2: index.html:269 says "— nothing else", but GLEIF and CourtListener lookups send names; the meta description still says "One plain plan".
- LN3: the one-step setup switches "Fully private — no AI" to evidence-gated without saying so on the sheet.
- LN4: the legacy full-copy match can also erase another case's identical full copy.

Review: [docs/agent-reviews/candidate-review-9da8a81d-legal-privacy.md](../../docs/agent-reviews/candidate-review-9da8a81d-legal-privacy.md)
