# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-07
Commit: e3ac8bf83b2d5367ada83014e29a6c6b964c09a4

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: LS17 and LS18 are fixed. Scope package S and the Living Case Map M1–M9 (schema v171–v173) add no sending, consent or network path.

- The new case content is kept only in the encrypted ledger. This covers saved map views and their search words, map links, saved searches, before/after revisions, checkpoints and the seen position.
- The map's preference state holds identifiers and geometry only, under the existing per-case key.
- Case erasure and full erasure cover every new table. Person erasure clears recorded states that name the person.
- Checkpoints cannot be edited or brought back after an erasure.
- Map export, copy and print go only through CaseOutputService.
- No preset, migration or the preview switch turns on Online, Spotlight, sync or monitors.
- The reworded review priority, source counts, the self-test diagnostic and "Filter by document date" make no accuracy or culpability claim.
- No entitlement is revoked and no paywall is added. The privacy label needs no change.

New should-fix items, none blocking:
- LS19: person erasure misses saved map view names and search words, map link reasons and milestone names. They are not erased and not reported.
- LS20: DATA_FLOW_INVENTORY L3 and L12 still describe the old capture and DEVONthink defaults.
- LS21: disclose that a checkpoint keeps the names and quotes of documents that are later forgotten, until a case, person or full erasure.
- LS22: two module texts (ProductModule.swift:178, :359) still say "previewed".
- LN4, LN6 and the owner steps LS6 and LS10 carry over.

If the uploaded commit is not e3ac8bf8, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-e3ac8bf8-legal-privacy.md](../../docs/agent-reviews/candidate-review-e3ac8bf8-legal-privacy.md)
