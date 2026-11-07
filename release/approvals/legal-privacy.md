# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-08
Commit: 4af12048004f95f394d1cf8613ee04e2f17d4c3d

This is an agent review, not a lawyer's opinion. It is a read-only review of the code and the release package; I did not build, run tests or use the GUI.

Summary: this confirmation review covers 93a3870d..4af12048. That range gives archive-scan contradictions stable ids and places collapsed case-map group cards clear of the items shown. It adds no network, sending, consent, preference or schema path. No privacy policy, terms or listing text change is needed.

- Stable ids: each id is a SHA-256-derived identifier of the kind, description, document ids and claim text. It is stored only in the places the random id used to go. The contradiction row already held that claim text, so the id adds no new copy of content. The id includes the knowledge-object ids, so after a document is erased no remaining record can re-attach to it.
- Erasure: case decisions are keyed by `case_id` and go with the case. Full erase removes everything. Person erasure is unchanged.
- Case map cards: layout is computed when the map is drawn, and nothing is saved.

New items, none blocking:
- LS25 (should-fix, older than this range): `contradictions` rows quote documents verbatim but are not removed when a case erasure also removes the documents only that case used (`evidence_a` / `evidence_b` are not among the erased columns). The case check's own rows survive rescans indefinitely. Person erasure's "still named in" inventory leaves them out. Fix: delete by `evidence_a` / `evidence_b` in the exclusive-source step, with count-back, and add them to the person inventory.
- LN12 (note): decisions now stay attached to the same archive finding across rescans (intended). Decisions orphaned by earlier rescans exist only in test ledgers.
- LN4, LN6, LN8, LN9, LN10 and LN11, and the owner steps LS6 and LS10, carry over.

If the uploaded commit is not 4af12048, re-point this record after a confirmation review.

Review: [docs/agent-reviews/candidate-review-4af12048-legal-privacy.md](../../docs/agent-reviews/candidate-review-4af12048-legal-privacy.md)
