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


---

## §C — The nondeterminism taxonomy (complete, 2026-09-01)

Six classes found, named, and closed **by law, none by hiding** — the determinism arc's deliverable:

| # | Class | Signature | Closed by |
|---|---|---|---|
| 1 | Per-process hash order | citation membership/order flips across processes | Unit A: total order (score → tier → stable content key) at every sort AND every top-K cut |
| 2 | Stable-arbitrary order | SQL result order silently shaping answers ("stable per run, meaningless in content") | Unit A, same law — input-order precedence explicitly rejected |
| 3 | Wall clock | freshness drifting confidences between runs (Δ ~0.003/25 min) | Pinned reference clock (KALSMRITIKOSH_REFERENCE_NOW); pin joins the artifact header |
| 4a | Self-mutation: ledger exhaust | a memory distilled from ask N's answer hydrating into ask N+1's evidence (+1 distinct source, the 0.002 lattice) | Unit C-i: provenance-class law — exhaust never enters candidacy; `exhaust_class` column (v120) so future writers self-mark |
| 4b | Self-mutation: in-RAM boot rebuild | first ~580 s of HNSW/community rebuild shifting vector-leg cut boundaries between asks (invisible to DB probes) | Quiescence-in-fact (self-measuring settle: warm-up repeated until <10 s); production cure filed to the boot item (I-6) |
| 5 | FP accumulation order | confidence differing in the last two bits (~1.5e-16) at bit-identical components | Canonical rounding at source, precision 1e-12 |

**The 1e-12 decision, two-sided:** nine orders below the smallest semantic step ever observed (the 0.002 lattice), four above ULP noise — *representation, not tolerance*; comparisons stay exact equality, and the seal header carries `confidence_precision: 1e-12` so every future comparison knows what "byte-identical" includes.

**Boot measurement (filed to the I-6 boot item):** ~580 s of rebuild in two ~300 s rounds; the old single warm-up absorbed only round one — the flagship question's "275.8 s retrieve1" was round two. Production implication on record: a user's first minutes are slow *and* unstable (pre-boot-complete answers can differ in evidence membership, not just latency).

**One-drain discipline, vindicated on day one:** V1 registration's trap test printed `stale facts=0 entities=0 events=0` — the staleness predicate selects nothing until a real logic bump (first: V2's patent pack). Recorded here because the *absence* of a false full-drain is invisible later.

**Meta-laws now standing:** every confidence component is a deterministic function of (resolved question, stamped ledger state, pinned clock); self-derived state either resolves the question — receipted — or is excluded entirely; session may rewrite the question, never touch the evidence.

**Toolchain gotcha:** a stale unsigned KalsmritikoshTests.xctest inside the Debug app product (from killed builds) fails CodeSign with "code object is not signed at all" — delete the product and rebuild.

## §D — The integrity law trio (Go 1, 2026-09-03)

Three laws the writer-binding arc (3c → 3d → drain) left standing. Each was ruled after a
live defect, not invented in advance; each is enforced in code, not promised in prose.

| # | Law | Born from | Enforced by |
|---|---|---|---|
| 1 | **No silent drop at the SQL layer.** A write statement that terminates non-DONE THROWS; a read emits a counted diagnostic. Never silence. | 3c's FK violation silently swallowed an anchor insert (wrong id passed; nothing failed, nothing landed) | `Database+Binding.collectRows` write/read split — writes throw, reads log through the storage counter. The split is deliberate: a throwing read would abort retrieval wholesale (proven: gold recall 0.0 on the first blanket attempt), hiding the very layer-death it should surface |
| 2 | **One chokepoint for entity writes.** Every door that can create an entity — batch insert, canonical-org upsert, anchor resolution — passes the same junk classifier and the same gate assertion. | 3d's ghost census: junk entered through whichever door lacked the newest filter | shared `hardJunkClasses` + `assertGatedEntityWrite` at ALL three doors; complement test asserts real entities still pass |
| 3 | **Anchors never auto-fold.** Identifier anchors are identity `(field, canonical value)`, exact. Merges are PROPOSED (reversible `FactReview`, reviewer "system"), never executed by the machine. The one fold license: explainable OCR letter-group substitution (rn↔m, cl↔d, vv↔w, li↔u, nn↔m) with exact given name — similarity (JW) is a veto floor only, never a fold reason. | the Sasmal/Sasrnal pair — same person, OCR-split; and its dual, 555489/555480 — different values that MUST NOT fold | `UNIQUE(kind, normalized)` carrying the identity key; `IdentifierAnchorReview.proposedMerges`; the logged-proposal-never-executes fixture |

**The drain rider (SR-01, self-ruled under the standing grant):** the one sanctioned
rewrite of derived layers ran snapshot-FIRST and proved it — the first launch failed AT
the snapshot (sandbox denied ~/Downloads) with zero ledger writes; the ruling moved the
snapshot beside the live ledger (refuse-if-exists guard: a rollback copy is never
silently overwritten) with an operator mirror to ~/Downloads. Receipt on record:
716 KOs → v123, 564 stale facts → 1,969 v2, 902 stale events → 864 class-gated v1,
36 lifecycle milestones, 30 ghosts retired, 253 legacy facts conservatively KEPT
(no re-extractable blocks — never delete what cannot be regenerated), untouched proof
chunks/fts/embeddings 10455/10455/9632 [PROVEN]. Seal #4 "the true ledger": 7/7 answers
byte-identical across ALL fields at LIKE stamps — the citation/meta wobble of every
pre-drain seal is gone with the junk that caused it.

## §E — HOLD 1 record (2026-09-03) + GO 2 REVISED

**HOLD 1 = COMPLETE, witnessed live by the owner on the real archive** (his session, his
questions, his screenshots). Findings, every one scheduled by GO 2 REVISED: the résumé
leak into a patent ask (P3-U0 subject resolution + surfacing gate), the "Bill Delhi"
scope bycatch (P3-U0), comma/quote-corrupted person entities from email display-name
splitting (U0-b, own unit, producer bump + targeted refresh), and the fact-spam answer
shapes (P3-U1/U2 — the "Reported:" fallback dies; existence composer first). The
"ledger is true" claim carries this enumerated caveat until U0-b lands. Rung-2's
wrapper note states its true condition (routing+composer, P3-U2 — corrected at 2831a7e).
R-2 card dispositions (release/PROMISE_CARD_INVENTORY.md): 10-professions EXACT ·
studios.hardcopy TEST-BACKED · Convert "back and forth" = owner wording call at HOLD 2 ·
export-citations guard 10/10 (SR-02 fixed XLSX) · History card wording rides rung 3.
Sequencing from here is GO 2 REVISED verbatim: U0-a/b/c → S2-U1…U5/#5 → P3-U0…U5/#6 →
P4/#7 → P5 + RC-1…RC-8 → HOLD 2. PROJECT COMPLETE now includes RC-8 (Language Contract)
and App Review passed.

_End of addenda (§A/§B original; §C added 2026-09-01; §D added 2026-09-03; §E added 2026-09-03 night). The build opened at V0; V2 opens after reseal #3._
