# Kalsmritikosh v1.1 — Program Addenda (execution record)

_Companion to the eight governing specs in the handoff set (precedence: PRODUCT_COMPLETION_PLAN > 1.1_FIRST_DECISION > FINAL_HANDOFF > AGENT_INSTRUCTIONS > V1.1_FINAL_SPEC > D17_v2 > COMPLETE_DATA_PROCESSING_PLAN > MASTER_PROGRAM). This file holds the items the specs said were "pending from the agent task list" plus flagged plan additions, so the reserved slots close **before Stage 2 opens**, per the gaps ledger's own rule. Anchored to `main` @ `ef19855`._

## Verification model (approved 2026-08-30)

Fixtures per commit (red→green, independent of the live ledger); **live-ledger witnesses batched at regeneration boundaries** (V6 post-drain, Stage 2 reindex, Stage 3, ship) — because V5b's targeted re-extraction regenerates the whole ledger, so mid-commit live witnessing measures a sandcastle mid-tide.

### The five bindings on the model
1. **Localization moves into fixtures.** Every commit's fixture suite includes **fixture-equivalents of rungs 1, 1n, 2** so a batched live witness is *confirmation*, never *first detection*. A live rung red whose fixture twin stayed green is itself a finding (fixture unrealism), filed as such.
2. **CausalDiscoverer bounding is a flagged plan addition** (not a silent unit) — see §A below.
3. **C-9 and C-10 texts are pasted verbatim below** (§B) — reserved slots closed before Stage 2.
4. **Stage 0 = human witness FIRST, then capture.** Owner's human pass in the running app (rung-1 ask, I-7 one-click verify, entity-register glance) → quit apps → `pgrep` clean → agent capture. The human pass rejoins each batched live witness (V6, Stage 3, ship).
5. **Ship-build gets its own Step-5.** rc13's completed archive+Step-5 proved the *pipeline*; the ship build's archive (unit 4.4) gets its **own** Step-5 — different artifacts, same proof, no conflict.

Cadence, autonomy with per-unit assertion-line reports, and stop conditions (any rung change / false-not-found on gold / grounding bypass / anything demanding user erase/re-ingest → STOP and report) are unchanged.

---

## §A — Flagged plan addition: CausalDiscoverer link bounding (Stage 1, unit 1.8)

**Admitted through the gate, not smuggled.** Live-ledger measurement (2026-08-30): `event_links` = 71,750 over 902 events (~80 links/event); 69,738 are `CONTRIBUTED_TO` (heuristic, conf 0.36–0.42) vs only 2,012 `CAUSED` (lexicalTrigger, conf ~0.74). Root cause: `CausalDiscoverer.swift:216-239` runs an O(n²) pairwise scan within a day-gap window and emits `CONTRIBUTED_TO` for any pair over threshold; a single-matter archive with ~800 near-duplicate thread emails clears the bar for nearly every pair. This is noise manufacturing.

**Traceability (required by §0):** turns on **C-3** (ledger quality — "it builds the ledger" implies signal, not 80×-inflated links), **C-4** (📊 See the big picture — matrix/graph views inherit this noise), and **Q6** (relationship answers walk this graph; ≤2-hop paths over a near-complete graph are meaningless).

**Correction:** per-event top-K link cap + a raised score threshold + near-duplicate thread-event dedup before pairing. Bound applies to the heuristic `CONTRIBUTED_TO` emission; lexical-trigger `CAUSED` links are unaffected.

**Red fixture:** a seeded thread of N near-identical dated events that currently explodes into ~N² `CONTRIBUTED_TO` links → after bounding, ≤K links/event, and the real `CAUSED` link (seeded with a lexical trigger) survives. Red first, green after 1.8.

---

## §B — Reserved slot texts, pasted verbatim (close before Stage 2)

### C-9 (medium) — Every pack runs on every block, blind to the document class

**Evidence.** `DomainFactExtractor.extract` runs all five packs over every substantive block, by design ("packs are additive and domain-neutral… no pack wins"). Meanwhile `DocumentClass` is computed for the document and thrown away (D-17).

**Consequence.** The permissiveness that made "Patent : 22/03/2023" extractable is structural: patterns must be loose because they get no context. An employment contract's dates are tested by the transaction pack; a research paper's year is tested by the contract pack. Loose patterns plus no context is exactly the recipe that produced the 29 Aug noise.

**Correction.** Keep additive extraction — that principle is right — but let the class *tighten* rather than exclude: once D-17 persists `document_class`, packs matching the class run with their normal patterns while non-matching packs run in a strict mode (require an explicit label, no bare-value fallback) and write at reduced confidence. Nothing is excluded, so a receipt inside a contract still yields transaction facts; the difference is that a bare date in a patent letter is no longer claimed as a contract's effective date.

**Tests.** A contract fixture yields the same contract facts as today; the same fixture yields no bare-date transaction fact; a mixed receipt-in-contract still yields the transaction amount via its explicit label.

### C-10 (medium) — `merge` keeps max confidence and drops the losing status

**Evidence.** `DomainFactExtractor.merge` unions `sourceBlockIDs` and takes `max(existing.confidence, f.confidence)`, keeping the first fact's `assessment`.

**Consequence.** Two independent sources asserting the same value should be *more* trustworthy than one — that is corroboration, and it's counted elsewhere in the system but not here. Meanwhile max-confidence means one weak block can inherit a strong block's number without any record of the disagreement in provenance strength.

**Correction.** Record `sourceCount` (distinct documents, not blocks) on the merged fact and let confidence reflect corroboration explicitly rather than by max; preserve the strongest `assessment` deterministically rather than "first wins". The slot ranker (D-12) can then prefer a twice-attested value over a once-attested one of equal tier — which is exactly the judgment a professional makes.

**Tests.** Same value from two documents merges with `sourceCount == 2` and confidence above either input's; same value twice within one document stays `sourceCount == 1`.

**Placement:** C-9 lands in Stage 2 unit 2.5 (needs D-17's persisted `document_class`); C-10 lands in Stage 1 unit 1.4 (write-time merge, alongside capture-group extraction).

---

_End of addenda. The build opens at V0 once the baseline artifact exists (Stage 0)._
