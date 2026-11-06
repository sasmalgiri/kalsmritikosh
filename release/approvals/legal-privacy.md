# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-06
Commit: 06e4b3a93edfad2864b3e5a084ab4c187c349ebd

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: The blocker LB3 from the review of 572b5893 is fixed. "Delete all my data" now clears the per-case workspace preference and the per-case "not applicable" reasons. The workspace preference no longer stores any document text or file name, only identifiers, and the passage is re-read from the ledger. LS11–LS16 are fixed. LS10 is left for the owner: the candidate packet holds a placeholder until the owner names the uploaded commit. The diff adds no new sending, consent or retention path. No public page or in-app text says "never leave your Mac" or "100 % on your Mac" without a qualifier. New should-fix items, none blocking:
- LS17: docs/sop-register.html:63 says "every send is previewed". Inside a case the person allowed, documents and questions go without a further preview.
- LS18: ProductModule.swift:402 says "You see exactly what will be sent before it goes", which is inaccurate in the same way.
- LN4, LN6 and the owner step LS6 (confirm the retention figures at submission) carry over.

If the uploaded commit is not 06e4b3a9, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-06e4b3a9-legal-privacy.md](../../docs/agent-reviews/candidate-review-06e4b3a9-legal-privacy.md)
