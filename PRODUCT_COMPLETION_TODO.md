# PRODUCT_COMPLETION_TODO — the execution plan to a finished product

**Revised:** 2026-09-24 (v3) · branch `v11-implement-all` · schema **v129**
**Supersedes:** the v1/v2 tier layout, which had grown by accretion into phases
numbered `0, 1, U, 2, 3, 4, 5, 6, A, 7, 8` — hard to execute against. Nothing was
dropped in the rewrite; every item carries its old label so prior notes resolve.

**Sources:** `PIPELINE_DIAGRAM_MATRIX.md` (findings F-1…F-10),
`PIPELINE_MATRIX.md` (generated wiring), the repo task list, and the owner
rulings of 2026-09-24: *"keep all 5"*, and *`people`/`companies`/`projects`/
`timelines` are for database building*.

## How to read this

- **ID** is stable. **Was** maps to the old label. **#** is the repo task.
- **AGENT** = I can complete and verify it. **OWNER** = genuinely needs you
  (private data, a real sample, a product decision, or eyes on a screen).
- Every item has **acceptance criteria**. "Done" means the criteria pass, not
  that code was written.
- Phases are ordered by dependency; within a phase, by risk.
- Nothing here is polish. Items I judged cosmetic are not listed.
- **Completeness is claimed only as far as §0 states.** §0 names the parts of the
  product I have NOT audited. A list that hides its own gaps is worse than a
  short one.

---

## §0 · COVERAGE LEDGER — what this list does and does not cover

The v1 list covered the ingest→answer spine and silently omitted eight shipping
feature lanes holding ~50 tables. Recorded here rather than quietly patched.

I cannot write honest acceptance criteria for code I have not read. So lanes are
either **AUDITED** (traced, findings and criteria below) or **NOT AUDITED**
(listed, with an audit unit in Phase 9 — never assumed working, never assumed
broken).

| lane | tables | status | covered in |
|---|---|---|---|
| `Ingestion/*` — Intake, Container, Readiness, Upgrade | 8 | **AUDITED** | P1, P4, P3 |
| `Knowledge/Ontology` + 11 DomainPacks | — | **AUDITED** | P3 (the universality gap) |
| `Knowledge/Topics` | 4 | **AUDITED** | P6.1 |
| `Knowledge/Boilerplate` | 2 | **AUDITED** | P2.4 |
| `Knowledge/Backfill` (the drain) | 3 | **AUDITED** | P3 sequencing |
| History — `history_*` | 6 | **AUDITED** | P2.1, P6.2 |
| `Brain/*` + `Retrieval/*` — answer + 8 layers | 4 | **AUDITED** | P7 |
| `Storage/Repositories` · `Storage/Schema` | 122 | **PARTLY** — the spine's tables traced; the other ~100 counted, not read | P8, P9.8 |
| **`Workbench`** (DataLab) | **14** | **NOT AUDITED** | **P9.1** |
| **`Personas`** | **13** | **NOT AUDITED** | **P9.2** |
| **`Method`** (professional methods) | **10** | **NOT AUDITED** | **P9.3** |
| **`Workflow`** (automation) | **4+** | **NOT AUDITED** | **P9.4** |
| **`Jobs`** | **3** | **NOT AUDITED** | **P9.5** |
| **`WorkCenter`** | **3** | **NOT AUDITED** | **P9.6** |
| **`Shell`** · **`Sutra`** · **`Forensics`** · **`Knowledge/Twins`** | **5** | **NOT AUDITED** | **P9.7** |
| Investigation — `investigation_*` | 15 | **NOT AUDITED** | **P9.8** |
| UI — `Kalsmritikosh/UI/*` | — | **NOT AUDITED** | **P9.9** |
| Privacy / security | — | **PARTLY** — tests pass; no adversarial pass by me | **P9.10** |

---

# PHASE 1 · INTEGRITY — the write path cannot corrupt silently

**Must precede the re-ingest.** A report over a ledger that can corrupt itself
mid-run measures the wrong thing.

| ID | was | # | who | item |
|---|---|---|---|---|
| **P1.1** | T0-1 | 83 | AGENT | Entity-insert failure cascades into wrong events |
| **P1.2** | T0-2 | 84 | AGENT | 11 swallowed write failures lose the reason |
| **P1.3** | T0-3 | 85 | AGENT | KO derivation transaction boundary (UNKNOWN today) |
| **P1.4** | T0-4 | — | AGENT | Guard against `try?`-on-persist regression |

**P1.1** `IngestCoordinator:1520` — `canonicalMapping = (try? await entities.insertBatch(raw)) ?? [:]`,
then `:1544` writes events remapped through the empty mapping. One swallowed
error persists events whose entity references were never canonicalised; the
corruption is downstream of the failure and looks like valid data.
*Accept:* injecting a failing repository yields zero events with
un-canonicalised references AND a recorded failure. A test proves both.

**P1.2** `:372`, `:398` embeddings · `:1042`, `:1067`, `:1123` recursive member
ingest · `:1146` `linkBlocks` · `:1544` events · `:1606` relationships, plus 5
in `Knowledge/`. Worst is `:1146` — the one call wiring the claim–evidence
contract. `:1042`/`:1067` mean an examiner cannot tell *"not in the container"*
from *"failed to parse"*.
*Accept:* each propagates or records a retrievable reason; embeddings can
distinguish **failed** from **pending**; the grep returns only sites carrying a
recorded-reason comment.

**P1.3** *Accept:* a test that kills the work between `:1395` (chunks) and
`:1520` (entities) leaves the ledger either complete or honestly marked
incomplete — never a partial KO that looks finished. The chosen design (one
SAVEPOINT per KO, or a recorded resumable partial) is documented.

**P1.4** *Accept:* an architecture test fails when a new `try?` appears on a
persist in `Ingestion/` or `Knowledge/` without a recorded reason.

---

# PHASE 2 · WIRING — the "keep all" rulings (nothing removed)

| ID | was | # | who | item |
|---|---|---|---|---|
| **P2.1** | T1-1 | 86 | AGENT | `history_chapters` gets a consumer (F-2) |
| **P2.2** | T1-2 | 86 | AGENT | `knowledge_objects_fts` gets a reader (F-7) |
| **P2.3** | T1-3 | 86 | AGENT | `qa_pairs_fts` + `synthetic_questions_fts` get producers (F-3) |
| **P2.4** | T1-4 | 86 | AGENT | `boilerplate_uses` gets a consumer (F-9) |
| **P2.5** | T1-5 | 86 | AGENT | `history_alternative_accounts` gets a writer (F-10) |
| **P2.6** | T1-6 | 86 | AGENT | `evidence_block_edges` producer, or DEFERRED-KEPT with a reason |
| **P2.7** | T1-8 | 87 | AGENT | POA grantor via the POA-FORMULA discriminator |

**P2.1** Written at `HistoryArtifactRepository:77`, read nowhere — inside a suite
whose test is named *"Save persists the full graph and reloads"* and asserts no
chapter. *Accept:* `load` returns chapters; a `chapterCount` helper exists; the
test asserts them, so its name stops overstating what it proves.

**P2.2** Trigger-maintained on every KO write (`SchemaMigrations:1226–1234`),
queried by nothing. *Accept:* a retrieval lane queries it, OR the redundancy
against `chunks_fts` is closed with a recorded measurement. The unexplained
write stops either way.

**P2.3** Both have **no producer** — indexes with no contents, so queries return
nothing silently. *Accept:* populated, and a seeded row findable through the
index.

**P2.7** Kept per your ruling, WITHOUT readmitting the junk. Measured:
`roleStopwords` alone does not catch "acknowledge receipt" / "need patent agent"
(×82 each live), so casing is load-bearing. The weak link is the bare `of` that
lets *"I acknowledge receipt **of** …"* match at all. *Accept:* the POA line
yields an `applicant`; all four witnessed junk strings yield zero; the
`withKnownIssue` red is **removed**, not re-wrapped.

Each lands as its own commit — six independent lanes in one commit would make a
regression hard to attribute.

---

# PHASE 3 · UNIVERSALITY — the central promise, currently unmet

**Measured position.** The storage model is universal; the producers are not.

| layer | universal? | evidence |
|---|---|---|
| Formats | mostly | 36 FULL + 7 PARTIAL, plugin registry, TextLoader fallback |
| Storage model | **YES** | `GenericFact` is domain-neutral; `FactSchemaRegistry`: "Open — an unknown field is `.text`, never dropped" |
| **Fact production** | **NO** | every fact comes from **11 fixed domain packs** |
| **Fact typing** | **NO** | `FactTypeClassifier` is a CLOSED enum — a commercial + project-management taxonomy |
| LLM assist | not the answer | `LLMSlotExtractor` fills slots of an ALREADY-KNOWN type's schema, and is not on the ingest path |
| Ask side | partly | `SlotFieldResolver` has ~25 fixed phrases; the F8 `<word> number|date` fallback is the one open mechanism |
| Language | NO | English-only; multilingual is v2 |

**Consequence:** a shipping manifest, car service record, school report, lab
instrument log, insurance claim or building permit yields chunks and **zero
facts**. The answer falls back to quoting passages, and the
database-in-the-middle — the moat — is empty for any unanticipated domain.

| ID | was | # | who | item |
|---|---|---|---|---|
| **P3.1** | U-1 | 88 | AGENT | Open-domain labeled-field extractor |
| **P3.2** | U-2 | 89 | AGENT | Open fact-type taxonomy |
| **P3.3** | U-3 | 89 | AGENT | LLM schema induction, evidence-bound + budgeted |
| **P3.4** | U-4 | 89 | AGENT | Ask-side universality |
| **P3.5** | U-5 | 89 | AGENT | Format universality closure |
| **P3.6** | U-6 | 89 | AGENT | Language honesty |

**P3.1 — the highest-leverage item in this document.** Real documents state facts
as `Label: value`, `Label — value`, or a two-column table, whatever the domain.
A domain-agnostic extractor for those gives structure on documents no pack
anticipated, and removes the need for 11 packs to become 50.
*Gates required* — the same discipline as the C-4/OCR work, which is why that
came first: label plausibility (not prose); value plausibility (reuse
`FactValuePlausibility`); block-kind weighting (a table cell outranks a
paragraph); per-document dedup; a cap so one junk page cannot mint 400 fields.
*Accept:* fixtures from ≥6 un-hard-coded domains each yield correct fields; the
existing 11-pack and gold fixtures produce **byte-identical** output to today —
this must ADD, never perturb; a noise page mints nothing; a perf guard holds.

**P3.2** *Accept:* an out-of-taxonomy document gets a stable derived type id
rather than `.other`; the health probe separates "genuinely novel" from
"classifier failed"; known types keep today's behaviour exactly.

**P3.3** *Accept:* no model-proposed value survives without a **verbatim** span
in a cited block; the call budget holds (per-document tier-2, never
per-question); model unavailable = a no-op that says so.

**P3.4** *Accept:* "what is the chassis number", "who was the attending
physician", "what was the policy number" resolve against the ledger's ACTUAL
field inventory with no new vocabulary entries; the honest field-named not-found
still fires when the field is truly absent.

**P3.5** *Accept:* every binary type without a loader is reported PRESERVED-ONLY
with a reason, never silently empty; `SUPPORTED_SOURCES.md` is **generated** from
the registry, so the claim and the code cannot diverge.

**P3.6** *Accept:* language detected per document and recorded; a non-English
document marked as such with its extraction limits stated in the report, rather
than quietly producing nothing.

> **Sequencing decision (mine, defended).** `LedgerDrainCoordinator` pass 2
> re-derives facts from the STORED `EvidenceBlocks`, not the original files — so
> P3 can land after a re-ingest and be applied by a **drain**, with no second
> file re-ingest. But **P3.1 should land BEFORE the owner's re-ingest** and the
> rest after. Rationale: P3.1 is the one deterministic unit that changes what the
> ledger CONTAINS in the common case, so running it first means the owner's
> validation exercises the real product rather than a narrow precursor. One extra
> unit before the gate; P3.2–P3.6 ride the drain.

---

# PHASE 4 · INGESTION TRUTH — the first step, and the owner gate

| ID | was | # | who | item |
|---|---|---|---|---|
| **P4.1** | T2-1 | 81 | AGENT | Generated producer/consumer/test map + coverage guard |
| **P4.2** | T2-2 | 72 | AGENT | Ingestion Report |
| **P4.3** | T2-3 | 73 | AGENT | Prove the report on fixtures first |
| **P4.4** | T2-4 | 74 | AGENT | Pre-flight stamp + erase proof |
| **P4.5** | — | — | **OWNER** | **THE GATE: erase → re-ingest → send the report** |
| **P4.6** | T2-5 | 75 | AGENT | Triage what the report flags |

**P4.1** Built and self-checking. *Remaining accept:* the "produced but untested"
count (17) becomes a **pinned** number, so a new table cannot ship without a test
or a recorded exemption.

**P4.2** *Accept:* discovered vs ingested vs failed, every gap grouped **by format
with a reason**; `extraction_status` per `detected_type` with top parser warnings;
coverage (chunks/embeddings/FTS) always with denominators; facts by field; v129
`derivation` counts; and an explicit could-not-measure list. No percentage
without its denominator; no zero that might mean "no data".

**P4.3** *Accept:* the fixture run shows the OCR fixture's patentNumber as
`OCR_CORRECTED` and the split letter's as `CROSS_BLOCK_ASSEMBLED` — proving the
run exercised the new extraction end to end, and proving the REPORT, not just the
pipeline.

**P4.4** *Accept:* header carries build SHA, schema `user_version` = 129, producer
versions, and **which optional loaders are ON** (a run with Messages off must not
read as "Messages produced nothing"). Erase asserts zero rows in every table
enumerated from `sqlite_master` — not a hardcoded list — and reports VACUUM size
before/after.

**P4.5 — what you do:** Backup → rebuild in Xcode → **confirm AI is not in
Fully-private** (topics build only when the model is up; an empty topic layer with
no error has cost us before) → erase → re-ingest → send me the report.

**P4.6** The item I expect to matter most: `derivation` counts far above
expectation would mean my OCR / cross-block gates are too loose on real data —
the risk I flagged when landing them, and only your archive can settle it.

---

# PHASE 5 · CHAIN PROOF

| ID | was | # | who | item |
|---|---|---|---|---|
| **P5.1** | T3-1 | 76 | AGENT | Golden Thread — one document traced by ID, end to end |
| **P5.2** | T3-2 | 80 | AGENT | Whole-chain fixed point |

**P5.1** Per-stage tests exist and pass, yet six latent failures survived them —
because each checks its own stage. A break BETWEEN stages is invisible to all of
them. *Accept:* file → `source_version` → `EvidenceBlock` → chunk (+FTS) →
embedding → `GenericFact` (+anchor) → topic → history item → retrieval hit →
**answer citation** back to that exact block, asserted **by ID, not by count**. A
broken link names the stage. Plus a negative thread: an unrecoverable fact breaks
the chain at a NAMED stage with an honest reason, never a silent answer.

**P5.2** *Accept:* on an unchanged corpus — second ingest writes zero new rows;
second extraction mints zero new facts; second topic build byte-identical; second
history build byte-identical; an identical ask returns identical citations. Report
the diff table by table. Precedent: 9,266 fact rows collapsing to 387 distinct,
and topics growing 92→143 on rebuild.

---

# PHASE 6 · STRUCTURE — topics, history, registries

| ID | was | # | who | item |
|---|---|---|---|---|
| **P6.1** | T4-1 | 77 | AGENT | Topic layer |
| **P6.2** | T4-2 | 78 | OWNER→AGENT | History per subject |
| **P6.3** | T1-7 | — | AGENT | Canonical registries: people / companies / projects / timelines |

**P6.1** *Accept:* "0 topics" always carries a REASON (model up or down; attempted
vs produced); every topic's `sourceObjectIDs` resolve; a second rebuild over an
unchanged ledger is byte-identical (the 92→143 defect cannot recur); coverage
reported with a denominator; topics do not mix subjects sharing no evidence.

**P6.2** **Needs from you:** 3–5 subject names — ideally one well-documented, one
thin, and one **ambiguous** (two people, similar spelling). The ambiguous one is
the most valuable: it proves we return *ambiguous* rather than silently picking.
*Accept:* per subject — every item cited and resolvable; zero leakage from other
subjects; a no-canonical-id subject returns empty AND flagged; ambiguity reported
as ambiguity; deterministic across two runs; no 1601/1970 sentinel dates leaking
as real; and the artifact states what it could not place in time.

**P6.3** **Owner ruling: these are for DATABASE BUILDING** — the canonical
registries the ledger accumulates (one row per real person, org, project; one
timeline per subject), distinct from `entities`, which holds alias-unified
mentions. **Depends on P3.1/P3.2:** a registry fed by 11 domain packs is a
registry of 11 domains. *Accept:* each has a producer fed by the open extractor;
every row cites the evidence that created it; a second build is idempotent
(registries merge, never duplicate).

---

# PHASE 7 · ANSWERS

| ID | was | # | who | item |
|---|---|---|---|---|
| **P7.1** | T5-1 | 79 | AGENT | Headless answer harness |
| **P7.2** | T5-2 | 71 | AGENT | Reranker latency |
| **P7.3** | T5-3 | — | AGENT | Reconcile the eighth retrieval layer (F-8) |

**P7.1** Closes the standing hole that I cannot press Ask. *Accept:* a fixed
question set runs through the real `MasterBrain` path and exports per question:
answer text; every citation **with a resolution check**; quality-strip numbers
that RECONCILE with the retrieval set used; the `ReasoningTrace`; and the
evidence-gate decision. **Assertions, not just capture:** no citation outside the
retrieval set, no claim without evidence, every refusal names what was missing.
Shapes must include slot, date, money (the `how much` case just fixed), existence,
list, comparison, story, role, a known-absent field, and one whose answer comes
from a repaired value.

**P7.2** `BGETokenizer` costs **3.6 s per 1 KB passage** at query time
(`CoreMLCrossEncoderTier`), so a top-20 rerank exceeds a minute. Not the ingest
path — the embedder's `BERTWordPieceTokenizer` is 0.62 ms.
*Accept:* a token-parity test proves IDENTICAL output over a corpus **before** the
scan changes (cross-encoder scores drive ranking; drifting tokens silently reorder
answers), then per-passage cost drops by an order of magnitude.
`BERTWordPieceTokenizer` is fast — borrow its algorithm.

**P7.3** `bondLayer` (`HybridRetriever:918`) is an eighth layer; CLAUDE.md
documents seven. *Accept:* the documented invariant and the code agree.

---

# PHASE 8 · COVERAGE — no unverified producer left

| ID | was | who | item |
|---|---|---|---|
| **P8.1** | T6-1 | AGENT | Test the 17 untested producers |
| **P8.2** | T6-2 | AGENT | Resolve the four UNKNOWNs |
| **P8.3** | T6-3 | AGENT | Full-suite completion protocol |

**P8.1** From `PIPELINE_MATRIX.md`: `assertions` (no test names it at all),
`entity_aliases`, `narrativeSlotExtractor`, boilerplate, `derived_objects`,
`embedding_cache`, `enrichment_status`, `entity_cooccurrences`, `event_versions`,
`monitor_snapshots`, `review_*`, `saved_*`, `screening_*`, `investigation_steps`.
*Accept:* the pinned count reaches zero, or every remainder carries a recorded
exemption.

**P8.2** `narrativeSlotExtractor` (`:1576`) writes what, read by what ·
`document_profiles` / `derived_objects` / `enrichment_status` / `event_versions`
semantics · whether any retrieval query is unbounded on a large ledger.
*Accept:* each becomes OK/RISK/GAP with evidence; unbounded queries get a bound or
a recorded reason.

**P8.3** Two `RunAllTests` runs both stopped after ~3,500 of ~4,700 with ~1,220
"No result" — a consistent cutoff, no crash, most likely a harness budget.
*Accept:* the suite completes in one run, OR the two-pass protocol is scripted and
recorded as the official acceptance method — so "green" is never claimed from a
partial run again.

---

# PHASE 9 · LANE AUDITS — the parts this list had omitted

Same method that produced Phases 1–8: trace the call chain, read the producers,
record findings with `file:line`, mark anything unestablished UNKNOWN, then write
acceptance criteria. **An audit unit's output is a findings list plus its own todo
items** — so these are the only items whose scope cannot be stated up front. That
is the honest position, not a hedge. All of these lanes SHIP today; what is
missing is my verification. Task **#90**.

| ID | lane | tables | audit for |
|---|---|---|---|
| **P9.1** | Workbench / DataLab | 14 | cell→evidence binding (every value drillable); scenario projection leaving the base untouched; derivation reproducibility; silent divergence from the ledger |
| **P9.2** | Personas | 13 | every persona job routes real or fails closed honestly; work-product exports carry custody + citations; no persona bypasses the scope filter |
| **P9.3** | Professional methods | 10 | a run reproducible from recorded inputs; findings bound to evidence; assumptions surfaced not buried; lifecycle gates actually gating |
| **P9.4** | Workflow automation | 4+ | mid-run failure leaves a resumable honest state; provenance snapshots complete; no automation writing outside the gated doors |
| **P9.5** | Jobs | 3 | objective→plan→evidence traceability; a job cannot claim completion without its objective met |
| **P9.6** | WorkCenter | 3 | record edits append-only + attributable; counters reconcile with rows rather than drifting |
| **P9.7** | Shell · Sutra · Forensics · Twins | 5 | the SOP register being the authority it claims; twin composition determinism |
| **P9.8** | Investigation | 15 | case scope as a HARD boundary (recorded lesson: enforcement, not stub registration); one fingerprint across Ask/Methods/DataLab; staleness on scope change; `investigations` + `investigation_steps` currently untested |
| **P9.9** | UI (static only) | — | palette reachability; no answer surface reading `rawMatch`; **the v129 `derivation` SURFACED on the receipt** — a repair the user cannot see is not an honest repair; a view for the P6.3 registries |
| **P9.10** | Privacy / security | — | no network reachable outside `Routing/Providers`; PrivacyGate under every regime; injection defanged not obeyed on real document text; sensitive scope fail-CLOSED on a nil repo; erase leaves nothing including caches |

---

# PHASE 10 · RELEASE

| ID | # | who | item |
|---|---|---|---|
| **P10.1** | 46 | AGENT → OWNER witness | GO2 P5 + RC-1..7 ship gate → HOLD 2 |
| **P10.2** | 52 | AGENT | SPEC A6 gold additions → reseal #10 |
| **P10.3** | 53 | AGENT | SPEC §1+§3 UI surface deltas + RC checklist audit |
| **P10.4** | 16 | OWNER-deferred | D-17 document marking |
| **P10.5** | — | **OWNER** | Visual verification of the answer surface (P7.1 machine-checks everything beneath it) |

---

# PHASE 11 · BLOCKED ON A REAL SAMPLE — I can code, I cannot verify

| ID | item | needs |
|---|---|---|
| **P11.1** | EVTX BinXML templates | one real `.evtx` — highest forensic value of the four |
| **P11.2** | LZXPRESS Huffman (Win10+ Prefetch bodies) | one compressed `.pf` |
| **P11.3** | journald binary journals | one real journal (the `journalctl -o json` export already ingests) |
| **P11.4** | Shimcache | a real hive — overlaps Prefetch + Amcache, lowest value |

Each would ship a decoder that passes a fixture built from my own reading of the
spec — which proves only that I am self-consistent. A real sample is the only
thing that makes them verifiable, so they stay blocked rather than shipping on a
shared misunderstanding.

---

## MASTER SEQUENCE

```
P1.1 → P1.2 → P1.3 → P1.4          write path cannot corrupt silently
P2.1 … P2.7                        the "keep all" rulings wired
P3.1                               open-domain extraction  ← BEFORE the gate
P4.1 → P4.2 → P4.3 → P4.4          the report exists, proven on fixtures
   ⟶  P4.5   OWNER GATE: erase → re-ingest → send the report
P4.6                               triage the real run
P3.2 … P3.6                        rest of universality (rides the DRAIN —
                                   no second file re-ingest)
P5.1 → P5.2                        the chain is proven and stable
P6.1, P6.2, P6.3                   topics · history · registries
P7.1 → P7.2 → P7.3                 answers machine-checked, latency fixed
P8.1 → P8.2 → P8.3                 no unverified producer left
P9.1 … P9.10                       audit the omitted lanes
P10                                ship gate
P11                                if and when samples arrive
```

**Counts:** 11 phases · 45 numbered items · 38 AGENT · 4 OWNER · 3 shared.

## Still needed from you

1. **P6.2** — 3–5 subject names from your archive, including one deliberately
   ambiguous (two people, similar spelling).
2. Archive size, roughly — for an ETA only; work proceeds without it.

*(T1-7 is answered: database building. Folded into P3 and P6.3.)*
