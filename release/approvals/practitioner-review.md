# Gate `practitioner-review` — AGENT review record (not a practitioner)

Decision: NOT APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT practitioner reviewer (investigator: HR/compliance, fraud/SIU, generalist)
Date: 2026-11-04
Commit: 7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0
Evidence: docs/agent-reviews/candidate-review-7d720fe1-practitioner.md; real-case records docs/agent-reviews/real-case-*.md; docs/ACCURACY.md
Notes: No practitioner took part; an agent read the code and texts. Blocking findings:
- PB1 — "The case's documents don't say" is shown as a not-found refusal whenever every AI statement failed the quote check, an unsupported negative from an unmeasured reader (Brain/CaseReader.swift:165-171, :188-195).
- PB2 — erasing a case leaves the case's full document text in the outbound log (same as legal LB1).
- PB3 — an AI-plan subscriber following the Help gets search results: "Use AI to write answers" (off by default) and the document-terms tick are required and documented nowhere (same as user-evaluation UB1).
- Investigators must be told: the candidate was tested by simulation only; the whole-case reader was never run on a real case; the last real-case result on earlier code (14e0708b, tuned cases) was 44 % correct, 9.9 % wrong, 2.5 confident-wrong per 100, 9 of 23 contradictions false; check every statement against its source.
- Should-fix: contradictions header ("cannot both be true"); no in-app "not measured" line; per-question cost after an idle hour; show documents read/withheld on the answer; estimate on analysis buttons; stale MSG/PST help.
