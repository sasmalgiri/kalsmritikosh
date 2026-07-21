> **DOC STATUS: PARTIALLY SUPERSEDED** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Directional; verify against current code. _(bannered 2026-07-22, GOV-002.)_

# Three Independent Systems — Implementation

**Kalsmritikosh** ships three selectable architectures in **one codebase, no forks**.
You pick one in **Settings → System mode**; it takes effect on next launch. The
retrieval / RAG / expert / verifier / ledger **answer stack is identical across all
three** — only *how much meaning is extracted, and when* changes.

This document records what was built and how, as of commit `886e662` (2026-07-02).

---

## 1. The core idea: one engine per system

Before, the three modes shared a tangle of `if systemMode == .x` checks scattered
through `AppState` and inside the background promoters. System 2 quietly collapsed
into System 3 because its distinguishing engine could never actually run.

Now each architecture is a **self-contained engine** you can read top-to-bottom in
one file. Exactly **one** engine is constructed at boot from the active `SystemMode`;
the other two are never even instantiated, so no engine needs to self-gate on mode.

### Files (`Kalsmritikosh/Knowledge/Ledger/`)
| File | Role |
|------|------|
| `SystemEngine.swift` | `protocol SystemEngine` (`mode`, `ingestPolicy`, `activate`, `deactivate`, `onAnswer`), `SystemEngineContext` (repos + closures the engine needs), `SystemEngineFactory.make(mode)` |
| `FullLLMEngine.swift` | System 1 |
| `HotWarmColdEngine.swift` | System 2 |
| `LedgerEventDrivenEngine.swift` | System 3 |

### How AppState wires it (in `AppState.boot`)
```
let engine = SystemEngineFactory.make(FeatureFlags.systemModeValue())
let basePolicy = engine.ingestPolicy               // per-system ingest policy
// generic plumbing driven by the policy (+ advanced FeatureFlags overrides OR'd in):
IncrementalUpdater(distillationEnabled: basePolicy.eagerMemoryDistillation || override)
if basePolicy.contextPrefixBackfill || override { ContextPrefixBackfiller(...).start() }
// hand the engine its dependencies and let it start its OWN maintenance:
await engine.activate(SystemEngineContext(enrichment, objects, entities, events,
                                          distiller, scanForGaps, onGapScan, bumpCitations))
self.systemEngine = engine
```
`recordAnswer(...)` now just calls `await systemEngine?.onAnswer(answer)` — all
mode-specific answer behaviour lives in the engine, not in AppState.

Adding a fourth system later = one new engine file + one case in the factory.

---

## 2. System 1 — Full LLM (deepest, slowest)

**Identity:** eager, deep enrichment of *everything* at ingest.

- `ingestPolicy = (eagerMemoryDistillation: true, contextPrefixBackfill: true)`.
- At ingest: per-subject **memory distillation** (`IncrementalUpdater` with distillation
  on) **and** a **context-prefix** on every chunk that is re-embedded so the LLM work
  improves retrieval (`ContextPrefixBackfiller`).
- No background promoter — there is nothing left to promote; it's all done up front.
- Cost: ~10 h / 100 MB. This is the reference baseline (the default mode).

**Status: complete and unchanged** by this work (the refactor kept it intact).

---

## LLM-per-ingest ladder (the defining difference)

The three modes sit on a clear ladder of how much LLM runs *at ingest*:

| Mode | Ingest LLM |
|------|-----------|
| **1 · Full LLM** | an LLM context-prefix on **every chunk** (+ re-embed) + memory distillation on every subject |
| **2 · Hot/Warm/Cold** | **one document-card call per file** (first chunk) + deep LLM on the **hot slice** only |
| **3 · Ledger** | **one document-card call per file** (first chunk) — nothing else; LLM otherwise at query time |

The "document card" is the Stage-2 idea from the Ledger-Construction / LLM-Reduction
specs: one LLM call on a file's first chunk to capture a document-level gist, written
as the chunk's context-prefix and re-embedded so it improves retrieval. It's
implemented as a `firstChunkPerObjectOnly` mode on `ContextPrefixBackfiller`, gated by
`EnrichmentPolicy.firstChunkCard` (true for Systems 2 & 3, redundant for System 1 which
already prefixes every chunk).

## 3. System 2 — Hot / Warm / Cold (tiered)  ← the main fix

**Identity:** cheap rule-based ingest **＋ one document-card LLM call per file**; spend
the deep LLM budget only on *important* docs.

**What was broken:** importance was only bumped by **citations** (`recordAnswer`).
On a fresh archive with no Q&A, every document stayed cold, so `TierPromoter` had
nothing to promote — System 2 behaved exactly like System 3.

**The fix — proactive structural tiering:**
- `ImportanceScorer.score(...)` gained two structural terms:
  `+ entityCount * 0.25 + eventCount * 0.75` (on top of citations, pins, recency).
  A document dense with extracted people/dates/events is important *on arrival*.
- `TierPromoter` now runs **two idle passes**:
  1. **Score** — walk the corpus in rolling batches (`objects.allIDs` cursor), count
     each object's entities (`findByMentionSource`) + events (`findBySourceObject`),
     combine with persisted citations/pins, and re-tier cold / warm / hot.
  2. **Enrich** — deep-enrich the un-enriched **hot** slice via memory distillation.
- `HotWarmColdEngine` owns the `TierPromoter`; `onAnswer` folds citations back in as
  a strong usage vote (via `context.bumpCitations`), applied on the next scoring pass.

**Verified on the real corpus (121 docs, zero questions asked):**

| Tier | Count |
|------|-------|
| Hot (importance ≥ 8) | 11 |
| Warm (3–8) | 77 |
| Cold (< 3) | 33 |

Top document: 91 entities + 50 events → importance 62. Tiers now populate **without
any Q&A**, which is the whole point of System 2.

**Status: complete.**

---

## 4. System 3 — Ledger event-driven (fastest)

**Identity:** near-zero-LLM ingest (rules **＋ one document-card call per file**); memory
warmed on demand; the system proactively maintains a rule-based **gap** layer and
**contradiction** layer during idle.

- `ingestPolicy = (eager: false, fullPrefix: false, firstChunkCard: true)` — rule
  extractors fill the ledger + one LLM card per file; no per-chunk LLM.
- `LedgerEventDrivenEngine` owns the `LedgerPromoter`, which on idle re-runs the gap
  and contradiction scans (no LLM).

### 4a. Gap detection — now all three rules (`AppState.scanForGaps`)
`GapDetector` had three rules but only one was wired. Now all three run:

| Rule | What it flags | Data source |
|------|---------------|-------------|
| `detectSequenceGaps` | holes in numbered runs (invoice/payment #s) | `entities.list(kind:)` |
| `detectDanglingReferences` | "invoice #42" mentioned but never ingested | bounded `objects.load` sample bodies + known invoice numbers |
| `detectThreadParent` | a `Re:`/`Fwd:` whose original wasn't ingested | email subjects from `metadata["subject"]`; a reply "has parent" iff a non-reply shares its normalized subject |

Helpers added: `isReplySubject`, `normalizeSubject` (strips `Re:`/`Fwd:`), `integers(in:)`.

**Verified on the real corpus:** 29 reply emails → **11 orphaned** (no ingested
parent). Invoice rules correctly find ~0 here because the archive has no invoice
sequences (only 2 junk `invoiceNumber` entities) — a data-shape reality, not a bug.

### 4b. Contradiction layer — newly finished (schema v31)
The `contradictions` table existed but nothing wrote to it. Now:

| File | Role |
|------|------|
| `Core/Models/Contradiction.swift` | model: `description`, `claimA`/`claimB`, `evidenceA`/`evidenceB`, `Severity {low,medium,high}`, `Status {open,resolved,dismissed}` |
| `Knowledge/Ledger/ContradictionDetector.swift` | pure, rule-based, no LLM |
| `Storage/Repositories/ContradictionsRepository.swift` | `insert`/`insertMany`/`open`/`all`/`setStatus`/`clear`/`count` |

**Rule — same-event temporal conflict:** group events by *kind + normalized title*;
within a group, if two **independent** sources (different `sourceObjectID`) date the
event more than 2 days apart, flag a contradiction. Only day-precision-or-finer dates
are compared (a month-precision "in March" can't contradict "March 14"). Severity
scales with the date gap and both sides' `dateConfidence`. **Both claims + both
sources are always kept — never averaged away** (the evidence-gate contract).

Wiring: `AppState.scanForContradictions()` persists the open set and updates
`proactiveContradictionCount`; System 3's idle maintenance runs it alongside the gap
scan; `InsightsView` shows a **Contradictions** section (both claims, severity pill,
dismiss).

**Verified on the real corpus:** same-title events genuinely conflict across sources —
e.g. a patent-intimation email dated **58.8 days** apart across 6 sources, an alert
**51.8 days** apart across 12. (Note: title-grouping is a heuristic; generic/recurring
titles like "email" can produce false positives — hence the per-row **Dismiss**.)

**Status: complete in code.** The invoice gap rules and investigation (Fishbone /
5-Whys) are wired but data-dependent; they surface results only where the corpus has
the relevant shape (invoice sequences / causal links).

---

## 5. How each system differs, at a glance

| | System 1 Full LLM | System 2 Hot/Warm/Cold | System 3 Ledger |
|---|---|---|---|
| Ingest LLM | Every chunk + distillation | 1 card/file + hot slice | 1 card/file |
| Memory distillation | At ingest, all subjects | On idle, hot slice | On demand (query time) |
| Context-prefix | Every chunk (+re-embed) | Document card, first chunk/file | Document card, first chunk/file |
| Background engine | none | `TierPromoter` (score + enrich) | `LedgerPromoter` (gaps + contradictions) |
| Populates without Q&A | n/a (all up front) | **Yes** (structural tiers) | **Yes** (gaps + conflicts) |
| Ingest cost | Highest (~10 h/100 MB) | Medium | Lowest |

---

## 6. Verification performed

- **Build:** green (`BuildProject`).
- **Capability discipline:** grep guard clean — no model names in the new files.
- **Real-data audit** (snapshot of the production `knowledge.sqlite`, 121 objects /
  835 entities / 354 events, live DB never modified): System 2 tier distribution,
  System 3 orphaned-reply count, and contradiction date-conflicts all confirmed
  against real rows (numbers above).

### Not yet done / honest caveats
- **Live in-app run requires a relaunch.** The production DB is at schema **v28**;
  the `enrichment_status`, `gap_nodes`, and `contradictions` tables are created by
  migrations v29→v31, which run automatically on next launch. Verification above was
  done by running the logic against a real-data snapshot, not through the running app.
- **Query-hit signal** for System 2 is intentionally *not* wired — it would touch the
  shared `HybridRetriever`, and the architecture invariant requires retrieval to be
  identical across modes. Structure + citations are sufficient to tier.
- **Contradiction title-grouping** is a heuristic and will occasionally group
  unrelated same-titled events; the UI offers Dismiss for these.
- Entity-extraction quality (e.g. junk `invoiceNumber` values like "for"/"Serial")
  is a separate concern, out of scope here.
- **Ingest-time "/100 MB" estimates are reference-config, not your Mac.** The numbers
  in Settings and the file-type guide assume a baseline machine
  (`IngestEstimator.referenceMachineDescription` — a modern Apple-silicon Mac, local
  ~8B model at ~3.5 s/LLM call), and the UI now says so explicitly. After the first
  LLM-heavy ingest, `CalibrationStore` measures this Mac's real throughput and the
  estimate switches from "reference config" to "calibrated to THIS Mac."

---

## 6b. Choosing a mode (UI)

- **First run** (`FeatureFlags.systemModeChosen == false`): the app entry awaits
  `AppState.awaitModeSelectionIfNeeded()` **before** `boot()`, so a `ModeChooserView`
  sheet (three cards with label, detail, and est /100 MB) is shown first and boot waits
  on a continuation. Picking a mode (`chooseMode`) writes the flag + mode and unblocks
  boot — the engine builds in the chosen mode, **no relaunch**. The sheet can't be
  dismissed without choosing on first run.
- **Active-mode badge**: the sidebar shows the running mode (icon + short label) at all
  times, plus an "N new" chip counting files the folder watcher discovered this launch
  (`AppState.newFilesSinceLaunch`). Tapping it re-opens the chooser.
- **Changing mode later / new files mid-session**: mode is a **boot-time** decision (the
  ingest `invalidations` stream has a single consumer, so the running engine can't be
  hot-swapped). A change made after boot is saved and applies on the next launch; the
  chooser shows an "applies on next launch" note in that case. New files are surfaced via
  the badge rather than a blocking modal, so the user is never interrupted mid-work.

## 7. Next steps (when you compare the three and pick a winner)

1. **Relaunch** and let each mode's idle maintenance populate its tables; compare the
   Live "Enrichment tiers" panel (System 2) and Insights gaps/contradictions (System 3).
2. Decide the winner per your evaluation, then delete the other two engine files +
   their factory cases — nothing else in the answer stack changes.
