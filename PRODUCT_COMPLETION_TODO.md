# PRODUCT_COMPLETION_TODO — everything remaining that I can do

**Assembled:** 2026-09-24, branch `v11-implement-all`, schema **v129**.
**Sources:** `PIPELINE_WORKFLOW.md` (findings F-1…F-10), `PIPELINE_MATRIX.md`
(generated wiring), the repo task list, and the owner's ruling of 2026-09-24:
**"keep all 5"** — nothing is removed, everything gets wired.

## How to read this

- Every item has **acceptance criteria**. "Done" means the criteria pass, not
  that code was written.
- **AGENT** = I can complete and verify it. **OWNER** = genuinely needs you
  (private data, a real sample, a product decision, GUI eyes).
- Tiers are ordered by dependency. Tier 0 precedes the re-ingest because a
  report over a ledger that can silently corrupt itself measures the wrong thing.
- Nothing here is "polish". Items I judged cosmetic are not listed.

---

## TIER 0 — write-path integrity · MUST precede the first re-ingest

### T0-1 · #83 · AGENT · Entity-insert failure cascades into wrong events
`IngestCoordinator.swift:1520` — `canonicalMapping = (try? await entities.insertBatch(raw)) ?? [:]`
then `:1544` writes events remapped through the empty mapping.
**Accept:** injecting a failing entities repository produces (a) zero events
carrying un-canonicalised references, and (b) a RECORDED failure. A test proves
both.

### T0-2 · #84 · AGENT · 11 swallowed write failures lose the reason
`:372`, `:398` (embeddings) · `:1042`, `:1067`, `:1123` (recursive member
ingest) · `:1146` (`linkBlocks`) · `:1544` (events) · `:1606` (relationships),
plus 5 more in `Knowledge/`.
**Accept:** every one either propagates or records a reason retrievable later;
`grep -rE "try\? await [a-zA-Z_.]*(insert|upsert|save|persist|link)" Ingestion/ Knowledge/`
returns only sites with a recorded-reason comment. Failed vs pending becomes
distinguishable for embeddings.

### T0-3 · #85 · AGENT · KO derivation transaction boundary (currently UNKNOWN)
**Accept:** a test that kills the work between `:1395` (chunks) and `:1520`
(entities) leaves the ledger either complete or honestly marked incomplete —
never a partial KO that looks finished. Whichever design is chosen (one
SAVEPOINT per KO, or a recorded resumable partial) is documented in
`PIPELINE_WORKFLOW.md`.

### T0-4 · AGENT · Guard against regression
**Accept:** an architecture test fails when a new `try?` appears on a persist in
`Ingestion/` or `Knowledge/` without a recorded reason. Pinned count, like the
existing 8 architecture guards.

---

## TIER 1 — wire the "keep all" rulings (no deletions)

### T1-1 · AGENT · `history_chapters` gets a consumer (F-2)
Written at `HistoryArtifactRepository.swift:77`, read nowhere. The suite's test
is named *"Save persists the full graph and reloads"* and asserts no chapter.
**Accept:** `load` returns chapters; a `chapterCount` helper exists; the
existing test asserts chapters round-trip — so its name stops overstating what
it proves; the history artifact surfaces chapters where the product intends them.

### T1-2 · AGENT · `knowledge_objects_fts` gets a reader (F-7)
Trigger-maintained on every KO write (`SchemaMigrations:1226–1234`), queried by
nothing.
**Accept:** a retrieval lane queries it, OR — if document-level FTS is genuinely
redundant against `chunks_fts` — the finding is closed with a recorded
measurement showing the redundancy. Either way the write stops being unexplained.

### T1-3 · AGENT · `qa_pairs_fts` + `synthetic_questions_fts` get producers (F-3)
Both have **no producer**: an index with no contents, so any query silently
returns nothing.
**Accept:** triggers or explicit inserts populate both; a test asserts a seeded
row is findable through the index.

### T1-4 · AGENT · `boilerplate_uses` gets a consumer (F-9)
Written at `BoilerplateRegistry:92`, never consulted — boilerplate associations
influence nothing today.
**Accept:** the embed-skip / dedup decision reads it, and a test shows a
repeated template affecting behaviour.

### T1-5 · AGENT · `history_alternative_accounts` gets a writer (F-10)
Has a test suite (`AlternativeAccountsTests`) and no writer — model built,
persistence never wired.
**Accept:** the history engine persists alternative accounts; the existing suite
exercises the real write path rather than an in-memory model.

### T1-6 · AGENT · `evidence_block_edges` gets a producer (F-10)
A block-to-block graph lane, permanently empty.
**Accept:** either the producer is implemented (block adjacency / reply-to /
continuation edges) or it is recorded as DEFERRED-KEPT with the reason and
exempted from the guard. Owner keeps the schema either way.

### T1-7 · AGENT · `people` / `companies` / `projects` / `timelines` — canonical registries
**Owner ruling 2026-09-24: these are for DATABASE BUILDING.** So they are neither
dead schema nor a UI grouping — they are the canonical registries the ledger is
meant to accumulate: one row per real person, organisation and project, and one
timeline per subject, distinct from `entities` (which holds mentions unified by
alias).
**Depends on TIER U.** Their producers can only be as broad as extraction is; a
registry fed by 11 domain packs is a registry of 11 domains. Build these AFTER
U-1/U-2 so the registries are universal from their first row.
**Accept:** each has a producer fed by the open extractor; every row cites the
evidence that created it; a second build is idempotent (registries merge, never
duplicate — the defect class that gave 9,266 fact rows for 387 distinct facts).

### T1-8 · AGENT · POA grantor recovered via the sharper discriminator
Kept per your ruling — so the name must be stored, WITHOUT readmitting the
witnessed junk ("acknowledge receipt" ×82, "need patent agent" ×82).
Measured: `roleStopwords` alone does not catch those, so the uppercase rule is
load-bearing and must not simply be relaxed.
**Design:** tighten the POA pattern's continuation set to the document FORMULA
("having" / "son of" / "daughter of" / "residing" / "nationality") and drop the
bare `of` alternative — `of` is what lets "I acknowledge receipt **of** …" match
at all. With the pattern sharpened, a lowercase name from that formula can be
stored at reduced confidence.
**Accept:** `I, shirshendu sasmal having Nationality of India` yields
`applicant`; the four witnessed junk strings still yield zero applicant facts;
the `withKnownIssue` red in `PatentDomainPackTests` is removed, not re-wrapped.

---

## TIER U — UNIVERSALITY · the central promise, currently unmet

**Why this tier exists.** The owner asked whether the existing list makes the
product universal. It does not. Tiers 0–8 make what exists *correct and
verified*; none of them make it *general*. Measured today:

| layer | universal? | evidence |
|---|---|---|
| Formats | mostly | 36 FULL + 7 PARTIAL, plugin registry, TextLoader fallback |
| Storage model | **YES** | `GenericFact` is domain-neutral; `FactSchemaRegistry` states "Open — an unknown field is `.text`, never dropped" |
| **Fact production** | **NO** | every fact comes from **11 fixed domain packs** in `Knowledge/Ontology/DomainPacks/` |
| **Fact typing** | **NO** | `FactTypeClassifier` is a CLOSED enum — person / org / project / deliverable / contract / invoice / delivery / meeting / email / task, plus `other`. A commercial + project-management taxonomy |
| LLM assist | NO | `LLMSlotExtractor` fills slots of an ALREADY-KNOWN fact type's schema (its own header says so) and is not on the ingest path — it runs via `OntologyBackfill` |
| Ask side | partly | `SlotFieldResolver.vocabulary` is ~25 fixed phrases; the F8 `<word> number|date` fallback is the one genuinely open mechanism |
| Language | NO | English-only; multilingual is v2 |

**The consequence, plainly:** a shipping manifest, a car service record, a school
report, a lab instrument log, an insurance claim, a building permit — each yields
chunks and **zero facts**. The answer then falls back to quoting passages instead
of answering from structure. The database-in-the-middle, which is the moat, is
empty for any domain nobody hard-coded.

**Sequencing relief.** `LedgerDrainCoordinator` pass 2 re-derives GenericFacts
from the STORED `EvidenceBlocks`, not from the original files. So landing TIER U
*after* a re-ingest costs a **drain**, not a second full re-ingest. Universality
does not have to block the first step.

### U-1 · AGENT · Open-domain labeled-field extractor — highest leverage here
Real documents state facts as `Label: value`, `Label — value`, or a two-column
table, whatever the domain. A domain-AGNOSTIC extractor capturing any such pair,
normalising the label to a field id and storing a `GenericFact`, gives structure
on documents no pack anticipated. It removes the need for 11 packs to become 50.
**Gates required** — the same discipline as the C-4/OCR work, which is why that
came first: label plausibility (not prose, not a sentence fragment); value
plausibility (reuse `FactValuePlausibility`); block-kind awareness (a table cell
outranks a paragraph); per-document dedup; and a cap so one junk page cannot
mint 400 fields.
**Accept:** fixtures from ≥6 domains nobody hard-coded (shipping, vehicle
service, school report, utility bill, insurance, permit) each yield correct
fields; the existing 11-pack fixtures produce output IDENTICAL to today — this
must ADD, never perturb; a noisy page mints nothing.

### U-2 · AGENT · Open fact-type taxonomy
`FactTypeClassifier`'s closed enum becomes the KNOWN subset of an open space: a
derived string type id is allowed, the enum stays the curated core, and
`_unclassified` stops being a dead end that `DataHealthCheck` counts as a defect.
**Accept:** an out-of-taxonomy document receives a stable derived type id rather
than `.other`; the health probe separates "genuinely novel type" from
"classifier failed"; known types keep today's behaviour exactly.

### U-3 · AGENT · LLM schema induction — evidence-bound and budgeted
For prose with no label/value structure, have the on-device model PROPOSE a field
set, then validate deterministically: every proposed value must appear verbatim
in a cited block or it is discarded. That is how open-domain extraction stays
inside the evidence gate instead of becoming generation.
**Accept:** no proposed value survives without a verbatim span in a cited block;
the call budget holds (a per-document tier-2 cost, never per-question); with the
model unavailable the lane is a no-op that SAYS so — never a silent gap.

### U-4 · AGENT · Ask-side universality
Resolve a question against the ACTUAL field inventory in the ledger — which U-1
makes open — instead of a fixed phrase list. Generalise the F8 fallback.
**Accept:** "what is the chassis number", "who was the attending physician",
"what was the policy number" resolve to fields the ledger holds with no new
vocabulary entries; the honest field-named not-found still fires when the field
is genuinely absent.

### U-5 · AGENT · Format universality closure
**Accept:** every binary type without a loader is reported PRESERVED-ONLY with a
reason, never silently empty; `SUPPORTED_SOURCES.md` is GENERATED from the
registry rather than hand-maintained, so the claim and the code cannot diverge.

### U-6 · AGENT · Language honesty — universality's other axis
English-only today. Full multilingual is v2, but silent mis-extraction is not
acceptable now.
**Accept:** language is DETECTED per document and recorded; a non-English
document is marked as such and its extraction limits appear in the Ingestion
Report, instead of quietly producing nothing.

---

## TIER 2 — the first step: erase → re-ingest → verify

### T2-1 · #81 · AGENT · Generated producer/consumer/test map + coverage guard
Already built and self-checking (`scripts/pipeline-matrix.py`).
**Remaining accept:** the "produced but untested" count (17) becomes a PINNED
number, so a new table cannot ship without a test or a recorded exemption.

### T2-2 · #72 · AGENT · Ingestion Report
**Accept:** one artifact answering "is the ingestion proper?" — discovered vs
ingested vs failed with every gap grouped BY FORMAT and reason;
`extraction_status` distribution per `detected_type` with top parser warnings;
coverage (chunks / embeddings / FTS) always with denominators; facts by field;
v129 `derivation` counts; and an explicit list of what could not be measured.
No percentage without its denominator; no zero that might mean "no data".

### T2-3 · #73 · AGENT · Prove the report on fixtures first
**Accept:** running ProjectDelta + the noise fixtures through the real pipeline
produces the report, and it shows the OCR fixture's patentNumber as
`OCR_CORRECTED` and the split letter's as `CROSS_BLOCK_ASSEMBLED` — proving the
run exercised the new extraction end to end.

### T2-4 · #74 · AGENT · Pre-flight stamp + erase proof
**Accept:** the report's header carries build SHA, schema `user_version` (129),
producer versions, and **which optional loaders are ON** (a run with Messages
off must not look like "Messages produced nothing"). Erase asserts zero rows in
every table enumerated from `sqlite_master` — not a hardcoded list — and reports
VACUUM file size before/after.

### ⟶ OWNER GATE: your erase + re-ingest
Backup → rebuild in Xcode → confirm AI is **not** in Fully-private (topics build
only when the model is up, and an empty topic layer with no error has cost us
before) → erase → re-ingest → send me the report.

### T2-5 · #75 · AGENT · Triage what the report flags
Blocked on your run. The item I expect to matter most: `derivation` counts far
above expectation would mean my OCR / cross-block gates are too loose on real
data — the risk I flagged when landing them, and only your archive can settle it.

---

## TIER 3 — prove the chain end to end

### T3-1 · #76 · AGENT · Golden Thread
**Accept:** one seeded document traced BY ID — file → `source_version` →
`EvidenceBlock` → chunk (+FTS) → embedding → `GenericFact` (+anchor) → topic →
history item → retrieval hit → **answer citation** back to that exact block. A
broken link names the stage. Plus a negative thread: an unrecoverable fact breaks
the chain at a NAMED stage with an honest reason, never a silent answer.

### T3-2 · #80 · AGENT · Whole-chain fixed point
**Accept:** on an unchanged corpus — second ingest writes zero new rows; second
extraction mints zero new facts; second topic build is byte-identical; second
history build is byte-identical; an identical ask returns identical citations.
Report the diff table by table. Precedent: 9,266 fact rows collapsing to 387
distinct, and topics growing 92→143 on rebuild.

---

## TIER 4 — the structural layers

### T4-1 · #77 · AGENT · Topic layer
**Accept:** "0 topics" always carries a REASON (model up or down — attempted vs
produced); every topic's `sourceObjectIDs` resolve; a second rebuild over an
unchanged ledger is byte-identical (the 92→143 defect cannot recur); coverage is
reported with a denominator; topics do not mix subjects sharing no evidence.

### T4-2 · #78 · OWNER→AGENT · History per subject
**Needs from you:** 3–5 subject names from your archive — ideally one
well-documented, one thin, and one **ambiguous** (two people, similar spelling).
The ambiguous one is the most valuable: it proves we return *ambiguous* rather
than silently picking.
**Accept:** per subject — every item cited and resolvable; zero leakage from
other subjects; a no-canonical-id subject returns empty AND flagged; ambiguity
reported as ambiguity; deterministic across two runs; no 1601/1970 sentinel
dates leaking as real; and the artifact states what it could not place in time.

---

## TIER 5 — answers

### T5-1 · #79 · AGENT · Headless answer harness
Closes the standing hole that I cannot press Ask.
**Accept:** a fixed question set runs through the real `MasterBrain` path and
exports, per question: answer text; every citation WITH a resolution check;
quality-strip numbers that RECONCILE with the retrieval set used; the
`ReasoningTrace`; and the evidence-gate decision. Assertions — not just capture:
no citation outside the retrieval set, no claim without evidence, every refusal
names what was missing. Question shapes must include slot, date, money (the
`how much` case just fixed), existence, list, comparison, story, role, a
known-absent field, and one whose answer comes from a repaired value.

### T5-2 · #71 · AGENT · Reranker latency
`BGETokenizer` costs **3.6 s per 1 KB passage** at query time
(`CoreMLCrossEncoderTier`), so a top-20 rerank exceeds a minute. Not the ingest
path — the embedder's `BERTWordPieceTokenizer` is 0.62 ms and fine.
**Accept:** a token-parity test proves IDENTICAL output over a corpus BEFORE the
scan changes (cross-encoder scores drive ranking; drifting tokens silently
reorder answers), then per-passage cost drops by an order of magnitude.
`BERTWordPieceTokenizer` is fast — borrow its algorithm rather than inventing one.

### T5-3 · AGENT · Reconcile the eighth retrieval layer (F-8)
`bondLayer` (`HybridRetriever:918`) sits between Graph and Vector; CLAUDE.md
documents seven layers.
**Accept:** the documented invariant and the code agree. The doc is what
reviewers check against, so one of the two changes.

---

## TIER 6 — close the verification gaps

### T6-1 · AGENT · Test the untested producers
From `PIPELINE_MATRIX.md`: `assertions` (no test names it at all),
`entity_aliases`, `narrativeSlotExtractor`, boilerplate, `derived_objects`,
`embedding_cache`, `enrichment_status`, `entity_cooccurrences`, `event_versions`,
`monitor_snapshots`, `review_*`, `saved_*`, `screening_*`, `investigation_steps`.
**Accept:** the pinned untested count reaches zero or every remainder carries a
recorded exemption.

### T6-2 · AGENT · Resolve the four UNKNOWNs
Stated as unknown in `PIPELINE_WORKFLOW.md` rather than assumed:
`narrativeSlotExtractor` (`:1576`) writes what, read by what; `document_profiles`
/ `derived_objects` / `enrichment_status` / `event_versions` semantics; whether
any retrieval query is unbounded (no LIMIT) on a large ledger.
**Accept:** each becomes OK / RISK / GAP with evidence; unbounded queries get a
bound or a recorded reason.

### T6-3 · AGENT · Full-suite completion
Two `RunAllTests` runs both stopped after ~3,500 of ~4,700 with ~1,220 "No
result" — a consistent cutoff, no crash, most likely a harness budget.
**Accept:** either the whole suite completes in one run, or the two-pass
protocol (run, then explicitly re-run the "No result" suites) is scripted and
recorded as the official acceptance method — so "green" is never claimed from a
partial run again.

---

## TIER 7 — release

| id | item | who |
|---|---|---|
| **#46** | GO2 P5 + RC-1..7 ship gate → HOLD 2 | AGENT → OWNER witness |
| **#52** | SPEC A6 gold additions → reseal #10 | AGENT |
| **#53** | SPEC §1+§3 UI surface deltas + RC checklist audit | AGENT |
| **#16** | D-17 document marking | OWNER-deferred |
| — | GUI verification of the answer surface | **OWNER** (T5-1 covers everything beneath it) |

---

## TIER 8 — blocked on a real sample (I can code, I cannot verify)

| item | needs |
|---|---|
| EVTX BinXML templates | one real `.evtx` — highest forensic value of the four |
| LZXPRESS Huffman (Win10+ Prefetch bodies) | one compressed `.pf` |
| journald binary journals | one real journal (the `journalctl -o json` export already ingests) |
| Shimcache | a real hive — overlaps Prefetch + Amcache, lowest value |

Each would ship a decoder that passes a fixture built from my own reading of the
spec — which proves only that I am self-consistent. A real sample is the only
thing that makes them verifiable, so they stay blocked rather than shipping on a
shared misunderstanding.

---

## Sequencing summary

```
T0-1 → T0-2 → T0-3 → T0-4          write path cannot corrupt silently
T1-1 … T1-6, T1-8                  wire the "keep all" rulings
T2-1 → T2-2 → T2-3 → T2-4          the report exists and is proven on fixtures
        ⟶ OWNER: erase + re-ingest
T2-5                               triage the real run
U-1 → U-2 → U-3 → U-4 → U-5/U-6    UNIVERSALITY (a drain re-derives facts from
                                   stored blocks, so NO second file re-ingest)
T1-7                               canonical registries, once extraction is open
T3-1 → T3-2                        the chain is proven and stable
T4-1, T4-2                         topics + history on real data
T5-1 → T5-2 → T5-3                 answers machine-checked, latency fixed
T6-1 → T6-2 → T6-3                 no unverified producer left
T7                                 ship gate
```

## Still needed from you

1. ~~T1-7~~ — **answered 2026-09-24: database building.** Folded into TIER U.
2. **T4-2** — 3–5 subject names, including one deliberately ambiguous.
3. Archive size, roughly — only for an ETA; I will proceed without it.
